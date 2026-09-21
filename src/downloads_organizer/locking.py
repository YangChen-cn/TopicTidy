from __future__ import annotations

import fcntl
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


@contextmanager
def app_lock(data_dir: Path) -> Iterator[None]:
    data_dir.mkdir(parents=True, exist_ok=True)
    lock_path = data_dir / "organizer.lock"
    with lock_path.open("a+") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("另一个 Downloads Organizer 进程正在运行") from exc
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

