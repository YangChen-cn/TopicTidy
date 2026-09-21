from __future__ import annotations

from .models import IndexedFile


def _sample(value: str, budget: int) -> str:
    value = " ".join(value.split())
    if len(value) <= budget:
        return value
    if budget < 12:
        return value[:budget]
    separator_budget = len(" … ") * 2
    part = max(1, (budget - separator_budget) // 3)
    middle = max(0, len(value) // 2 - part // 2)
    return " … ".join((value[:part], value[middle:middle + part], value[-part:]))


def build_semantic_text(file: IndexedFile, *, max_chars: int = 2400) -> str:
    """Build a short, stable representation for embedding and translation.

    Metadata gets a reserved prefix and the extracted body is sampled from the
    front, middle, and tail.  The function never returns more than max_chars.
    """
    if max_chars < 256:
        raise ValueError("semantic text budget must be at least 256 characters")

    sections: list[str] = []
    seen: set[str] = set()
    for label, value in (
        ("Title", file.title or file.path.stem),
        ("Summary", file.summary),
        ("Keywords", ", ".join(file.keywords)),
    ):
        cleaned = " ".join(value.split())
        key = cleaned.casefold()
        if cleaned and key not in seen:
            sections.append(f"{label}: {cleaned}")
            seen.add(key)

    prefix = "\n".join(sections)
    body_budget = max(0, max_chars - len(prefix) - (2 if prefix else 0))
    body = _sample(file.text, body_budget) if body_budget else ""
    result = "\n\n".join(part for part in (prefix, body) if part)
    return result[:max_chars]
