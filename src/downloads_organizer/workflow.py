from __future__ import annotations

from dataclasses import dataclass, field

from .clustering import AUTO_CONFIRM_SUPPORT_KINDS, cluster, save_plan
from .config import Settings
from .db import Database, dumps, loads
from .embedding import NativeMacOSEncoder, SemanticEncoder
from .models import IndexedFile, ProposedGroup
from .operations import apply_plan
from .translation import NativeTranslationBackend, TranslationBackend


@dataclass
class ProposalResult:
    plan_id: int
    groups: list[ProposedGroup]
    unclassified: list[IndexedFile]
    encoder_version: str | None = None
    translation_version: str | None = None
    semantic_error: str | None = None
    translation_warnings: list[str] = field(default_factory=list)


@dataclass
class AutoConfirmResult:
    plan_id: int
    eligible_topics: list[str]
    batch_id: int | None
    moved: int
    skipped: int


def create_proposal(
    db: Database,
    settings: Settings,
    *,
    use_semantic: bool = True,
    encoder: SemanticEncoder | None = None,
    translator: TranslationBackend | None = None,
) -> ProposalResult:
    semantic_error = None
    translation_warnings: list[str] = []
    active_encoder = encoder
    active_translator = translator
    if use_semantic and active_encoder is None:
        try:
            active_encoder = NativeMacOSEncoder(settings)
            active_translator = NativeTranslationBackend(settings, prepare=False)
        except RuntimeError as exc:
            semantic_error = str(exc)
            active_encoder = None
            active_translator = None
    groups, unclassified = cluster(
        db,
        settings,
        encoder=active_encoder if use_semantic else None,
        translator=active_translator if use_semantic else None,
        translation_messages=translation_warnings,
    )
    plan_id = save_plan(db, settings, groups, unclassified)
    return ProposalResult(
        plan_id=plan_id,
        groups=groups,
        unclassified=unclassified,
        encoder_version=active_encoder.version if active_encoder and use_semantic else None,
        translation_version=active_translator.version if active_translator and use_semantic else None,
        semantic_error=semantic_error,
        translation_warnings=translation_warnings,
    )


def auto_confirm_plan(
    db: Database,
    settings: Settings,
    plan_id: int,
    threshold: float,
) -> AutoConfirmResult:
    """Confirm and apply only complete, conflict-free groups above the threshold."""
    rows = db.conn.execute(
        """SELECT topic_key,group_name,confidence,conflicts,evidence,excluded
        FROM plan_members WHERE plan_id=? AND group_name IS NOT NULL""",
        (plan_id,),
    ).fetchall()
    grouped: dict[str, list] = {}
    for row in rows:
        if row["topic_key"]:
            grouped.setdefault(str(row["topic_key"]), []).append(row)
    eligible_keys = set()
    for key, members in grouped.items():
        complete = all(not bool(member["excluded"]) for member in members)
        conflict_free = all(not loads(member["conflicts"], []) for member in members)
        confident = min(float(member["confidence"]) for member in members) >= threshold
        evidence = [
            item
            for member in members
            for item in loads(member["evidence"], [])
            if isinstance(item, dict)
        ]
        uses_document_links = any(
            item.get("kind") == "document_links" and item.get("strength") == "strong"
            for item in evidence
        )
        independent_strong = any(
            item.get("kind") in AUTO_CONFIRM_SUPPORT_KINDS
            and item.get("strength") == "strong"
            for item in evidence
        )
        document_links_safe = not uses_document_links or independent_strong
        if complete and conflict_free and confident and document_links_safe:
            eligible_keys.add(key)
    eligible_topics = sorted({
        str(member["group_name"])
        for key, members in grouped.items()
        if key in eligible_keys
        for member in members
    })
    with db.transaction() as conn:
        if eligible_keys:
            placeholders = ",".join("?" for _ in eligible_keys)
            conn.execute(
                f"""UPDATE plan_members SET excluded=1
                WHERE plan_id=? AND (topic_key IS NULL OR topic_key NOT IN ({placeholders}))""",
                (plan_id, *sorted(eligible_keys)),
            )
        else:
            conn.execute("UPDATE plan_members SET excluded=1 WHERE plan_id=?", (plan_id,))
        plan = conn.execute("SELECT config_json FROM plans WHERE id=?", (plan_id,)).fetchone()
        config = loads(plan["config_json"], {}) if plan else {}
        config["auto_confirm"] = {
            "threshold": threshold,
            "eligible_topic_keys": sorted(eligible_keys),
        }
        conn.execute(
            "UPDATE plans SET status=?,config_json=? WHERE id=?",
            ("auto_confirmed" if eligible_keys else "no_auto_matches", dumps(config), plan_id),
        )
    if not eligible_keys:
        return AutoConfirmResult(plan_id, [], None, 0, 0)
    batch_id, results = apply_plan(db, settings, plan_id, operation_kind="auto_apply")
    return AutoConfirmResult(
        plan_id,
        eligible_topics,
        batch_id,
        sum(item["status"] == "moved" for item in results),
        sum(item["status"] != "moved" for item in results),
    )
