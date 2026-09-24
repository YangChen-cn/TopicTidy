import Foundation

/// Per-run memo table for the per-file derivations `assess_pair` needs.
///
/// Every entry is a pure function of one `IndexedFile`, so caching cannot change
/// any score: it only avoids re-scanning the same 20k-character body and
/// re-tokenising the same strings for every pair in the corpus.
final class ClusterCache {
    private var filenameTokens: [Int: Set<String>] = [:]
    private var contentTokens: [Int: Set<String>] = [:]
    private var titleIdentifiers: [Int: Set<String>] = [:]
    private var primaryCourses: [Int: String] = [:]
    private var declaredCourses: [Int: String] = [:]
    private var bodyCandidates: [Int: Set<String>] = [:]
    private var urlTokens: [Int: Set<String>] = [:]
    private var domains: [Int: Set<String>] = [:]

    func filenameTokens(_ file: IndexedFile) -> Set<String> {
        if let cached = filenameTokens[file.id] { return cached }
        let value = ClusterMath.tokens(file.path.deletingPathExtension().lastPathComponent)
        filenameTokens[file.id] = value
        return value
    }

    func contentTokens(_ file: IndexedFile) -> Set<String> {
        if let cached = contentTokens[file.id] { return cached }
        let value = Set(file.keywords).union(ClusterMath.tokens("\(file.title) \(Py.prefix(file.summary, 600))"))
        contentTokens[file.id] = value
        return value
    }

    func titleIdentifiers(_ file: IndexedFile) -> Set<String> {
        if let cached = titleIdentifiers[file.id] { return cached }
        let value = ClusterMath.identifierLikeTokens(file.title)
        titleIdentifiers[file.id] = value
        return value
    }

    func primaryCourse(_ file: IndexedFile) -> String {
        if let cached = primaryCourses[file.id] { return cached }
        let value = ClusterMath.primaryCourse(file)
        primaryCourses[file.id] = value
        return value
    }

    func declaredCourse(_ file: IndexedFile) -> String {
        if let cached = declaredCourses[file.id] { return cached }
        let value = ClusterMath.declaredCourse(file)
        declaredCourses[file.id] = value
        return value
    }

    func bodyCourseCandidates(_ file: IndexedFile) -> Set<String> {
        if let cached = bodyCandidates[file.id] { return cached }
        let value = ClusterMath.bodyCourseCandidates(file)
        bodyCandidates[file.id] = value
        return value
    }

    func urlTokens(_ file: IndexedFile) -> Set<String> {
        if let cached = urlTokens[file.id] { return cached }
        let value = TextFeatures.urlTokens(file.sourceURLs)
        urlTokens[file.id] = value
        return value
    }

    func domains(_ file: IndexedFile) -> Set<String> {
        if let cached = domains[file.id] { return cached }
        let value = Set(file.sourceURLs.map { PyURL.parse($0).netloc })
        domains[file.id] = value
        return value
    }
}

public let autoConfirmSupportKinds: Set<String> = [
    "course_code", "series_identifier", "semantic_similarity",
    "semantic_cross_language", "source_url",
]

public struct PairAssessment: Sendable {
    public let total: Double
    public let metrics: [String: Double]
    public let evidence: [Evidence]
    public let conflicts: [String]
}

enum ClusterMath {
    static let genericTokens: Set<String> = [
        "pdf", "docx", "pptx", "txt", "markdown", "final", "copy", "download",
        "report", "project", "notes", "note", "document", "presentation", "summary",
        "overview", "results", "result", "draft",
    ]

    static func tokens(_ value: String) -> Set<String> {
        Set(TextFeatures.tokenize(value).filter { !genericTokens.contains($0) })
    }

