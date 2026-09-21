from __future__ import annotations

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
