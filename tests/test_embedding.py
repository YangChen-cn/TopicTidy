from __future__ import annotations

import sys
from pathlib import Path

import pytest

from downloads_organizer.clustering import assess_pair
from downloads_organizer.embedding import NativeMacOSEncoder
from downloads_organizer.models import IndexedFile


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS NaturalLanguage backend")
def test_native_macos_encoder_is_small_offline_and_language_scoped(workspace):
    settings, _ = workspace
    encoder = NativeMacOSEncoder(settings)

    encoded = encoder.encode(["renewable energy systems", "可再生能源系统"])

    assert settings.native_helper.stat().st_size < 1_000_000
    assert encoded[0].space == "en"
    assert encoded[1].space == "zh-Hans"
    assert len(encoded[0].vector or []) == 512
    # Some clean macOS runners do not have the Chinese system asset installed.
    # The backend must report the space and degrade without downloading it.
    assert encoded[1].vector is None or len(encoded[1].vector) > 0


def _indexed(name: str, vector: list[float], space: str, identifier: int) -> IndexedFile:
    return IndexedFile(
        id=identifier,
        path=Path(name),
        name=name,
        extension=Path(name).suffix,
        size=1,
        created_at=0,
        modified_at=0,
        device=1,
        inode=identifier,
        fingerprint=str(identifier),
        source_urls=[],
        text="",
        title="",
        keywords=[],
        summary="",
        extraction_error=None,
        vector=vector,
        vector_space=space,
    )


def test_vectors_from_different_language_spaces_are_not_compared():
    english = _indexed("alpha.txt", [1.0, 0.0], "en", 1)
    chinese = _indexed("beta.txt", [1.0, 0.0], "zh-Hans", 2)

    assessment = assess_pair(english, chinese)

    assert assessment.metrics["semantic_similarity"] == 0.0
    semantic = next(item for item in assessment.evidence if item.kind == "semantic_similarity")
    assert semantic.strength == "none"


def test_different_languages_use_cached_english_pivots():
    english = _indexed("energy.txt", [1.0, 0.0], "en", 1)
    chinese = _indexed("能源.txt", [0.0, 1.0], "zh-Hans", 2)
    english.pivot_vector = [1.0, 0.0]
    english.pivot_space = "en"
    english.pivot_source_language = "en"
    chinese.pivot_vector = [0.84, 0.16]
    chinese.pivot_space = "en"
    chinese.pivot_source_language = "zh-Hans"

    assessment = assess_pair(english, chinese)

    assert assessment.metrics["semantic_similarity"] == 0.0
    assert assessment.metrics["semantic_cross_language"] > 0.8
    evidence = next(item for item in assessment.evidence if item.kind == "semantic_cross_language")
    assert evidence.strength == "strong"
    assert "zh-Hans → en" in evidence.detail


def test_same_language_prefers_native_vectors_over_pivots():
    left = _indexed("left.txt", [1.0, 0.0], "en", 1)
    right = _indexed("right.txt", [0.0, 1.0], "en", 2)
    left.pivot_vector = right.pivot_vector = [1.0, 0.0]
    left.pivot_space = right.pivot_space = "en"
    left.pivot_source_language = right.pivot_source_language = "en"

    assessment = assess_pair(left, right)

    assert assessment.metrics["semantic_similarity"] == 0.0
    assert assessment.metrics["semantic_cross_language"] == 0.0
