import Foundation
import Testing

@testable import TopicTidyCore

/// Golden outputs captured from the Python reference implementation before it
/// was removed; a change here means clustering behaviour changed.
private func golden(_ name: String) throws -> [String: Any] {
    let path = fixtureDirectory().appendingPathComponent(name)
    let data = try Data(contentsOf: path)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func runFixture(_ fixture: FixtureData.Name) throws -> [String: Any] {
    try Benchmark.run(fixture: try #require(FixtureData.json(for: fixture).data(using: .utf8)))
}

@Test func coreBenchmarkDetectsExpectedClustersWithoutFalseMerges() throws {
    let result = try runFixture(.core)

    #expect(result["pairwise_precision"] as? Double == 1.0)
    #expect(result["pairwise_recall"] as? Double == 1.0)
    #expect(result["pairwise_f1"] as? Double == 1.0)
    #expect(result["exact_cluster_match"] as? Bool == true)
    #expect(result["unclassified_match"] as? Bool == true)
    let predicted = try #require(result["predicted_clusters"] as? [String: [String]])
    #expect(predicted["Grid Storage Design"] == [
        "Grid Storage Design v1.pdf", "Grid Storage Design v2.docx",
    ])
    #expect(predicted.values.contains(["Reference Notes.md", "电池储能概论.md"]))
}

@Test func holdoutBenchmarkPreservesPrecisionAndUnclassifiedFiles() throws {
    let result = try runFixture(.holdout)

    #expect(result["pairwise_precision"] as? Double == 1.0)
    #expect((result["pairwise_recall"] as? Double ?? 0) >= 0.90)
    #expect((result["pairwise_f1"] as? Double ?? 0) >= 0.94)
    #expect(result["unclassified_match"] as? Bool == true)
}

@Test func coreBenchmarkMatchesFrozenReferenceOutput() throws {
    let result = try runFixture(.core)
    let expected = try golden("benchmark-core-golden.json")

    #expect(result["predicted_clusters"] as? [String: [String]]
        == expected["predicted_clusters"] as? [String: [String]])
    #expect(result["predicted_unclassified"] as? [String]
        == expected["predicted_unclassified"] as? [String])
}

@Test func holdoutBenchmarkMatchesFrozenReferenceOutput() throws {
    let result = try runFixture(.holdout)
    let expected = try golden("benchmark-holdout-golden.json")

    #expect(result["predicted_clusters"] as? [String: [String]]
        == expected["predicted_clusters"] as? [String: [String]])
    #expect(result["predicted_unclassified"] as? [String]
        == expected["predicted_unclassified"] as? [String])
}

@Test func benchmarkAcceptsAnExternalFixturePath() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let path = PyPath.join(workspace.root, "fixture.json")
    let payload: [String: Any] = [
        "documents": [
            ["name": "ELEC6008 Lecture 1.md", "content": "power electronics converter design"],
            ["name": "ELEC6008 Lecture 2.md", "content": "power electronics inverter design"],
        ],
        "expected_clusters": ["ELEC6008": ["ELEC6008 Lecture 1.md", "ELEC6008 Lecture 2.md"]],
        "expected_unclassified": [],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: path)

    let result = try Benchmark.run(fixturePath: path.path)

    #expect(result["pairwise_f1"] as? Double == 1.0)
    #expect(result["exact_cluster_match"] as? Bool == true)
}
