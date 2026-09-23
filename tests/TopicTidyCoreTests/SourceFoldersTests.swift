import Foundation
import Testing

@testable import TopicTidyCore

@Test func multipleScanRootsCanApplyAndUndoAfterPreferenceChanges() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let extra = PyPath.join(workspace.root, "Course Material")
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    let first = try workspace.put("ELEC6008 Lecture 1.md", "ELEC6008 course lecture one")
    let second = PyPath.join(extra, "ELEC6008 Lecture 2.md")
    try "ELEC6008 course lecture two".write(to: second, atomically: true, encoding: .utf8)

    let store = PreferenceStore(workspace.db, base: workspace.settings)
    #expect(store.get().scanRoots == [workspace.downloads])
    try store.setScanRoots([workspace.downloads, extra])
    let settings = store.resolvedSettings()
    #expect(settings.scanRoots == [Paths.resolve(workspace.downloads), Paths.resolve(extra)])
    let stats = try Scanner.scan(workspace.db, settings)
    #expect(stats.scanned == 2)
    let proposal = try Workflow.createProposal(workspace.db, settings, useSemantic: false)
    #expect(proposal.groups.count == 1)
    if let group = proposal.groups.first {
        #expect(Set(group.files.map { Paths.resolve($0.path) })
            == Set([Paths.resolve(first), Paths.resolve(second)]))
    }

    try store.setScanRoots([workspace.downloads])
    let changed = store.resolvedSettings()
    #expect(try Operations.planScanRoots(workspace.db, changed, proposal.planID)
        == [Paths.resolve(workspace.downloads), Paths.resolve(extra)])
    let (_, applied) = try Operations.applyPlan(workspace.db, changed, proposal.planID)
    #expect(applied.count == 2 && applied.allSatisfy { $0.status == "moved" })
    #expect(!FileManager.default.fileExists(atPath: second.path))

    let batch = try workspace.rows("SELECT id FROM operation_batches WHERE kind='apply' ORDER BY id DESC LIMIT 1")[0]["id"].int
    let (_, undone) = try Operations.undoBatch(workspace.db, changed, batch)
    #expect(undone.count == 2 && undone.allSatisfy { $0.status == "undone" })
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
}

@Test func scanRootsRejectUnsafePathsAndUnavailableFolderDoesNotClearIndex() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let extra = PyPath.join(workspace.root, "Extra")
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    let file = PyPath.join(extra, "notes.md")
    try "course notes".write(to: file, atomically: true, encoding: .utf8)
    let store = PreferenceStore(workspace.db, base: workspace.settings)

    #expect(throws: (any Error).self) { try store.setScanRoots([]) }
    #expect(throws: (any Error).self) {
        try store.setScanRoots([workspace.downloads, workspace.downloads])
    }
    let link = PyPath.join(workspace.root, "Linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: extra)
    #expect(throws: (any Error).self) { try store.setScanRoots([link]) }
    try FileManager.default.createDirectory(at: workspace.settings.organizedDir,
                                            withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try store.setScanRoots([workspace.settings.organizedDir]) }

    try store.setAutoConfirm(true)
    try store.setScanRoots([workspace.downloads, extra])
    #expect(!store.get().autoConfirmEnabled)
    let settings = store.resolvedSettings()
    #expect(try Scanner.scan(workspace.db, settings).scanned == 1)
    try FileManager.default.removeItem(at: extra)
    #expect(throws: (any Error).self) { try Scanner.scan(workspace.db, settings) }
    #expect(try workspace.rows("SELECT status FROM files WHERE path=?", [Paths.resolve(file).path])[0]["status"].string
        == "active")
}

@Test func appServiceUsesConfiguredScanRoots() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let extra = PyPath.join(workspace.root, "Research")
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    let path = PyPath.join(extra, "Project Compass.md")
    try "Project Compass research notes".write(to: path, atomically: true, encoding: .utf8)
    let service = AppService(base: workspace.settings)
    var request = ServiceRequest()
    request.action = "preferences"
    request.scanRoots = [workspace.downloads.path, extra.path]
    let saved = await service.dispatch(request)
    #expect(saved.ok)
    #expect(saved.snapshot?.preferences.scanRoots.count == 2)

    request = ServiceRequest()
    request.action = "scan"
    request.semantic = false
    let scanned = await service.dispatch(request)
    #expect(scanned.ok)
    #expect(scanned.snapshot?.members.map(\.name) == [path.lastPathComponent])
}
