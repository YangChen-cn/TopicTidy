import Foundation

/// A proposal-local cache: pair assessments may depend on both files and must
/// never be kept in ClusterCache or reused after another proposal.
final class PairAssessmentCache {
    private var current: [Clustering.PairKey: PairAssessment] = [:]
    private let fileCache: ClusterCache

    init(fileCache: ClusterCache) { self.fileCache = fileCache }

    func assess(_ left: IndexedFile, _ right: IndexedFile) -> PairAssessment {
        let key = Clustering.PairKey(min(left.id, right.id), max(left.id, right.id))
        if let value = current[key] { return value }
        let value = assessPair(left, right, cache: fileCache)
        current[key] = value
        return value
    }
}

struct MembershipAssessment {
    let candidate: IndexedFile
    let score: Double
    let support: Int
    let profileScore: Double
    let reason: String
}

/// Immutable core profile. Its tokens and centroids never include later members.
struct ClusterProfile {
    let core: [IndexedFile]
    let courseCode: String
    let series: Set<String>
    let tokens: [String: Int]
    let repositories: [String: Int]
    let centroids: [String: [Double]]

    init(core: [IndexedFile], courseCode: String = "", cache: ClusterCache) {
        self.core = core
        self.courseCode = courseCode
        self.series = ClusterMath.sharedSeriesIdentifiers(core)
        var counts: [String: Int] = [:]
        var repos: [String: Int] = [:]
        var vectors: [String: [[Double]]] = [:]
        for file in core {
            let words = cache.filenameTokens(file).union(cache.contentTokens(file))
                .filter { !ClusterMath.genericTokens.contains($0) && !TextFeatures.stopwords.contains($0) }
            for word in words { counts[word, default: 0] += 1 }
            for repository in ClusterMath.githubRepositories(file.sourceURLs) {
                repos[repository, default: 0] += 1
            }
            for (view, encoded) in file.nativeViews {
                if let space = encoded.space, let vector = encoded.vector {
                    vectors["native:\(space):\(view)", default: []].append(vector)
                }
            }
            for (view, encoded) in file.pivotViews {
                if let space = encoded.space, let vector = encoded.vector {
                    vectors["pivot:\(space):\(view)", default: []].append(vector)
                }
            }
        }
        self.tokens = counts
        self.repositories = repos
        self.centroids = vectors.compactMapValues { NativeMacOSEncoder.normalizedAverage($0) }
    }

    func evaluate(_ candidate: IndexedFile, threshold: Double,
                  fileCache: ClusterCache, pairs: PairAssessmentCache) -> MembershipAssessment? {
        let assessments = core.map { pairs.assess(candidate, $0) }
        guard !assessments.isEmpty, assessments.allSatisfy({ $0.conflicts.isEmpty }) else { return nil }
        let ordered = assessments.map(\.total).sorted(by: >)
        let top = Array(ordered.prefix(3))
        let score = top.reduce(0, +) / Double(top.count)
        guard ordered[0] >= threshold, score >= threshold else { return nil }
        if core.count == 1 {
            return MembershipAssessment(candidate: candidate, score: score, support: 1,
                                        profileScore: 0, reason: "匹配已确认的单个样本 \(format2(score))")
        }

        let requiredCoverage = max(2, Int((Double(core.count) * 0.60).rounded(.up)))
        let commonWords = fileCache.filenameTokens(candidate).union(fileCache.contentTokens(candidate))
            .filter { !ClusterMath.genericTokens.contains($0) && !TextFeatures.stopwords.contains($0) }
            .filter { (tokens[$0] ?? 0) >= requiredCoverage }
        let candidateCourse = fileCache.declaredCourse(candidate)
        let identity = (!courseCode.isEmpty && candidateCourse == courseCode)
            || !fileCache.filenameTokens(candidate).union(fileCache.titleIdentifiers(candidate))
                .intersection(series).isEmpty
            || !commonWords.isEmpty
        let native = semanticCentroid(candidate, prefix: "native")
        let pivot = semanticCentroid(candidate, prefix: "pivot")
        let sourceClue = core.contains { other in
            let metric = pairs.assess(candidate, other).metrics
            return (metric["filename_similarity"] ?? 0) >= 0.15
                || (metric["source_url"] ?? 0) >= 0.50
        }
        let withinTime = core.contains {
            ClusterMath.timeGap(candidate, $0) <= AppDefaults.crossLanguageTimeWindowSeconds
        }
        let semantic = native >= 0.82 || pivot >= 0.92
            || (pivot >= 0.88 && sourceClue && withinTime)
        guard identity || semantic else { return nil }
        let support = assessments.filter { $0.total >= threshold }.count
        let label = identity ? "共同主题线索" : "多视图语义中心"
        return MembershipAssessment(candidate: candidate, score: score, support: support,
                                    profileScore: max(native, pivot),
                                    reason: "\(label)；\(support)/\(core.count) 个核心成员达到阈值，前三支持均值 \(format2(score))")
    }

