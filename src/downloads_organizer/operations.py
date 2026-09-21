from __future__ import annotations

import os
import re
import time
import uuid
from pathlib import Path

from .config import Settings
from .db import Database
from .scanner import fingerprint

SAFE_COMPONENT = re.compile(r"[/:\x00]")


def safe_topic_name(name: str) -> str:
    clean = SAFE_COMPONENT.sub("-", name).strip().strip(".")
    if not clean or clean in {".", ".."}:
        raise ValueError("主题名称无效")
    return clean[:100]


def within(child: Path, parent: Path) -> bool:
    try:
        child.resolve(strict=False).relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def unique_destination(path: Path, reserved: set[Path] | None = None) -> Path:
    reserved = reserved or set()
    if not path.exists() and path not in reserved:
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem} ({index}){path.suffix}")
        if not candidate.exists() and candidate not in reserved:
            return candidate
    raise RuntimeError(f"无法为 {path.name} 生成唯一目标名称")


def ensure_topic(db: Database, display_name: str) -> str:
    row = db.conn.execute(
        "SELECT topic_key FROM topics WHERE display_name=? AND active=1 ORDER BY topic_key LIMIT 1", (display_name,),
    ).fetchone()
    if row and row[0]:
        return str(row[0])
    key = "topic:" + uuid.uuid4().hex
    db.conn.execute(
        "INSERT INTO topics(topic_key,display_name,source,active) VALUES(?,?,'manual',1)",
        (key, display_name),
    )
    return key


def plan_rows(db: Database, plan_id: int):
    return db.conn.execute(
        """SELECT m.*,f.path,f.name,f.fingerprint AS current_fingerprint,f.size,f.modified_at
        FROM plan_members m JOIN files f ON f.id=m.file_id WHERE m.plan_id=? ORDER BY m.group_name,f.name""",
        (plan_id,),
    ).fetchall()


def preview_moves(db: Database, settings: Settings, plan_id: int) -> list[dict[str, object]]:
    plan = db.conn.execute("SELECT * FROM plans WHERE id=?", (plan_id,)).fetchone()
    if not plan:
        raise ValueError(f"方案 {plan_id} 不存在")
    reserved: set[Path] = set()
    moves = []
    for row in plan_rows(db, plan_id):
        if row["excluded"] or not row["group_name"]:
            continue
        source = Path(row["path"])
        folder = settings.organized_dir / safe_topic_name(row["group_name"])
        if row["destination"]:
            proposed_folder = Path(row["destination"]).parent
            if within(proposed_folder, settings.organized_dir):
                folder = proposed_folder
        destination = unique_destination(folder / source.name, reserved)
        reserved.add(destination)
        stale = (not source.exists()) or row["source_fingerprint"] != row["current_fingerprint"]
        moves.append({"member_id": row["id"], "file_id": row["file_id"], "source": source,
                      "destination": destination, "fingerprint": row["source_fingerprint"], "stale": stale,
                      "topic": row["group_name"], "topic_key": row["topic_key"]})
    return moves


