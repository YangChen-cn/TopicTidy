from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, runtime_checkable

from ..models import Extracted
from ..text_features import keywords


@dataclass(frozen=True)
class ExtractionContext:
    max_chars: int


@runtime_checkable
class DocumentExtractor(Protocol):
    name: str
    version: str

    def supports(self, path: Path) -> bool: ...

    def extract(self, path: Path, context: ExtractionContext) -> Extracted: ...


def finalize_text(text: str, *, truncated: bool = False, title_hint: str = "") -> Extracted:
    normalized = re.sub(r"[ \t]+", " ", text).strip()
    lines = [line.strip(" #\t") for line in normalized.splitlines() if len(line.strip()) >= 3]
    title = title_hint.strip()[:180] or (lines[0][:180] if lines else "")
    representative = " ".join(lines[:5])[:600]
    return Extracted(
        text=normalized,
        title=title,
        keywords=keywords(normalized),
        summary=representative,
        truncated=truncated,
    )

