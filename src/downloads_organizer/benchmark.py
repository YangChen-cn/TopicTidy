from __future__ import annotations

import hashlib
import json
import tempfile
from importlib.resources import files as resource_files
from pathlib import Path
from typing import Any

from .clustering import cluster
from .config import Settings
from .db import Database, dumps
from .text_features import keywords


def default_fixture_path() -> Path:
    return Path(str(resource_files("downloads_organizer.fixtures").joinpath("benchmark_core.json")))


def _pairs(groups: list[set[str]]) -> set[tuple[str, str]]:
    return {
        tuple(sorted((left, right)))
        for group in groups
        for left in group
        for right in group
        if left < right
    }


def _load_fixture(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data.get("documents"), list) or not isinstance(data.get("expected_clusters"), dict):
        raise ValueError("benchmark fixture 必须包含 documents 和 expected_clusters")
    return data


def run_benchmark(path: Path | None = None) -> dict[str, Any]:
    fixture_path = path or default_fixture_path()
    fixture = _load_fixture(fixture_path)
    with tempfile.TemporaryDirectory(prefix="topictidy-benchmark-") as temp:
        root = Path(temp)
        downloads = root / "Downloads"
        downloads.mkdir()
        settings = Settings(downloads=downloads, data_dir=root / "state", stable_seconds=0)
        db = Database(settings.database)
        try:
            for index, document in enumerate(fixture["documents"], start=1):
                name = str(document["name"])
                content = str(document.get("content", ""))
                digest = hashlib.sha256((name + "\0" + content).encode()).hexdigest()
                path_value = downloads / name
                cursor = db.conn.execute(
                    """INSERT INTO files(path,name,extension,size,created_at,modified_at,device,inode,fingerprint,source_urls,status,last_seen)
                    VALUES(?,?,?,?,0,0,1,?,?,?,'active',0)""",
                    (str(path_value), name, path_value.suffix.lower(), len(content), index, digest,
                     dumps(document.get("source_urls", []))),
                )
                vector = document.get("vector")
                db.conn.execute(
                    """INSERT INTO features(
                    file_id,fingerprint,extractor_version,model_version,text,title,keywords,summary,
                    native_embedding,native_embedding_space
                    ) VALUES(?,?,?,'benchmark-fixed',?,?,?,?,?,?)""",
                    (cursor.lastrowid, digest, "benchmark:1", content, document.get("title", ""),
                     dumps(keywords(content)), content[:600], json.dumps(vector).encode() if vector else None,
                     document.get("native_space", "benchmark-multilingual")),
                )
                pivot = document.get("pivot_vector")
                if pivot:
                    db.conn.execute(
                        """INSERT INTO semantic_pivots(
                        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
                        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
                        ) VALUES(?,?,?,'en',?,?,'benchmark-translation',?,'en','benchmark-pivot',0)""",
                        (cursor.lastrowid, digest, document.get("native_space", "en"), content,
                         document.get("translated_content", content), json.dumps(pivot).encode()),
                    )
            db.conn.commit()
            predicted, unclassified = cluster(db, settings)
        finally:
            db.close()

    expected_groups = [set(members) for members in fixture["expected_clusters"].values()]
    predicted_groups = [{file.name for file in group.files} for group in predicted]
    expected_pairs, predicted_pairs = _pairs(expected_groups), _pairs(predicted_groups)
    true_positive = len(expected_pairs & predicted_pairs)
    precision = true_positive / len(predicted_pairs) if predicted_pairs else (1.0 if not expected_pairs else 0.0)
    recall = true_positive / len(expected_pairs) if expected_pairs else 1.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    expected_normalized = {frozenset(group) for group in expected_groups}
    predicted_normalized = {frozenset(group) for group in predicted_groups}
    return {
        "fixture": str(fixture_path),
        "expected_clusters": {name: sorted(members) for name, members in fixture["expected_clusters"].items()},
        "predicted_clusters": {group.display_name: sorted(file.name for file in group.files) for group in predicted},
        "expected_unclassified": sorted(fixture.get("expected_unclassified", [])),
        "predicted_unclassified": sorted(file.name for file in unclassified),
        "pairwise_precision": round(precision, 4),
        "pairwise_recall": round(recall, 4),
        "pairwise_f1": round(f1, 4),
        "exact_cluster_match": expected_normalized == predicted_normalized,
        "unclassified_match": set(fixture.get("expected_unclassified", [])) == {file.name for file in unclassified},
    }