    static func jaccard(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    static func overlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count))
    }

    private static let identifierRegex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]{2,}")

    /// Identifier-like title tokens, such as FreeRTOS or CS229.
    ///
    /// Ordinary phrases like "machine learning" are intentionally excluded: they
    /// describe a field, but do not establish that two files belong to one series.
    static func identifierLikeTokens(_ value: String) -> Set<String> {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var result: Set<String> = []
        for match in identifierRegex.matches(in: value, options: [], range: range) {
            guard let matchRange = Range(match.range, in: value) else { continue }
            let token = String(value[matchRange])
            let characters = Array(token)
            let hasMixedCase = characters.contains { $0.isLowercase }
                && characters.dropFirst().contains { $0.isUppercase }
            let hasDigit = characters.contains { $0.isNumber }
            if hasDigit || hasMixedCase { result.insert(Py.lower(token)) }
        }
        return result
    }

    static func filenameSimilarity(_ left: String, _ right: String,
                                   leftTokens: Set<String>, rightTokens: Set<String>) -> Double {
        var score = jaccard(leftTokens, rightTokens)
        let shared = leftTokens.intersection(rightTokens)
        let identifiers = identifierLikeTokens(left).intersection(identifierLikeTokens(right))
        if shared.count >= 2 || !identifiers.isEmpty {
            score = max(score, overlap(leftTokens, rightTokens))
        }
        return score
    }

    static func sharedSeriesIdentifiers(_ files: [IndexedFile]) -> Set<String> {
        guard !files.isEmpty else { return [] }
        let identifiers = files.map {
            identifierLikeTokens($0.path.deletingPathExtension().lastPathComponent)
                .union(identifierLikeTokens($0.title))
        }
        var result = identifiers[0]
        for set in identifiers.dropFirst() { result.formIntersection(set) }
        return result
    }

    /// Resolve explicit Markdown/wiki links to other indexed top-level files.
    static func documentLinkTargets(_ file: IndexedFile, candidates: [IndexedFile]) -> [IndexedFile] {
        let (names, stems) = TextFeatures.documentReferenceNames(file.text)
        return candidates.filter { candidate in
            candidate.id != file.id
                && (names.contains(Py.lower(candidate.name))
                    || stems.contains(Py.lower(candidate.path.deletingPathExtension().lastPathComponent)))
        }
    }

    static func cosine(_ left: [Double]?, _ right: [Double]?) -> Double {
        guard let left, let right, !left.isEmpty, !right.isEmpty, left.count == right.count else { return 0 }
        var total = 0.0
        for (a, b) in zip(left, right) { total += a * b }
        return max(0.0, min(1.0, total))
    }

    static func multiView(_ left: IndexedFile, _ right: IndexedFile, crossLanguage: Bool) -> (Double, Int) {
        let leftViews = crossLanguage ? left.pivotViews : left.nativeViews
        let rightViews = crossLanguage ? right.pivotViews : right.nativeViews
        var values: [Double] = []
        for view in SemanticText.views {
            guard let a = leftViews[view], let b = rightViews[view],
                  let space = a.space, !space.isEmpty, space == b.space,
                  let vectorA = a.vector, let vectorB = b.vector,
                  !vectorA.isEmpty, vectorA.count == vectorB.count else { continue }
            values.append(cosine(vectorA, vectorB))
        }
        guard values.count >= 2 else { return (0, values.count) }
        values.sort()
        return (values[values.count / 2], values.count)
    }

    static func sourceScore(_ left: IndexedFile, _ right: IndexedFile, cache: ClusterCache) -> (Double, String) {
        // GitHub and its raw-content host serve unrelated repositories under
        // one domain. Shared words such as README, main, microsoft and lessons
        // must not make two different repositories look like one source.
        let leftRepositories = githubRepositories(left.sourceURLs)
        let rightRepositories = githubRepositories(right.sourceURLs)
        if !leftRepositories.isEmpty && !rightRepositories.isEmpty {
            if leftRepositories.isDisjoint(with: rightRepositories) {
                return (0.15, "仅共享 GitHub 托管站点；仓库不同")
            }
            let shared = leftRepositories.intersection(rightRepositories).sorted(by: Py.less)
            let pathSimilarity = jaccard(cache.urlTokens(left), cache.urlTokens(right))
            return (max(0.60, min(1.0, pathSimilarity + 0.15)),
                    "共同 GitHub 仓库 \(shared[0])")
        }
        let pathSimilarity = jaccard(cache.urlTokens(left), cache.urlTokens(right))
        let sharedDomains = cache.domains(left).intersection(cache.domains(right)).sorted(by: Py.less)
        let domainBonus = sharedDomains.isEmpty ? 0.0 : 0.15
        let score = min(1.0, pathSimilarity + domainBonus)
        let detail: String
        if pathSimilarity >= 0.35 {
            detail = "来源 URL 路径相似度 \(format2(pathSimilarity))"
        } else if let first = sharedDomains.first {
            detail = "仅共享下载域名 \(first)"
        } else {
            detail = "没有共同下载来源证据"
        }
        return (score, detail)
    }

    static func githubRepositories(_ urls: [String]) -> Set<String> {
        var result: Set<String> = []
        for url in urls {
            let parsed = PyURL.parse(url)
            let host = Py.lower(parsed.netloc).split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            guard host == "github.com" || host == "raw.githubusercontent.com" else { continue }
            let parts = parsed.path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            result.insert("\(Py.lower(String(parts[0])))/\(Py.lower(String(parts[1])))")
        }
        return result
    }

    static func primaryCourse(_ file: IndexedFile) -> String {
        let stem = file.path.deletingPathExtension().lastPathComponent
        let strong = allCourses(stem + " " + file.sourceURLs.joined(separator: " "))
        if strong.count == 1, let value = strong.first { return value }
        let titleCourses = bodyCourses(file.title)
        if titleCourses.count == 1, let value = titleCourses.first { return value }
        let body = CoursePattern.matches(Py.prefix(file.text, 20_000))
        var counts = OrderedCounter<String>()
        for match in body {
            let prefix = match.prefix.uppercased()
            if isBodyCourseCandidate(prefix, match.number) {
                counts.add("\(prefix)\(match.number)")
            }
        }
        let repeated = counts.keys.filter { counts.count(of: $0) >= 2 }
        return repeated.count == 1 ? repeated[0] : ""
    }

    /// Course codes found in the representative document text.
    ///
    /// A single body occurrence is deliberately only a candidate. It becomes
    /// strong evidence when another document independently exposes the same code.
    static func bodyCourseCandidates(_ file: IndexedFile) -> Set<String> {
        bodyCourses([file.title, file.summary, Py.prefix(file.text, 20_000)].joined(separator: " "))
    }

    static func declaredCourse(_ file: IndexedFile) -> String {
        let strong = primaryCourse(file)
        if !strong.isEmpty { return strong }
        let candidates = bodyCourseCandidates(file)
        return candidates.count == 1 ? candidates.first! : ""
    }

    static func strength(_ kind: String, _ score: Double) -> String {
        let strongAt = ["filename": 0.50, "content": 0.40, "semantic": 0.82, "source_url": 0.50]
        let weakAt = ["filename": 0.15, "content": 0.15, "semantic": 0.60, "source_url": 0.01]
        if score >= strongAt[kind]! { return "strong" }
        if score >= weakAt[kind]! { return "weak" }
        return "none"
    }

    static func crossLanguageDetail(_ left: IndexedFile, _ right: IndexedFile, _ score: Double) -> String {
        let languages = Set([left.pivotSourceLanguage, right.pivotSourceLanguage]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "en" }).sorted(by: Py.less)
        let route = languages.isEmpty ? "未使用 English pivot" : languages.joined(separator: "、") + " → en"
        return "跨语言语义相似度 \(format2(score))（\(route)）"
    }

    static func timeGap(_ left: IndexedFile, _ right: IndexedFile) -> Double {
        var gaps: [Double] = []
        if left.createdAt > 0 && right.createdAt > 0 {
            gaps.append(abs(left.createdAt - right.createdAt))
        }
        if left.modifiedAt > 0 && right.modifiedAt > 0 {
            gaps.append(abs(left.modifiedAt - right.modifiedAt))
        }
        return gaps.min() ?? Double.infinity
    }
}

