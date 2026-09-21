from __future__ import annotations

import json
import shlex
import threading
import time
from datetime import datetime

import typer
from rich.console import Console
from rich.table import Table

from .clustering import cluster, save_plan
from .config import Settings
from .db import Database, loads
from .embedding import LocalEncoder, download_model
from .locking import app_lock
from .operations import apply_plan, edit_plan, plan_rows, preview_moves, undo_batch
from .scanner import scan as run_scan

app = typer.Typer(help="本地、可解释、可撤销的 macOS Downloads 整理器", no_args_is_help=True)
model_app = typer.Typer(help="管理离线语义模型")
app.add_typer(model_app, name="model")
console = Console()


def _open() -> tuple[Settings, Database]:
    settings = Settings.load()
    db = Database(settings.database)
    recovered = db.recover_interrupted()
    if recovered:
        console.print(f"[yellow]已核对 {recovered} 个上次中断的操作批次。[/yellow]")
    return settings, db


@model_app.command("download")
def model_download(revision: str = typer.Option("main", help="Hugging Face revision；解析后会锁定 commit")) -> None:
    """显式下载模型并记录不可变的解析版本。"""
    settings = Settings.load()
    with app_lock(settings.data_dir):
        manifest = download_model(settings, revision)
    console.print(f"模型已保存到 {settings.model_dir}")
    console.print(f"锁定版本：{manifest['resolved_revision']}")


@app.command()
def scan() -> None:
    """扫描 Downloads 顶层并更新本地索引。"""
    settings, db = _open()
    try:
        with app_lock(settings.data_dir):
            stats = run_scan(db, settings)
        console.print(
            f"扫描完成：新增/更新 {stats['scanned']}，未变化 {stats['unchanged']}，"
            f"跳过 {stats['skipped']}，提取错误 {stats['errors']}"
        )
    finally:
        db.close()


def _render_plan(db: Database, settings: Settings, plan_id: int) -> None:
    rows = plan_rows(db, plan_id)
    grouped: dict[str, list] = {}
    for row in rows:
        grouped.setdefault(row["group_name"] or "Unclassified", []).append(row)
    console.print(f"\nProposed organization (plan {plan_id}):")
    for group, members in grouped.items():
        confidence = max(float(row["confidence"]) for row in members)
        label = f"[{group}]" if group == "Unclassified" else f"[{group}] confidence={confidence:.2f} (启发式)"
        console.print(f"\n[bold]{label}[/bold]")
        for row in members:
            status = " [dim](excluded)[/dim]" if row["excluded"] else ""
            console.print(f"  #{row['id']} {row['name']}{status}")
        reasons = loads(members[0]["reasons"], [])
        if reasons:
            console.print("  [dim]依据：" + "；".join(reasons) + "[/dim]")


