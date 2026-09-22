from __future__ import annotations

import json
import shlex
import threading
import time
from datetime import datetime
from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

from .automation import DailyAutomationService
from .benchmark import run_benchmark
from .config import Settings
from .db import Database, loads
from .embedding import NativeMacOSEncoder, native_status
from .locking import app_lock
from .operations import (
    apply_plan,
    edit_plan,
    plan_destination_root,
    plan_rows,
    preview_moves,
    undo_batch,
)
from .preferences import PreferenceStore
from .scanner import scan as run_scan
from .scheduler import LaunchAgentScheduler
from .translation import NativeTranslationBackend, translation_status
from .workflow import create_proposal

app = typer.Typer(help="本地、可解释、可撤销的 macOS Downloads 整理器", no_args_is_help=True)
semantic_app = typer.Typer(help="管理零下载的 macOS 原生语义 backend")
config_app = typer.Typer(help="管理整理目录和自动确认设置")
schedule_app = typer.Typer(help="管理 macOS 每日自动扫描")
auto_app = typer.Typer(help="运行可供 launchd 和未来 GUI 调用的自动化工作流")
app.add_typer(semantic_app, name="semantic")
app.add_typer(config_app, name="config")
app.add_typer(schedule_app, name="schedule")
app.add_typer(auto_app, name="auto")
console = Console()


def _open() -> tuple[Settings, Database]:
    base = Settings.load()
    db = Database(base.database)
    settings = PreferenceStore(db, base).resolved_settings()
    recovered = db.recover_interrupted()
    if recovered:
        console.print(f"[yellow]已核对 {recovered} 个上次中断的操作批次。[/yellow]")
    return settings, db


