import CryptoKit
import Foundation

public enum Benchmark {
    public enum Variant: String, CaseIterable {
        case legacy, expansionOnly = "expansion-only", multiViewOnly = "multiview-only", upgraded

        var algorithm: ClusterEngine.Algorithm {
            switch self {
            case .legacy: .legacy
            case .expansionOnly: .expansionOnly
            case .multiViewOnly: .multiViewOnly
            case .upgraded: .upgraded
            }
        }
    }
    /// Packaged fixture names. The JSON lives in `Resources/fixtures` and is
    /// embedded so the app and CLI stay relocatable without a resource bundle.
    public enum Fixture: String, CaseIterable {
        case core = "benchmark_core"
        case holdout = "holdout_unseen"
        case upgradeDevelopment = "upgrade_development"
        case upgradeHoldout = "upgrade_holdout"
    }

    public static func defaultFixtureData() throws -> Data {
        guard let data = FixtureData.json(for: .core).data(using: .utf8) else {
            throw OrganizerError("内置 benchmark fixture 缺失")
        }
        return data
    }

    static func pairs(_ groups: [Set<String>]) -> Set<[String]> {
        var result: Set<[String]> = []
        for group in groups {
            let members = group.sorted()
            for left in members {
                for right in members where left < right {
                    result.insert([left, right])
                }
            }
        }
        return result
    }

    static func loadFixture(_ data: Data) throws -> [String: Any] {
        guard let fixture = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              fixture["documents"] is [Any], fixture["expected_clusters"] is [String: Any] else {
            throw OrganizerError("benchmark fixture 必须包含 documents 和 expected_clusters")
        }
        return fixture
    }