def apply_plan(db: Database, settings: Settings, plan_id: int) -> tuple[int, list[dict[str, str]]]:
    if settings.organized_dir.is_symlink() or not within(settings.organized_dir, settings.downloads):
        raise RuntimeError("Organized 目录必须是 Downloads 内的真实目录，不能是符号链接")
    moves = preview_moves(db, settings, plan_id)
    now = time.time()
    cursor = db.conn.execute(
        "INSERT INTO operation_batches(plan_id,kind,status,created_at) VALUES(?, 'apply', 'running', ?)",
        (plan_id, now),
    )
    batch_id = int(cursor.lastrowid)
    results: list[dict[str, str]] = []
    for move in moves:
        src, dst = move["source"], move["destination"]
        log = db.conn.execute(
            """INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
            VALUES(?,?,?,?,?,'intent',?)""",
            (batch_id, move["file_id"], str(src), str(dst), move["fingerprint"], time.time()),
        )
        log_id = int(log.lastrowid)
        db.conn.commit()  # Persist intent before touching the filesystem.
        status, error = "moved", None
        try:
            if move["stale"] or not src.is_file() or fingerprint(src) != move["fingerprint"]:
                raise RuntimeError("文件在方案生成后已改变或已消失")
            if not within(src, settings.downloads) or not within(dst, settings.organized_dir):
                raise RuntimeError("移动路径越出允许范围")
            if src.stat().st_dev != settings.downloads.stat().st_dev:
                raise RuntimeError("首版仅允许同卷移动")
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists():
                raise RuntimeError("目标文件已存在")
            os.rename(src, dst)
            db.conn.execute("UPDATE files SET path=?,name=?,status='organized' WHERE id=?", (str(dst), dst.name, move["file_id"]))
            db.conn.execute(
                """INSERT INTO associations(topic_key,file_fingerprint,confirmed_at,active) VALUES(?,?,?,1)
                ON CONFLICT(file_fingerprint) DO UPDATE SET topic_key=excluded.topic_key,
                confirmed_at=excluded.confirmed_at,active=1""",
                (move["topic_key"], move["fingerprint"], time.time()),
            )
        except Exception as exc:
            status, error = "skipped", str(exc)
        db.conn.execute(
            "UPDATE operation_logs SET status=?,error=?,completed_at=? WHERE id=?",
            (status, error, time.time(), log_id),
        )
        db.conn.commit()
        results.append({"source": str(src), "destination": str(dst), "status": status, "error": error or ""})
    final = "completed" if all(r["status"] == "moved" for r in results) else "partial"
    db.conn.execute("UPDATE operation_batches SET status=?,completed_at=? WHERE id=?", (final, time.time(), batch_id))
    db.conn.execute("UPDATE plans SET status=? WHERE id=?", ("applied" if final == "completed" else "partial", plan_id))
    db.conn.commit()
    return batch_id, results


def undo_batch(db: Database, settings: Settings, batch_id: int) -> tuple[int, list[dict[str, str]]]:
    original = db.conn.execute("SELECT * FROM operation_batches WHERE id=?", (batch_id,)).fetchone()
    if not original or original["kind"] != "apply":
        raise ValueError(f"找不到可撤销的整理批次 {batch_id}")
    rows = db.conn.execute(
        "SELECT * FROM operation_logs WHERE batch_id=? AND status='moved' ORDER BY id DESC", (batch_id,)
    ).fetchall()
    cursor = db.conn.execute(
        "INSERT INTO operation_batches(plan_id,kind,status,created_at) VALUES(?, 'undo', 'running', ?)",
        (original["plan_id"], time.time()),
    )
    undo_id = int(cursor.lastrowid)
    results = []
    for row in rows:
        current, original_path = Path(row["destination"]), Path(row["source"])
        log = db.conn.execute(
            """INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
            VALUES(?,?,?,?,?,'intent',?)""",
            (undo_id, row["file_id"], str(current), str(original_path), row["fingerprint"], time.time()),
        )
        log_id = int(log.lastrowid)
        db.conn.commit()
        status, error = "undone", None
        try:
            if not current.is_file() or fingerprint(current) != row["fingerprint"]:
                raise RuntimeError("已整理文件缺失或内容已改变")
            if original_path.exists():
                raise RuntimeError("原路径已被占用")
            if not within(current, settings.organized_dir) or not within(original_path, settings.downloads):
                raise RuntimeError("撤销路径越出允许范围")
            original_path.parent.mkdir(parents=True, exist_ok=True)
            os.rename(current, original_path)
            db.conn.execute("UPDATE files SET path=?,name=?,status='active' WHERE id=?", (str(original_path), original_path.name, row["file_id"]))
            db.conn.execute("UPDATE associations SET active=0 WHERE file_fingerprint=?", (row["fingerprint"],))
        except Exception as exc:
            status, error = "skipped", str(exc)
        db.conn.execute("UPDATE operation_logs SET status=?,error=?,completed_at=? WHERE id=?", (status, error, time.time(), log_id))
        db.conn.commit()
        results.append({"source": str(current), "destination": str(original_path), "status": status, "error": error or ""})
    final = "completed" if all(r["status"] == "undone" for r in results) else "partial"
    db.conn.execute("UPDATE operation_batches SET status=?,completed_at=? WHERE id=?", (final, time.time(), undo_id))
    db.conn.commit()
    return undo_id, results


