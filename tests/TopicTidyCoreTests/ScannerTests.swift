import Foundation
import Testing

@testable import TopicTidyCore

/// Ported from tests/test_scanner.py.
@Test func scanExcludesHiddenIncompleteDirectoriesAndSymlinks() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("visible.md", "hello")
    try workspace.put(".hidden.md", "secret")
    try workspace.put("partial.crdownload", "partial")
    try FileManager.default.createDirectory(at: PyPath.join(workspace.downloads, "folder"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: PyPath.join(workspace.downloads, "link.md"),
        withDestinationURL: PyPath.join(workspace.downloads, "visible.md")
    )

    let candidates = try Scanner.candidates(workspace.settings)
    #expect(candidates.map(\.lastPathComponent) == ["visible.md"])
    #expect(try workspace.scan().scanned == 1)
}

@Test func corruptPDFDoesNotStopScan() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("broken.pdf", "not a pdf")
    try workspace.put("notes.md", "valid notes")

    let stats = try workspace.scan()

    #expect(stats.scanned == 2)
    #expect(stats.errors == 1)
    let errors = try workspace.rows("SELECT extraction_error FROM features WHERE extraction_error IS NOT NULL")
    #expect(errors.count == 1)
}

@Test func changedFileClearsCachedEmbeddingAndLanguageSpace() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    _ = try workspace.put("notes.md", "first version")
    let path = PyPath.join(workspace.downloads, "notes.md")
    _ = try workspace.scan()
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='en',model_version='old'",
        [Data("[1.0,0.0]".utf8)]
    )
    let row = try #require(try workspace.rows("SELECT id,fingerprint FROM files").first)
    try workspace.db.connection.run(
        """
        INSERT INTO semantic_pivots(
        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
        ) VALUES(?,?,'en','en','first','first','identity:1',?,'en','old',1)
        """,
        [row["id"].int, row["fingerprint"].string, Data("[1.0,0.0]".utf8)]
    )
    try "second version with new content".write(to: path, atomically: true, encoding: .utf8)

    _ = try workspace.scan()

    let feature = try #require(try workspace.rows(
        "SELECT native_embedding,native_embedding_space,model_version FROM features"
    ).first)
    #expect(feature["native_embedding"].isNull)
    #expect(feature["native_embedding_space"].isNull)
    #expect(feature["model_version"].isNull)
    #expect(try workspace.scalar("SELECT count(*) FROM semantic_pivots")?.int == 0)
}

/// Mirrors the reference's pluggable test extractor.
private final class VersionedExtractor: DocumentExtractor, @unchecked Sendable {
    let name = "versioned"
    let version: String
    let text: String
    private(set) var calls = 0

    init(version: String, text: String) {
        self.version = version
        self.text = text
    }

    func supports(_ path: URL) -> Bool { dotSuffix(path) == ".fixture" }

    func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        calls += 1
        return Extracted(text: text, title: text, summary: text)
    }
}

@Test func extractorVersionChangeInvalidatesUnchangedFileCache() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("document.fixture", "unchanged bytes")
    let first = VersionedExtractor(version: "1", text: "first extraction")
    _ = try workspace.scan(registry: ExtractorRegistry([first]))
    let row = try #require(try workspace.rows("SELECT id,fingerprint FROM files").first)
    try workspace.db.connection.run(
        "UPDATE features SET native_embedding=?,native_embedding_space='en',model_version='old'",
        [Data("[1.0,0.0]".utf8)]
    )
    try workspace.db.connection.run(
        """
        INSERT INTO semantic_pivots(
        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
        ) VALUES(?,?,'en','en','old','old','identity:1',?,'en','old',1)
        """,
        [row["id"].int, row["fingerprint"].string, Data("[1.0,0.0]".utf8)]
    )
    let second = VersionedExtractor(version: "2", text: "second extraction")

    let stats = try workspace.scan(registry: ExtractorRegistry([second]))

    #expect(stats.scanned == 1)
    #expect(stats.unchanged == 0)
    let feature = try #require(try workspace.rows("SELECT * FROM features").first)
    #expect(feature["extractor_version"].string == "versioned:2;text-features:\(TextFeatures.version)")
    #expect(feature["text"].string == "second extraction")
    #expect(feature["native_embedding"].isNull)
    #expect(feature["native_embedding_space"].isNull)
    #expect(feature["model_version"].isNull)
    #expect(try workspace.scalar("SELECT count(*) FROM semantic_pivots")?.int == 0)
    #expect(second.calls == 1)

    let repeated = try workspace.scan(registry: ExtractorRegistry([second]))
    #expect(repeated.unchanged == 1)
    #expect(second.calls == 1)
}

@Test func scannerAcceptsPluggableExtractor() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("sample.custom", "opaque")

    let stats = try workspace.scan(registry: ExtractorRegistry([CustomExtractor()]))

    #expect(stats.scanned == 1)
    let feature = try #require(try workspace.rows("SELECT extractor_version,text,title FROM features").first)
    #expect(feature["extractor_version"].string == "custom:7;text-features:\(TextFeatures.version)")
    #expect(feature["text"].string == "plugged in")
    #expect(feature["title"].string == "Custom Title")
}

private struct CustomExtractor: DocumentExtractor {
    let name = "custom"
    let version = "7"
    func supports(_ path: URL) -> Bool { dotSuffix(path) == ".custom" }
    func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        Extracted(text: "plugged in", title: "Custom Title", keywords: ["plugged"])
    }
}

@Test func interruptedMoveRecoveryUpdatesFileLocation() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let source = try workspace.put("recover.md", "recover me")
    _ = try workspace.scan()
    let row = try #require(try workspace.rows("SELECT id,fingerprint FROM files WHERE name='recover.md'").first)
    let destination = PyPath.join(workspace.settings.organizedDir, "Recovered", source.lastPathComponent)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try workspace.db.connection.run(
        "INSERT INTO operation_batches(kind,status,created_at) VALUES('apply','running',1)"
    )
    let batch = workspace.db.connection.lastInsertRowID
    try workspace.db.connection.run(
        """
        INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
        VALUES(?,?,?,?,?,'intent',1)
        """,
        [batch, row["id"].int, source.path, destination.path, row["fingerprint"].string]
    )
    try FileManager.default.moveItem(at: source, to: destination)

    #expect(try workspace.db.recoverInterrupted() == 1)
    let recovered = try #require(try workspace.rows(
        "SELECT path,status FROM files WHERE id=?", [row["id"].int]
    ).first)
    #expect(recovered["path"].string == destination.path)
    #expect(recovered["status"].string == "organized")
}

@Test func scanWaitsForStabilityAndSkipsGrowingFiles() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    var settings = workspace.settings
    settings.stableSeconds = 0.2
    try workspace.put("stable.md", "content")

    let stats = try Scanner.scan(workspace.db, settings, waitForStability: true)

    #expect(stats.scanned == 1)
    #expect(stats.skipped == 0)
}