    public static func run(fixture data: Data, fixturePath: String = "builtin",
                           variant: Variant = .upgraded) throws -> [String: Any] {
        let fixture = try loadFixture(data)
        let documents = fixture["documents"] as? [[String: Any]] ?? []
        let expectedClusters = fixture["expected_clusters"] as? [String: [String]] ?? [:]
        let expectedUnclassified = fixture["expected_unclassified"] as? [String] ?? []

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("topictidy-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloads = PyPath.join(root, "Downloads")
        try FileManager.default.createDirectory(atPath: downloads.path, withIntermediateDirectories: true)
        var settings = Settings(downloads: downloads, dataDir: PyPath.join(root, "state"))
        settings.stableSeconds = 0

        let db = try Database(path: settings.database)
        var predicted: [ProposedGroup] = []
        var unclassified: [IndexedFile] = []
        do {
            for (index, document) in documents.enumerated() {
                let name = document["name"] as? String ?? ""
                let content = document["content"] as? String ?? ""
                let digest = Scanner.fingerprintString(name + "\0" + content)
                let path = PyPath.join(downloads, name)
                try db.connection.run(
                    """
                    INSERT INTO files(path,name,extension,size,created_at,modified_at,device,inode,fingerprint,source_urls,status,last_seen)
                    VALUES(?,?,?,?,0,0,1,?,?,?,'active',0)
                    """,
                    [path.path, name, Operations.pythonSuffix(name).lowercased(),
                     Py.count(content), index + 1, digest,
                     JSONValue.dumps(document["source_urls"] as? [String] ?? [])]
                )
                let fileID = db.connection.lastInsertRowID
                let vector = document["vector"] as? [Double]
                try db.connection.run(
                    """
                    INSERT INTO features(
                    file_id,fingerprint,extractor_version,model_version,text,title,keywords,summary,
                    native_embedding,native_embedding_space
                    ) VALUES(?,?,?,'benchmark-fixed',?,?,?,?,?,?)
                    """,
                    [fileID, digest, "benchmark:1", content, document["title"] as? String ?? "",
                     JSONValue.dumps(TextFeatures.keywords(content)),
                     Py.prefix(content, 600),
                     vector.map { Data(JSONValue.dumps($0).utf8) },
                     document["native_space"] as? String ?? "benchmark-multilingual"]
                )
                if let pivot = document["pivot_vector"] as? [Double] {
                    try db.connection.run(
                        """
                        INSERT INTO semantic_pivots(
                        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
                        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
                        ) VALUES(?,?,?,'en',?,?,'benchmark-translation',?,'en','benchmark-pivot',0)
                        """,
                        [fileID, digest, document["native_space"] as? String ?? "en", content,
                         document["translated_content"] as? String ?? content,
                         Data(JSONValue.dumps(pivot).utf8)]
                    )
                }
                for (field, kind, space) in [
                    ("native_views", "native", document["native_space"] as? String ?? "benchmark-multilingual"),
                    ("pivot_views", "pivot", "en"),
                ] {
                    let views = document[field] as? [String: [Double]] ?? [:]
                    for view in SemanticText.views where views[view] != nil {
                        let native = kind == "native"
                        let translated = document["translated_content"] as? String ?? content
                        try db.connection.run(
                            """
                            INSERT INTO semantic_views(file_id,fingerprint,view,kind,semantic_text,translated_text,
                              text_version,encoder_version,translation_version,source_language,embedding,embedding_space)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                            """,
                            [fileID, digest, view, kind,
                             SemanticText.viewText(IndexedFile(
                                id: fileID, path: path, name: name, fileExtension: "", size: 0,
                                createdAt: 0, modifiedAt: 0, device: 0, inode: 0, fingerprint: digest,
                                sourceURLs: [], text: content, title: document["title"] as? String ?? "",
                                keywords: TextFeatures.keywords(content), summary: Py.prefix(content, 600),
                                extractionError: nil), view: view),
                             native ? nil : translated, SemanticText.viewVersion, "benchmark-fixed",
                             native ? nil : "benchmark-translation",
                             document["native_space"] as? String ?? "benchmark-multilingual",
                             Data(JSONValue.dumps(views[view]!).utf8), space]
                        )
                    }
                }
            }
            let result = try ClusterEngine.cluster(db, settings, algorithm: variant.algorithm)
            predicted = result.groups
            unclassified = result.unclassified
        } catch {
            db.close()
            throw error
        }
        db.close()

        let expectedGroups = expectedClusters.values.map { Set($0) }
        let predictedGroups = predicted.map { Set($0.files.map(\.name)) }
        let expectedPairSet = pairs(expectedGroups)
        let predictedPairSet = pairs(predictedGroups)
        let truePositive = expectedPairSet.intersection(predictedPairSet).count
        let precision = predictedPairSet.isEmpty
            ? (expectedPairSet.isEmpty ? 1.0 : 0.0)
            : Double(truePositive) / Double(predictedPairSet.count)
        let recall = expectedPairSet.isEmpty ? 1.0 : Double(truePositive) / Double(expectedPairSet.count)
        let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0
        let expectedNormalized = Set(expectedGroups.map { $0.sorted().joined(separator: "|") })
        let predictedNormalized = Set(predictedGroups.map { $0.sorted().joined(separator: "|") })
        let predictedUnclassified = unclassified.map(\.name).sorted(by: Py.less)

        var predictedClusters: [String: [String]] = [:]
        for group in predicted {
            let key = predictedClusters[group.displayName] == nil
                ? group.displayName : "\(group.displayName) [\(group.topicKey)]"
            predictedClusters[key] = group.files.map(\.name).sorted(by: Py.less)
        }
        return [
            "fixture": fixturePath,
            "variant": variant.rawValue,
            "expected_clusters": expectedClusters.mapValues { $0.sorted(by: Py.less) },
            "predicted_clusters": predictedClusters,
            "predicted_groups": predicted.map { group in
                ["topic_id": group.topicKey,
                 "display_name": group.displayName,
                 "files": group.files.map(\.name).sorted(by: Py.less)] as [String: Any]
            },
            "expected_unclassified": expectedUnclassified.sorted(by: Py.less),
            "predicted_unclassified": predictedUnclassified,
            "pairwise_precision": rounded(precision, 4),
            "pairwise_recall": rounded(recall, 4),
            "pairwise_f1": rounded(f1, 4),
            "exact_cluster_match": expectedNormalized == predictedNormalized,
            "unclassified_match": Set(expectedUnclassified) == Set(predictedUnclassified),
        ]
    }

    public static func run(fixturePath: String?, variant: Variant = .upgraded) throws -> [String: Any] {
        if let fixturePath {
            let url = Paths.resolve(Paths.expand(fixturePath))
            guard let data = try? Data(contentsOf: url) else {
                throw OrganizerError("找不到 fixture：\(fixturePath)")
            }
            return try run(fixture: data, fixturePath: url.path, variant: variant)
        }
        return try run(fixture: try defaultFixtureData(), variant: variant)
    }
}

public extension Scanner {
    /// SHA-256 of an in-memory string, matching the on-disk fingerprint format.
    static func fingerprintString(_ value: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(value.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
