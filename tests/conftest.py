from __future__ import annotations

from pathlib import Path

import pytest

from downloads_organizer.config import Settings
from downloads_organizer.db import Database


@pytest.fixture
def workspace(tmp_path: Path):
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    settings = Settings(downloads=downloads, data_dir=tmp_path / "data", stable_seconds=0)
    db = Database(settings.database)
    try:
        yield settings, db
    finally:
        db.close()


def put(folder: Path, name: str, text: str = "sample") -> Path:
    path = folder / name
    path.write_text(text, encoding="utf-8")
    return path

