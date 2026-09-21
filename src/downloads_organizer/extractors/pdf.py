from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

from .base import ExtractionContext, finalize_text
from ..models import Extracted


def sampled_page_indices(page_count: int) -> list[int]:
    """Return front, representative middle, and tail pages in reading order."""
    if page_count <= 8:
        return list(range(page_count))
    front = [0, 1, 2]
    middle = [round((page_count - 1) * fraction) for fraction in (0.25, 0.5, 0.75)]
    tail = [page_count - 2, page_count - 1]
    return list(dict.fromkeys(front + middle + tail))


class PdfExtractor:
    name = "pdf"
    version = "2"

    def __init__(self, reader_factory: Callable[[Path], Any] | None = None):
        self._reader_factory = reader_factory

    def supports(self, path: Path) -> bool:
        return path.suffix.lower() == ".pdf"

    def _reader(self, path: Path):
        if self._reader_factory:
            return self._reader_factory(path)
        from pypdf import PdfReader
        return PdfReader(path)

    def extract(self, path: Path, context: ExtractionContext) -> Extracted:
        reader = self._reader(path)
        if reader.is_encrypted:
            try:
                reader.decrypt("")
            except Exception as exc:
                raise ValueError("PDF 已加密") from exc
        page_count = len(reader.pages)
        indices = sampled_page_indices(page_count)
        if not indices:
            return Extracted()

        # Front pages receive twice the per-page budget. Middle and tail pages
        # still have reserved space, so a verbose first page cannot consume all
        # memory before representative pages are read.
        weights = [2 if index < 3 else 1 for index in indices]
        unit = max(1, context.max_chars // sum(weights))
        parts: list[str] = []
        used = 0
        truncated = len(indices) < page_count
        for index, weight in zip(indices, weights):
            if used >= context.max_chars:
                truncated = True
                break
            page_text = reader.pages[index].extract_text() or ""
            allowance = min(unit * weight, context.max_chars - used)
            selected = page_text[:allowance]
            if selected:
                parts.append(selected)
                used += len(selected)
            truncated |= len(selected) < len(page_text)
        combined = "\n".join(parts)
        truncated |= len(combined) > context.max_chars
        return finalize_text(combined[:context.max_chars], truncated=truncated)
