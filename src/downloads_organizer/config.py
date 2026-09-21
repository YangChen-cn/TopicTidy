from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

from platformdirs import user_data_dir

APP_NAME = "DownloadsOrganizer"
COURSE_PATTERN = re.compile(r"(?i)(?<![A-Z0-9])([A-Z]{2,8})[\s_-]?(\d{4})(?!\d)")
NON_COURSE_PREFIXES = {
    "AUTUMN", "FALL", "SPRING", "SUMMER", "WINTER", "TERM", "SEMESTER",
    "LECTURE", "CHAPTER",
}
INCOMPLETE_SUFFIXES = {".crdownload", ".download", ".part", ".tmp"}
CROSS_LANGUAGE_TIME_WINDOW_SECONDS = 14 * 24 * 60 * 60


@dataclass(frozen=True)
class Settings:
    downloads: Path
    data_dir: Path
    organized_name: str = "Organized"
    max_text_chars: int = 120_000
    stable_seconds: float = 2.0
    cluster_threshold: float = 0.64
    course_attach_threshold: float = 0.70
    cross_language_candidate_neighbors: int = 2
    cross_language_translation_limit: int = 24

    @property
    def database(self) -> Path:
        return self.data_dir / "organizer.sqlite3"

    @property
    def native_helper(self) -> Path:
        return self.data_dir / "bin" / "native-embedding"

    @property
    def native_helper_stamp(self) -> Path:
        return self.data_dir / "bin" / "native-embedding.sha256"

    @property
    def translation_helper(self) -> Path:
        return self.data_dir / "bin" / "native-translation"

    @property
    def translation_helper_stamp(self) -> Path:
        return self.data_dir / "bin" / "native-translation.sha256"

    @property
    def organized_dir(self) -> Path:
        return self.downloads / self.organized_name

    @classmethod
    def load(cls) -> "Settings":
        downloads = Path(os.getenv("DOWNLOADS_ORGANIZER_DOWNLOADS", "~/Downloads")).expanduser()
        data = Path(os.getenv("DOWNLOADS_ORGANIZER_HOME", user_data_dir(APP_NAME))).expanduser()
        return cls(downloads=downloads.resolve(), data_dir=data.resolve())


def normalize_course(value: str) -> str:
    for raw_prefix, number in COURSE_PATTERN.findall(value):
        prefix = raw_prefix.upper()
        if prefix not in NON_COURSE_PREFIXES:
            return f"{prefix}{number}"
    return ""


def all_courses(value: str) -> set[str]:
    return {
        f"{prefix}{number}"
        for raw_prefix, number in COURSE_PATTERN.findall(value)
        if (prefix := raw_prefix.upper()) not in NON_COURSE_PREFIXES
    }
