from __future__ import annotations

from pathlib import Path

from .base import DocumentExtractor, ExtractionContext
from .office import DocxExtractor, PptxExtractor
from .pdf import PdfExtractor
from .plain import PlainTextExtractor
from ..models import Extracted
from ..text_features import TEXT_FEATURE_VERSION


class ExtractorRegistry:
    def __init__(self, extractors: list[DocumentExtractor] | None = None):
        self._extractors = list(extractors or [])

    def register(self, extractor: DocumentExtractor) -> None:
        self._extractors.append(extractor)

    def for_path(self, path: Path) -> DocumentExtractor | None:
        return next((extractor for extractor in self._extractors if extractor.supports(path)), None)

    def cache_version(self, path: Path) -> str:
        extractor = self.for_path(path)
        extractor_version = f"{extractor.name}:{extractor.version}" if extractor else "metadata-only:1"
        return f"{extractor_version};text-features:{TEXT_FEATURE_VERSION}"

    def extract(self, path: Path, max_chars: int) -> Extracted:
        extractor = self.for_path(path)
        if extractor is None:
            return Extracted()
        try:
            return extractor.extract(path, ExtractionContext(max_chars=max_chars))
        except Exception as exc:
            return Extracted(error=f"{type(exc).__name__}: {exc}")


def default_registry() -> ExtractorRegistry:
    return ExtractorRegistry([PdfExtractor(), DocxExtractor(), PptxExtractor(), PlainTextExtractor()])
