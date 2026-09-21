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
