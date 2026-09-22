import Foundation
import Testing

@testable import TopicTidyCore

/// Mirrors the pytest `workspace` fixture: a temporary Downloads directory plus
/// an isolated state directory.
final class Workspace {
    let root: URL
    let downloads: URL
    let dataDir: URL
    var settings: Settings
    let db: Database

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("topictidy-test-\(UUID().uuidString)")
        downloads = PyPath.join(root, "Downloads")
        dataDir = PyPath.join(root, "data")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var settings = Settings(downloads: downloads, dataDir: dataDir)
        settings.stableSeconds = 0
        self.settings = settings
        self.db = try Database(path: settings.database)
    }

    func close() {
        db.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// `put(folder, name, text)` from the reference conftest.
    @discardableResult
    func put(_ name: String, _ text: String = "sample") throws -> URL {
        let path = PyPath.join(downloads, name)
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func scan(waitForStability: Bool = false, registry: ExtractorRegistry = .default()) throws -> ScanStats {
        try Scanner.scan(db, settings, waitForStability: waitForStability, registry: registry)
    }

    func rows(_ sql: String, _ parameters: [Any?] = []) throws -> [Row] {
        try db.connection.query(sql, parameters)
    }

    func scalar(_ sql: String, _ parameters: [Any?] = []) throws -> Value? {
        try db.connection.scalar(sql, parameters)
    }
}

extension Workspace {
    /// Create a plan the way the CLI does, without any encoder.
    @discardableResult
    func proposePlan() throws -> Int {
        let result = try ClusterEngine.cluster(db, settings)
        return try ClusterEngine.savePlan(db, settings, groups: result.groups, unclassified: result.unclassified)
    }

    func cluster() throws -> ClusterResult {
        try ClusterEngine.cluster(db, settings)
    }
}

struct AnyObjectError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

extension String {
    var trimmedEmpty: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
