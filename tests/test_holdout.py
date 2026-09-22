from __future__ import annotations

from importlib.resources import files as resource_files
from pathlib import Path

from downloads_organizer.benchmark import run_benchmark


def holdout_path() -> Path:
    return Path(str(resource_files("downloads_organizer.fixtures").joinpath("holdout_unseen.json")))


def test_unseen_holdout_preserves_precision_and_unclassified_files():
    result = run_benchmark(holdout_path())

    assert result["pairwise_precision"] == 1.0
    assert result["pairwise_recall"] >= 0.90
    assert result["pairwise_f1"] >= 0.94
    assert result["unclassified_match"]