/// Python `f"{value:.2f}"` formatting for the evidence details.
public func format2(_ value: Double) -> String {
    String(format: "%.2f", value)
}

public func assessPair(_ left: IndexedFile, _ right: IndexedFile) -> PairAssessment {
    assessPair(left, right, cache: ClusterCache())
}

func assessPair(_ left: IndexedFile, _ right: IndexedFile, cache: ClusterCache,
                legacy: Bool = false) -> PairAssessment {
    let leftStem = left.path.deletingPathExtension().lastPathComponent
    let rightStem = right.path.deletingPathExtension().lastPathComponent
    let filename = ClusterMath.filenameSimilarity(
        leftStem, rightStem,
        leftTokens: cache.filenameTokens(left), rightTokens: cache.filenameTokens(right)
    )
    var content = ClusterMath.jaccard(cache.contentTokens(left), cache.contentTokens(right))
    if !cache.titleIdentifiers(left).intersection(cache.titleIdentifiers(right)).isEmpty {
        content = max(content, 0.50)
    }
    let sameNativeSpace = !(left.vectorSpace ?? "").isEmpty && left.vectorSpace == right.vectorSpace
    let nativeMulti = sameNativeSpace && !legacy ? ClusterMath.multiView(left, right, crossLanguage: false) : (0.0, 0)
    let semantic = sameNativeSpace
        ? (nativeMulti.1 >= 2 ? nativeMulti.0 : ClusterMath.cosine(left.vector, right.vector)) : 0.0
    var crossSemantic = 0.0
    var pivotCoverage = 0
    if let leftSpace = left.vectorSpace, let rightSpace = right.vectorSpace,
       !leftSpace.isEmpty, !rightSpace.isEmpty, leftSpace != rightSpace,
       left.pivotSpace == "en", right.pivotSpace == "en" {
        let pivotMulti = legacy ? (0.0, 0) : ClusterMath.multiView(left, right, crossLanguage: true)
        pivotCoverage = pivotMulti.1
        crossSemantic = pivotMulti.1 >= 2 ? pivotMulti.0 : ClusterMath.cosine(left.pivotVector, right.pivotVector)
    }
    let semanticForScore = sameNativeSpace ? semantic : crossSemantic
    let (source, sourceDetail) = ClusterMath.sourceScore(left, right, cache: cache)
    let leftPrimary = cache.primaryCourse(left)
    let rightPrimary = cache.primaryCourse(right)
    let leftCourse = cache.declaredCourse(left)
    let rightCourse = cache.declaredCourse(right)
    let sharedCourse = (!leftCourse.isEmpty && leftCourse == rightCourse) ? leftCourse : ""
    let sharedFromBody = !sharedCourse.isEmpty && !(leftPrimary == rightPrimary && rightPrimary == sharedCourse)
    var conflicts: [String] = []

    let courseDetail: String
    if sharedCourse.isEmpty {
        courseDetail = "没有共同课程代码"
    } else if sharedFromBody {
        courseDetail = "共同正文课程代码 \(sharedCourse)"
    } else {
        courseDetail = "共同课程代码 \(sharedCourse)"
    }
    let evidence = [
        Evidence(kind: "course_code", strength: sharedCourse.isEmpty ? "none" : "strong",
                 score: sharedCourse.isEmpty ? 0.0 : 1.0, detail: courseDetail),
        Evidence(kind: "filename_similarity", strength: ClusterMath.strength("filename", filename),
                 score: filename, detail: "文件名相似度 \(format2(filename))"),
        Evidence(kind: "content_similarity", strength: ClusterMath.strength("content", content),
                 score: content, detail: "正文关键词相似度 \(format2(content))"),
        Evidence(kind: "semantic_similarity", strength: ClusterMath.strength("semantic", semantic),
                 score: semantic, detail: "本地语义相似度 \(format2(semantic))"
                    + (!legacy && semantic > 0 && nativeMulti.1 < 2 ? "（多视图覆盖不足，使用综合向量）" : "")),
        Evidence(kind: "semantic_cross_language", strength: ClusterMath.strength("semantic", crossSemantic),
                 score: crossSemantic, detail: ClusterMath.crossLanguageDetail(left, right, crossSemantic)
                    + (!legacy && crossSemantic > 0 && pivotCoverage < 2 ? "（多视图覆盖不足，使用综合向量）" : "")),
        Evidence(kind: "source_url", strength: ClusterMath.strength("source_url", source),
                 score: source, detail: sourceDetail),
    ]

    let metrics: [String: Double] = [
        "course_code": sharedCourse.isEmpty ? 0.0 : 1.0,
        "filename_similarity": filename,
        "content_similarity": content,
        "semantic_similarity": semantic,
        "semantic_cross_language": crossSemantic,
        "source_url": source,
    ]

    if !leftCourse.isEmpty && !rightCourse.isEmpty && leftCourse != rightCourse {
        conflicts.append("课程号冲突：\(leftCourse) / \(rightCourse)")
        var metrics = metrics
        metrics["course_code"] = 0.0
        return PairAssessment(total: 0.0, metrics: metrics, evidence: evidence, conflicts: conflicts)
    }

    let leftRepositories = ClusterMath.githubRepositories(left.sourceURLs)
    let rightRepositories = ClusterMath.githubRepositories(right.sourceURLs)
    if sharedCourse.isEmpty && !leftRepositories.isEmpty && !rightRepositories.isEmpty
        && leftRepositories.isDisjoint(with: rightRepositories) {
        conflicts.append("来源 GitHub 仓库不同")
        return PairAssessment(total: 0.0, metrics: metrics, evidence: evidence, conflicts: conflicts)
    }

    var score = filename * 0.32 + source * 0.13 + content * 0.25 + semanticForScore * 0.30
    if !sharedCourse.isEmpty { score = max(score, 0.96) }
    // Native and translated vectors have different error profiles. A broad
    // translated AI/ML description can resemble an unrelated course chapter;
    // require either very strong pivot agreement or an independent filename
    // or source clue before a cross-language match creates a group.
    if sameNativeSpace && semantic >= 0.82 && content >= 0.20 { score = max(score, 0.68) }
    if sameNativeSpace && semantic >= 0.60 && content >= 0.25 { score = max(score, 0.65) }
    if sameNativeSpace && semantic >= 0.82 && filename >= 0.50 { score = max(score, 0.68) }
    if filename >= 0.50 && source >= 0.50 { score = max(score, 0.68) }
    if sameNativeSpace && semantic >= 0.78 && source >= 0.50 { score = max(score, 0.68) }
    if crossSemantic >= 0.92 {
        score = max(score, 0.65)
    } else if crossSemantic >= 0.88 && (filename >= 0.15 || source >= 0.50)
                && ClusterMath.timeGap(left, right) <= AppDefaults.crossLanguageTimeWindowSeconds {
        score = max(score, 0.65)
    }
    return PairAssessment(total: score, metrics: metrics, evidence: evidence, conflicts: conflicts)
}

