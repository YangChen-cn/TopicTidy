from __future__ import annotations

import json
import time
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

from .config import COURSE_PATTERN, Settings, all_courses
from .db import Database, dumps, loads
from .embedding import LocalEncoder
from .extract import STOPWORDS, WORD_RE, url_tokens
from .models import IndexedFile, ProposedGroup


def _tokens(value: str) -> set[str]:
    generic = STOPWORDS | {"pdf", "docx", "pptx", "txt", "final", "copy", "download"}
    return {t.lower() for t in WORD_RE.findall(value) if t.lower() not in generic and not t.isdigit()}


def _jaccard(a: set[str], b: set[str]) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def _cosine(a: list[float] | None, b: list[float] | None) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    return max(0.0, min(1.0, sum(x * y for x, y in zip(a, b))))


def _source_score(a: IndexedFile, b: IndexedFile) -> float:
    paths = _jaccard(url_tokens(a.source_urls), url_tokens(b.source_urls))
    domains_a = {urlparse(x).netloc for x in a.source_urls}
    domains_b = {urlparse(x).netloc for x in b.source_urls}
    # A shared domain is weak evidence and cannot independently form a cluster.
    domain = 0.15 if domains_a & domains_b else 0.0
    return min(1.0, paths + domain)


def pair_score(a: IndexedFile, b: IndexedFile) -> tuple[float, list[str], list[str]]:
    filename = _jaccard(_tokens(a.path.stem), _tokens(b.path.stem))
    content = _jaccard(set(a.keywords), set(b.keywords))
    source = _source_score(a, b)
    semantic = _cosine(a.vector, b.vector)
    courses_a = all_courses(a.path.stem + " " + " ".join(a.source_urls))
    courses_b = all_courses(b.path.stem + " " + " ".join(b.source_urls))
    conflicts: list[str] = []
    if courses_a and courses_b and courses_a.isdisjoint(courses_b):
        conflicts.append(f"课程号冲突：{', '.join(sorted(courses_a))} / {', '.join(sorted(courses_b))}")
        return 0.0, [], conflicts
    score = filename * 0.32 + source * 0.13 + content * 0.25 + semantic * 0.30
    reasons = []
    if courses_a & courses_b:
        score = max(score, 0.96)
        reasons.append(f"相同课程号 {next(iter(courses_a & courses_b))}")
    if filename >= 0.3:
        reasons.append(f"文件名词元相似 {filename:.2f}")
    if content >= 0.25:
        reasons.append(f"正文关键词相似 {content:.2f}")
    if semantic >= 0.65:
        reasons.append(f"本地语义相似 {semantic:.2f}")
    # Strong agreement between semantic and lexical content can identify related
    # documents even when their filenames (for example, numbered lectures) differ.
    if semantic >= 0.82 and content >= 0.20:
        score = max(score, 0.68)
    if source >= 0.35:
        reasons.append(f"下载来源路径相似 {source:.2f}")
    return score, reasons, conflicts


