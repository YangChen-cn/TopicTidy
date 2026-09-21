from __future__ import annotations

from pathlib import Path

from .base import ExtractionContext, finalize_text
from ..models import Extracted


class PlainTextExtractor:
    name = "plain-text"
    version = "1"
    suffixes = {".txt", ".md", ".markdown"}

    def supports(self, path: Path) -> bool:
        return path.suffix.lower() in self.suffixes

    def extract(self, path: Path, context: ExtractionContext) -> Extracted:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            text = handle.read(context.max_chars + 1)
        truncated = len(text) > context.max_chars
        return finalize_text(text[:context.max_chars], truncated=truncated)