/// Backward-compatible tuple API; structured callers should use `assessPair`.
public func pairScore(_ left: IndexedFile, _ right: IndexedFile) -> (Double, [String], [String]) {
    let assessment = assessPair(left, right)
    return (assessment.total, assessment.evidence.filter { $0.strength != "none" }.map(\.detail), assessment.conflicts)
}

public func loadIndex(_ db: Database, statuses: [String] = ["active"]) throws -> [IndexedFile] {
    let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
    let rows = try db.connection.query(
        """
        SELECT f.*,x.text,x.title,x.keywords,x.summary,x.extraction_error,
        x.native_embedding,x.native_embedding_space,
        p.pivot_embedding,p.pivot_embedding_space,p.source_language AS pivot_source_language,
        p.embedding_version AS pivot_embedding_version,
        p.translation_version AS pivot_translation_version
        FROM files f LEFT JOIN features x ON x.file_id=f.id
        LEFT JOIN semantic_pivots p ON p.file_id=f.id AND p.target_language='en' AND p.fingerprint=f.fingerprint
        WHERE f.status IN (\(placeholders)) ORDER BY f.name
        """,
        statuses
    )
    return rows.map { row in
        IndexedFile(
            id: row["id"].int,
            path: URL(fileURLWithPath: row["path"].string),
            name: row["name"].string,
            fileExtension: row["extension"].string,
            size: row["size"].int,
            createdAt: row["created_at"].double,
            modifiedAt: row["modified_at"].double,
            device: row["device"].int,
            inode: row["inode"].int,
            fingerprint: row["fingerprint"].string,
            sourceURLs: JSONValue.stringArray(row["source_urls"].string),
            text: row["text"].string,
            title: row["title"].string,
            keywords: JSONValue.stringArray(row["keywords"].string),
            summary: row["summary"].string,
            extractionError: row["extraction_error"].optionalString,
            vector: decodeVector(row["native_embedding"].blob),
            vectorSpace: row["native_embedding_space"].optionalString,
            pivotVector: decodeVector(row["pivot_embedding"].blob),
            pivotSpace: row["pivot_embedding_space"].optionalString,
            pivotSourceLanguage: row["pivot_source_language"].optionalString,
            pivotEmbeddingVersion: row["pivot_embedding_version"].optionalString,
            pivotTranslationVersion: row["pivot_translation_version"].optionalString
        )
    }
}

