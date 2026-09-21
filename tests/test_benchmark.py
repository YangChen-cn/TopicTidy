from __future__ import annotations

from downloads_organizer.benchmark import run_benchmark


def test_core_benchmark_detects_expected_clusters_without_false_merges():
    result = run_benchmark()

    assert result["pairwise_precision"] == 1.0
    assert result["pairwise_recall"] == 1.0
    assert result["pairwise_f1"] == 1.0
    assert result["exact_cluster_match"]
    assert result["unclassified_match"]
    assert result["predicted_clusters"]["Grid Storage"] == [
        "Grid Storage Design v1.pdf",
        "Grid Storage Design v2.docx",
    ]

