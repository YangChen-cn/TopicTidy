from __future__ import annotations

import hashlib
import re
from collections import Counter
from urllib.parse import unquote, urlparse

from .config import COURSE_PATTERN
from .models import IndexedFile
from .text_features import STOPWORDS, tokenize

NOISE = STOPWORDS | {
    "v1", "v2", "v3", "draft", "updated", "update", "new", "old", "assignment",
    "solution", "solutions", "tutorial", "lab", "material", "materials", "main", "readme",
    "md", "pdf", "docx", "pptx", "txt",
}


def topic_key(files: list[IndexedFile], course_code: str = "") -> str:
    if course_code:
        return f"course:{course_code.upper()}"
    identity = "\n".join(sorted(file.fingerprint for file in files))
    return "cluster:" + hashlib.sha256(identity.encode()).hexdigest()[:20]


def _clean_tokens(value: str) -> list[str]:
    value = COURSE_PATTERN.sub(" ", value)
    value = re.sub(r"(?i)\b(?:v(?:ersion)?\s*)?\d+(?:\.\d+)*\b", " ", value)
    return [token for token in tokenize(value) if token not in NOISE]


def _ngrams(tokens: list[str]) -> list[tuple[str, ...]]:
    result = []
    for size in range(2, min(4, len(tokens)) + 1):
        result.extend(tuple(tokens[index:index + size]) for index in range(len(tokens) - size + 1))
    return result


def _format_phrase(tokens: tuple[str, ...]) -> str:
    spellings = {"freertos": "FreeRTOS", "linux": "Linux", "ml": "ML", "mlb": "MLB"}
    words = [
        spellings.get(token, token.upper() if any(char.isdigit() for char in token) else token.title())
        for token in tokens
    ]
    return " ".join(words)[:80]


def display_name(files: list[IndexedFile], course_code: str = "") -> str:
    if course_code:
        return course_code.upper()

    sources = []
    document_tokens = []
    for file in files:
        stem_tokens = _clean_tokens(file.path.stem)
        title_tokens = _clean_tokens(file.title)
        sources.extend([stem_tokens, title_tokens])
        document_tokens.append(set(stem_tokens + title_tokens + file.keywords + tokenize(file.text[:20_000])))

    stem_lists = [_clean_tokens(file.path.stem) for file in files]
    stem_common: tuple[str, ...] = ()
    if stem_lists:
        common = set(stem_lists[0]).intersection(*(set(tokens) for tokens in stem_lists[1:]))
        stem_common = tuple(dict.fromkeys(token for token in stem_lists[0] if token in common))[:4]

    source_lists = [
        _clean_tokens(unquote(urlparse(url).path))
        for file in files for url in file.source_urls
    ]
    if len(stem_common) <= 1 and source_lists:
        common = set(source_lists[0]).intersection(*(set(tokens) for tokens in source_lists[1:]))
        source_common = tuple(dict.fromkeys(token for token in source_lists[0] if token in common))[:4]
        if len(source_common) >= 2:
            return _format_phrase(source_common)
    if stem_common:
        return _format_phrase(stem_common)

    title_lists = [_clean_tokens(file.title) for file in files]
    if title_lists:
        common = set(title_lists[0]).intersection(*(set(tokens) for tokens in title_lists[1:]))
        stable = tuple(
            token for token in title_lists[0]
            if token in common and (any(char.isdigit() for char in token) or token in {"freertos", "linux"})
        )[:4]
        if stable:
            return _format_phrase(stable)

    candidates = Counter(ngram for source in sources for ngram in _ngrams(source))
    ranked: list[tuple[float, tuple[str, ...]]] = []
    for phrase, origin_count in candidates.items():
        coverage = sum(set(phrase).issubset(tokens) for tokens in document_tokens)
        if coverage < max(2, len(files) // 2 + 1):
            continue
        length_bonus = {2: 2.0, 3: 1.2}.get(len(phrase), 0.3)
        ranked.append((coverage * 10 + origin_count * 2 + length_bonus, phrase))
    if ranked:
        _, phrase = max(ranked, key=lambda item: item[0])
        return _format_phrase(phrase)

    if title_lists:
        common = set(title_lists[0]).intersection(*(set(tokens) for tokens in title_lists[1:]))
        ordered = tuple(token for token in title_lists[0] if token in common)[:4]
        if ordered:
            return _format_phrase(ordered)

    informative_titles = [tokens for tokens in title_lists if tokens]
    if informative_titles:
        return _format_phrase(tuple(min(informative_titles, key=lambda tokens: (len(tokens), tokens))[:4]))
    return "Related Documents"