func decodeVector(_ blob: Data?) -> [Double]? {
    guard let blob, !blob.isEmpty else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: blob) as? [Any] else { return nil }
    return object.compactMap { ($0 as? NSNumber)?.doubleValue }
}

public enum Clustering {
    /// Encodes missing vectors and writes them back into `files` and the cache.
    public static func addEmbeddings(_ db: Database, _ files: inout [IndexedFile], encoder: SemanticEncoder) throws {
        let cacheVersion = SemanticText.cacheVersion(encoder.version)
        var pending: [IndexedFile] = []
        for index in files.indices {
            let file = files[index]
            let row = try db.connection.query("SELECT model_version FROM features WHERE file_id=?", [file.id]).first
            let hasVector = !(file.vector ?? []).isEmpty
            if !file.text.isEmpty && (!hasVector || row == nil || row!["model_version"].optionalString != cacheVersion) {
                files[index].vector = nil
                pending.append(files[index])
            }
        }
        if pending.isEmpty { return }
        var encodedByID: [Int: EncodedVector] = [:]
        var languageGroups: [String: [IndexedFile]] = [:]
        var languageOrder: [String] = []
        for file in pending {
            let language = SemanticText.language(file)
            if languageGroups[language] == nil { languageOrder.append(language) }
            languageGroups[language, default: []].append(file)
        }
        for language in languageOrder {
            let members = languageGroups[language]!
            let texts = members.map { SemanticText.build($0) }
            let encoded = try encoder.encodeInLanguage(texts, language: language)
            for (file, value) in zip(members, encoded) { encodedByID[file.id] = value }
        }
        for index in files.indices {
            guard let encoded = encodedByID[files[index].id] else { continue }
            files[index].vector = encoded.vector
            files[index].vectorSpace = encoded.space
            try db.connection.run(
                "UPDATE features SET native_embedding=?,native_embedding_space=?,model_version=? WHERE file_id=?",
                [encoded.vector.map { Data(JSONValue.dumps($0).utf8) }, encoded.space, cacheVersion, files[index].id]
            )
        }
    }

