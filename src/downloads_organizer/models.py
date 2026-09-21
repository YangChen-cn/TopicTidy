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
    vector_space: str | None = None


@dataclass
class Evidence:
    kind: str
    strength: str
    score: float | None
    detail: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "strength": self.strength,
            "score": round(self.score, 3) if self.score is not None else None,
            "detail": self.detail,
        }


@dataclass
class ProposedGroup:
    topic_key: str
    display_name: str
    confidence: float
    files: list[IndexedFile]
    evidence: list[Evidence]
    conflicts: list[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        """Compatibility alias for CLI and operation code."""
        return self.display_name

    @property
    def reasons(self) -> list[str]:
        return [item.detail for item in self.evidence if item.strength != "none"]

    def as_dict(self, destination: Path) -> dict[str, Any]:
        return {
            "topic_id": self.topic_key,
            "display_name": self.display_name,
            "name": self.display_name,
            "confidence": round(self.confidence, 3),
            "confidence_note": "启发式评分，不代表统计准确率",
            "destination": str(destination / self.display_name),
            "files": [str(f.path) for f in self.files],
            "reasons": self.reasons,
            "evidence": [item.as_dict() for item in self.evidence],
            "conflicts": self.conflicts,
        }
