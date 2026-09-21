from __future__ import annotations

import json
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from .config import COURSE_PATTERN, NON_COURSE_PREFIXES, Settings, all_courses
from .db import Database, dumps, loads
from .embedding import SemanticEncoder
from .models import Evidence, IndexedFile, ProposedGroup
from .text_features import url_tokens, tokenize
from .topic_naming import display_name, topic_key


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
    body = COURSE_PATTERN.findall(file.text[:20_000])
    counts = Counter(
        f"{prefix.upper()}{number}"
        for prefix, number in body
        if prefix.upper() not in NON_COURSE_PREFIXES
    )
    repeated = [code for code, count in counts.items() if count >= 2]
    return repeated[0] if len(repeated) == 1 else ""


def _body_course_candidates(file: IndexedFile) -> set[str]:
    """Return course codes found in the representative document text.

    A single body occurrence is deliberately only a candidate.  It becomes
    strong evidence when another document independently exposes the same code.
    """
    return all_courses(" ".join((file.title, file.summary, file.text[:20_000])))


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


def assess_pair(left: IndexedFile, right: IndexedFile) -> PairAssessment:
    filename = _jaccard(_tokens(left.path.stem), _tokens(right.path.stem))
    content = _jaccard(set(left.keywords), set(right.keywords))
    semantic = _cosine(left.vector, right.vector) if left.vector_space == right.vector_space else 0.0
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
        Evidence("source_url", _strength("source_url", source), source, source_detail),
    ]

    if left_course and right_course and left_course != right_course:
        conflicts.append(f"课程号冲突：{left_course} / {right_course}")
        return PairAssessment(0.0, {
            "course_code": 0.0, "filename_similarity": filename, "content_similarity": content,
            "semantic_similarity": semantic, "source_url": source,
        }, evidence, conflicts)

    score = filename * 0.32 + source * 0.13 + content * 0.25 + semantic * 0.30
    if shared_course:
        score = max(score, 0.96)
    if semantic >= 0.82 and content >= 0.20:
        score = max(score, 0.68)
    if semantic >= 0.78 and source >= 0.50:
        score = max(score, 0.68)
    return PairAssessment(score, {
        "course_code": 1.0 if shared_course else 0.0,
        "filename_similarity": filename,
        "content_similarity": content,
        "semantic_similarity": semantic,
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
        f"""SELECT f.*,x.text,x.title,x.keywords,x.summary,x.extraction_error,x.embedding,x.embedding_space
        FROM files f LEFT JOIN features x ON x.file_id=f.id WHERE f.status IN ({placeholders}) ORDER BY f.name""",
        statuses,
    ).fetchall()
    result = []
    for row in rows:
        vector = None
        if row["embedding"]:
            try:
                vector = json.loads(bytes(row["embedding"]).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                pass
        result.append(IndexedFile(
            id=row["id"], path=Path(row["path"]), name=row["name"], extension=row["extension"],
            size=row["size"], created_at=row["created_at"], modified_at=row["modified_at"],
            device=row["device"], inode=row["inode"], fingerprint=row["fingerprint"],
            source_urls=loads(row["source_urls"], []), text=row["text"] or "", title=row["title"] or "",
            keywords=loads(row["keywords"], []), summary=row["summary"] or "",
            extraction_error=row["extraction_error"], vector=vector, vector_space=row["embedding_space"],
        ))
    return result


def add_embeddings(db: Database, files: list[IndexedFile], encoder: SemanticEncoder) -> None:
    pending = []
    for file in files:
        row = db.conn.execute("SELECT model_version FROM features WHERE file_id=?", (file.id,)).fetchone()
        if file.text and (not file.vector or not row or row[0] != encoder.version):
            file.vector = None
            pending.append(file)
    if not pending:
        return
    texts = [(file.title + "\n" + file.summary + "\n" + file.text).strip() for file in pending]
    for file, encoded in zip(pending, encoder.encode(texts)):
        file.vector = encoded.vector
        file.vector_space = encoded.space
        db.conn.execute(
            "UPDATE features SET embedding=?,embedding_space=?,model_version=? WHERE file_id=?",
            (json.dumps(encoded.vector).encode("utf-8") if encoded.vector is not None else None,
             encoded.space, encoder.version, file.id),
        )
    db.conn.commit()


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
        "source_url": "组内来源 URL 证据",
    }
    strength_kind = kind.removesuffix("_similarity")
    return Evidence(kind, _strength(strength_kind, score), score, f"{labels[kind]} {score:.2f}")


def _group_details(files: list[IndexedFile], course_code: str = "") -> tuple[float, list[Evidence], list[str]]:
    if len(files) < 2:
        evidence = [_metric_evidence("course_code", 1.0 if course_code else 0.0, course_code)]
        evidence.extend(_metric_evidence(kind, 0.0) for kind in (
            "filename_similarity", "content_similarity", "semantic_similarity", "source_url",
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
    for kind in ("filename_similarity", "content_similarity", "semantic_similarity", "source_url"):
        value = sum(item.metrics[kind] for item in assessments) / len(assessments)
        evidence.append(_metric_evidence(kind, value))
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
) -> tuple[list[ProposedGroup], list[IndexedFile]]:
    files = load_index(db)
    prototypes = load_index(db, ("organized",))
    if encoder:
        add_embeddings(db, files, encoder)
        add_embeddings(db, prototypes, encoder)
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
        for kind in ("filename_similarity", "content_similarity", "semantic_similarity", "source_url"):
            score = sum(item[1].metrics[kind] for item in matches) / len(matches)
            evidence.append(_metric_evidence(kind, score))
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
            "SELECT display_name FROM topics WHERE topic_key=? AND active=1", (group.topic_key,),
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
            (now, dumps({"cluster_threshold": settings.cluster_threshold, "organized_dir": str(settings.organized_dir)})),
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
