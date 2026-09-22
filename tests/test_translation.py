from __future__ import annotations

from pathlib import Path

from downloads_organizer.clustering import cluster
from downloads_organizer.config import CROSS_LANGUAGE_TIME_WINDOW_SECONDS
from downloads_organizer.embedding import EncodedVector
from downloads_organizer.models import IndexedFile
from downloads_organizer.scanner import scan
from downloads_organizer.semantic_text import build_semantic_text, semantic_cache_version
from downloads_organizer.translation import LanguagePair

from conftest import put


class FixedCrossLanguageEncoder:
    version = "fixed-native:1"

    def encode(self, texts: list[str]) -> list[EncodedVector]:
        return [
            EncodedVector([0.0, 1.0], "zh-Hans")
            if any("\u4e00" <= character <= "\u9fff" for character in text)
            else EncodedVector([1.0, 0.0], "en")
            for text in texts
        ]

    def encode_in_language(self, texts: list[str], language: str) -> list[EncodedVector]:
        results = []
        for text in texts:
            lowered = text.lower()
            if language != "en":
                vector = [0.0, 1.0]
            elif "cooking" in lowered or "kitchen" in lowered:
                vector = [0.0, 1.0]
            else:
                vector = [1.0, 0.0]
            results.append(EncodedVector(vector, language))
        return results


class FixedTranslator:
    version = "fixed-translation:1"

    def __init__(self):
        self.translate_calls = 0

    def statuses(self, pairs: list[LanguagePair]) -> dict[LanguagePair, str]:
        return {pair: "installed" for pair in pairs}

    def translate(self, texts: list[str], *, source: str, target: str = "en") -> list[str]:
        self.translate_calls += 1
        assert source == "zh-Hans"
        assert target == "en"
        return [
            "Cooking recipes and kitchen equipment."
            if "烹饪" in text else
            "Battery storage systems capacity safety and grid operations."
            for text in texts
        ]


def _file(text: str) -> IndexedFile:
    return IndexedFile(
        id=1, path=Path("report.pdf"), name="report.pdf", extension=".pdf", size=len(text),
        created_at=0, modified_at=0, device=1, inode=1, fingerprint="fingerprint",
        source_urls=[], text=text, title="Energy Systems", keywords=["energy", "storage"],
        summary="A concise energy systems summary.", extraction_error=None,
    )


def test_semantic_text_is_bounded_and_samples_document_regions():
    text = "front-marker " + "a " * 3000 + " middle-marker " + "b " * 3000 + " tail-marker"

    result = build_semantic_text(_file(text), max_chars=2400)

    assert len(result) <= 2400
    assert "Title: Energy Systems" in result
    assert "Keywords: energy, storage" in result
    assert "front-marker" in result
    assert "middle-marker" in result
    assert "tail-marker" in result


def test_pivot_translation_is_lazy_cached_and_explained(workspace, monkeypatch):
    settings, db = workspace
    put(settings.downloads, "储能概论.md", "电池储能系统容量安全与电网调度")
    put(settings.downloads, "Battery Storage.md", "Battery storage systems capacity safety and grid operations")
    monkeypatch.setattr(
        "downloads_organizer.scanner.source_urls",
        lambda _: ["https://lms.example.edu/course/storage/lecture"],
    )
    scan(db, settings)
    encoder = FixedCrossLanguageEncoder()
    translator = FixedTranslator()
    messages: list[str] = []

    groups, unclassified = cluster(
        db, settings, encoder=encoder, translator=translator, translation_messages=messages,
    )

    assert not unclassified
    assert len(groups) == 1
    assert translator.translate_calls == 1
    assert not messages
    cross = next(item for item in groups[0].evidence if item.kind == "semantic_cross_language")
    assert cross.strength == "strong"
    assert "zh-Hans → en" in cross.detail
    assert db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0] == 2

    cluster(db, settings, encoder=encoder, translator=translator)
    assert translator.translate_calls == 1

    db.conn.execute("UPDATE semantic_pivots SET embedding_version='old-embedding'")
    db.conn.commit()
    cluster(db, settings, encoder=encoder, translator=translator)
    assert translator.translate_calls == 1
    assert {
        row[0] for row in db.conn.execute("SELECT embedding_version FROM semantic_pivots")
    } == {semantic_cache_version(encoder.version)}


