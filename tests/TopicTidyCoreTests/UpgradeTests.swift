import Foundation
import Testing

@testable import TopicTidyCore

private final class CountingEncoder: SemanticEncoder {
    let version = "counting-encoder:1"
    var calls = 0

    func encode(_ texts: [String]) throws -> [EncodedVector] {
        try encodeInLanguage(texts, language: "en")
    }

    func encodeInLanguage(_ texts: [String], language: String) throws -> [EncodedVector] {
        calls += texts.count
        return texts.map { _ in EncodedVector(vector: [1, 0], space: language) }
    }
}

private final class CountingTranslator: TranslationBackend {
    var version = "counting-translation:1"
    var calls = 0

    func statuses(_ pairs: [LanguagePair]) throws -> [LanguagePair: String] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0, "installed") })
    }

    func translate(_ texts: [String], source: String, target: String) throws -> [String] {
        calls += texts.count
        return texts
    }
}

@Test func twoViewsAverageAndThreeViewsUseMedianInBothSpaces() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("Left.md", "left")
    try workspace.put("Right.md", "right")
    _ = try workspace.scan()
    let files = try loadIndex(workspace.db)
    var left = try #require(files.first { $0.name == "Left.md" })
    var right = try #require(files.first { $0.name == "Right.md" })
    let identical = EncodedVector(vector: [1, 0], space: "en")
    let unrelated = EncodedVector(vector: [0, 1], space: "en")
    left.nativeViews = ["identity": identical, "overview": identical]
    right.nativeViews = ["identity": identical, "overview": unrelated]
    left.pivotViews = left.nativeViews
    right.pivotViews = right.nativeViews

    #expect(ClusterMath.multiView(left, right, crossLanguage: false).0 == 0.5)
    #expect(ClusterMath.multiView(left, right, crossLanguage: true).0 == 0.5)

    left.nativeViews["body"] = identical
    right.nativeViews["body"] = EncodedVector(vector: [0.25, sqrt(0.9375)], space: "en")
    let three = ClusterMath.multiView(left, right, crossLanguage: false)
    #expect(three.1 == 3)
    #expect(abs(three.0 - 0.25) < 0.000001)
}

@Test func distinctOfficialCoursePathsConflictDespiteSharedUniversityAndSubject() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    for name in ["MIT6.006 lecture 1.md", "MIT6.006 lecture 2.md", "MIT6.046 lecture 1.md"] {
        try workspace.put(name, "MIT algorithms dynamic programming sorting graph lecture notes")
    }
    _ = try workspace.scan()
    for name in ["MIT6.006 lecture 1.md", "MIT6.006 lecture 2.md", "MIT6.046 lecture 1.md"] {
        let slug = name.contains("6.006") ? "6-006-introduction-to-algorithms-spring-2020"
            : "6-046j-design-and-analysis-of-algorithms-spring-2015"
        try workspace.db.connection.run("UPDATE files SET source_urls=? WHERE name=?", [
            JSONValue.dumps(["https://ocw.mit.edu/courses/\(slug)/lecture.pdf"]), name,
        ])
    }
    let files = try loadIndex(workspace.db)
    let first = try #require(files.first { $0.name == "MIT6.006 lecture 1.md" })
    let second = try #require(files.first { $0.name == "MIT6.006 lecture 2.md" })
    let other = try #require(files.first { $0.name == "MIT6.046 lecture 1.md" })
    #expect((assessPair(first, second).metrics["source_url"] ?? 0) >= 0.60)
    #expect(assessPair(first, other).total == 0)
    #expect(assessPair(first, other).conflicts.contains("来源 MIT OpenCourseWare 课程不同"))
}

@Test func verifiedCollectionAndTwoSemanticViewsCanSupportDifferentChapters() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    for (name, text) in [
        ("Graph Foundations.md", "vertex edge traversal"),
        ("Sorting Methods.md", "quicksort heaps insertion"),
        ("Network Applications.md", "telemetry packets routing"),
    ] {
        try workspace.put(name, text)
    }
    _ = try workspace.scan()
    var files = try loadIndex(workspace.db)
    let collection = "https://github.com/example/algorithms/blob/main/lessons/"
    let base = EncodedVector(vector: [1, 0], space: "en")
    let low = EncodedVector(vector: [0, 1], space: "en")
    let middle = EncodedVector(vector: [0.70, sqrt(0.51)], space: "en")
    let high = EncodedVector(vector: [0.90, sqrt(0.19)], space: "en")
    for index in files.indices {
        files[index].sourceURLs = [collection + files[index].name]
        files[index].vector = [1, 0]
        files[index].vectorSpace = "en"
        files[index].nativeViews = files[index].name == "Network Applications.md"
            ? ["identity": low, "overview": middle, "body": high]
            : ["identity": base, "overview": base, "body": base]
    }
    let candidate = try #require(files.first { $0.name == "Network Applications.md" })
    let core = files.filter { $0.name != candidate.name }
    let cache = ClusterCache()
    let pairs = PairAssessmentCache(fileCache: cache)
    #expect(core.allSatisfy { pairs.assess(candidate, $0).total < 0.64 })
    let result = ClusterProfile(core: core, cache: cache).evaluate(
        candidate, threshold: 0.64, fileCache: cache, pairs: pairs)
    #expect(result != nil)
    #expect(result?.reason.contains("同一来源集合与独立语义") == true)
}

