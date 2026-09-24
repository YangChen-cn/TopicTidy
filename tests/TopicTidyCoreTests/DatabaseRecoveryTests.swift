import Foundation
import Testing

@testable import TopicTidyCore

@Test func incompatibleDatabaseCanBeExplicitlyDeletedAndRescanned() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("topictidy-recovery-\(UUID().uuidString)")
    let downloads = root.appendingPathComponent("Downloads")
    let data = root.appendingPathComponent("State")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = downloads.appendingPathComponent("lecture.txt")
    try "lecture content".write(to: file, atomically: true, encoding: .utf8)
    let settings = Settings(downloads: downloads, dataDir: data)

    let old = try SQLiteConnection(path: settings.database.path)
    try old.execute("""
        CREATE TABLE schema_meta(version INTEGER NOT NULL);
        INSERT INTO schema_meta(version) VALUES (6);
        CREATE TABLE app_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);
        INSERT INTO app_settings(key,value,updated_at) VALUES ('old_marker','keep_until_confirmed',0);
        """)
    old.close()

    let service = AppService(base: settings)
    var status = ServiceRequest()
    status.action = "status"
    let blocked = await service.dispatch(status)
    #expect(!blocked.ok)
    #expect(blocked.incompatibleDatabase)
    let stillOld = try SQLiteConnection(path: settings.database.path)
    #expect(try stillOld.query("SELECT version FROM schema_meta").first?[0].int == 6)
    #expect(try stillOld.query("SELECT value FROM app_settings WHERE key='old_marker'").first?[0].string == "keep_until_confirmed")
    stillOld.close()

    var reset = ServiceRequest()
    reset.action = "delete-incompatible-database"
    reset.semantic = false
    let recovered = await service.dispatch(reset)
    #expect(recovered.ok)
    #expect(recovered.snapshot != nil)
    #expect(FileManager.default.fileExists(atPath: file.path))
    let fresh = try Database(path: settings.database)
    #expect(try fresh.connection.query("SELECT version FROM schema_meta").first?[0].int == Database.schemaVersion)
    #expect(try fresh.connection.query("SELECT COUNT(*) FROM files").first?[0].int == 1)
    #expect(try fresh.connection.query("SELECT value FROM app_settings WHERE key='old_marker'").isEmpty)
    fresh.close()

    let refused = await service.dispatch(reset)
    #expect(!refused.ok)
    #expect(!refused.incompatibleDatabase)
    #expect(FileManager.default.fileExists(atPath: settings.database.path))
}
