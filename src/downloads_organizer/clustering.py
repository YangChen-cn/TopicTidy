from __future__ import annotations

import json
import re
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from .config import (
    COURSE_PATTERN,
    CROSS_LANGUAGE_TIME_WINDOW_SECONDS,
    Settings,
    all_courses,
    body_courses,
    is_body_course_candidate,
)
from .db import Database, dumps, loads
from .embedding import SemanticEncoder
from .models import Evidence, IndexedFile, ProposedGroup
from .semantic_text import build_semantic_text, semantic_cache_version, semantic_language
from .text_features import document_reference_names, url_tokens, tokenize
from .topic_naming import display_name, topic_key
from .translation import TranslationBackend, ensure_pivot_embeddings


@dataclass(frozen=True)
class PairAssessment:
    total: float
    metrics: dict[str, float]
    evidence: list[Evidence]
    conflicts: list[str]


def _tokens(value: str) -> set[str]:
    generic = {"pdf", "docx", "pptx", "txt", "markdown", "final", "copy", "download"}
    return {token for token in tokenize(value) if token not in generic}


def _jaccard(left: set[str], right: set[str]) -> float:
    return len(left & right) / len(left | right) if left and right else 0.0


def _overlap(left: set[str], right: set[str]) -> float:
    return len(left & right) / min(len(left), len(right)) if left and right else 0.0


def _series_title_tokens(value: str) -> set[str]:
    """Return identifier-like title tokens, such as FreeRTOS or CS229.

    Ordinary phrases like "machine learning" are intentionally excluded: they
    describe a field, but do not establish that two files belong to one series.
    """
    result = set()
    for token in re.findall(r"[A-Za-z][A-Za-z0-9]{2,}", value):
        has_mixed_case = any(char.islower() for char in token) and any(char.isupper() for char in token[1:])
        if any(char.isdigit() for char in token) or has_mixed_case:
            result.add(token.casefold())
    return result


def _document_link_targets(file: IndexedFile, candidates: list[IndexedFile]) -> list[IndexedFile]:
    """Resolve explicit Markdown/wiki links to other indexed top-level files."""
    names, stems = document_reference_names(file.text)
    return [
        candidate for candidate in candidates
        if candidate.id != file.id
        and (candidate.name.casefold() in names or candidate.path.stem.casefold() in stems)
    ]


def _cosine(left: list[float] | None, right: list[float] | None) -> float:
    if not left or not right or len(left) != len(right):
        return 0.0
    return max(0.0, min(1.0, sum(a * b for a, b in zip(left, right))))


def _source_score(left: IndexedFile, right: IndexedFile) -> tuple[float, str]:
    path_similarity = _jaccard(url_tokens(left.source_urls), url_tokens(right.source_urls))
    left_domains = {urlparse(url).netloc for url in left.source_urls}
    right_domains = {urlparse(url).netloc for url in right.source_urls}
    shared_domains = sorted(left_domains & right_domains)
    domain_bonus = 0.15 if shared_domains else 0.0
    score = min(1.0, path_similarity + domain_bonus)
    if path_similarity >= 0.35:
        detail = f"来源 URL 路径相似度 {path_similarity:.2f}"
    elif shared_domains:
        detail = f"仅共享下载域名 {shared_domains[0]}"
    else:
        detail = "没有共同下载来源证据"
    return score, detail


def _primary_course(file: IndexedFile) -> str:
    strong = all_courses(file.path.stem + " " + " ".join(file.source_urls))
    if len(strong) == 1:
        return next(iter(strong))
    title_courses = body_courses(file.title)
    if len(title_courses) == 1:
        return next(iter(title_courses))
    body = COURSE_PATTERN.findall(file.text[:20_000])
    counts = Counter(
        f"{prefix.upper()}{number}"
        for prefix, number in body
        if is_body_course_candidate(prefix.upper(), number)
    )
    repeated = [code for code, count in counts.items() if count >= 2]
    return repeated[0] if len(repeated) == 1 else ""


def _body_course_candidates(file: IndexedFile) -> set[str]:
    """Return course codes found in the representative document text.

    A single body occurrence is deliberately only a candidate.  It becomes
    strong evidence when another document independently exposes the same code.
    """
    return body_courses(" ".join((file.title, file.summary, file.text[:20_000])))