@Test func sourceAndCorroboratedViewsQualifyAChapterSeed() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("Transfer Learning.md", "feature adaptation weights")
    try workspace.put("Symbolic Reasoning.md", "logic rules inference")
    _ = try workspace.scan()
    var files = try loadIndex(workspace.db)
    let base = EncodedVector(vector: [1, 0], space: "en")
    for index in files.indices {
        files[index].sourceURLs = ["https://github.com/example/ai-course/blob/main/lessons/\(files[index].name)"]
        files[index].vector = [1, 0]
        files[index].vectorSpace = "en"
        files[index].nativeViews = files[index].name == "Transfer Learning.md"
            ? ["identity": EncodedVector(vector: [0, 1], space: "en"),
               "overview": EncodedVector(vector: [0.78, sqrt(0.3916)], space: "en"),
               "body": EncodedVector(vector: [0.80, 0.60], space: "en")]
            : ["identity": base, "overview": base, "body": base]
    }
    let cache = ClusterCache()
    let pairs = PairAssessmentCache(fileCache: cache)
    #expect(OrdinaryExpansion.seedEligible(files, cache: cache, pairs: pairs, threshold: 0.64))
}

@Test func multiViewCacheReusesVectorsAndInvalidatesChangedFile() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("Battery Thermal.md", "Battery thermal safety sensor monitoring and isolation.")
    try workspace.put("电池热安全.md", "电池热安全监测与紧急隔离程序。")
    _ = try workspace.scan()
    let encoder = CountingEncoder()
    let translator = CountingTranslator()

    _ = try ClusterEngine.cluster(workspace.db, workspace.settings,
                                  encoder: encoder, translator: translator)
    let firstCount = encoder.calls
    let firstTranslations = translator.calls
    #expect(firstCount > 2)
    #expect(firstTranslations > 0)
    #expect(try workspace.scalar("SELECT COUNT(*) FROM semantic_views")?.int ?? 0 > 0)
    _ = try ClusterEngine.cluster(workspace.db, workspace.settings,
                                  encoder: encoder, translator: translator)
    #expect(encoder.calls == firstCount)
    #expect(translator.calls == firstTranslations)

    translator.version = "counting-translation:2"
    _ = try ClusterEngine.cluster(workspace.db, workspace.settings,
                                  encoder: encoder, translator: translator)
    #expect(translator.calls > firstTranslations)

    try "Battery thermal safety monitoring and evacuation update.".write(
        to: PyPath.join(workspace.downloads, "Battery Thermal.md"), atomically: true, encoding: .utf8)
    _ = try workspace.scan()
    let stale = try workspace.rows(
        "SELECT COUNT(*) AS n FROM semantic_views v JOIN files f ON f.id=v.file_id WHERE f.name='Battery Thermal.md'"
    )
    #expect(stale.first?["n"].int == 0)
    _ = try ClusterEngine.cluster(workspace.db, workspace.settings,
                                  encoder: encoder, translator: translator)
    #expect(encoder.calls > firstCount)
}

@Test func translationBudgetCountsAttemptedText() {
    let budget = TranslationBudget(limit: 5)
    #expect(budget.reserve("abc"))
    #expect(!budget.reserve("def"))
    #expect(budget.used == 3)
    #expect(budget.reserve("de"))
    #expect(budget.used == 5)
}

@Test func upgradeGroupingIsIndependentOfFixtureInputOrder() throws {
    let data = try #require(FixtureData.json(for: .upgradeDevelopment).data(using: .utf8))
    let original = try Benchmark.run(fixture: data)
    var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    payload["documents"] = Array((payload["documents"] as? [[String: Any]] ?? []).reversed())
    let reordered = try Benchmark.run(fixture: JSONSerialization.data(withJSONObject: payload))
    #expect(original["predicted_clusters"] as? [String: [String]]
        == reordered["predicted_clusters"] as? [String: [String]])
    #expect(original["predicted_unclassified"] as? [String]
        == reordered["predicted_unclassified"] as? [String])
}

private func makeExpandedCoursePlan(_ workspace: Workspace) throws -> (Int, [String], ProposedGroup) {
    let entries: [(String, String, String, String)] = [
        ("Atlas Research Design.md", "ELEC7301 ELEC7301 atlas research sensor calibration harbor measurement methods.",
         "[1,0,0]", "https://github.com/acme/atlas/blob/main/research/design.md"),
        ("Harbor Research Field.md", "ELEC7301 ELEC7301 harbor research sensor calibration field measurements.",
         "[0.9,0.43589,0]", "https://github.com/acme/atlas/blob/main/research/field.md"),
        ("Atlas Research Addendum.md", "atlas research sensor calibration harbor measurement methods field notes.",
         "[1,0,0]", "https://github.com/acme/atlas/blob/main/research/design-addendum.md"),
    ]
    for (name, content, _, _) in entries { try workspace.put(name, content) }
    _ = try workspace.scan()
    for (name, _, vector, source) in entries {
        try workspace.db.connection.run(
            "UPDATE features SET native_embedding=?,native_embedding_space='benchmark-multilingual' WHERE file_id=(SELECT id FROM files WHERE name=?)",
            [Data(vector.utf8), name]
        )
        try workspace.db.connection.run("UPDATE files SET source_urls=? WHERE name=?",
                                        [JSONValue.dumps([source]), name])
    }
    let result = try workspace.cluster()
    let group = try #require(result.groups.first)
    let planID = try ClusterEngine.savePlan(workspace.db, workspace.settings,
                                            groups: result.groups, unclassified: result.unclassified)
    return (planID, entries.map(\.0), group)
}

