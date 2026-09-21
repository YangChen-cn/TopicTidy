from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class Extracted:
    text: str = ""
    title: str = ""
    keywords: list[str] = field(default_factory=list)
    summary: str = ""
    truncated: bool = False
    error: str | None = None


@dataclass
class IndexedFile:
    id: int
    path: Path
    name: str
    extension: str
    size: int
    created_at: float
    modified_at: float
    device: int
    inode: int
    fingerprint: str
    source_urls: list[str]
    text: str
    title: str
    keywords: list[str]
    summary: str
    extraction_error: str | None
    vector: list[float] | None = None


@dataclass
class ProposedGroup:
    name: str
    confidence: float
    files: list[IndexedFile]
    reasons: list[str]
    conflicts: list[str] = field(default_factory=list)

    def as_dict(self, destination: Path) -> dict[str, Any]:
        return {
            "name": self.name,
            "confidence": round(self.confidence, 3),
            "confidence_note": "启发式评分，不代表统计准确率",
            "destination": str(destination / self.name),
            "files": [str(f.path) for f in self.files],
            "reasons": self.reasons,
            "conflicts": self.conflicts,
        }

