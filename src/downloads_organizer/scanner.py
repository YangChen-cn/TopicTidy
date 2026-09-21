from __future__ import annotations

import hashlib
import time
from pathlib import Path

from .config import INCOMPLETE_SUFFIXES, Settings
from .db import Database, dumps
from .extractors import ExtractorRegistry, default_registry
from .metadata import source_urls


def fingerprint(path: Path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def candidates(settings: Settings) -> list[Path]:
    if not settings.downloads.exists():
        raise FileNotFoundError(f"Downloads 目录不存在：{settings.downloads}")
    result = []
    for path in settings.downloads.iterdir():
        if path.name == settings.organized_name or path.name.startswith("."):
            continue
        if path.is_symlink() or not path.is_file() or path.suffix.lower() in INCOMPLETE_SUFFIXES:
            continue
        result.append(path)
    return sorted(result, key=lambda p: p.name.lower())


def is_stable(path: Path, seconds: float) -> bool:
    first = path.stat()
    if seconds:
        time.sleep(seconds)
    try:
        second = path.stat()
    except FileNotFoundError:
        return False
    return (first.st_size, first.st_mtime_ns) == (second.st_size, second.st_mtime_ns)


def scan(
    db: Database,
    settings: Settings,
    *,
    wait_for_stability: bool = False,
    extractors: ExtractorRegistry | None = None,
) -> dict[str, int]:
    registry = extractors or default_registry()
    stats = {"scanned": 0, "unchanged": 0, "skipped": 0, "errors": 0}
    seen: set[str] = set()
    now = time.time()
    for path in candidates(settings):
        try:
            if wait_for_stability and not is_stable(path, settings.stable_seconds):
                stats["skipped"] += 1
                continue
            stat = path.stat()
            resolved = str(path.resolve())
            seen.add(resolved)
            existing = db.conn.execute("SELECT * FROM files WHERE path=?", (resolved,)).fetchone()
            extractor_version = registry.cache_version(path)
            existing_feature = None
            if existing:
                existing_feature = db.conn.execute(
                    "SELECT fingerprint,extractor_version FROM features WHERE file_id=?",
                    (existing["id"],),
                ).fetchone()
            same_file_state = bool(
                existing
                and existing["size"] == stat.st_size
                and existing["modified_at"] == stat.st_mtime
            )
            cache_current = bool(
                same_file_state
                and existing_feature
                and existing_feature["fingerprint"] == existing["fingerprint"]
                and existing_feature["extractor_version"] == extractor_version
            )
            if cache_current:
                db.conn.execute("UPDATE files SET status='active', last_seen=? WHERE id=?", (now, existing["id"]))
                stats["unchanged"] += 1
                continue
            digest = existing["fingerprint"] if same_file_state else fingerprint(path)
            urls = source_urls(path)
            with db.transaction() as conn:
                conn.execute(
                    """INSERT INTO files(path,name,extension,size,created_at,modified_at,device,inode,fingerprint,source_urls,status,last_seen)
                    VALUES(?,?,?,?,?,?,?,?,?,?, 'active',?)
                    ON CONFLICT(path) DO UPDATE SET name=excluded.name,extension=excluded.extension,size=excluded.size,
                    created_at=excluded.created_at,modified_at=excluded.modified_at,device=excluded.device,
                    inode=excluded.inode,fingerprint=excluded.fingerprint,source_urls=excluded.source_urls,status='active',last_seen=excluded.last_seen""",
                    (resolved, path.name, path.suffix.lower(), stat.st_size, stat.st_birthtime, stat.st_mtime,
                     stat.st_dev, stat.st_ino, digest, dumps(urls), now),
                )
                file_id = conn.execute("SELECT id FROM files WHERE path=?", (resolved,)).fetchone()[0]
                cached = conn.execute(
                    "SELECT 1 FROM features WHERE file_id=? AND fingerprint=? AND extractor_version=?",
                    (file_id, digest, extractor_version),
                ).fetchone()
                if not cached:
                    result = registry.extract(path, settings.max_text_chars)
                    conn.execute(
                        """INSERT INTO features(file_id,fingerprint,extractor_version,text,title,keywords,summary,truncated,extraction_error)
                        VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET
                        fingerprint=excluded.fingerprint,extractor_version=excluded.extractor_version,model_version=NULL,
                        text=excluded.text,title=excluded.title,keywords=excluded.keywords,summary=excluded.summary,
                        truncated=excluded.truncated,extraction_error=excluded.extraction_error,
                        native_embedding=NULL,native_embedding_space=NULL""",
                        (file_id, digest, extractor_version, result.text, result.title, dumps(result.keywords),
                         result.summary, int(result.truncated), result.error),
                    )
                    conn.execute("DELETE FROM semantic_pivots WHERE file_id=?", (file_id,))
                    if result.error:
                        stats["errors"] += 1
            stats["scanned"] += 1
        except (OSError, PermissionError):
            stats["errors"] += 1
    if seen:
        placeholders = ",".join("?" for _ in seen)
        db.conn.execute(f"UPDATE files SET status='missing' WHERE status='active' AND path NOT IN ({placeholders})", tuple(seen))
    else:
        db.conn.execute("UPDATE files SET status='missing' WHERE status='active'")
    db.conn.commit()
    return stats