    static func pivotCandidateIDs(_ files: [IndexedFile], _ settings: Settings,
                                  cache: ClusterCache) -> Set<Int> {
        var lexicalPairs: [(Double, IndexedFile, IndexedFile)] = []
        var explorationByFile: [Int: [(Double, IndexedFile, IndexedFile)]] = [:]
        for (index, left) in files.enumerated() {
            for right in files[(index + 1)...] {
                let leftSpace = left.vectorSpace ?? ""
                let rightSpace = right.vectorSpace ?? ""
                if leftSpace.isEmpty || rightSpace.isEmpty || leftSpace == rightSpace { continue }
                let assessment = assessPair(left, right, cache: cache)
                if !assessment.conflicts.isEmpty || assessment.total >= settings.clusterThreshold { continue }
                let metrics = assessment.metrics
                let lexicalSignal = max(
                    metrics["filename_similarity"]! / 0.15,
                    metrics["content_similarity"]! / 0.10,
                    metrics["source_url"]! / 0.35
                )
                if lexicalSignal >= 1.0 {
                    lexicalPairs.append((-lexicalSignal, left, right))
                } else {
                    let gap = ClusterMath.timeGap(left, right)
                    explorationByFile[left.id, default: []].append((gap, left, right))
                    explorationByFile[right.id, default: []].append((gap, left, right))
                }
            }
        }

        var selected: Set<Int> = []
        var newPivots: Set<Int> = []

        func addPair(_ left: IndexedFile, _ right: IndexedFile) -> Bool {
            let newIDs = Set([left, right].filter { $0.pivotVector == nil && !newPivots.contains($0.id) }.map(\.id))
            if newPivots.count + newIDs.count > settings.crossLanguageTranslationLimit { return false }
            selected.insert(left.id)
            selected.insert(right.id)
            newPivots.formUnion(newIDs)
            return true
        }

        let orderedLexical = lexicalPairs.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1.id != right.1.id { return left.1.id < right.1.id }
            return left.2.id < right.2.id
        }
        for (_, left, right) in orderedLexical { _ = addPair(left, right) }

