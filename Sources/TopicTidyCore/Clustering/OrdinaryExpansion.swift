import Foundation

enum OrdinaryExpansion {
    struct Seed {
        var core: [IndexedFile]
        var originalCores: [[IndexedFile]]
        var expandable: Bool
        var added: [(IndexedFile, MembershipAssessment)] = []
    }

    static func seedEligible(_ files: [IndexedFile], cache: ClusterCache,
                             pairs: PairAssessmentCache, threshold: Double) -> Bool {
        guard files.count >= 2 else { return false }
        if !ClusterMath.sharedSeriesIdentifiers(files).isEmpty { return true }
        for (index, left) in files.enumerated() {
            for right in files.dropFirst(index + 1) {
                let assessment = pairs.assess(left, right)
                guard assessment.conflicts.isEmpty, assessment.total >= threshold else { continue }
                let metrics = assessment.metrics
                let lexical = (metrics["filename_similarity"] ?? 0) >= 0.50
                    || (metrics["content_similarity"] ?? 0) >= 0.40
                let sharedCollection = !ClusterMath.sourceCollections(left.sourceURLs)
                    .intersection(ClusterMath.sourceCollections(right.sourceURLs)).isEmpty
                let nativeViews = ClusterMath.multiView(left, right, crossLanguage: false)
                let sourceCorroboratedSemantic = sharedCollection
                    && left.vectorSpace != nil && left.vectorSpace == right.vectorSpace
                    && ClusterMath.cosine(left.vector, right.vector) >= 0.82
                    && nativeViews.1 >= 2 && nativeViews.0 >= 0.70
                let semantic = (metrics["semantic_similarity"] ?? 0) >= 0.82
                    || (metrics["semantic_cross_language"] ?? 0) >= 0.92
                    || sourceCorroboratedSemantic
                let source = (metrics["source_url"] ?? 0) >= 0.50
                    && sharedCollection
                if [lexical, semantic, source].filter({ $0 }).count >= 2 { return true }
            }
        }
        return false
    }