@Test func expandedGroupRequiresManualReviewAndNeverPartiallyAutoMoves() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let (planID, names, group) = try makeExpandedCoursePlan(workspace)
    #expect(group.files.count == 3)
    #expect(group.reviewRequired)
    #expect(!group.autoEligible)
    let rows = try workspace.rows("SELECT review_required,auto_eligible FROM plan_members WHERE plan_id=?", [planID])
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0["review_required"].int == 1 && $0["auto_eligible"].int == 0 })
    let attempted = try Workflow.autoConfirmPlan(workspace.db, workspace.settings, planID, threshold: 0.90)
    #expect(attempted.moved == 0)
    #expect(attempted.batchID == nil)
    for name in names {
        #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, name).path))
    }
}

@Test func manuallyConfirmedExpandedGroupAppliesAndUndoesAllMembers() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let (planID, names, group) = try makeExpandedCoursePlan(workspace)
    let preview = try Operations.previewMoves(workspace.db, workspace.settings, planID)
    #expect(preview.count == 3)
    #expect(Set(preview.map { $0.topicKey }) == [group.topicKey])
    let (batchID, moved) = try Operations.applyPlan(workspace.db, workspace.settings, planID)
    #expect(moved.count == 3 && moved.allSatisfy { $0.status == "moved" })
    let (_, undone) = try Operations.undoBatch(workspace.db, workspace.settings, batchID)
    #expect(undone.count == 3 && undone.allSatisfy { $0.status == "undone" })
    for name in names {
        #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, name).path))
    }
}

@Test func equallyPlausibleCourseTopicsLeaveCandidateUnclassified() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let names = [
        ("Atlas Research Design A.md", "ELEC7301 ELEC7301 atlas research sensor calibration harbor measurement methods."),
        ("Harbor Research Field A.md", "ELEC7301 ELEC7301 harbor research sensor calibration field measurements."),
        ("Atlas Research Design B.md", "ELEC7302 ELEC7302 atlas research sensor calibration harbor measurement methods."),
        ("Harbor Research Field B.md", "ELEC7302 ELEC7302 harbor research sensor calibration field measurements."),
        ("Atlas Research Addendum.md", "atlas research sensor calibration harbor measurement methods field notes."),
    ]
    for (name, text) in names { try workspace.put(name, text) }
    _ = try workspace.scan()
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='benchmark-multilingual'",
        [Data("[1,0,0]".utf8)]
    )
    for (name, _) in names {
        try workspace.db.connection.run(
            "UPDATE files SET source_urls=? WHERE name=?",
            [JSONValue.dumps(["https://github.com/acme/atlas/blob/main/research/\(name)"]), name]
        )
    }
    let result = try workspace.cluster()
    #expect(result.groups.count == 2)
    let candidate = try #require(result.unclassified.first { $0.name == "Atlas Research Addendum.md" })
    #expect(result.unclassifiedReasons[candidate.id]?.contains("多个课程") == true)
}

@Test func memberEditInvalidatesAutoEligibilityButRenamePreservesIt() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "power electronics conversion")
    try workspace.put("ELEC6008 Lecture 2.md", "power electronics inverter")
    try workspace.put("unrelated.txt", "household groceries")
    _ = try workspace.scan()
    let planID = try workspace.proposePlan()
    let before = try workspace.rows("SELECT DISTINCT auto_eligible FROM plan_members WHERE plan_id=? AND topic_key IS NOT NULL", [planID])
    #expect(before.count == 1 && before[0]["auto_eligible"].int == 1)
    _ = try Operations.editPlan(workspace.db, planID, command: "rename", args: ["ELEC6008", "Power Course"])
    let afterRename = try workspace.rows("SELECT DISTINCT auto_eligible FROM plan_members WHERE plan_id=? AND topic_key IS NOT NULL", [planID])
    #expect(afterRename.count == 1 && afterRename[0]["auto_eligible"].int == 1)

    let member = try #require(workspace.rows("SELECT id FROM plan_members WHERE plan_id=? AND topic_key IS NULL", [planID]).first)["id"].int
    _ = try Operations.editPlan(workspace.db, planID, command: "move",
                                args: [String(member), "Power Course"])
    let afterMove = try workspace.rows("SELECT review_required,auto_eligible FROM plan_members WHERE plan_id=?", [planID])
    #expect(afterMove.allSatisfy { $0["review_required"].int == 1 && $0["auto_eligible"].int == 0 })
}