        var explorationPairs: [PairKey: (Double, IndexedFile, IndexedFile)] = [:]
        var explorationOrder: [PairKey] = []
        for key in explorationByFile.keys.sorted() {
            let pairs = explorationByFile[key]!
            let ordered = pairs.sorted { left, right in
                if left.0 != right.0 { return left.0 < right.0 }
                if left.1.id != right.1.id { return left.1.id < right.1.id }
                return left.2.id < right.2.id
            }
            var chosen = Array(ordered.prefix(1))
            chosen.append(contentsOf: ordered.dropFirst().prefix(settings.crossLanguageCandidateNeighbors - 1)
                .filter { $0.0 <= AppDefaults.crossLanguageTimeWindowSeconds })
            for item in chosen {
                let key = PairKey(min(item.1.id, item.2.id), max(item.1.id, item.2.id))
                if explorationPairs[key] == nil { explorationOrder.append(key) }
                explorationPairs[key] = item
            }
        }
        let orderedExploration = explorationOrder.compactMap { explorationPairs[$0] }.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1.id != right.1.id { return left.1.id < right.1.id }
            return left.2.id < right.2.id
        }
        for (_, left, right) in orderedExploration { _ = addPair(left, right) }
        return selected
    }

    struct PairKey: Hashable, Comparable {
        let left: Int
        let right: Int
        init(_ left: Int, _ right: Int) { self.left = left; self.right = right }
        static func < (lhs: PairKey, rhs: PairKey) -> Bool {
            lhs.left == rhs.left ? lhs.right < rhs.right : lhs.left < rhs.left
        }
    }

    static func completeLink(_ clusters: [[IndexedFile]], threshold: Double,
                             cache: ClusterCache, pairCache: PairAssessmentCache? = nil) -> [[IndexedFile]] {
        var clusters = clusters
        // Pair scores depend on two immutable indexed files. Complete-link
        // revisits the same pairs after every merge, so calculate each score
        // once for this proposal instead of repeating URL/text/vector work.
        let files = clusters.flatMap { $0 }
        var pairScores: [PairKey: Double] = [:]
        for (index, left) in files.enumerated() {
            for right in files.dropFirst(index + 1) {
                pairScores[PairKey(min(left.id, right.id), max(left.id, right.id))] =
                    (pairCache?.assess(left, right) ?? assessPair(left, right, cache: cache)).total
            }
        }
        while true {
            var best: (Double, Int, Int)?
            for leftIndex in clusters.indices {
                for rightIndex in clusters.indices where rightIndex > leftIndex {
                    var score = Double.infinity
                    var hasPairs = false
                    for left in clusters[leftIndex] {
                        for right in clusters[rightIndex] {
                            let total = pairScores[PairKey(min(left.id, right.id), max(left.id, right.id))] ?? 0
                            score = hasPairs ? min(score, total) : total
                            hasPairs = true
                        }
                    }
                    if !hasPairs { score = 0 }
                    if score >= threshold && (best == nil || score > best!.0) {
                        best = (score, leftIndex, rightIndex)
                    }
                }
            }
            guard let best else { return clusters }
            clusters[best.1].append(contentsOf: clusters[best.2])
            clusters.remove(at: best.2)
        }
    }

    static func metricEvidence(_ kind: String, _ score: Double, courseCode: String = "") -> Evidence {
        if kind == "course_code" {
            return Evidence(kind: kind, strength: courseCode.isEmpty ? "none" : "strong", score: score,
                            detail: courseCode.isEmpty ? "没有共同课程代码" : "共同课程代码 \(courseCode)")
        }
        let labels = [
            "filename_similarity": "组内文件名相似度",
            "content_similarity": "组内正文关键词相似度",
            "semantic_similarity": "组内本地语义相似度",
            "semantic_cross_language": "组内跨语言语义相似度",
            "source_url": "组内来源 URL 证据",
        ]
        let strengthKind = kind == "semantic_cross_language" ? "semantic" : removeSuffix(kind, "_similarity")
        return Evidence(kind: kind, strength: ClusterMath.strength(strengthKind, score), score: score,
                        detail: "\(labels[kind]!) \(format2(score))")
    }

    static let metricKinds = [
        "filename_similarity", "content_similarity", "semantic_similarity",
        "semantic_cross_language", "source_url",
    ]

    static func groupDetails(_ files: [IndexedFile], courseCode: String = "",
                             cache: ClusterCache) -> (Double, [Evidence], [String]) {
        if files.count < 2 {
            var evidence = [metricEvidence("course_code", courseCode.isEmpty ? 0.0 : 1.0, courseCode: courseCode)]
            evidence.append(contentsOf: metricKinds.map { metricEvidence($0, 0.0) })
            return (courseCode.isEmpty ? 0.0 : 0.96, evidence, [])
        }
        var assessments: [PairAssessment] = []
        for (index, left) in files.enumerated() {
            for right in files[(index + 1)...] { assessments.append(assessPair(left, right, cache: cache)) }
        }
        let scores = assessments.map(\.total)
        let confidence = (scores.min() ?? 0) * 0.7 + (scores.reduce(0, +) / Double(scores.count)) * 0.3
        var evidence = [metricEvidence("course_code", courseCode.isEmpty ? 0.0 : 1.0, courseCode: courseCode)]
        for kind in metricKinds {
            let values = assessments.map { $0.metrics[kind]! }
            let positive = values.filter { $0 > 0 }
            let value: Double
            if (kind == "semantic_similarity" || kind == "semantic_cross_language") && !positive.isEmpty {
                value = positive.reduce(0, +) / Double(positive.count)
            } else {
                value = values.reduce(0, +) / Double(values.count)
            }
            var item = metricEvidence(kind, value)
            if kind == "semantic_cross_language" && value > 0 {
                let languages = Set(files.compactMap { $0.pivotSourceLanguage }
                    .filter { !$0.isEmpty && $0 != "en" }).sorted(by: Py.less)
                let route = languages.joined(separator: "、") + " → en"
                item = Evidence(kind: kind, strength: item.strength, score: value,
                                detail: "跨语言语义相似度 \(format2(value))（\(route)）")
            }
            evidence.append(item)
        }
        let conflicts = Set(assessments.flatMap(\.conflicts)).sorted(by: Py.less)
        return (confidence, evidence, conflicts)
    }

    static func newGroup(_ files: [IndexedFile], courseCode: String = "",
                         cache: ClusterCache) -> ProposedGroup {
        var (confidence, evidence, conflicts) = groupDetails(files, courseCode: courseCode, cache: cache)
        var namingCourse = courseCode
        if namingCourse.isEmpty {
            let observed = Set(files.map { cache.declaredCourse($0) }.filter { !$0.isEmpty })
            if observed.count == 1 {
                namingCourse = observed.first!
                evidence[0] = Evidence(kind: "course_code", strength: "weak", score: 0.5,
                                       detail: "组内部分文件发现课程代码 \(namingCourse)")
            }
        }
        let identifiers = ClusterMath.sharedSeriesIdentifiers(files).sorted(by: Py.less)
        if let first = identifiers.first {
            evidence.insert(Evidence(kind: "series_identifier", strength: "strong", score: 1.0,
                                     detail: "共同系列标识 \(first)"), at: 1)
        }
        let name = TopicNaming.displayName(files, courseCode: namingCourse)
        return ProposedGroup(topicKey: TopicNaming.topicKey(files, courseCode: namingCourse),
                             displayName: name, confidence: confidence, files: files,
                             evidence: evidence, conflicts: conflicts)
    }
}

func removeSuffix(_ value: String, _ suffix: String) -> String {
    guard !suffix.isEmpty, value.hasSuffix(suffix) else { return value }
    return String(value.dropLast(suffix.count))
}
