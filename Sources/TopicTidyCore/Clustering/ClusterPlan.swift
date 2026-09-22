import Foundation

public struct ClusterResult: Sendable {
    public var groups: [ProposedGroup]
    public var unclassified: [IndexedFile]
}

public enum ClusterEngine {
    public static func cluster(
        _ db: Database,
        _ settings: Settings,
        encoder: SemanticEncoder? = nil,
        translator: TranslationBackend? = nil,
        translationMessages: SendableBox<[String]>? = nil
    ) throws -> ClusterResult {
        // One memo table per run: per-file features are pure functions of the file.
        let cache = ClusterCache()
        var files = try loadIndex(db)
        var prototypes = try loadIndex(db, statuses: ["organized"])
        if let encoder {
            try Clustering.addEmbeddings(db, &files, encoder: encoder)
            try Clustering.addEmbeddings(db, &prototypes, encoder: encoder)
            if let translator {
                var allFiles = files + prototypes
                let cacheVersion = SemanticText.cacheVersion(encoder.version)
                for index in allFiles.indices where allFiles[index].pivotEmbeddingVersion != cacheVersion {
                    allFiles[index].pivotVector = nil
                    allFiles[index].pivotSpace = nil
                }
                let candidateIDs = Clustering.pivotCandidateIDs(allFiles, settings, cache: cache)
                var selected = allFiles.filter { candidateIDs.contains($0.id) }
                let messages = try Pivot.ensurePivotEmbeddings(
                    db, &selected, encoder: encoder, translator: translator
                )
                translationMessages?.update { $0.append(contentsOf: messages) }
                // Keep the caller's view of pivots in sync with the cache.
                for updated in selected {
                    if let index = files.firstIndex(where: { $0.id == updated.id }) {
                        files[index].pivotVector = updated.pivotVector
                        files[index].pivotSpace = updated.pivotSpace
                        files[index].pivotSourceLanguage = updated.pivotSourceLanguage
                        files[index].pivotEmbeddingVersion = updated.pivotEmbeddingVersion
                    }
                    if let index = prototypes.firstIndex(where: { $0.id == updated.id }) {
                        prototypes[index].pivotVector = updated.pivotVector
                        prototypes[index].pivotSpace = updated.pivotSpace
                        prototypes[index].pivotSourceLanguage = updated.pivotSourceLanguage
                        prototypes[index].pivotEmbeddingVersion = updated.pivotEmbeddingVersion
                    }
                }
            } else {
                // Pivot vectors from an older embedding cache must not be compared.
                let cacheVersion = SemanticText.cacheVersion(encoder.version)
                for index in files.indices where files[index].pivotEmbeddingVersion != cacheVersion {
                    files[index].pivotVector = nil
                    files[index].pivotSpace = nil
                }
            }
        }

        var assigned: Set<Int> = []
        var groups: [ProposedGroup] = []
        var forcedUnclassified: [IndexedFile] = []

        for file in files {
            let row = try db.connection.query(
                """
                SELECT action FROM corrections WHERE file_fingerprint=? AND active=1
                ORDER BY created_at DESC,id DESC LIMIT 1
                """,
                [file.fingerprint]
            ).first
            if let row, row["action"].string == "exclude" {
                forcedUnclassified.append(file)
                assigned.insert(file.id)
            }
        }

        var learned: [TopicIdentity: [IndexedFile]] = [:]
        var learnedOrder: [TopicIdentity] = []
        for file in files {
            if assigned.contains(file.id) { continue }
            let row = try db.connection.query(
                """
                SELECT a.topic_key,t.display_name
                FROM associations a JOIN topics t ON t.topic_key=a.topic_key
                WHERE a.file_fingerprint=? AND a.active=1
                """,
                [file.fingerprint]
            ).first
            if let row {
                let identity = TopicIdentity(key: row["topic_key"].string, name: row["display_name"].string)
                if learned[identity] == nil { learnedOrder.append(identity) }
                learned[identity, default: []].append(file)
                assigned.insert(file.id)
            }
        }
        for identity in learnedOrder {
            let members = learned[identity]!
            let (confidence, details, conflicts) = Clustering.groupDetails(
                members, courseCode: cache.primaryCourse(members[0]), cache: cache
            )
            var evidence = details
            evidence.insert(Evidence(kind: "manual_association", strength: "strong", score: 1.0,
                                     detail: "人工确认的主题关联"), at: 0)
            groups.append(ProposedGroup(topicKey: identity.key, displayName: identity.name,
                                        confidence: max(0.99, confidence), files: members,
                                        evidence: evidence, conflicts: conflicts))
        }

        var prototypeTopics: [TopicIdentity: [IndexedFile]] = [:]
        var prototypeOrder: [TopicIdentity] = []
        for prototype in prototypes {
            let row = try db.connection.query(
                """
                SELECT a.topic_key,t.display_name
                FROM associations a JOIN topics t ON t.topic_key=a.topic_key
                WHERE a.file_fingerprint=? AND a.active=1
                """,
                [prototype.fingerprint]
            ).first
            if let row {
                let identity = TopicIdentity(key: row["topic_key"].string, name: row["display_name"].string)
                if prototypeTopics[identity] == nil { prototypeOrder.append(identity) }
                prototypeTopics[identity, default: []].append(prototype)
            }
        }
        var attached: [TopicIdentity: [(IndexedFile, PairAssessment)]] = [:]
        var attachedOrder: [TopicIdentity] = []
        for file in files {
            if assigned.contains(file.id) { continue }
            var matches: [(Double, TopicIdentity, [PairAssessment])] = []
            for identity in prototypeOrder {
                let examples = prototypeTopics[identity]!
                let comparisons = examples.map { assessPair(file, $0, cache: cache) }
                let scores = comparisons.map(\.total)
                if !scores.isEmpty, (scores.min() ?? 0) >= settings.clusterThreshold {
                    matches.append((scores.reduce(0, +) / Double(scores.count), identity, comparisons))
                }
            }
            if matches.count == 1 {
                let (_, identity, comparisons) = matches[0]
                if attached[identity] == nil { attachedOrder.append(identity) }
                let weakest = comparisons.min { $0.total < $1.total }!
                attached[identity, default: []].append((file, weakest))
                assigned.insert(file.id)
            }
        }
        for identity in attachedOrder {
            let matches = attached[identity]!
            let members = matches.map(\.0)
            let confidence = matches.map(\.1.total).min() ?? 0
            var evidence = [Evidence(kind: "learned_topic", strength: "strong", score: 1.0,
                                     detail: "匹配已确认的主题样本")]
            for kind in Clustering.metricKinds {
                let score = matches.map { $0.1.metrics[kind]! }.reduce(0, +) / Double(matches.count)
                var metric = Clustering.metricEvidence(kind, score)
                if kind == "semantic_cross_language" && score > 0 {
                    let details = Set(matches.flatMap { _, assessment in
                        assessment.evidence.filter { $0.kind == kind && ($0.score ?? 0) > 0 }.map(\.detail)
                    }).sorted(by: Py.less)
                    metric = Evidence(kind: kind, strength: metric.strength, score: score,
                                      detail: details.joined(separator: "；"))
                }
                evidence.append(metric)
            }
            groups.append(ProposedGroup(topicKey: identity.key, displayName: identity.name,
                                        confidence: confidence, files: members, evidence: evidence))
        }

        var courseMap: [String: [IndexedFile]] = [:]
        var courseOrder: [String] = []
        for file in files {
            if assigned.contains(file.id) { continue }
            let code = cache.primaryCourse(file)
            if !code.isEmpty {
                if courseMap[code] == nil { courseOrder.append(code) }
                courseMap[code, default: []].append(file)
                assigned.insert(file.id)
            }
        }

        // A body course code mentioned once cannot classify a document by itself.
        // Promote it only when at least two independent files expose the same code.
        var bodyCandidates: [Int: Set<String>] = [:]
        var bodyCounts = OrderedCounter<String>()
        for file in files where !assigned.contains(file.id) {
            let candidates = cache.bodyCourseCandidates(file)
            bodyCandidates[file.id] = candidates
            for code in candidates { bodyCounts.add(code) }
        }
        for file in files {
            if assigned.contains(file.id) { continue }
            let shared = (bodyCandidates[file.id] ?? []).filter { bodyCounts.count(of: $0) >= 2 }
            if shared.count == 1, let code = shared.first {
                if courseMap[code] == nil { courseOrder.append(code) }
                courseMap[code, default: []].append(file)
                assigned.insert(file.id)
            }
        }
        for file in files {
            if assigned.contains(file.id) { continue }
            var candidates: [(Double, String)] = []
            for code in courseOrder {
                let members = courseMap[code]!
                let assessments = members.map { assessPair(file, $0, cache: cache) }
                if !assessments.isEmpty,
                   (assessments.map(\.total).min() ?? 0) >= settings.courseAttachThreshold {
                    candidates.append((assessments.map(\.total).reduce(0, +) / Double(assessments.count), code))
                }
            }
            if candidates.count == 1 {
                courseMap[candidates[0].1]!.append(file)
                assigned.insert(file.id)
            }
        }
        for code in courseOrder {
            let members = courseMap[code]!
            if members.count < 2 {
                assigned.remove(members[0].id)
                continue
            }
            var group = Clustering.newGroup(members, courseCode: code, cache: cache)
            group.confidence = max(0.90, group.confidence)
            groups.append(group)
        }

        // A local index/README that explicitly links several present documents is
        // strong collection evidence. Process the largest hubs first and never use
        // transitive links, so one bridge document cannot chain unrelated groups.
        let available = files.filter { !assigned.contains($0.id) }
        var linkedCollections: [(Int, IndexedFile, [IndexedFile])] = []
        for hub in available {
            let linked = ClusterMath.documentLinkTargets(hub, candidates: available)
            if linked.count >= 3 {
                let members = [hub] + linked
                let declared = Set(members.map { cache.declaredCourse($0) }.filter { !$0.isEmpty })
                if declared.count <= 1 { linkedCollections.append((members.count, hub, members)) }
            }
        }
        let orderedCollections = linkedCollections.pySorted { left, right in
            if left.0 != right.0 { return left.0 > right.0 }
            return left.1.id < right.1.id
        }
        for (_, hub, candidates) in orderedCollections {
            let members = candidates.filter { !assigned.contains($0.id) }
            if assigned.contains(hub.id) || members.count < 4 { continue }
            var group = Clustering.newGroup(members, cache: cache)
            let stem = Py.lower(hub.path.deletingPathExtension().lastPathComponent)
            if !hub.title.isEmpty && ["readme", "index", "contents", "toc"].contains(stem) {
                group.displayName = Py.prefix(Py.strip(hub.title), 80)
            }
            group.evidence.insert(Evidence(
                kind: "document_links", strength: "strong", score: 1.0,
                detail: "\(hub.name) 明确链接组内 \(members.count - 1) 个文件"
            ), at: 0)
            let independentStrong = group.evidence.contains {
                autoConfirmSupportKinds.contains($0.kind) && $0.strength == "strong"
            }
            if independentStrong {
                group.confidence = max(group.confidence, 0.92)
            } else {
                group.confidence = min(group.confidence, 0.91)
            }
            groups.append(group)
            assigned.formUnion(members.map(\.id))
        }

        let remaining = files.filter { !assigned.contains($0.id) }
        let clusters = Clustering.completeLink(remaining.map { [$0] }, threshold: settings.clusterThreshold,
                                              cache: cache)
        var unclassified = forcedUnclassified
        for members in clusters {
            if members.count < 2 {
                unclassified.append(contentsOf: members)
            } else {
                groups.append(Clustering.newGroup(members, cache: cache))
            }
        }
        for index in groups.indices {
            let saved = try db.connection.query(
                "SELECT display_name FROM topics WHERE topic_key=? AND active=1 AND source='manual'",
                [groups[index].topicKey]
            ).first
            if let saved { groups[index].displayName = saved["display_name"].string }
        }
        return ClusterResult(
            groups: groups.pySorted { Py.less(Py.lower($0.displayName), Py.lower($1.displayName)) },
            unclassified: unclassified.pySorted { Py.less(Py.lower($0.name), Py.lower($1.name)) }
        )
    }

