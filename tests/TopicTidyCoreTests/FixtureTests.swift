import Foundation
import Testing

@testable import TopicTidyCore

/// The fixtures are embedded for relocatable distribution; the JSON files stay
/// the editable source of truth, so keep both copies identical.
@Test func embeddedFixturesMatchCheckedInJSON() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    for name in ["benchmark_core", "holdout_unseen", "upgrade_development", "upgrade_holdout"] {
        let path = root.appendingPathComponent("Resources/fixtures/\(name).json")
        let contents = try String(contentsOf: path, encoding: .utf8)
        let identifier = try #require(FixtureData.Name(rawValue: name))
        let embedded = FixtureData.json(for: identifier)
        #expect(embedded == contents)
    }
}

@Test func benchmarkFixtureLoads() throws {
    let names: [FixtureData.Name] = [.core, .holdout, .upgradeDevelopment, .upgradeHoldout]
    for fixture in names {
        let data = try #require(FixtureData.json(for: fixture).data(using: .utf8))
        let parsed = try Benchmark.loadFixture(data)
        #expect((parsed["documents"] as? [Any])?.isEmpty == false)
        #expect((parsed["expected_clusters"] as? [String: Any])?.isEmpty == false)
    }
}
