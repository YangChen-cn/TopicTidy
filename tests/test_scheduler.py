from __future__ import annotations

import plistlib
from types import SimpleNamespace

import pytest

from downloads_organizer.scheduler import LaunchAgentScheduler, parse_daily_time


def test_parse_daily_time():
    assert parse_daily_time("09:05") == (9, 5)
    with pytest.raises(ValueError):
        parse_daily_time("25:00")
    with pytest.raises(ValueError):
        parse_daily_time("nine")


def test_launch_agent_enable_status_and_disable(workspace, tmp_path, monkeypatch):
    settings, _ = workspace
    calls = []

    def runner(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr("downloads_organizer.scheduler.sys.platform", "darwin")
    plist_path = tmp_path / "com.topictidy.daily.plist"
    scheduler = LaunchAgentScheduler(settings, plist_path=plist_path, runner=runner)

    enabled = scheduler.enable("07:30")

    assert enabled.enabled is True
    assert enabled.time == "07:30"
    with plist_path.open("rb") as handle:
        payload = plistlib.load(handle)
    assert payload["ProgramArguments"][-2:] == ["auto", "run"]
    assert payload["StartCalendarInterval"] == {"Hour": 7, "Minute": 30}
    assert any("bootstrap" in command for command in calls)

    disabled = scheduler.disable()
    assert disabled.enabled is False
    assert not plist_path.exists()


def test_launch_agent_removes_new_plist_when_bootstrap_fails(workspace, tmp_path, monkeypatch):
    settings, _ = workspace

    def runner(command, **kwargs):
        return SimpleNamespace(
            returncode=1 if "bootstrap" in command else 0,
            stdout="",
            stderr="load failed",
        )

    monkeypatch.setattr("downloads_organizer.scheduler.sys.platform", "darwin")
    plist_path = tmp_path / "com.topictidy.daily.plist"
    scheduler = LaunchAgentScheduler(settings, plist_path=plist_path, runner=runner)

    with pytest.raises(RuntimeError, match="load failed"):
        scheduler.enable("07:30")
    assert not plist_path.exists()