@config_app.command("show")
def config_show(json_output: bool = typer.Option(False, "--json")) -> None:
    """显示当前应用设置。"""
    _, db = _open()
    try:
        payload = PreferenceStore(db, Settings.load()).get().as_dict()
        if json_output:
            typer.echo(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            console.print(f"整理目录：{payload['destination']}")
            state = "已启用" if payload["auto_confirm_enabled"] else "已停用"
            console.print(f"高置信度自动确认：{state}")
            console.print(f"自动确认阈值：{float(payload['auto_confirm_threshold']):.2f}（启发式）")
    finally:
        db.close()


@config_app.command("destination")
def config_destination(path: Path) -> None:
    """设置整理后的根目录；新方案会固化该路径。"""
    base = Settings.load()
    db = Database(base.database)
    try:
        try:
            preferences = PreferenceStore(db, base).set_destination(path)
        except ValueError as exc:
            raise typer.BadParameter(str(exc)) from exc
        console.print(f"整理目录已设置为：{preferences.destination}")
        console.print("已有方案仍使用其生成时保存的目录。")
    finally:
        db.close()


@config_app.command("auto-confirm")
def config_auto_confirm(
    enabled: bool = typer.Option(True, "--enable/--disable", help="启用或停用自动确认"),
    threshold: float | None = typer.Option(None, min=0.85, max=1.0, help="启发式置信度阈值"),
) -> None:
    """配置每日任务是否自动移动高置信度、无冲突的完整分组。"""
    base = Settings.load()
    db = Database(base.database)
    try:
        try:
            preferences = PreferenceStore(db, base).set_auto_confirm(enabled, threshold)
        except ValueError as exc:
            raise typer.BadParameter(str(exc)) from exc
        state = "启用" if preferences.auto_confirm_enabled else "停用"
        console.print(f"高置信度自动确认已{state}；阈值 {preferences.auto_confirm_threshold:.2f}（启发式）。")
        if enabled:
            console.print("低于阈值、存在冲突或未分类的文件不会移动。")
    finally:
        db.close()


@schedule_app.command("status")
def schedule_status(json_output: bool = typer.Option(False, "--json")) -> None:
    """显示每日扫描 LaunchAgent 状态。"""
    settings, db = _open()
    try:
        status = LaunchAgentScheduler(settings).status()
        if json_output:
            typer.echo(json.dumps(status.as_dict(), ensure_ascii=False, indent=2))
        elif status.state == "loaded":
            console.print(f"每日自动扫描：已启用，每天 {status.time}")
            console.print(f"LaunchAgent：{status.plist_path}")
        elif status.state == "configured_not_loaded":
            suffix = f"，计划时间 {status.time}" if status.time else ""
            console.print(f"每日自动扫描：已配置但未载入 launchd{suffix}")
            console.print(f"LaunchAgent：{status.plist_path}")
        else:
            console.print("每日自动扫描：未配置")
    finally:
        db.close()


@schedule_app.command("enable")
def schedule_enable(at: str = typer.Option("09:00", "--at", help="每天运行时间，HH:MM")) -> None:
    """安装或更新当前用户的每日扫描 LaunchAgent。"""
    settings, db = _open()
    try:
        try:
            status = LaunchAgentScheduler(settings).enable(at)
        except (ValueError, RuntimeError) as exc:
            raise typer.BadParameter(str(exc)) from exc
        console.print(f"每日自动扫描已启用：每天 {status.time}")
        console.print("任务会始终扫描；只有显式启用 auto-confirm 时才会自动移动文件。")
    finally:
        db.close()


@schedule_app.command("disable")
def schedule_disable() -> None:
    """卸载每日扫描 LaunchAgent。"""
    settings, db = _open()
    try:
        LaunchAgentScheduler(settings).disable()
        console.print("每日自动扫描已停用。")
    finally:
        db.close()


@auto_app.command("run")
def auto_run(
    json_output: bool = typer.Option(False, "--json"),
    no_semantic: bool = typer.Option(False, "--no-semantic"),
) -> None:
    """立即执行一次每日任务；供 launchd 和未来 GUI 使用。"""
    settings, db = _open()
    try:
        result = DailyAutomationService(db, settings).run(use_semantic=not no_semantic)
        if json_output:
            typer.echo(json.dumps(result.as_dict(), ensure_ascii=False, indent=2))
            return
        stats = result.scan_stats
        console.print(
            f"扫描完成：新增/更新 {stats['scanned']}，未变化 {stats['unchanged']}，"
            f"跳过 {stats['skipped']}，提取错误 {stats['errors']}"
        )
        if not result.auto_confirm_enabled:
            console.print("高置信度自动确认未启用；本次没有生成或执行移动方案。")
        elif result.batch_id is None:
            console.print(f"方案 {result.plan_id} 没有达到阈值的无冲突分组；没有移动文件。")
        else:
            topics = "、".join(result.eligible_topics or [])
            console.print(
                f"自动确认方案 {result.plan_id}：{topics}；批次 {result.batch_id} "
                f"已移动 {result.moved} 个，跳过 {result.skipped} 个。"
            )
    finally:
        db.close()


@semantic_app.command("status")
def semantic_status() -> None:
    """检查系统原生语义能力；不会下载任何内容。"""
    settings = Settings.load()
    embedding = native_status(settings, inspect_languages=True)
    translation = translation_status(settings)
    console.print("[bold]Apple embedding:[/bold]")
    for language, state in embedding.get("languages", {}).items():
        console.print(f"  {language}: {state}")
    if embedding.get("error"):
        console.print(f"  [yellow]{embedding['error']}[/yellow]")
    console.print("\n[bold]Cross-language translation:[/bold]")
    labels = {"installed": "installed", "supported": "not installed", "unsupported": "unavailable"}
    for pair, state in translation.get("pairs", {}).items():
        console.print(f"  {pair}: {labels.get(state, state)}")
    if translation.get("error"):
        console.print(f"  [yellow]{translation['error']}[/yellow]")
    console.print("\n[dim]只检查本地资产；未请求或下载语言包。[/dim]")


@semantic_app.command("prepare")
def semantic_prepare() -> None:
    """编译轻量原生 helper；使用系统模型，不访问网络。"""
    settings = Settings.load()
    with app_lock(settings.data_dir):
        encoder = NativeMacOSEncoder(settings)
        vectors = encoder.encode(["renewable energy systems", "power grid control"])
        try:
            translator = NativeTranslationBackend(settings)
            translation_message = f"Translation helper 已就绪：{translator.settings.translation_helper}"
        except RuntimeError as exc:
            translation_message = f"Translation helper 不可用，后续将自动降级：{exc}"
    size = settings.native_helper.stat().st_size
    console.print(f"原生语义 backend 已就绪：{settings.native_helper}")
    console.print(f"helper 大小：{size / 1024:.0f} KB；系统向量维度：{len(vectors[0].vector or [])}")
    console.print(translation_message)
    console.print("未下载模型或 Python ML 框架。")


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
        evidence = loads(members[0]["evidence"], [])
        if evidence:
            for item in evidence:
                strength = item.get("strength", "none")
                color = {"strong": "green", "weak": "yellow", "none": "dim"}.get(strength, "dim")
                console.print(f"  [{color}]{strength.upper():6} {item.get('detail', '')}[/{color}]")
        else:
            reasons = loads(members[0]["reasons"], [])
            if reasons:
                console.print("  [dim]依据：" + "；".join(reasons) + "[/dim]")


@app.command()
def propose(
    json_output: bool = typer.Option(False, "--json", help="输出机器可读 JSON"),
    no_semantic: bool = typer.Option(
        False, "--no-semantic", help="跳过 macOS 原生语义向量",
    ),
) -> None:
    """基于当前索引生成并保存整理建议。"""
    settings, db = _open()
    try:
        with app_lock(settings.data_dir):
            result = create_proposal(db, settings, use_semantic=not no_semantic)
        if json_output:
            payload = {
                "plan_id": result.plan_id,
                "groups": [group.as_dict(settings.organized_dir) for group in result.groups],
                "unclassified": [str(file.path) for file in result.unclassified],
                "semantic_backend_used": result.encoder_version,
                "semantic_error": result.semantic_error,
                "translation_backend_used": result.translation_version,
                "translation_warnings": result.translation_warnings,
            }
            typer.echo(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            _render_plan(db, settings, result.plan_id)
            if result.semantic_error:
                console.print(f"\n[yellow]原生语义不可用，已继续使用其他特征：{result.semantic_error}[/yellow]")
            elif result.encoder_version is None:
                console.print("\n[dim]已按要求跳过原生语义特征。[/dim]")
            for message in result.translation_warnings:
                console.print(f"\n[yellow]跨语言语义已降级：{message}[/yellow]")
            console.print(f"\n审阅：tt review {result.plan_id}")
    finally:
        db.close()


@app.command()
def benchmark(
    fixture: Path | None = typer.Argument(None, help="fixture JSON；省略时使用内置核心数据集"),
    json_output: bool = typer.Option(False, "--json", help="输出机器可读 JSON"),
    min_f1: float = typer.Option(1.0, min=0.0, max=1.0, help="低于阈值时返回非零退出码"),
) -> None:
    """对标注 fixture 比较 expected clusters 与 predicted clusters。"""
    result = run_benchmark(fixture)
    if json_output:
        typer.echo(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        console.print(f"Fixture: {result['fixture']}")
        console.print("\n[bold]Expected clusters[/bold]")
        for name, members in result["expected_clusters"].items():
            console.print(f"  {name}: {', '.join(members)}")
        console.print("\n[bold]Predicted clusters[/bold]")
        for name, members in result["predicted_clusters"].items():
            console.print(f"  {name}: {', '.join(members)}")
        console.print(
            f"\nPairwise precision={result['pairwise_precision']:.4f} "
            f"recall={result['pairwise_recall']:.4f} F1={result['pairwise_f1']:.4f}"
        )
        console.print(f"Exact cluster match: {result['exact_cluster_match']}")
        console.print(f"Unclassified match: {result['unclassified_match']}")
    if result["pairwise_f1"] < min_f1 or not result["unclassified_match"]:
        raise typer.Exit(code=1)


REVIEW_HELP = """命令：
  list
  rename <旧主题> <新主题>
  move <成员编号> <主题>
  split <成员编号> <新主题>
  merge <源主题...> <目标主题>
  exclude <成员编号>
  folder <主题> <整理根目录内已有目录>
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
                console.print(f"审阅已保存。下一步执行：tt apply {plan_id}")
                break
            if parts[0] in {"help", "?"}:
                console.print(REVIEW_HELP)
                continue
            if parts[0] == "list":
                _render_plan(db, settings, plan_id)
                continue
            try:
                with app_lock(settings.data_dir):
                    root = plan_destination_root(db, settings, plan_id)
                    console.print(edit_plan(db, plan_id, parts[0], parts[1:], root))
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
