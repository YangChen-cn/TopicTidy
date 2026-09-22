from __future__ import annotations

from dataclasses import replace

from downloads_organizer.automation import DailyAutomationService
from downloads_organizer.clustering import cluster, save_plan
from downloads_organizer.scanner import scan
from downloads_organizer.workflow import auto_confirm_plan

from conftest import put


def test_daily_run_auto_confirms_only_high_confidence_groups(workspace):
    settings, db = workspace
    settings = replace(settings, auto_confirm_enabled=True, auto_confirm_threshold=0.92)
    put(settings.downloads, "ELEC6008 Lecture 1.md", "power electronics")
    put(settings.downloads, "ELEC6008 Lecture 2.md", "power conversion")
    put(settings.downloads, "random.json", "{}")

    result = DailyAutomationService(db, settings).run(use_semantic=False)

    assert result.plan_id is not None
    assert result.batch_id is not None
    assert result.eligible_topics == ["ELEC6008"]
    assert result.moved == 2
    assert (settings.organized_dir / "ELEC6008" / "ELEC6008 Lecture 1.md").exists()
    assert (settings.downloads / "random.json").exists()
    batch = db.conn.execute("SELECT kind FROM operation_batches WHERE id=?", (result.batch_id,)).fetchone()
    assert batch["kind"] == "auto_apply"


def test_daily_run_without_auto_confirm_only_scans(workspace):
    settings, db = workspace
    put(settings.downloads, "ELEC6008 Lecture 1.md", "one")
    put(settings.downloads, "ELEC6008 Lecture 2.md", "two")

    result = DailyAutomationService(db, settings).run(use_semantic=False)

    assert result.auto_confirm_enabled is False
    assert result.plan_id is None
    assert db.conn.execute("SELECT COUNT(*) FROM plans").fetchone()[0] == 0
    assert db.conn.execute("SELECT COUNT(*) FROM operation_batches").fetchone()[0] == 0


def test_auto_confirm_threshold_can_leave_group_for_manual_review(workspace):
    settings, db = workspace
    settings = replace(settings, auto_confirm_enabled=True, auto_confirm_threshold=0.99)
    put(settings.downloads, "ELEC6008 Lecture 1.md", "one")
    put(settings.downloads, "ELEC6008 Lecture 2.md", "two")

    result = DailyAutomationService(db, settings).run(use_semantic=False)

    assert result.plan_id is not None
    assert result.batch_id is None
    assert result.moved == 0
    assert (settings.downloads / "ELEC6008 Lecture 1.md").exists()
    plan = db.conn.execute("SELECT status FROM plans WHERE id=?", (result.plan_id,)).fetchone()
    assert plan["status"] == "no_auto_matches"


def test_auto_confirm_never_applies_group_with_conflict(workspace):
    settings, db = workspace
    put(settings.downloads, "ELEC6008 Lecture 1.md", "one")
    put(settings.downloads, "ELEC6008 Lecture 2.md", "two")
    scan(db, settings)
    groups, unclassified = cluster(db, settings)
    plan_id = save_plan(db, settings, groups, unclassified)
    db.conn.execute(
        "UPDATE plan_members SET conflicts='[\"人工注入的冲突\"]' WHERE plan_id=?",
        (plan_id,),
    )
    db.conn.commit()

    result = auto_confirm_plan(db, settings, plan_id, 0.90)

    assert result.batch_id is None
    assert result.eligible_topics == []
    assert (settings.downloads / "ELEC6008 Lecture 1.md").exists()