def load_index(db: Database, statuses: tuple[str, ...] = ("active",)) -> list[IndexedFile]:
    placeholders = ",".join("?" for _ in statuses)
    rows = db.conn.execute(
        f"""SELECT f.*,x.text,x.title,x.keywords,x.summary,x.extraction_error,x.embedding
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
            extraction_error=row["extraction_error"], vector=vector,
        ))
    return result


def add_embeddings(db: Database, files: list[IndexedFile], encoder: LocalEncoder) -> None:
    pending = []
    for file in files:
        row = db.conn.execute("SELECT model_version FROM features WHERE file_id=?", (file.id,)).fetchone()
        if file.text and (not file.vector or not row or row[0] != encoder.version):
            file.vector = None
            pending.append(file)
    if not pending:
        return
    texts = [(f.title + "\n" + f.summary + "\n" + f.text).strip() for f in pending]
    for file, vector in zip(pending, encoder.encode(texts)):
        file.vector = vector
        db.conn.execute(
            "UPDATE features SET embedding=?,model_version=? WHERE file_id=?",
            (json.dumps(vector).encode("utf-8"), encoder.version, file.id),
        )
    db.conn.commit()


def _primary_course(file: IndexedFile) -> str:
    strong = all_courses(file.path.stem + " " + " ".join(file.source_urls))
    if len(strong) == 1:
        return next(iter(strong))
    body = COURSE_PATTERN.findall(file.text[:20_000])
    counts = Counter(f"{a.upper()}{n}" for a, n in body)
    repeated = [code for code, count in counts.items() if count >= 2]
    return repeated[0] if len(repeated) == 1 else ""


def _complete_link(clusters: list[list[IndexedFile]], threshold: float) -> list[list[IndexedFile]]:
    while True:
        best: tuple[float, int, int] | None = None
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                scores = [pair_score(a, b)[0] for a in clusters[i] for b in clusters[j]]
                score = min(scores) if scores else 0.0
                if score >= threshold and (best is None or score > best[0]):
                    best = (score, i, j)
        if best is None:
            return clusters
        _, i, j = best
        clusters[i].extend(clusters[j])
        del clusters[j]


def _topic_name(files: list[IndexedFile]) -> str:
    counts = Counter(word for file in files for word in file.keywords if word not in STOPWORDS)
    words = [word for word, _ in counts.most_common(3)]
    if words:
        return " ".join(word.title() if word.isascii() else word for word in words)[:80]
    stems = [_tokens(f.path.stem) for f in files]
    common = set.intersection(*stems) if stems and all(stems) else set()
    return " ".join(sorted(common))[:80].title() or "Related Files"


def _group_details(files: list[IndexedFile]) -> tuple[float, list[str], list[str]]:
    if len(files) < 2:
        return 0.0, [], []
    scores, reasons, conflicts = [], Counter(), set()
    for i, left in enumerate(files):
        for right in files[i + 1:]:
            score, why, problem = pair_score(left, right)
            scores.append(score)
            reasons.update(why)
            conflicts.update(problem)
    confidence = min(scores) * 0.7 + (sum(scores) / len(scores)) * 0.3
    return confidence, [r for r, _ in reasons.most_common(4)], sorted(conflicts)


def cluster(db: Database, settings: Settings, *, encoder: LocalEncoder | None = None) -> tuple[list[ProposedGroup], list[IndexedFile]]:
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
            ORDER BY created_at DESC,id DESC LIMIT 1""", (file.fingerprint,)
        ).fetchone()
        if row and row[0] == "exclude":
            forced_unclassified.append(file)
            assigned.add(file.id)

    # Confirmed associations are immutable seeds until the user rejects or undoes them.
    learned: dict[str, list[IndexedFile]] = {}
    for file in files:
        if file.id in assigned:
            continue
        row = db.conn.execute(
            "SELECT topic_name FROM associations WHERE file_fingerprint=? AND active=1", (file.fingerprint,)
        ).fetchone()
        if row:
            learned.setdefault(row[0], []).append(file)
            assigned.add(file.id)
    for name, members in learned.items():
        confidence, reasons, conflicts = _group_details(members)
        groups.append(ProposedGroup(name, max(0.99, confidence), members, ["人工确认的主题关联"] + reasons, conflicts))

    # Previously organized files remain local prototypes. They influence the
    # destination of new files but are never added to a new move plan.
    prototype_topics: dict[str, list[IndexedFile]] = {}
    for prototype in prototypes:
        row = db.conn.execute(
            "SELECT topic_name FROM associations WHERE file_fingerprint=? AND active=1",
            (prototype.fingerprint,),
        ).fetchone()
        if row:
            prototype_topics.setdefault(row[0], []).append(prototype)
    attached: dict[str, list[tuple[IndexedFile, float, list[str]]]] = {}
    for file in files:
        if file.id in assigned:
            continue
        matches = []
        for topic, examples in prototype_topics.items():
            comparisons = [pair_score(file, example) for example in examples]
            scores = [item[0] for item in comparisons]
            if scores and min(scores) >= settings.cluster_threshold:
                reasons = [reason for _, pair_reasons, _ in comparisons for reason in pair_reasons]
                matches.append((sum(scores) / len(scores), topic, reasons))
        if len(matches) == 1:
            score, topic, reasons = matches[0]
            attached.setdefault(topic, []).append((file, score, reasons))
            assigned.add(file.id)
    for topic, matches in attached.items():
        members = [item[0] for item in matches]
        confidence = min(item[1] for item in matches)
        reason_counts = Counter(reason for item in matches for reason in item[2])
        reasons = ["匹配已确认的主题样本"] + [reason for reason, _ in reason_counts.most_common(3)]
        groups.append(ProposedGroup(topic, confidence, members, reasons))

    course_map: dict[str, list[IndexedFile]] = {}
    for file in files:
        if file.id in assigned:
            continue
        code = _primary_course(file)
        if code:
            course_map.setdefault(code, []).append(file)
            assigned.add(file.id)
    # Attach an unlabelled file only when it matches every current course member sufficiently.
    for file in files:
        if file.id in assigned:
            continue
        candidates = []
        for code, members in course_map.items():
            scores = [pair_score(file, member)[0] for member in members]
            if scores and min(scores) >= settings.course_attach_threshold:
                candidates.append((sum(scores) / len(scores), code))
        if len(candidates) == 1:
            course_map[candidates[0][1]].append(file)
            assigned.add(file.id)
    for code, members in course_map.items():
        if len(members) < 2:
            assigned.remove(members[0].id)
            continue
        confidence, reasons, conflicts = _group_details(members)
        groups.append(ProposedGroup(code, max(0.90, confidence), members, reasons, conflicts))

    remaining = [f for f in files if f.id not in assigned]
    clusters = _complete_link([[file] for file in remaining], settings.cluster_threshold)
    unclassified = list(forced_unclassified)
    existing_names = {g.name for g in groups}
    for members in clusters:
        if len(members) < 2:
            unclassified.extend(members)
            continue
        confidence, reasons, conflicts = _group_details(members)
        name = _topic_name(members)
        base, index = name, 2
        while name in existing_names:
            name, index = f"{base} {index}", index + 1
        existing_names.add(name)
        groups.append(ProposedGroup(name, confidence, members, reasons, conflicts))
    return sorted(groups, key=lambda g: g.name.lower()), sorted(unclassified, key=lambda f: f.name.lower())


def save_plan(db: Database, settings: Settings, groups: list[ProposedGroup], unclassified: list[IndexedFile]) -> int:
    now = time.time()
    with db.transaction() as conn:
        cursor = conn.execute("INSERT INTO plans(created_at,status,config_json) VALUES(?, 'draft', ?)", (
            now, dumps({"cluster_threshold": settings.cluster_threshold, "organized_dir": str(settings.organized_dir)}),
        ))
        plan_id = cursor.lastrowid
        for group in groups:
            for file in group.files:
                conn.execute(
                    """INSERT INTO plan_members(plan_id,file_id,group_name,confidence,reasons,conflicts,source_fingerprint,destination)
                    VALUES(?,?,?,?,?,?,?,?)""",
                    (plan_id, file.id, group.name, group.confidence, dumps(group.reasons), dumps(group.conflicts),
                     file.fingerprint, str(settings.organized_dir / group.name / file.name)),
                )
        for file in unclassified:
            conn.execute(
                "INSERT INTO plan_members(plan_id,file_id,group_name,confidence,source_fingerprint) VALUES(?,?,NULL,0,?)",
                (plan_id, file.id, file.fingerprint),
            )
    return int(plan_id)
