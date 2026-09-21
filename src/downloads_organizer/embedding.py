from __future__ import annotations

import json
import math
import os
from pathlib import Path

from .config import MODEL_ID, Settings


def download_model(settings: Settings, revision: str = "main") -> dict[str, str]:
    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        raise RuntimeError("请先安装模型依赖：pip install 'downloads-organizer[model]'") from exc
    settings.model_dir.parent.mkdir(parents=True, exist_ok=True)
    resolved = snapshot_download(repo_id=MODEL_ID, revision=revision, local_dir=settings.model_dir)
    commit = Path(resolved).resolve().name if "snapshots" in str(resolved) else revision
    try:
        from huggingface_hub import HfApi
        commit = HfApi().model_info(MODEL_ID, revision=revision).sha
    except Exception:
        pass
    manifest = {"model_id": MODEL_ID, "requested_revision": revision, "resolved_revision": commit}
    (settings.model_dir / "organizer-model.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


class LocalEncoder:
    def __init__(self, settings: Settings):
        manifest_path = settings.model_dir / "organizer-model.json"
        if not manifest_path.exists():
            raise RuntimeError("本地模型尚未安装；运行 downloads-organizer model download")
        self.manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as exc:
            raise RuntimeError("请先安装模型依赖：pip install 'downloads-organizer[model]'") from exc
        self.model = SentenceTransformer(str(settings.model_dir), local_files_only=True)

    @property
    def version(self) -> str:
        return str(self.manifest["resolved_revision"])

    def encode(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        prepared: list[str] = []
        owners: list[int] = []
        for owner, text in enumerate(texts):
            chunks = [text[index:index + 2_000] for index in range(0, len(text), 2_000)] or [""]
            if len(chunks) > 32:
                step = (len(chunks) - 1) / 31
                chunks = [chunks[round(index * step)] for index in range(32)]
            prepared.extend("passage: " + chunk for chunk in chunks)
            owners.extend([owner] * len(chunks))
        chunk_vectors = self.model.encode(prepared, normalize_embeddings=True, show_progress_bar=False)
        dimensions = len(chunk_vectors[0])
        sums = [[0.0] * dimensions for _ in texts]
        counts = [0] * len(texts)
        for owner, vector in zip(owners, chunk_vectors):
            counts[owner] += 1
            for index, value in enumerate(vector):
                sums[owner][index] += float(value)
        results = []
        for values, count in zip(sums, counts):
            averaged = [value / count for value in values]
            norm = math.sqrt(sum(value * value for value in averaged)) or 1.0
            results.append([value / norm for value in averaged])
        return results