def edit_plan(db: Database, plan_id: int, command: str, args: list[str], organized_dir: Path | None = None) -> str:
    correction_fingerprint = ""
    correction_topic: str | None = None
    if command == "rename" and len(args) >= 2:
        old, new = args[0], safe_topic_name(" ".join(args[1:]))
        keys = [row[0] for row in db.conn.execute(
            "SELECT DISTINCT topic_key FROM plan_members WHERE plan_id=? AND group_name=? AND topic_key IS NOT NULL",
            (plan_id, old),
        )]
        db.conn.execute(
            "UPDATE plan_members SET group_name=?,destination=NULL WHERE plan_id=? AND group_name=?",
            (new, plan_id, old),
        )
        for key in keys:
            db.conn.execute("UPDATE topics SET display_name=? WHERE topic_key=?", (new, key))
        action = f"主题 {old} 已改名为 {new}"
    elif command == "exclude" and len(args) == 1:
        row = db.conn.execute(
            "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?", (plan_id, int(args[0]))
        ).fetchone()
        if not row:
            raise ValueError("成员不存在")
        correction_fingerprint = row[0]
        db.conn.execute("UPDATE plan_members SET excluded=1 WHERE plan_id=? AND id=?", (plan_id, int(args[0])))
        action = f"成员 {args[0]} 已排除"
    elif command == "move" and len(args) >= 2:
        topic = safe_topic_name(" ".join(args[1:]))
        correction_topic = topic
        row = db.conn.execute(
            "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?", (plan_id, int(args[0]))
        ).fetchone()
        if not row:
            raise ValueError("成员不存在")
        correction_fingerprint = row[0]
        identity = ensure_topic(db, topic)
        db.conn.execute(
            "UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL,excluded=0 WHERE plan_id=? AND id=?",
            (identity, topic, plan_id, int(args[0])),
        )
        action = f"成员 {args[0]} 已移至 {topic}"
    elif command == "merge" and len(args) >= 2:
        target = safe_topic_name(args[-1])
        row = db.conn.execute(
            "SELECT topic_key FROM plan_members WHERE plan_id=? AND group_name=? AND topic_key IS NOT NULL LIMIT 1",
            (plan_id, target),
        ).fetchone()
        identity = str(row[0]) if row else ensure_topic(db, target)
        for source in args[:-1]:
            db.conn.execute(
                "UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL WHERE plan_id=? AND group_name=?",
                (identity, target, plan_id, source),
            )
        action = f"已合并到 {target}"
    elif command == "split" and len(args) >= 2:
        topic = safe_topic_name(" ".join(args[1:]))
        correction_topic = topic
        row = db.conn.execute(
            "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?", (plan_id, int(args[0]))
        ).fetchone()
        if not row:
            raise ValueError("成员不存在")
        correction_fingerprint = row[0]
        identity = ensure_topic(db, topic)
        db.conn.execute(
            "UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL,excluded=0 WHERE plan_id=? AND id=?",
            (identity, topic, plan_id, int(args[0])),
        )
        action = f"成员 {args[0]} 已拆分到 {topic}"
    elif command == "folder" and len(args) == 2:
        folder = Path(args[1]).expanduser().resolve()
        if organized_dir is None or not within(folder, organized_dir):
            raise ValueError("主题目录必须位于 Organized 内")
        db.conn.execute(
            "UPDATE plan_members SET destination=? || '/' || (SELECT name FROM files WHERE id=plan_members.file_id) WHERE plan_id=? AND group_name=?",
            (str(folder), plan_id, args[0]),
        )
        action = f"主题 {args[0]} 的目录设为 {folder}"
    else:
        raise ValueError("无法识别命令或参数数量不正确")
    db.conn.execute(
        "INSERT INTO corrections(created_at,file_fingerprint,action,topic_name,plan_id) VALUES(?,?,?,?,?)",
        (time.time(), correction_fingerprint, command, correction_topic, plan_id),
    )
    db.conn.commit()
    return action
