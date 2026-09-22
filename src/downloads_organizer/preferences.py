from __future__ import annotations

import time
from dataclasses import asdict, dataclass, replace
from pathlib import Path

from .config import Settings
from .db import Database


@dataclass(frozen=True)
class OrganizerPreferences:
    destination: Path
    auto_confirm_enabled: bool
    auto_confirm_threshold: float

    def as_dict(self) -> dict[str, object]:
        values = asdict(self)
        values["destination"] = str(self.destination)
        return values


class PreferenceStore:
    """Persistence API shared by the CLI and a future GUI."""

    DESTINATION = "destination"
    AUTO_CONFIRM_ENABLED = "auto_confirm_enabled"
    AUTO_CONFIRM_THRESHOLD = "auto_confirm_threshold"

    def __init__(self, db: Database, base: Settings):
        self.db = db
        self.base = base

    def _values(self) -> dict[str, str]:
        return {
            str(row["key"]): str(row["value"])
            for row in self.db.conn.execute("SELECT key,value FROM app_settings")
        }

    def get(self) -> OrganizerPreferences:
        values = self._values()
        destination = Path(values.get(self.DESTINATION, str(self.base.organized_dir))).expanduser().resolve()
        enabled = values.get(
            self.AUTO_CONFIRM_ENABLED,
            "1" if self.base.auto_confirm_enabled else "0",
        ) == "1"
        try:
            threshold = float(values.get(self.AUTO_CONFIRM_THRESHOLD, str(self.base.auto_confirm_threshold)))
        except ValueError:
            threshold = self.base.auto_confirm_threshold
        threshold = min(1.0, max(0.85, threshold))
        return OrganizerPreferences(destination, enabled, threshold)

    def resolved_settings(self) -> Settings:
        preferences = self.get()
        return replace(
            self.base,
            organized_root=preferences.destination,
            auto_confirm_enabled=preferences.auto_confirm_enabled,
            auto_confirm_threshold=preferences.auto_confirm_threshold,
        )

    def _set(self, key: str, value: str) -> None:
        self.db.conn.execute(
            """INSERT INTO app_settings(key,value,updated_at) VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at""",
            (key, value, time.time()),
        )
        self.db.conn.commit()

    def set_destination(self, destination: Path) -> OrganizerPreferences:
        expanded = destination.expanduser()
        if expanded.is_symlink():
            raise ValueError("整理根目录不能是符号链接")
        resolved = expanded.resolve()
        if resolved == self.base.downloads:
            raise ValueError("整理根目录不能直接等于 Downloads；请指定一个子目录或其他目录")
        if resolved.exists() and not resolved.is_dir():
            raise ValueError("整理根目录已存在，但不是目录")
        existing_parent = resolved
        while not existing_parent.exists():
            existing_parent = existing_parent.parent
        if existing_parent.stat().st_dev != self.base.downloads.stat().st_dev:
            raise ValueError("当前版本仅支持与 Downloads 位于同一磁盘的整理目录")
        self._set(self.DESTINATION, str(resolved))
        return self.get()

    def set_auto_confirm(self, enabled: bool, threshold: float | None = None) -> OrganizerPreferences:
        if threshold is not None and not 0.85 <= threshold <= 1.0:
            raise ValueError("自动确认阈值必须在 0.85 到 1.0 之间")
        self._set(self.AUTO_CONFIRM_ENABLED, "1" if enabled else "0")
        if threshold is not None:
            self._set(self.AUTO_CONFIRM_THRESHOLD, f"{threshold:.6f}")
        return self.get()