    private func semanticCentroid(_ file: IndexedFile, prefix: String) -> Double {
        let views = prefix == "native" ? file.nativeViews : file.pivotViews
        var scores: [Double] = []
        for view in SemanticText.views {
            guard let encoded = views[view], let space = encoded.space,
                  let centroid = centroids["\(prefix):\(space):\(view)"],
                  let vector = encoded.vector, vector.count == centroid.count else { continue }
            scores.append(ClusterMath.cosine(vector, centroid))
        }
        guard scores.count >= 2 else { return 0 }
        scores.sort()
        return scores[scores.count / 2]
    }

    func evidence(for members: [IndexedFile], expanded: Int) -> [Evidence] {
        let requiredCoverage = max(2, Int((Double(core.count) * 0.60).rounded(.up)))
        let common = tokens.filter { $0.value >= requiredCoverage }
            .sorted { left, right in
                left.value != right.value ? left.value > right.value : Py.less(left.key, right.key)
            }
        let supported = common.prefix(3).map { "\($0.key) \($0.value)/\(core.count)" }.joined(separator: "、")
        let coverage = core.isEmpty ? 0.0 : Double(common.first?.value ?? 0) / Double(core.count)
        let commonSource = repositories.filter { $0.value >= requiredCoverage }
            .sorted { left, right in
                left.value != right.value ? left.value > right.value : Py.less(left.key, right.key)
            }.first
        let multi = members.filter {
            $0.nativeViews.values.filter { $0.vector != nil }.count >= 2
                || $0.pivotViews.values.filter { $0.vector != nil }.count >= 2
        }.count
        return [
            Evidence(kind: "cluster_identity", strength: common.isEmpty ? "none" : "strong",
                     score: coverage,
                     detail: common.isEmpty ? "核心无共同身份词" : "核心共同线索：\(supported)"),
            Evidence(kind: "cluster_source", strength: commonSource == nil ? "none" : "strong",
                     score: commonSource.map { Double($0.value) / Double(core.count) } ?? 0,
                     detail: commonSource.map { "核心共同来源仓库 \($0.key) \($0.value)/\(core.count)" }
                        ?? "核心无共同来源仓库"),
            Evidence(kind: "cluster_semantic_views", strength: multi >= 2 ? "strong" : multi > 0 ? "weak" : "none",
                     score: members.isEmpty ? 0 : Double(multi) / Double(members.count),
                     detail: "组内 \(multi)/\(members.count) 个文件具备至少两个有效语义视图"),
            Evidence(kind: "cluster_membership", strength: expanded > 0 ? "strong" : "none",
                     score: expanded > 0 ? Double(expanded) / Double(members.count) : 0,
                     detail: "固定核心 \(core.count) 个文件；受约束扩张 \(expanded) 个文件"),
        ]
    }
}
