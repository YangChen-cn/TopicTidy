import Foundation
import Testing

@testable import TopicTidyCore

/// Ported from tests/test_clustering.py.
@Test func sameCourseClustersAndConflictingCoursesStayApart() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Chapter 1.md", "power electronics converter")
    try workspace.put("ELEC6008 Chapter 2.md", "power electronics inverter")
    try workspace.put("ELEC6103 Chapter 1.md", "power electronics converter")
    try workspace.put("ELEC6103 Chapter 2.md", "power electronics inverter")
    try workspace.put("random.json", "{}")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(Set(result.groups.map(\.name)) == ["ELEC6008", "ELEC6103"])
    #expect(Set(result.unclassified.map(\.name)) == ["random.json"])
    #expect(result.groups.allSatisfy { $0.files.count == 2 })
}

@Test func contentAndFixedSemanticVectorsClusterNumberedDocuments() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("01 Introduction.md", "renewable energy solar wind systems overview")
    try workspace.put("02 Renewable Energy.md", "renewable energy solar wind generation systems")
    _ = try workspace.scan()
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='test',model_version='test-fixed'",
        [Data("[1.0,0.0]".utf8)]
    )

    let result = try workspace.cluster()

    #expect(result.groups.count == 1)
    let group = try #require(result.groups.first)
    #expect(Set(group.files.map(\.name)) == ["01 Introduction.md", "02 Renewable Energy.md"])
    #expect(result.unclassified.isEmpty)
    #expect(group.displayName == "Renewable Energy")
    #expect(group.topicKey.hasPrefix("cluster:"))
    let evidence = Dictionary(uniqueKeysWithValues: group.evidence.map { ($0.kind, $0) })
    #expect(Set(evidence.keys).isSuperset(of: [
        "course_code", "filename_similarity", "content_similarity", "semantic_similarity",
        "semantic_cross_language", "source_url", "cluster_support",
    ]))
    #expect(evidence["semantic_similarity"]?.strength == "strong")
    #expect(evidence["source_url"]?.strength == "none")
}

@Test func bodyCourseCodeGroupsFilesWithoutCodeInFilename() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("01 Systems Overview.md", "ELEC6200 ELEC6200 autonomous control architecture")
    try workspace.put("02 Control Design.md", "ELEC6200 ELEC6200 autonomous control design")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(result.unclassified.isEmpty)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.displayName == "ELEC6200")
    #expect(result.groups.first?.topicKey == "course:ELEC6200")
    #expect(result.groups.first?.evidence.first { $0.kind == "course_code" }?.strength == "strong")
}

@Test func courseCodeSeenOnceInEachBodyBecomesCollectiveEvidence() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("01 Introduction.md", "ELEC7011 Energy Internet systems overview")
    try workspace.put("02 Renewable Energy.md", "ELEC7011 Energy Internet solar wind generation")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(result.unclassified.isEmpty)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.displayName == "ELEC7011")
    #expect(Set(result.groups.first?.files.map(\.name) ?? []) == [
        "01 Introduction.md", "02 Renewable Energy.md",
    ])
}

@Test func singleBodyCourseReferenceDoesNotClassifyAFile() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("Introduction.md", "ELEC7011 Energy Internet overview")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(result.groups.isEmpty)
    #expect(result.unclassified.map(\.name) == ["Introduction.md"])
}

@Test func termAndYearIsNotMistakenForCourseCode() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("lec1.md", "ELEC7043 Digital Image Processing Autumn 2026")
    try workspace.put("lec2.md", "Autumn 2026 Digital Image Processing intensity transformations")
    _ = try workspace.scan()
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='test',model_version='test-fixed'",
        [Data("[1.0,0.0]".utf8)]
    )
    try workspace.db.connection.run(
        "UPDATE files SET source_urls=?",
        ["[\"https://moodle.example/course/7043/lecture\"]"]
    )

    let result = try workspace.cluster()

    #expect(result.unclassified.isEmpty)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.displayName == "ELEC7043")
    #expect(Set(result.groups.first?.files.map(\.name) ?? []) == ["lec1.md", "lec2.md"])
}

@Test func genericSharedDomainIsNotEnoughToCluster() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("tax receipt.md", "annual personal tax receipt")
    try workspace.put("holiday booking.md", "hotel booking itinerary")
    _ = try workspace.scan()
    // The reference monkeypatches `source_urls`; set the same value directly.
    try workspace.db.connection.run(
        "UPDATE files SET source_urls=?", ["[\"https://example.com/download/file\"]"]
    )

    let result = try workspace.cluster()

    #expect(result.groups.isEmpty)
    #expect(result.unclassified.count == 2)
}