def _declared_course(file: IndexedFile) -> str:
    strong = _primary_course(file)
    if strong:
        return strong
    candidates = _body_course_candidates(file)
    return next(iter(candidates)) if len(candidates) == 1 else ""


def _strength(kind: str, score: float) -> str:
    strong_at = {"filename": 0.50, "content": 0.40, "semantic": 0.82, "source_url": 0.50}
    weak_at = {"filename": 0.15, "content": 0.15, "semantic": 0.60, "source_url": 0.01}
    if score >= strong_at[kind]:
        return "strong"
    if score >= weak_at[kind]:
        return "weak"
    return "none"


def _cross_language_detail(left: IndexedFile, right: IndexedFile, score: float) -> str:
    languages = sorted({
        language for language in (left.pivot_source_language, right.pivot_source_language)
        if language and language != "en"
    })
    route = "、".join(languages) + " → en" if languages else "未使用 English pivot"
    return f"跨语言语义相似度 {score:.2f}（{route}）"


def _time_gap(left: IndexedFile, right: IndexedFile) -> float:
    gaps = []
    if left.created_at > 0 and right.created_at > 0:
        gaps.append(abs(left.created_at - right.created_at))
    if left.modified_at > 0 and right.modified_at > 0:
        gaps.append(abs(left.modified_at - right.modified_at))
    return min(gaps) if gaps else float("inf")


def assess_pair(left: IndexedFile, right: IndexedFile) -> PairAssessment:
    left_filename = _tokens(left.path.stem)
    right_filename = _tokens(right.path.stem)
    filename = max(_jaccard(left_filename, right_filename), _overlap(left_filename, right_filename))
    left_content = set(left.keywords) | _tokens(" ".join((left.title, left.summary[:600])))
    right_content = set(right.keywords) | _tokens(" ".join((right.title, right.summary[:600])))
    content = _jaccard(left_content, right_content)
    if _series_title_tokens(left.title) & _series_title_tokens(right.title):
        content = max(content, 0.50)
    same_native_space = bool(left.vector_space and left.vector_space == right.vector_space)
    semantic = _cosine(left.vector, right.vector) if same_native_space else 0.0
    cross_semantic = 0.0
    if (
        left.vector_space and right.vector_space and left.vector_space != right.vector_space
        and left.pivot_space == right.pivot_space == "en"
    ):
        cross_semantic = _cosine(left.pivot_vector, right.pivot_vector)
    semantic_for_score = semantic if same_native_space else cross_semantic
    source, source_detail = _source_score(left, right)
    left_primary, right_primary = _primary_course(left), _primary_course(right)
    left_course, right_course = _declared_course(left), _declared_course(right)
    shared_course = left_course if left_course and left_course == right_course else ""
    shared_from_body = bool(shared_course and not (left_primary == right_primary == shared_course))
    conflicts: list[str] = []

    evidence = [
        Evidence(
            "course_code",
            "strong" if shared_course else "none",
            1.0 if shared_course else 0.0,
            (f"共同正文课程代码 {shared_course}" if shared_from_body else f"共同课程代码 {shared_course}")
            if shared_course else "没有共同课程代码",
        ),
        Evidence("filename_similarity", _strength("filename", filename), filename, f"文件名相似度 {filename:.2f}"),
        Evidence("content_similarity", _strength("content", content), content, f"正文关键词相似度 {content:.2f}"),
        Evidence("semantic_similarity", _strength("semantic", semantic), semantic, f"本地语义相似度 {semantic:.2f}"),
        Evidence(
            "semantic_cross_language", _strength("semantic", cross_semantic), cross_semantic,
            _cross_language_detail(left, right, cross_semantic),
        ),
        Evidence("source_url", _strength("source_url", source), source, source_detail),
    ]

    if left_course and right_course and left_course != right_course:
        conflicts.append(f"课程号冲突：{left_course} / {right_course}")
        return PairAssessment(0.0, {
            "course_code": 0.0, "filename_similarity": filename, "content_similarity": content,
            "semantic_similarity": semantic, "semantic_cross_language": cross_semantic, "source_url": source,
        }, evidence, conflicts)

    score = filename * 0.32 + source * 0.13 + content * 0.25 + semantic_for_score * 0.30
    if shared_course:
        score = max(score, 0.96)
    if semantic_for_score >= 0.82 and content >= 0.20:
        score = max(score, 0.68)
    if semantic_for_score >= 0.60 and content >= 0.25:
        score = max(score, 0.65)
    if semantic_for_score >= 0.82 and filename >= 0.50:
        score = max(score, 0.68)
    if filename >= 0.50 and source >= 0.50:
        score = max(score, 0.68)
    if semantic_for_score >= 0.78 and source >= 0.50:
        score = max(score, 0.68)
    if cross_semantic >= 0.92:
        score = max(score, 0.65)
    elif cross_semantic >= 0.88 and _time_gap(left, right) <= CROSS_LANGUAGE_TIME_WINDOW_SECONDS:
        score = max(score, 0.65)
    return PairAssessment(score, {
        "course_code": 1.0 if shared_course else 0.0,
        "filename_similarity": filename,
        "content_similarity": content,
        "semantic_similarity": semantic,
        "semantic_cross_language": cross_semantic,
        "source_url": source,
    }, evidence, conflicts)


