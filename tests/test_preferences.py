from __future__ import annotations

from pathlib import Path

import pytest

from downloads_organizer.preferences import PreferenceStore


def test_preferences_persist_destination_and_auto_confirm(workspace, tmp_path: Path):
    settings, db = workspace
    destination = tmp_path / "Course Archive"
    store = PreferenceStore(db, settings)

    store.set_destination(destination)
    store.set_auto_confirm(True, 0.94)
    resolved = store.resolved_settings()

    assert resolved.organized_dir == destination.resolve()
    assert resolved.auto_confirm_enabled is True
    assert resolved.auto_confirm_threshold == pytest.approx(0.94)


def test_preferences_reject_downloads_as_destination_and_low_threshold(workspace):
    settings, db = workspace
    store = PreferenceStore(db, settings)

    with pytest.raises(ValueError, match="不能直接等于 Downloads"):
        store.set_destination(settings.downloads)
    with pytest.raises(ValueError, match="0.85"):
        store.set_auto_confirm(True, 0.5)


def test_preferences_reject_file_as_destination(workspace, tmp_path: Path):
    settings, db = workspace
    destination = tmp_path / "not-a-directory"
    destination.write_text("occupied", encoding="utf-8")

    with pytest.raises(ValueError, match="不是目录"):
        PreferenceStore(db, settings).set_destination(destination)