def test_zero_lexical_clue_cross_language_pair_uses_temporal_recall(workspace):
    settings, db = workspace
    put(settings.downloads, "甲.md", "电池储能系统容量安全与电网调度")
    put(settings.downloads, "Reference.md", "Battery storage systems capacity safety and grid operations")
    scan(db, settings)
    encoder = FixedCrossLanguageEncoder()
    translator = FixedTranslator()

    groups, unclassified = cluster(db, settings, encoder=encoder, translator=translator)

    assert not unclassified
    assert len(groups) == 1
    assert translator.translate_calls == 1
    cross = next(item for item in groups[0].evidence if item.kind == "semantic_cross_language")
    assert cross.strength == "strong"


def test_temporal_recall_translates_but_does_not_merge_unrelated_files(workspace):
    settings, db = workspace
    put(settings.downloads, "无关说明.md", "烹饪食谱和厨房用品")
    put(settings.downloads, "Tax Receipt.md", "Annual personal tax payment receipt")
    scan(db, settings)
    encoder = FixedCrossLanguageEncoder()
    translator = FixedTranslator()

    groups, unclassified = cluster(db, settings, encoder=encoder, translator=translator)

    assert not groups
    assert len(unclassified) == 2
    assert translator.translate_calls == 1
    assert db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0] == 2


def test_nearest_cross_language_pair_is_explored_outside_temporal_window(workspace):
    settings, db = workspace
    put(settings.downloads, "甲.md", "电池储能系统容量安全与电网调度")
    put(settings.downloads, "Reference.md", "Battery storage systems capacity safety and grid operations")
    scan(db, settings)
    old = db.conn.execute("SELECT id FROM files WHERE name='甲.md'").fetchone()[0]
    db.conn.execute(
        "UPDATE files SET created_at=created_at-?,modified_at=modified_at-? WHERE id=?",
        (CROSS_LANGUAGE_TIME_WINDOW_SECONDS + 1, CROSS_LANGUAGE_TIME_WINDOW_SECONDS + 1, old),
    )
    db.conn.commit()
    translator = FixedTranslator()

    groups, unclassified = cluster(
        db, settings, encoder=FixedCrossLanguageEncoder(), translator=translator,
    )

    assert len(groups) == 1
    assert not unclassified
    assert translator.translate_calls == 1
    assert db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0] == 2


def test_cross_language_exploration_budget_advances_on_later_proposals(workspace):
    settings, db = workspace
    for index in range(13):
        put(settings.downloads, f"中语资料{index}.md", f"电池储能系统课程材料 {index}")
        put(settings.downloads, f"Reference-{index}.md", f"Battery storage course material {index}")
    scan(db, settings)
    encoder = FixedCrossLanguageEncoder()
    translator = FixedTranslator()

    cluster(db, settings, encoder=encoder, translator=translator)
    first_count = db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0]
    cluster(db, settings, encoder=encoder, translator=translator)
    second_count = db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0]

    assert first_count == settings.cross_language_translation_limit
    assert second_count == 26


def test_uninstalled_translation_degrades_without_failing(workspace, monkeypatch):
    settings, db = workspace
    put(settings.downloads, "한국어.md", "배터리 에너지 저장 시스템")
    put(settings.downloads, "Battery.md", "Battery energy storage system")
    monkeypatch.setattr(
        "downloads_organizer.scanner.source_urls",
        lambda _: ["https://lms.example.edu/course/storage/lecture"],
    )
    scan(db, settings)
    encoder = FixedCrossLanguageEncoder()
    # Make the first document a Korean-space vector without changing the fake encoder class.
    encoder.encode = lambda texts: [
        EncodedVector([0.0, 1.0], "ko") if "배터리" in text else EncodedVector([1.0, 0.0], "en")
        for text in texts
    ]

    class Uninstalled(FixedTranslator):
        def statuses(self, pairs: list[LanguagePair]) -> dict[LanguagePair, str]:
            return {pair: "supported" for pair in pairs}

    messages: list[str] = []
    groups, unclassified = cluster(
        db, settings, encoder=encoder, translator=Uninstalled(), translation_messages=messages,
    )

    assert not groups
    assert len(unclassified) == 2
    assert any("ko → en 翻译未安装" in message for message in messages)
