from __future__ import annotations

import collections
import re
from urllib.parse import unquote, urlparse

WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,}|[\u4e00-\u9fff]{2,}")
STOPWORDS = {
    "the", "and", "for", "with", "from", "this", "that", "chapter", "introduction",
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

