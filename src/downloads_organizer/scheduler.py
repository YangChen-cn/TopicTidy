from __future__ import annotations

import os
import plistlib
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from .config import Settings

LAUNCH_AGENT_LABEL = "com.topictidy.daily"


@dataclass(frozen=True)
class ScheduleStatus:
    state: str
    configured: bool
    loaded: bool
    time: str | None
    plist_path: Path
    command: list[str]

    @property
    def enabled(self) -> bool:
        """Compatibility alias: enabled means launchd has actually loaded it."""
        return self.loaded

    def as_dict(self) -> dict[str, object]:
        result = asdict(self)
        result["plist_path"] = str(self.plist_path)
        result["enabled"] = self.enabled
        return result


def parse_daily_time(value: str) -> tuple[int, int]:
    try:
        hour_text, minute_text = value.split(":", 1)
        hour, minute = int(hour_text), int(minute_text)
    except (ValueError, AttributeError) as exc:
        raise ValueError("时间必须使用 HH:MM 格式，例如 09:00") from exc
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ValueError("时间必须使用 00:00 到 23:59")
    return hour, minute


class LaunchAgentScheduler:
    """macOS launchd adapter shared by the CLI and a future GUI."""

    def __init__(
        self,
        settings: Settings,
        *,
        plist_path: Path | None = None,
        runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    ):
        self.settings = settings
        self.plist_path = plist_path or (
            Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
        )
        self.runner = runner

    @property
    def command(self) -> list[str]:
        flags = ["-I", "-B"] if os.getenv("TOPICTIDY_HELPERS") else []
        return [sys.executable, *flags, "-m", "downloads_organizer", "auto", "run"]

    def status(self) -> ScheduleStatus:
        if not self.plist_path.exists():
            return ScheduleStatus(
                "not_configured", False, False, None, self.plist_path, self.command,
            )
        at = None
        command = self.command
        try:
            with self.plist_path.open("rb") as handle:
                payload = plistlib.load(handle)
            interval = payload.get("StartCalendarInterval", {})
            at = f"{int(interval['Hour']):02d}:{int(interval['Minute']):02d}"
            command = [str(item) for item in payload.get("ProgramArguments", self.command)]
        except (OSError, KeyError, TypeError, ValueError, plistlib.InvalidFileException):
            pass
        loaded = False
        if sys.platform == "darwin":
            domain = f"gui/{os.getuid()}"
            result = self.runner(
                ["launchctl", "print", f"{domain}/{LAUNCH_AGENT_LABEL}"],
                check=False,
                capture_output=True,
                text=True,
            )
            loaded = result.returncode == 0
        return ScheduleStatus(
            "loaded" if loaded else "configured_not_loaded",
            True,
            loaded,
            at,
            self.plist_path,
            command,
        )

    def enable(self, at: str) -> ScheduleStatus:
        if sys.platform != "darwin":
            raise RuntimeError("每日调度仅支持 macOS launchd")
        hour, minute = parse_daily_time(at)
        logs = self.settings.data_dir / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        self.plist_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "Label": LAUNCH_AGENT_LABEL,
            "ProgramArguments": self.command,
            "StartCalendarInterval": {"Hour": hour, "Minute": minute},
            "ProcessType": "Background",
            "StandardOutPath": str(logs / "daily.log"),
            "StandardErrorPath": str(logs / "daily-error.log"),
            "EnvironmentVariables": {
                "DOWNLOADS_ORGANIZER_DOWNLOADS": str(self.settings.downloads),
                "DOWNLOADS_ORGANIZER_HOME": str(self.settings.data_dir),
            },
        }
        if os.getenv("TOPICTIDY_HELPERS"):
            payload["EnvironmentVariables"]["TOPICTIDY_HELPERS"] = os.environ["TOPICTIDY_HELPERS"]
        previous = self.plist_path.read_bytes() if self.plist_path.exists() else None
        temporary = self.plist_path.with_suffix(".plist.tmp")
        with temporary.open("wb") as handle:
            plistlib.dump(payload, handle, sort_keys=True)
        temporary.replace(self.plist_path)
        domain = f"gui/{os.getuid()}"
        self.runner(
            ["launchctl", "bootout", domain, str(self.plist_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        loaded = self.runner(
            ["launchctl", "bootstrap", domain, str(self.plist_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        if loaded.returncode != 0:
            if previous is None:
                self.plist_path.unlink(missing_ok=True)
            else:
                self.plist_path.write_bytes(previous)
                self.runner(
                    ["launchctl", "bootstrap", domain, str(self.plist_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
            raise RuntimeError((loaded.stderr or loaded.stdout or "launchctl bootstrap 失败").strip())
        return self.status()

    def disable(self) -> ScheduleStatus:
        domain = f"gui/{os.getuid()}"
        if self.plist_path.exists() and sys.platform == "darwin":
            self.runner(
                ["launchctl", "bootout", domain, str(self.plist_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.plist_path.unlink(missing_ok=True)
        return self.status()
