from __future__ import annotations

import os
from dataclasses import replace

import pytest

from downloads_organizer.clustering import cluster, save_plan
from downloads_organizer.operations import apply_plan, edit_plan, preview_moves, undo_batch
from downloads_organizer.scanner import scan

from conftest import put


def _course_plan(settings, db):
    put(settings.downloads, "ELEC6008 Chapter 1.md", "one")
    put(settings.downloads, "ELEC6008 Chapter 2.md", "two")
    scan(db, settings)
    groups, unclassified = cluster(db, settings)
    return save_plan(db, settings, groups, unclassified)


def test_apply_uses_deterministic_collision_name_and_undo_restores(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    existing = settings.organized_dir / "ELEC6008" / "ELEC6008 Chapter 1.md"
    existing.parent.mkdir(parents=True)
    existing.write_text("existing", encoding="utf-8")

    preview = preview_moves(db, settings, plan_id)
    assert any(item["destination"].name == "ELEC6008 Chapter 1 (2).md" for item in preview)
    batch_id, results = apply_plan(db, settings, plan_id)
    assert all(item["status"] == "moved" for item in results)
    undo_id, undone = undo_batch(db, settings, batch_id)
    assert undo_id > batch_id
    assert all(item["status"] == "undone" for item in undone)
    assert (settings.downloads / "ELEC6008 Chapter 1.md").exists()


def test_apply_skips_file_changed_after_plan(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    changed = settings.downloads / "ELEC6008 Chapter 1.md"
    changed.write_text("changed after plan", encoding="utf-8")

    _, results = apply_plan(db, settings, plan_id)

    assert any(item["status"] == "skipped" and "已改变" in item["error"] for item in results)
    assert changed.exists()


def test_undo_skips_when_original_path_is_occupied(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    batch_id, _ = apply_plan(db, settings, plan_id)
    put(settings.downloads, "ELEC6008 Chapter 1.md", "replacement")

    _, results = undo_batch(db, settings, batch_id)

    assert any(item["status"] == "skipped" and "原路径已被占用" in item["error"] for item in results)


def test_manual_exclusion_is_used_by_future_proposals(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    member = db.conn.execute(
        "SELECT id FROM plan_members WHERE plan_id=? ORDER BY id LIMIT 1", (plan_id,)
    ).fetchone()[0]
    edit_plan(db, plan_id, "exclude", [str(member)], settings.organized_dir)

    groups, unclassified = cluster(db, settings)

    assert len(groups) == 0
    assert len(unclassified) == 2


def test_confirmed_topic_becomes_prototype_for_new_download(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    batch_id, results = apply_plan(db, settings, plan_id)
    assert batch_id and all(item["status"] == "moved" for item in results)
    put(settings.downloads, "ELEC6008 Revision.md", "revision")
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert len(groups) == 1
    assert groups[0].name == "ELEC6008"
    assert [file.name for file in groups[0].files] == ["ELEC6008 Revision.md"]
    assert not unclassified


def test_rename_changes_display_name_without_changing_topic_identity(workspace):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    before = db.conn.execute(
        "SELECT DISTINCT topic_key FROM plan_members WHERE plan_id=?", (plan_id,)
    ).fetchone()[0]

    edit_plan(db, plan_id, "rename", ["ELEC6008", "Power Conversion"], settings.organized_dir)

    member = db.conn.execute(
        "SELECT topic_key,group_name,destination FROM plan_members WHERE plan_id=? LIMIT 1", (plan_id,)
    ).fetchone()
    topic = db.conn.execute(
        "SELECT topic_key,display_name,source FROM topics WHERE topic_key=?", (before,)
    ).fetchone()
    assert member["topic_key"] == before
    assert member["group_name"] == "Power Conversion"
    assert member["destination"] is None
    assert topic["topic_key"] == before
    assert topic["display_name"] == "Power Conversion"
    assert topic["source"] == "manual"

    groups, _ = cluster(db, settings)
    assert groups[0].topic_key == before
    assert groups[0].display_name == "Power Conversion"


def test_plan_keeps_custom_destination_after_setting_changes(workspace, tmp_path):
    settings, db = workspace
    custom = tmp_path / "Sorted Files"
    original_settings = replace(settings, organized_root=custom)
    plan_id = _course_plan(original_settings, db)
    changed_settings = replace(settings, organized_root=tmp_path / "Somewhere Else")

    preview = preview_moves(db, changed_settings, plan_id)
    assert all(str(item["destination"]).startswith(str(custom)) for item in preview)

    batch_id, results = apply_plan(db, changed_settings, plan_id)
    assert all(item["status"] == "moved" for item in results)
    assert (custom / "ELEC6008" / "ELEC6008 Chapter 1.md").exists()

    _, undone = undo_batch(db, changed_settings, batch_id)
    assert all(item["status"] == "undone" for item in undone)


@pytest.mark.parametrize("operation_kind", ["apply", "auto_apply"])
def test_recovery_restores_topic_association_after_crash_immediately_after_rename(
    workspace, monkeypatch, operation_kind,
):
    settings, db = workspace
    plan_id = _course_plan(settings, db)
    real_rename = os.rename

    class SimulatedCrash(BaseException):
        pass

    def rename_then_crash(source, destination):
        real_rename(source, destination)
        raise SimulatedCrash

    monkeypatch.setattr("downloads_organizer.operations.os.rename", rename_then_crash)
    with pytest.raises(SimulatedCrash):
        apply_plan(db, settings, plan_id, operation_kind=operation_kind)

    batch = db.conn.execute(
        "SELECT id,status,kind FROM operation_batches ORDER BY id DESC LIMIT 1"
    ).fetchone()
    log = db.conn.execute(
        "SELECT * FROM operation_logs WHERE batch_id=? ORDER BY id LIMIT 1", (batch["id"],)
    ).fetchone()
    member = db.conn.execute(
        "SELECT topic_key FROM plan_members WHERE plan_id=? AND file_id=?",
        (plan_id, log["file_id"]),
    ).fetchone()
    assert batch["status"] == "running"
    assert batch["kind"] == operation_kind
    assert db.conn.execute("SELECT COUNT(*) FROM associations").fetchone()[0] == 0

    assert db.recover_interrupted() == 1

    recovered = db.conn.execute(
        "SELECT path,status FROM files WHERE id=?", (log["file_id"],)
    ).fetchone()
    association = db.conn.execute(
        "SELECT topic_key,active FROM associations WHERE file_fingerprint=?", (log["fingerprint"],)
    ).fetchone()
    assert recovered["path"] == log["destination"]
    assert recovered["status"] == "organized"
    assert association["topic_key"] == member["topic_key"]
    assert association["active"] == 1
