from __future__ import annotations

import collections
import re
from pathlib import Path
from urllib.parse import unquote, urlparse

WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9]{1,}|[\u4e00-\u9fff]{2,}")
TEXT_FEATURE_VERSION = "2"
STOPWORDS = {
    "the", "and", "for", "with", "from", "this", "that", "a", "an", "of", "to", "in",
    "is", "are", "was", "were", "be", "been", "being", "as", "at", "by", "on", "or",
    "if", "it", "its", "we", "you", "they", "he", "she", "them", "our", "your", "their",
    "can", "could", "will", "would", "may", "might", "should", "do", "does", "did", "not",
    "have", "has", "had", "also", "than", "then", "there", "here", "when", "where", "which",
    "who", "what", "how", "all", "any", "some", "such", "into", "over", "under", "between",
    "these", "those", "using", "used", "use", "more", "most", "other", "each", "one", "two",
    "chapter", "introduction",
    "lecture", "lectures", "notes", "slide", "slides", "document", "documents", "file",
    "course", "week", "part", "version", "final", "copy", "download", "revision", "revised",
    "的", "了", "和", "以及", "课程", "讲义", "章节", "介绍", "文档", "文件",
}


def tokenize(value: str, *, remove_stopwords: bool = True) -> list[str]:
    tokens = [token.lower() for token in WORD_RE.findall(value)]
    if remove_stopwords:
        return [token for token in tokens if token not in STOPWORDS and not token.isdigit()]
    return tokens


def keywords(text: str, limit: int = 12) -> list[str]:
    counts = collections.Counter(tokenize(text))
    return [word for word, _ in counts.most_common(limit)]


def url_tokens(urls: list[str]) -> set[str]:
    values: set[str] = set()
    for url in urls:
        parsed = urlparse(url)
        values.update(tokenize(unquote(parsed.path + " " + parsed.query)))
    return values


def document_reference_names(text: str) -> tuple[set[str], set[str]]:
    """Return local filenames and stems referenced by Markdown/wiki links."""
    references = re.findall(r"\[[^\]]+\]\(([^)]+)\)", text)
    references.extend(re.findall(r"\[\[([^\]|#]+)", text))
    names: set[str] = set()
    stems: set[str] = set()
    for raw in references:
        value = unquote(raw.split("#", 1)[0].split("?", 1)[0]).strip()
        if not value or "://" in value:
            continue
        name = Path(value).name.casefold()
        names.add(name)
        stems.add(Path(name).stem)
    return names, stems
