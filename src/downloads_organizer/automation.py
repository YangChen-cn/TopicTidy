from __future__ import annotations

from dataclasses import asdict, dataclass

from .config import Settings
from .db import Database
from .locking import app_lock
from .scanner import scan
from .workflow import AutoConfirmResult, auto_confirm_plan, create_proposal


@dataclass
class DailyRunResult:
    scan_stats: dict[str, int]
    auto_confirm_enabled: bool
    plan_id: int | None = None
    batch_id: int | None = None
    eligible_topics: list[str] | None = None
    moved: int = 0
    skipped: int = 0
    semantic_error: str | None = None
    translation_warnings: list[str] | None = None

    def as_dict(self) -> dict[str, object]:
        return asdict(self)


class DailyAutomationService:
    """Application service suitable for CLI, launchd, and a future GUI."""

    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings

    def run(self, *, use_semantic: bool = True) -> DailyRunResult:
        with app_lock(self.settings.data_dir):
            scan_stats = scan(self.db, self.settings)
            if not self.settings.auto_confirm_enabled:
                return DailyRunResult(scan_stats, False)
            proposal = create_proposal(
                self.db,
                self.settings,
                use_semantic=use_semantic,
            )
            confirmed: AutoConfirmResult = auto_confirm_plan(
                self.db,
                self.settings,
                proposal.plan_id,
                self.settings.auto_confirm_threshold,
            )
        return DailyRunResult(
            scan_stats=scan_stats,
            auto_confirm_enabled=True,
            plan_id=proposal.plan_id,
            batch_id=confirmed.batch_id,
            eligible_topics=confirmed.eligible_topics,
            moved=confirmed.moved,
            skipped=confirmed.skipped,
            semantic_error=proposal.semantic_error,
            translation_warnings=proposal.translation_warnings,
        )