@Test func distinctiveSeriesTokenAndSemanticsJoinDifferentChapters() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("cs229-notes1.md", "linear regression likelihood optimization")
    try workspace.put("cs229-deep-learning.md", "neural network backpropagation representation")
    _ = try workspace.scan()
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='test',model_version='test-fixed'",
        [Data("[1.0,0.0]".utf8)]
    )

    let result = try workspace.cluster()

    #expect(result.unclassified.isEmpty)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.displayName == "CS229")
}

@Test func markdownIndexLinksFormABoundedCollection() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("README.md", "# Embedded Linux Notes\n[Processes](01-processes.md)\n"
        + "[Files](02-files.md)\n[Signals](03-signals.md)\n")
    try workspace.put("01-processes.md", "fork exec process lifecycle")
    try workspace.put("02-files.md", "open read write descriptors")
    try workspace.put("03-signals.md", "sigaction interrupt handling")
    try workspace.put("unrelated.md", "holiday packing list")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(result.groups.count == 1)
    let group = try #require(result.groups.first)
    #expect(group.displayName == "Embedded Linux Notes")
    #expect(Set(group.files.map(\.name)) == ["README.md", "01-processes.md", "02-files.md", "03-signals.md"])
    #expect(group.evidence.first?.kind == "document_links")
    #expect(group.confidence < 0.92)
    #expect(result.unclassified.map(\.name) == ["unrelated.md"])
}

@Test func genericSingleFilenameTokenDoesNotGetOverlapScoreOfOne() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("report.md", "annual tax filing receipt")
    try workspace.put("final-report-energy.md", "solar inverter performance")
    _ = try workspace.scan()
    let index = try loadIndex(workspace.db)

    let assessment = assessPair(index[0], index[1])
    let filename = try #require(assessment.evidence.first { $0.kind == "filename_similarity" })
    #expect((filename.score ?? 0) < 0.50)

    let result = try workspace.cluster()
    #expect(result.groups.isEmpty)
    #expect(result.unclassified.count == 2)
}

@Test func crossLanguagePivotSupportsBilingualPair() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("Reference Notes.md", "energy storage reference notes")
    try workspace.put("电池储能概论.md", "电池储能系统概论")
    _ = try workspace.scan()
    let rows = try workspace.rows("SELECT id FROM files ORDER BY name")
    let pivot = Data("[1.0,0.0]".utf8)
    for row in rows {
        try workspace.db.connection.run(
            "UPDATE features SET native_embedding=?,native_embedding_space='en' WHERE file_id=?",
            [pivot, row["id"].int]
        )
    }
    // Put the two files in different native spaces with English pivots.
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding_space='zh-Hans' WHERE file_id=?",
        [rows[1]["id"].int]
    )
    for row in rows {
        try workspace.db.connection.run(
            """
            INSERT INTO semantic_pivots(
            file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
            translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
            ) SELECT id,fingerprint,'zh-Hans','en','text','text','test',?,'en','test',0 FROM files WHERE id=?
            """,
            [pivot, row["id"].int]
        )
    }

    let result = try workspace.cluster()

    #expect(result.groups.count == 1)
    let group = try #require(result.groups.first)
    let cross = try #require(group.evidence.first { $0.kind == "semantic_cross_language" })
    #expect((cross.score ?? 0) > 0)
    #expect(group.files.count == 2)
}

@Test func confidenceIsHeuristicAndReportedPerGroup() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Chapter 1.md", "power electronics converter")
    try workspace.put("ELEC6008 Chapter 2.md", "power electronics inverter")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    let group = try #require(result.groups.first)
    #expect(group.confidence >= 0.90)
    #expect(group.confidence <= 1.0)
    #expect(group.conflicts.isEmpty)
}

@Test func topicKeyIsStableAcrossRunsAndDisplayNameChanges() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Chapter 1.md", "power electronics converter")
    try workspace.put("ELEC6008 Chapter 2.md", "power electronics inverter")
    _ = try workspace.scan()

    let first = try workspace.cluster()
    let originalName = try #require(first.groups.first?.displayName)
    let planID = try ClusterEngine.savePlan(workspace.db, workspace.settings,
                                            groups: first.groups, unclassified: first.unclassified)
    _ = try Operations.editPlan(workspace.db, planID, command: "rename",
                                args: [originalName, "Power Conversion"],
                                organizedDir: workspace.settings.organizedDir)
    let second = try workspace.cluster()

    #expect(second.groups.first?.topicKey == first.groups.first?.topicKey)
    #expect(second.groups.first?.displayName == "Power Conversion")
}