@app.command()
def propose(
    json_output: bool = typer.Option(False, "--json", help="输出机器可读 JSON"),
    no_model: bool = typer.Option(False, help="即使已下载模型也跳过语义向量"),
) -> None:
    """基于当前索引生成并保存整理建议。"""
    settings, db = _open()
    try:
        encoder = None
        if not no_model and (settings.model_dir / "organizer-model.json").exists():
            encoder = LocalEncoder(settings)
        with app_lock(settings.data_dir):
            groups, unclassified = cluster(db, settings, encoder=encoder)
            plan_id = save_plan(db, settings, groups, unclassified)
        if json_output:
            payload = {
                "plan_id": plan_id,
                "groups": [group.as_dict(settings.organized_dir) for group in groups],
                "unclassified": [str(file.path) for file in unclassified],
                "semantic_model_used": encoder.version if encoder else None,
            }
            typer.echo(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            _render_plan(db, settings, plan_id)
            if encoder is None:
                console.print("\n[yellow]未使用语义模型；运行 model download 可启用离线语义相似度。[/yellow]")
            console.print(f"\n审阅：downloads-organizer review {plan_id}")
    finally:
        db.close()


REVIEW_HELP = """命令：
  list
  rename <旧主题> <新主题>
  move <成员编号> <主题>
  split <成员编号> <新主题>
  merge <源主题...> <目标主题>
  exclude <成员编号>
  folder <主题> <Organized 内已有目录>
  done
"""


@app.command()
def review(plan_id: int) -> None:
    """在终端中修订分组方案；不会移动文件。"""
    settings, db = _open()
    try:
        if not db.conn.execute("SELECT 1 FROM plans WHERE id=?", (plan_id,)).fetchone():
            raise typer.BadParameter(f"方案 {plan_id} 不存在")
        _render_plan(db, settings, plan_id)
        console.print(REVIEW_HELP)
        while True:
            try:
                parts = shlex.split(typer.prompt("review"))
            except (EOFError, KeyboardInterrupt):
                console.print("\n审阅已保存。")
                break
            if not parts:
                continue
            if parts[0] in {"done", "quit", "exit"}:
                db.conn.execute("UPDATE plans SET status='reviewed' WHERE id=?", (plan_id,))
                db.conn.commit()
                console.print("审阅已保存。")
                break
            if parts[0] in {"help", "?"}:
                console.print(REVIEW_HELP)
                continue
            if parts[0] == "list":
                _render_plan(db, settings, plan_id)
                continue
            try:
                with app_lock(settings.data_dir):
                    console.print(edit_plan(db, plan_id, parts[0], parts[1:], settings.organized_dir))
            except (ValueError, RuntimeError) as exc:
                console.print(f"[red]{exc}[/red]")
    finally:
        db.close()


@app.command("apply")
def apply_command(plan_id: int, yes: bool = typer.Option(False, "--yes", "-y", help="跳过确认")) -> None:
    """确认并执行已保存方案中的移动。"""
    settings, db = _open()
    try:
        moves = preview_moves(db, settings, plan_id)
        if not moves:
            console.print("方案中没有需要移动的文件。")
            raise typer.Exit()
        table = Table("源文件", "目标", "状态")
        for item in moves:
            table.add_row(str(item["source"]), str(item["destination"]), "已变化" if item["stale"] else "就绪")
        console.print(table)
        if not yes and not typer.confirm("执行以上移动？"):
            raise typer.Abort()
        with app_lock(settings.data_dir):
            batch_id, results = apply_plan(db, settings, plan_id)
        moved = sum(r["status"] == "moved" for r in results)
        console.print(f"批次 {batch_id}：已移动 {moved}/{len(results)} 个文件。")
        for result in results:
            if result["error"]:
                console.print(f"[yellow]跳过 {result['source']}：{result['error']}[/yellow]")
    finally:
        db.close()


@app.command()
def history(limit: int = typer.Option(30, min=1, max=500)) -> None:
    """显示整理与撤销历史。"""
    _, db = _open()
    try:
        rows = db.conn.execute(
            "SELECT * FROM operation_batches ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
        table = Table("批次", "类型", "状态", "方案", "时间")
        for row in rows:
            table.add_row(str(row["id"]), row["kind"], row["status"], str(row["plan_id"] or ""),
                          datetime.fromtimestamp(row["created_at"]).strftime("%Y-%m-%d %H:%M:%S"))
        console.print(table)
    finally:
        db.close()


@app.command()
def undo(batch_id: int) -> None:
    """验证文件身份后撤销一个整理批次。"""
    settings, db = _open()
    try:
        with app_lock(settings.data_dir):
            undo_id, results = undo_batch(db, settings, batch_id)
        done = sum(r["status"] == "undone" for r in results)
        console.print(f"撤销批次 {undo_id}：已恢复 {done}/{len(results)} 个文件。")
        for result in results:
            if result["error"]:
                console.print(f"[yellow]跳过 {result['source']}：{result['error']}[/yellow]")
    finally:
        db.close()


class _EventHandler:
    def __init__(self, wake: threading.Event):
        self.wake = wake

    def dispatch(self, event) -> None:
        if not event.is_directory:
            self.wake.set()


@app.command()
def watch(interval: int = typer.Option(300, min=10, help="补扫间隔（秒）")) -> None:
    """以前台进程监控 Downloads；只更新索引，不移动文件。"""
    from watchdog.observers import Observer

    settings, db = _open()
    wake = threading.Event()
    observer = Observer()
    observer.schedule(_EventHandler(wake), str(settings.downloads), recursive=False)
    observer.start()
    console.print(f"正在监控 {settings.downloads}。按 Ctrl-C 停止。")
    try:
        with app_lock(settings.data_dir):
            initial = run_scan(db, settings, wait_for_stability=True)
        console.print(f"初始索引：更新 {initial['scanned']} 个文件，{initial['errors']} 个错误")
        while True:
            wake.wait(interval)
            wake.clear()
            time.sleep(1)  # merge event bursts before the stability check
            with app_lock(settings.data_dir):
                stats = run_scan(db, settings, wait_for_stability=True)
            if stats["scanned"] or stats["errors"]:
                console.print(f"索引已更新：{stats['scanned']} 个文件，{stats['errors']} 个错误")
    except KeyboardInterrupt:
        console.print("监控已停止。")
    finally:
        observer.stop()
        observer.join(timeout=5)
        db.close()


if __name__ == "__main__":
    app()
