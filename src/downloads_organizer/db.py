from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

SCHEMA_VERSION = 1
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_meta(version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS files(
 id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, extension TEXT NOT NULL,
 size INTEGER NOT NULL, created_at REAL NOT NULL, modified_at REAL NOT NULL,
 device INTEGER NOT NULL, inode INTEGER NOT NULL, fingerprint TEXT NOT NULL,
 source_urls TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', last_seen REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS files_fingerprint_idx ON files(fingerprint);
CREATE TABLE IF NOT EXISTS features(
 file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
 fingerprint TEXT NOT NULL, extractor_version TEXT NOT NULL, model_version TEXT,
 text TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', keywords TEXT NOT NULL DEFAULT '[]',
 summary TEXT NOT NULL DEFAULT '', truncated INTEGER NOT NULL DEFAULT 0,
 extraction_error TEXT, embedding BLOB
);
CREATE TABLE IF NOT EXISTS topics(
 id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, folder TEXT, source TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS plans(
 id INTEGER PRIMARY KEY, created_at REAL NOT NULL, status TEXT NOT NULL, config_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS plan_members(
 id INTEGER PRIMARY KEY, plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
 file_id INTEGER NOT NULL REFERENCES files(id), group_name TEXT, confidence REAL NOT NULL,
 reasons TEXT NOT NULL DEFAULT '[]', conflicts TEXT NOT NULL DEFAULT '[]', excluded INTEGER NOT NULL DEFAULT 0,
 source_fingerprint TEXT NOT NULL, destination TEXT
);
CREATE TABLE IF NOT EXISTS corrections(
 id INTEGER PRIMARY KEY, created_at REAL NOT NULL, file_fingerprint TEXT NOT NULL,
 action TEXT NOT NULL, topic_name TEXT, plan_id INTEGER, active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS associations(
 id INTEGER PRIMARY KEY, topic_name TEXT NOT NULL, file_fingerprint TEXT NOT NULL UNIQUE,
 confirmed_at REAL NOT NULL, active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS operation_batches(
 id INTEGER PRIMARY KEY, plan_id INTEGER, kind TEXT NOT NULL, status TEXT NOT NULL,
 created_at REAL NOT NULL, completed_at REAL
);
CREATE TABLE IF NOT EXISTS operation_logs(
 id INTEGER PRIMARY KEY, batch_id INTEGER NOT NULL REFERENCES operation_batches(id), file_id INTEGER,
 source TEXT NOT NULL, destination TEXT NOT NULL, fingerprint TEXT NOT NULL,
 status TEXT NOT NULL, error TEXT, created_at REAL NOT NULL, completed_at REAL
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.migrate()

    def migrate(self) -> None:
        self.conn.executescript(SCHEMA)
        row = self.conn.execute("SELECT version FROM schema_meta LIMIT 1").fetchone()
        if row is None:
            self.conn.execute("INSERT INTO schema_meta(version) VALUES (?)", (SCHEMA_VERSION,))
        elif row[0] != SCHEMA_VERSION:
            raise RuntimeError(f"不支持的数据库版本 {row[0]}")
        self.conn.commit()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        try:
            yield self.conn
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

    def close(self) -> None:
        self.conn.close()

    def recover_interrupted(self) -> int:
        rows = self.conn.execute("SELECT id FROM operation_batches WHERE status='running'").fetchall()
        for row in rows:
            logs = self.conn.execute("SELECT * FROM operation_logs WHERE batch_id=? AND status='intent'", (row[0],)).fetchall()
            for log in logs:
                src, dst = Path(log["source"]), Path(log["destination"])
                if dst.exists() and not src.exists():
                    status, error = "moved", None
                    if log["file_id"]:
                        self.conn.execute(
                            "UPDATE files SET path=?,name=?,status='organized' WHERE id=?",
                            (str(dst), dst.name, log["file_id"]),
                        )
                elif src.exists() and not dst.exists():
                    status, error = "not_started", "上次运行在移动前中断"
                else:
                    status, error = "ambiguous", "源和目标状态无法自动判定"
                self.conn.execute("UPDATE operation_logs SET status=?, error=? WHERE id=?", (status, error, log["id"]))
            self.conn.execute("UPDATE operation_batches SET status='interrupted' WHERE id=?", (row[0],))
        self.conn.commit()
        return len(rows)


def dumps(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def loads(value: str | None, default: object):
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default
