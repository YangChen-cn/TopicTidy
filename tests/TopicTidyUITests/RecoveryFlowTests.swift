import AppKit
import SwiftUI
import Testing

@testable import TopicTidy
@testable import TopicTidyCore

/// The recovery used to be an alert sheet inside the menu bar panel. The panel
/// is transient, so it resigned key, closed under the pointer, and the click
/// never rebuilt the database. This drives the recovery through the same model
/// entry point the notice's button uses, against isolated state, and renders the
/// surfaces that replaced the sheet. Set TOPICTIDY_RENDER_RECOVERY for PNGs.
///
/// The hosted views start their own `status` task, so rendering happens last and
/// nothing after it depends on the model.
@MainActor
@Test func recoveryRebuildsTheDatabaseWithoutASheet() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("topictidy-gui-recovery-\(UUID().uuidString)")
    let downloads = root.appendingPathComponent("Downloads")
    let state = root.appendingPathComponent("State")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "lecture content".write(to: downloads.appendingPathComponent("ELEC6008 lecture.txt"),
                                atomically: true, encoding: .utf8)

    setenv("DOWNLOADS_ORGANIZER_DOWNLOADS", downloads.path, 1)
    setenv("DOWNLOADS_ORGANIZER_HOME", state.path, 1)
    defer {
        unsetenv("DOWNLOADS_ORGANIZER_DOWNLOADS")
        unsetenv("DOWNLOADS_ORGANIZER_HOME")
    }

    let store = state.appendingPathComponent("organizer.sqlite3")
    let old = try SQLiteConnection(path: store.path)
    try old.execute("""
        CREATE TABLE schema_meta(version INTEGER NOT NULL);
        INSERT INTO schema_meta(version) VALUES (6);
        CREATE TABLE app_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);
        INSERT INTO app_settings(key,value,updated_at) VALUES ('old_marker','keep_until_confirmed',0);
        """)
    old.close()

    let model = AppModel()
    #expect(await model.perform("status") == false)
    #expect(model.incompatibleDatabase)
    #expect(model.error?.contains("版本 6") == true)

    // What the notice's destructive button runs.
    #expect(await model.perform("delete-incompatible-database"))
    #expect(!model.incompatibleDatabase)
    #expect(model.error == nil)
    #expect(model.snapshot?.members.count == 1)

    let fresh = try Database(path: store)
    #expect(try fresh.connection.query("SELECT version FROM schema_meta").first?[0].int == Database.schemaVersion)
    #expect(try fresh.connection.query("SELECT COUNT(*) FROM files").first?[0].int == 1)
    #expect(try fresh.connection.query("SELECT value FROM app_settings WHERE key='old_marker'").isEmpty)
    // A database this build can open is never deleted.
    #expect(await model.perform("delete-incompatible-database") == false)
    #expect(model.error?.contains("不是旧版本") == true)
    // Leave the store incompatible again so the notice can be rendered.
    try fresh.connection.run("UPDATE schema_meta SET version=6")
    fresh.close()
    #expect(await model.perform("status") == false)
    #expect(model.incompatibleDatabase)

    // Hosting these views starts their own `status` task, which clears the error
    // before failing again. An operation in flight makes `perform` refuse that
    // call, so the capture sees the state the user sees instead of a half-cleared
    // one. It is also the state right after the destructive button is clicked.
    model.busy = true
    defer { model.busy = false }

    let panel = ImageRenderer(content: PanelView(model: model).frame(width: 340))
    panel.scale = 2
    let panelImage = try #require(panel.nsImage)
    #expect(panelImage.size.height > 180)
    let window = ImageRenderer(content: OrganizerView(model: model).frame(width: 1100, height: 460))
    window.scale = 2
    let windowImage = try #require(window.nsImage)
    #expect(windowImage.size.height >= 460)

    if let path = ProcessInfo.processInfo.environment["TOPICTIDY_RENDER_RECOVERY"] {
        try writePNG(panelImage, to: "\(path)-panel-live.png")
        try writePNG(windowImage, to: "\(path)-window-live.png")
    }
}

private func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        Issue.record("could not encode \(path)")
        return
    }
    try png.write(to: URL(fileURLWithPath: path))
}