    static func run(_ clusters: [[IndexedFile]], threshold: Double,
                    cache: ClusterCache, pairs: PairAssessmentCache)
        -> (groups: [ProposedGroup], unclassified: [IndexedFile], reasons: [Int: String]) {
        var seeds = clusters.filter { $0.count >= 2 }.map { members in
            Seed(core: members, originalCores: [members],
                 expandable: seedEligible(members, cache: cache, pairs: pairs, threshold: threshold))
        }
        seeds.sort { stable($0.core[0], $1.core[0]) }
        var remaining = clusters.filter { $0.count == 1 }.flatMap { $0 }.sorted(by: stable)
        var reasons: [Int: String] = [:]

        // Merge cores only if every original core supports every other core in
        // both directions. The merged core is frozen before singleton expansion.
        var index = 0
        while index < seeds.count {
            var other = index + 1
            while other < seeds.count {
                if seeds[index].expandable && seeds[other].expandable
                    && compatible(seeds[index], seeds[other], threshold: threshold,
                                  cache: cache, pairs: pairs) {
                    seeds[index].core.append(contentsOf: seeds[other].core)
                    seeds[index].originalCores.append(contentsOf: seeds[other].originalCores)
                    seeds.remove(at: other)
                } else { other += 1 }
            }
            index += 1
        }

        let profiles = seeds.map { ClusterProfile(core: $0.core, cache: cache) }
        var proposals: [(Int, MembershipAssessment, Double)] = []
        for file in remaining {
            let matches = profiles.enumerated().compactMap { seedIndex, profile
                -> (Int, MembershipAssessment)? in
                guard seeds[seedIndex].expandable,
                      let result = profile.evaluate(file, threshold: threshold,
                                                    fileCache: cache, pairs: pairs) else { return nil }
                return (seedIndex, result)
            }.sorted { left, right in
                if left.1.score != right.1.score { return left.1.score > right.1.score }
                return left.0 < right.0
            }
            guard let winner = matches.first else {
                reasons[file.id] = "没有达到强种子的组级准入条件"
                continue
            }
            let margin = matches.count > 1 ? winner.1.score - matches[1].1.score : 1.0
            guard margin >= 0.08 else {
                reasons[file.id] = "同时匹配多个主题，最佳领先不足 0.08"
                continue
            }
            proposals.append((winner.0, winner.1, margin))
        }
        proposals.sort { left, right in
            if left.1.score != right.1.score { return left.1.score > right.1.score }
            return stable(left.1.candidate, right.1.candidate)
        }
        var used: Set<Int> = []
        var competitionMargins: [Int: Double] = [:]
        for (seedIndex, assessment, margin) in proposals {
            let file = assessment.candidate
            let accepted = seeds[seedIndex].added.allSatisfy {
                pairs.assess(file, $0.0).conflicts.isEmpty
            }
            if accepted {
                seeds[seedIndex].added.append((file, assessment))
                competitionMargins[seedIndex] = min(competitionMargins[seedIndex] ?? 1, margin)
                used.insert(file.id)
            } else {
                reasons[file.id] = "与已加入成员存在课程或来源冲突"
            }
        }
        remaining.removeAll { used.contains($0.id) }

        let groups = seeds.enumerated().map { seedIndex, seed -> ProposedGroup in
            let members = seed.core + seed.added.map(\.0)
            var group = Clustering.newGroup(members, cache: cache)
            let coreQuality = seed.originalCores.map {
                Clustering.groupDetails($0, cache: cache).0
            }.min() ?? 0
            let supports = seed.added.map { $0.1.score }.sorted()
            group.confidence = coreQuality
            if !supports.isEmpty {
                let quartile = supports[(supports.count - 1) / 4]
                group.confidence = min(coreQuality, quartile)
            }
            let minimum = supports.first ?? coreQuality
            group.evidence.append(Evidence(kind: "cluster_support", strength: seed.added.isEmpty ? "none" : "strong",
                                           score: minimum,
                                           detail: "固定核心 \(seed.core.count) 份，扩张 \(seed.added.count) 份，最弱成员支持 \(format2(minimum))"))
            group.evidence.append(contentsOf: profiles[seedIndex].evidence(for: members,
                                                                             expanded: seed.added.count))
            if let margin = competitionMargins[seedIndex] {
                group.evidence.append(Evidence(kind: "cluster_competition", strength: "weak",
                                               score: margin,
                                               detail: "扩张成员对竞争主题的最小领先差 \(format2(margin))"))
            }
            group.diagnostics = [
                "core_count": AnySendableValue(seed.core.count),
                "expanded_count": AnySendableValue(seed.added.count),
                "minimum_member_support": AnySendableValue(minimum),
                "competition_margin": AnySendableValue(competitionMargins[seedIndex] ?? 1),
            ]
            group.memberReasons = Dictionary(uniqueKeysWithValues:
                seed.core.map { ($0.id, "强种子核心成员") }
                + seed.added.map { ($0.0.id, $0.1.reason) })
            return group
        }
        return (groups, remaining, reasons)
    }

    private static func compatible(_ left: Seed, _ right: Seed, threshold: Double,
                                   cache: ClusterCache, pairs: PairAssessmentCache) -> Bool {
        let all = left.originalCores + right.originalCores
        for i in all.indices {
            for j in all.indices where j > i {
                let a = ClusterProfile(core: all[i], cache: cache)
                let b = ClusterProfile(core: all[j], cache: cache)
                if !all[j].allSatisfy({ a.evaluate($0, threshold: threshold, fileCache: cache, pairs: pairs) != nil })
                    || !all[i].allSatisfy({ b.evaluate($0, threshold: threshold, fileCache: cache, pairs: pairs) != nil }) {
                    return false
                }
            }
        }
        return true
    }

    private static func stable(_ left: IndexedFile, _ right: IndexedFile) -> Bool {
        if left.fingerprint != right.fingerprint { return left.fingerprint < right.fingerprint }
        return left.path.path < right.path.path
    }
}