    public static func savePlan(
        _ db: Database,
        _ settings: Settings,
        groups: [ProposedGroup],
        unclassified: [IndexedFile]
    ) throws -> Int {
        let now = Date().timeIntervalSince1970
        var planID = 0
        try db.withTransaction { database in
            try database.connection.run(
                "INSERT INTO plans(created_at,status,config_json) VALUES(?, 'draft', ?)",
                [now, JSONValue.dumps([
                    "cluster_threshold": settings.clusterThreshold,
                    "cross_language_candidate_neighbors": settings.crossLanguageCandidateNeighbors,
                    "cross_language_translation_limit": settings.crossLanguageTranslationLimit,
                    "cross_language_time_window_seconds": AppDefaults.crossLanguageTimeWindowSeconds,
                    "organized_dir": settings.organizedDir.path,
                ])]
            )
            planID = database.connection.lastInsertRowID
            for group in groups {
                try database.connection.run(
                    """
                    INSERT INTO topics(topic_key,display_name,source,active)
                    VALUES(?,?,'proposal',1)
                    ON CONFLICT(topic_key) DO UPDATE SET display_name=COALESCE(topics.display_name,excluded.display_name),active=1
                    """,
                    [group.topicKey, group.displayName]
                )
                for file in group.files {
                    try database.connection.run(
                        """
                        INSERT INTO plan_members(
                        plan_id,file_id,topic_key,group_name,confidence,reasons,evidence,conflicts,source_fingerprint,destination
                        ) VALUES(?,?,?,?,?,?,?,?,?,?)
                        """,
                        [planID, file.id, group.topicKey, group.displayName, group.confidence,
                         JSONValue.dumps(group.reasons),
                         JSONValue.dumps(group.evidence.map(\.asDictionary)),
                         JSONValue.dumps(group.conflicts), file.fingerprint,
                         PyPath.join(settings.organizedDir, group.displayName, file.name).path]
                    )
                }
            }
            for file in unclassified {
                try database.connection.run(
                    """
                    INSERT INTO plan_members(plan_id,file_id,topic_key,group_name,confidence,source_fingerprint)
                    VALUES(?,?,NULL,NULL,0,?)
                    """,
                    [planID, file.id, file.fingerprint]
                )
            }
        }
        return planID
    }
}

/// Learned-topic identity: a durable `topic_key` plus its editable display name.
struct TopicIdentity: Hashable {
    let key: String
    let name: String
}