def pair_score(left: IndexedFile, right: IndexedFile) -> tuple[float, list[str], list[str]]:
    """Backward-compatible tuple API; structured callers should use assess_pair."""
    assessment = assess_pair(left, right)
    reasons = [item.detail for item in assessment.evidence if item.strength != "none"]
    return assessment.total, reasons, assessment.conflicts


def load_index(db: Database, statuses: tuple[str, ...] = ("active",)) -> list[IndexedFile]:
    placeholders = ",".join("?" for _ in statuses)
    rows = db.conn.execute(
        f"""SELECT f.*,x.text,x.title,x.keywords,x.summary,x.extraction_error,
        x.native_embedding,x.native_embedding_space,
        p.pivot_embedding,p.pivot_embedding_space,p.source_language AS pivot_source_language,
        p.embedding_version AS pivot_embedding_version
        FROM files f LEFT JOIN features x ON x.file_id=f.id
        LEFT JOIN semantic_pivots p ON p.file_id=f.id AND p.target_language='en' AND p.fingerprint=f.fingerprint
        WHERE f.status IN ({placeholders}) ORDER BY f.name""",
        statuses,
    ).fetchall()
    result = []
    for row in rows:
        vector = None
        if row["native_embedding"]:
            try:
                vector = json.loads(bytes(row["native_embedding"]).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                pass
        pivot_vector = None
        if row["pivot_embedding"]:
            try:
                pivot_vector = json.loads(bytes(row["pivot_embedding"]).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                pass
        result.append(IndexedFile(
            id=row["id"], path=Path(row["path"]), name=row["name"], extension=row["extension"],
            size=row["size"], created_at=row["created_at"], modified_at=row["modified_at"],
            device=row["device"], inode=row["inode"], fingerprint=row["fingerprint"],
            source_urls=loads(row["source_urls"], []), text=row["text"] or "", title=row["title"] or "",
            keywords=loads(row["keywords"], []), summary=row["summary"] or "",
            extraction_error=row["extraction_error"], vector=vector,
            vector_space=row["native_embedding_space"], pivot_vector=pivot_vector,
            pivot_space=row["pivot_embedding_space"], pivot_source_language=row["pivot_source_language"],
            pivot_embedding_version=row["pivot_embedding_version"],
        ))
    return result


def add_embeddings(db: Database, files: list[IndexedFile], encoder: SemanticEncoder) -> None:
    cache_version = semantic_cache_version(encoder.version)
    pending = []
    for file in files:
        row = db.conn.execute("SELECT model_version FROM features WHERE file_id=?", (file.id,)).fetchone()
        if file.text and (not file.vector or not row or row[0] != cache_version):
            file.vector = None
            pending.append(file)
    if not pending:
        return
    encoded_by_id = {}
    language_groups: dict[str, list[IndexedFile]] = {}
    for file in pending:
        language_groups.setdefault(semantic_language(file), []).append(file)
    for language, members in language_groups.items():
        texts = [build_semantic_text(file) for file in members]
        for file, encoded in zip(members, encoder.encode_in_language(texts, language)):
            encoded_by_id[file.id] = encoded
    for file in pending:
        encoded = encoded_by_id[file.id]
        file.vector = encoded.vector
        file.vector_space = encoded.space
        db.conn.execute(
            "UPDATE features SET native_embedding=?,native_embedding_space=?,model_version=? WHERE file_id=?",
            (json.dumps(encoded.vector).encode("utf-8") if encoded.vector is not None else None,
             encoded.space, cache_version, file.id),
        )
    db.conn.commit()


def _pivot_candidate_ids(files: list[IndexedFile], settings: Settings) -> set[int]:
    lexical_pairs: list[tuple[float, IndexedFile, IndexedFile]] = []
    exploration_by_file: dict[int, list[tuple[float, IndexedFile, IndexedFile]]] = {}
    for index, left in enumerate(files):
        for right in files[index + 1:]:
            if not left.vector_space or not right.vector_space or left.vector_space == right.vector_space:
                continue
            assessment = assess_pair(left, right)
            if assessment.conflicts or assessment.total >= settings.cluster_threshold:
                continue
            metrics = assessment.metrics
            lexical_signal = max(
                metrics["filename_similarity"] / 0.15,
                metrics["content_similarity"] / 0.10,
                metrics["source_url"] / 0.35,
            )
            if lexical_signal >= 1.0:
                lexical_pairs.append((-lexical_signal, left, right))
            else:
                gap = _time_gap(left, right)
                exploration_by_file.setdefault(left.id, []).append((gap, left, right))
                exploration_by_file.setdefault(right.id, []).append((gap, left, right))

    selected: set[int] = set()
    new_pivots: set[int] = set()

    def add_pair(left: IndexedFile, right: IndexedFile) -> bool:
        new_ids = {
            file.id for file in (left, right)
            if not file.pivot_vector and file.id not in new_pivots
        }
        if len(new_pivots) + len(new_ids) > settings.cross_language_translation_limit:
            return False
        selected.update((left.id, right.id))
        new_pivots.update(new_ids)
        return True

    for _, left, right in sorted(lexical_pairs, key=lambda item: (item[0], item[1].id, item[2].id)):
        add_pair(left, right)

    exploration_pairs: dict[tuple[int, int], tuple[float, IndexedFile, IndexedFile]] = {}
    for pairs in exploration_by_file.values():
        ordered = sorted(pairs, key=lambda item: (item[0], item[1].id, item[2].id))
        chosen = ordered[:1]
        chosen.extend(
            item for item in ordered[1:settings.cross_language_candidate_neighbors]
            if item[0] <= CROSS_LANGUAGE_TIME_WINDOW_SECONDS
        )
        for item in chosen:
            _, left, right = item
            exploration_pairs[(min(left.id, right.id), max(left.id, right.id))] = item

    for _, left, right in sorted(exploration_pairs.values(), key=lambda item: (item[0], item[1].id, item[2].id)):
        add_pair(left, right)
    return selected


def _complete_link(clusters: list[list[IndexedFile]], threshold: float) -> list[list[IndexedFile]]:
    while True:
        best: tuple[float, int, int] | None = None
        for left_index in range(len(clusters)):
            for right_index in range(left_index + 1, len(clusters)):
                scores = [
                    assess_pair(left, right).total
                    for left in clusters[left_index]
                    for right in clusters[right_index]
                ]
                score = min(scores) if scores else 0.0
                if score >= threshold and (best is None or score > best[0]):
                    best = (score, left_index, right_index)
        if best is None:
            return clusters
        _, left_index, right_index = best
        clusters[left_index].extend(clusters[right_index])
        del clusters[right_index]


def _metric_evidence(kind: str, score: float, course_code: str = "") -> Evidence:
    if kind == "course_code":
        return Evidence(kind, "strong" if course_code else "none", score,
                        f"共同课程代码 {course_code}" if course_code else "没有共同课程代码")
    labels = {
        "filename_similarity": "组内文件名相似度",
        "content_similarity": "组内正文关键词相似度",
        "semantic_similarity": "组内本地语义相似度",
        "semantic_cross_language": "组内跨语言语义相似度",
        "source_url": "组内来源 URL 证据",
    }
    strength_kind = "semantic" if kind == "semantic_cross_language" else kind.removesuffix("_similarity")
    return Evidence(kind, _strength(strength_kind, score), score, f"{labels[kind]} {score:.2f}")


def _group_details(files: list[IndexedFile], course_code: str = "") -> tuple[float, list[Evidence], list[str]]:
    if len(files) < 2:
        evidence = [_metric_evidence("course_code", 1.0 if course_code else 0.0, course_code)]
        evidence.extend(_metric_evidence(kind, 0.0) for kind in (
            "filename_similarity", "content_similarity", "semantic_similarity",
            "semantic_cross_language", "source_url",
        ))
        return (0.96 if course_code else 0.0), evidence, []
    assessments = [
        assess_pair(left, right)
        for index, left in enumerate(files)
        for right in files[index + 1:]
    ]
    scores = [assessment.total for assessment in assessments]
    confidence = min(scores) * 0.7 + (sum(scores) / len(scores)) * 0.3
    evidence = [_metric_evidence("course_code", 1.0 if course_code else 0.0, course_code)]
    for kind in (
        "filename_similarity", "content_similarity", "semantic_similarity",
        "semantic_cross_language", "source_url",
    ):
        values = [item.metrics[kind] for item in assessments]
        positive = [value for value in values if value > 0]
        value = (
            sum(positive) / len(positive)
            if kind in {"semantic_similarity", "semantic_cross_language"} and positive
            else sum(values) / len(values)
        )
        item = _metric_evidence(kind, value)
        if kind == "semantic_cross_language" and value > 0:
            languages = sorted({
                file.pivot_source_language for file in files
                if file.pivot_source_language and file.pivot_source_language != "en"
            })
            route = "、".join(languages) + " → en"
            item = Evidence(kind, item.strength, value, f"跨语言语义相似度 {value:.2f}（{route}）")
        evidence.append(item)
    conflicts = sorted({conflict for item in assessments for conflict in item.conflicts})
    return confidence, evidence, conflicts


def _new_group(files: list[IndexedFile], *, course_code: str = "") -> ProposedGroup:
    confidence, evidence, conflicts = _group_details(files, course_code)
    naming_course = course_code
    if not naming_course:
        observed = {code for file in files if (code := _declared_course(file))}
        if len(observed) == 1:
            naming_course = next(iter(observed))
            evidence[0] = Evidence(
                "course_code", "weak", 0.5,
                f"组内部分文件发现课程代码 {naming_course}",
            )
    name = display_name(files, naming_course)
    return ProposedGroup(topic_key(files, naming_course), name, confidence, files, evidence, conflicts)


def cluster(
    db: Database,
    settings: Settings,
    *,
    encoder: SemanticEncoder | None = None,
    translator: TranslationBackend | None = None,
    translation_messages: list[str] | None = None,
) -> tuple[list[ProposedGroup], list[IndexedFile]]:
    files = load_index(db)
    prototypes = load_index(db, ("organized",))
    if encoder:
        add_embeddings(db, files, encoder)
        add_embeddings(db, prototypes, encoder)
        if translator:
            all_files = files + prototypes
            for file in all_files:
                if file.pivot_embedding_version != semantic_cache_version(encoder.version):
                    file.pivot_vector = None
                    file.pivot_space = None
            candidate_ids = _pivot_candidate_ids(all_files, settings)
            selected = [file for file in all_files if file.id in candidate_ids]
            messages = ensure_pivot_embeddings(db, selected, encoder, translator)
            if translation_messages is not None:
                translation_messages.extend(messages)
    assigned: set[int] = set()
    groups: list[ProposedGroup] = []
    forced_unclassified: list[IndexedFile] = []

    for file in files:
        row = db.conn.execute(
            """SELECT action FROM corrections WHERE file_fingerprint=? AND active=1
            ORDER BY created_at DESC,id DESC LIMIT 1""", (file.fingerprint,),
        ).fetchone()
        if row and row[0] == "exclude":
            forced_unclassified.append(file)
            assigned.add(file.id)

    learned: dict[tuple[str, str], list[IndexedFile]] = {}
    for file in files:
        if file.id in assigned:
            continue
        row = db.conn.execute(
            """SELECT a.topic_key,t.display_name
            FROM associations a JOIN topics t ON t.topic_key=a.topic_key
            WHERE a.file_fingerprint=? AND a.active=1""",
            (file.fingerprint,),
        ).fetchone()
        if row:
            learned.setdefault((row[0], row[1]), []).append(file)
            assigned.add(file.id)
    for (key, name), members in learned.items():
        confidence, evidence, conflicts = _group_details(members, _primary_course(members[0]))
        evidence.insert(0, Evidence("manual_association", "strong", 1.0, "人工确认的主题关联"))
        groups.append(ProposedGroup(key, name, max(0.99, confidence), members, evidence, conflicts))

    prototype_topics: dict[tuple[str, str], list[IndexedFile]] = {}
    for prototype in prototypes:
        row = db.conn.execute(
            """SELECT a.topic_key,t.display_name
            FROM associations a JOIN topics t ON t.topic_key=a.topic_key
            WHERE a.file_fingerprint=? AND a.active=1""",
            (prototype.fingerprint,),
        ).fetchone()
        if row:
            prototype_topics.setdefault((row[0], row[1]), []).append(prototype)
    attached: dict[tuple[str, str], list[tuple[IndexedFile, PairAssessment]]] = {}
    for file in files:
        if file.id in assigned:
            continue
        matches = []
        for identity, examples in prototype_topics.items():
            comparisons = [assess_pair(file, example) for example in examples]
            scores = [comparison.total for comparison in comparisons]
            if scores and min(scores) >= settings.cluster_threshold:
                matches.append((sum(scores) / len(scores), identity, comparisons))
        if len(matches) == 1:
            _, identity, comparisons = matches[0]
            attached.setdefault(identity, []).append((file, min(comparisons, key=lambda item: item.total)))
            assigned.add(file.id)
    for (key, name), matches in attached.items():
        members = [item[0] for item in matches]
        confidence = min(item[1].total for item in matches)
        evidence = [Evidence("learned_topic", "strong", 1.0, "匹配已确认的主题样本")]
        for kind in (
            "filename_similarity", "content_similarity", "semantic_similarity",
            "semantic_cross_language", "source_url",
        ):
            score = sum(item[1].metrics[kind] for item in matches) / len(matches)
            metric = _metric_evidence(kind, score)
            if kind == "semantic_cross_language" and score > 0:
                details = {
                    entry.detail
                    for _, assessment in matches
                    for entry in assessment.evidence
                    if entry.kind == kind and entry.score and entry.score > 0
                }
                metric = Evidence(kind, metric.strength, score, "；".join(sorted(details)))
            evidence.append(metric)
        groups.append(ProposedGroup(key, name, confidence, members, evidence))

    course_map: dict[str, list[IndexedFile]] = {}
    for file in files:
        if file.id in assigned:
            continue
        code = _primary_course(file)
        if code:
            course_map.setdefault(code, []).append(file)
            assigned.add(file.id)

    # A body course code mentioned once cannot classify a document by itself.
    # Promote it only when at least two independent files expose the same code.
    body_candidates: dict[int, set[str]] = {}
    body_counts: Counter[str] = Counter()
    for file in files:
        if file.id in assigned:
            continue
        candidates = _body_course_candidates(file)
        body_candidates[file.id] = candidates
        body_counts.update(candidates)
    for file in files:
        if file.id in assigned:
            continue
        shared = {code for code in body_candidates[file.id] if body_counts[code] >= 2}
        if len(shared) == 1:
            code = next(iter(shared))
            course_map.setdefault(code, []).append(file)
            assigned.add(file.id)
    for file in files:
        if file.id in assigned:
            continue
        candidates = []
        for code, members in course_map.items():
            assessments = [assess_pair(file, member) for member in members]
            if assessments and min(item.total for item in assessments) >= settings.course_attach_threshold:
                candidates.append((sum(item.total for item in assessments) / len(assessments), code))
        if len(candidates) == 1:
            course_map[candidates[0][1]].append(file)
            assigned.add(file.id)
    for code, members in course_map.items():
        if len(members) < 2:
            assigned.remove(members[0].id)
            continue
        group = _new_group(members, course_code=code)
        group.confidence = max(0.90, group.confidence)
        groups.append(group)

    # A local index/README that explicitly links several present documents is
    # strong collection evidence. Process the largest hubs first and never use
    # transitive links, so one bridge document cannot chain unrelated groups.
    available = [file for file in files if file.id not in assigned]
    linked_collections = []
    for hub in available:
        linked = _document_link_targets(hub, available)
        if len(linked) >= 3:
            members = [hub, *linked]
            declared = {code for member in members if (code := _declared_course(member))}
            if len(declared) <= 1:
                linked_collections.append((len(members), hub, members))
    for _, hub, candidates in sorted(linked_collections, key=lambda item: (-item[0], item[1].id)):
        members = [member for member in candidates if member.id not in assigned]
        if hub.id in assigned or len(members) < 4:
            continue
        group = _new_group(members)
        if hub.title and hub.path.stem.casefold() in {"readme", "index", "contents", "toc"}:
            group.display_name = hub.title.strip()[:80]
        group.confidence = max(group.confidence, 0.92)
        group.evidence.insert(0, Evidence(
            "document_links", "strong", 1.0,
            f"{hub.name} 明确链接组内 {len(members) - 1} 个文件",
        ))
        groups.append(group)
        assigned.update(member.id for member in members)

    remaining = [file for file in files if file.id not in assigned]
    clusters = _complete_link([[file] for file in remaining], settings.cluster_threshold)
    unclassified = list(forced_unclassified)
    for members in clusters:
        if len(members) < 2:
            unclassified.extend(members)
        else:
            groups.append(_new_group(members))
    for group in groups:
        saved = db.conn.execute(
            "SELECT display_name FROM topics WHERE topic_key=? AND active=1 AND source='manual'", (group.topic_key,),
        ).fetchone()
        if saved:
            group.display_name = saved[0]
    return sorted(groups, key=lambda group: group.display_name.lower()), sorted(unclassified, key=lambda file: file.name.lower())


def save_plan(
    db: Database,
    settings: Settings,
    groups: list[ProposedGroup],
    unclassified: list[IndexedFile],
) -> int:
    now = time.time()
    with db.transaction() as conn:
        cursor = conn.execute(
            "INSERT INTO plans(created_at,status,config_json) VALUES(?, 'draft', ?)",
            (now, dumps({
                "cluster_threshold": settings.cluster_threshold,
                "cross_language_candidate_neighbors": settings.cross_language_candidate_neighbors,
                "cross_language_translation_limit": settings.cross_language_translation_limit,
                "cross_language_time_window_seconds": CROSS_LANGUAGE_TIME_WINDOW_SECONDS,
                "organized_dir": str(settings.organized_dir),
            })),
        )
        plan_id = cursor.lastrowid
        for group in groups:
            conn.execute(
                """INSERT INTO topics(topic_key,display_name,source,active)
                VALUES(?,?,'proposal',1)
                ON CONFLICT(topic_key) DO UPDATE SET display_name=COALESCE(topics.display_name,excluded.display_name),active=1""",
                (group.topic_key, group.display_name),
            )
            for file in group.files:
                conn.execute(
                    """INSERT INTO plan_members(
                    plan_id,file_id,topic_key,group_name,confidence,reasons,evidence,conflicts,source_fingerprint,destination
                    ) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                    (plan_id, file.id, group.topic_key, group.display_name, group.confidence, dumps(group.reasons),
                     dumps([item.as_dict() for item in group.evidence]), dumps(group.conflicts), file.fingerprint,
                     str(settings.organized_dir / group.display_name / file.name)),
                )
        for file in unclassified:
            conn.execute(
                """INSERT INTO plan_members(plan_id,file_id,topic_key,group_name,confidence,source_fingerprint)
                VALUES(?,?,NULL,NULL,0,?)""",
                (plan_id, file.id, file.fingerprint),
            )
    return int(plan_id)
