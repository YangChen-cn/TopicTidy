import Foundation
import Testing

@testable import TopicTidyCore

/// Ported from tests/test_operations.py.
private func coursePlan(_ workspace: Workspace) throws -> Int {
    try workspace.put("ELEC6008 Chapter 1.md", "one")
    try workspace.put("ELEC6008 Chapter 2.md", "two")
    _ = try workspace.scan()
    return try workspace.proposePlan()
}

@Test func applyUsesDeterministicCollisionNameAndUndoRestores() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let existing = PyPath.join(workspace.settings.organizedDir, "ELEC6008", "ELEC6008 Chapter 1.md")
    try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "existing".write(to: existing, atomically: true, encoding: .utf8)

    let preview = try Operations.previewMoves(workspace.db, workspace.settings, planID)
    #expect(preview.contains { $0.destination.lastPathComponent == "ELEC6008 Chapter 1 (2).md" })

    let (batchID, results) = try Operations.applyPlan(workspace.db, workspace.settings, planID)
    #expect(results.allSatisfy { $0.status == "moved" })

    let (undoID, undone) = try Operations.undoBatch(workspace.db, workspace.settings, batchID)
    #expect(undoID > batchID)
    #expect(undone.allSatisfy { $0.status == "undone" })
    #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, "ELEC6008 Chapter 1.md").path))
}

@Test func applySkipsFileChangedAfterPlan() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let changed = PyPath.join(workspace.downloads, "ELEC6008 Chapter 1.md")
    try "changed after plan".write(to: changed, atomically: true, encoding: .utf8)

    let (_, results) = try Operations.applyPlan(workspace.db, workspace.settings, planID)

    #expect(results.contains { $0.status == "skipped" && $0.error.contains("已改变") })
    #expect(FileManager.default.fileExists(atPath: changed.path))
}

@Test func applyOneTopicKeepsOtherTopicsDraft() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    for course in ["ELEC6008", "ELEC6103"] {
        try workspace.put("\(course) Lecture 1.md", "one")
        try workspace.put("\(course) Lecture 2.md", "two")
    }
    _ = try workspace.scan()
    let planID = try workspace.proposePlan()
    let firstTopic = try #require(try workspace.rows(
        "SELECT topic_key FROM plan_members WHERE plan_id=? ORDER BY group_name LIMIT 1", [planID]
    ).first)["topic_key"].string
    let memberIDs = Set(try workspace.rows(
        "SELECT id FROM plan_members WHERE plan_id=? AND topic_key=?", [planID, firstTopic]
    ).map { $0["id"].int })

    let (batchID, results) = try Operations.applyPlan(workspace.db, workspace.settings, planID,
                                                      memberIDs: memberIDs)

    #expect(batchID > 0)
    #expect(results.count == 2)
    #expect(try workspace.scalar("SELECT status FROM plans WHERE id=?", [planID])?.string == "draft")
    #expect(try workspace.scalar(
        "SELECT COUNT(*) FROM plan_members WHERE plan_id=? AND applied=1", [planID]
    )?.int == 2)
    #expect(try Operations.previewMoves(workspace.db, workspace.settings, planID).count == 2)
}

@Test func dismissTopicIsPlanOnlyAndReversible() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let topicKey = try #require(try workspace.rows(
        "SELECT topic_key FROM plan_members WHERE plan_id=? LIMIT 1", [planID]
    ).first)["topic_key"].string

    #expect(try Operations.editPlan(workspace.db, planID, command: "dismiss-topic", args: [topicKey])
        == "主题已取消")
    #expect(try Operations.previewMoves(workspace.db, workspace.settings, planID).isEmpty)
    #expect(try workspace.scalar("SELECT COUNT(*) FROM corrections")?.int == 0)

    #expect(try Operations.editPlan(workspace.db, planID, command: "restore-topic", args: [topicKey])
        == "主题已恢复")
    #expect(try Operations.previewMoves(workspace.db, workspace.settings, planID).count == 2)
}

@Test func undoSkipsWhenOriginalPathIsOccupied() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let (batchID, _) = try Operations.applyPlan(workspace.db, workspace.settings, planID)
    try workspace.put("ELEC6008 Chapter 1.md", "replacement")

    let (_, results) = try Operations.undoBatch(workspace.db, workspace.settings, batchID)

    #expect(results.contains { $0.status == "skipped" && $0.error.contains("原路径已被占用") })
}

@Test func manualExclusionIsUsedByFutureProposals() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let member = try #require(try workspace.rows(
        "SELECT id FROM plan_members WHERE plan_id=? ORDER BY id LIMIT 1", [planID]
    ).first)["id"].int
    _ = try Operations.editPlan(workspace.db, planID, command: "exclude",
                                args: [String(member)], organizedDir: workspace.settings.organizedDir)

    let result = try workspace.cluster()

    #expect(result.groups.isEmpty)
    #expect(result.unclassified.count == 2)
}

@Test func confirmedTopicBecomesPrototypeForNewDownload() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let (batchID, results) = try Operations.applyPlan(workspace.db, workspace.settings, planID)
    #expect(batchID > 0)
    #expect(results.allSatisfy { $0.status == "moved" })
    try workspace.put("ELEC6008 Revision.md", "revision")
    _ = try workspace.scan()

    let result = try workspace.cluster()

    #expect(result.groups.count == 1)
    #expect(result.groups.first?.name == "ELEC6008")
    #expect(result.groups.first?.files.map(\.name) == ["ELEC6008 Revision.md"])
    #expect(result.unclassified.isEmpty)
}

@Test func renameChangesDisplayNameWithoutChangingTopicIdentity() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let before = try #require(try workspace.rows(
        "SELECT DISTINCT topic_key FROM plan_members WHERE plan_id=?", [planID]
    ).first)["topic_key"].string

    _ = try Operations.editPlan(workspace.db, planID, command: "rename",
                                args: ["ELEC6008", "Power Conversion"],
                                organizedDir: workspace.settings.organizedDir)

    let member = try #require(try workspace.rows(
        "SELECT topic_key,group_name,destination FROM plan_members WHERE plan_id=? LIMIT 1", [planID]
    ).first)
    let topic = try #require(try workspace.rows(
        "SELECT topic_key,display_name,source FROM topics WHERE topic_key=?", [before]
    ).first)
    #expect(member["topic_key"].string == before)
    #expect(member["group_name"].string == "Power Conversion")
    #expect(member["destination"].isNull)
    #expect(topic["topic_key"].string == before)
    #expect(topic["display_name"].string == "Power Conversion")
    #expect(topic["source"].string == "manual")

    let result = try workspace.cluster()
    #expect(result.groups.first?.topicKey == before)
    #expect(result.groups.first?.displayName == "Power Conversion")
}

@Test func planKeepsCustomDestinationAfterSettingChanges() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let custom = PyPath.join(workspace.root, "Sorted Files")
    let original = workspace.settings.with(organizedRoot: custom)
    workspace.settings = original
    try workspace.put("ELEC6008 Chapter 1.md", "one")
    try workspace.put("ELEC6008 Chapter 2.md", "two")
    _ = try workspace.scan()
    let planID = try workspace.proposePlan()

    let changed = workspace.settings.with(organizedRoot: PyPath.join(workspace.root, "Somewhere Else"))
    let preview = try Operations.previewMoves(workspace.db, changed, planID)
    // Destinations are canonicalised (realpath), so compare resolved paths.
    #expect(preview.allSatisfy { Paths.resolve($0.destination).path.hasPrefix(Paths.resolve(custom).path) })

    let (batchID, results) = try Operations.applyPlan(workspace.db, changed, planID)
    #expect(results.allSatisfy { $0.status == "moved" })
    #expect(FileManager.default.fileExists(
        atPath: PyPath.join(custom, "ELEC6008", "ELEC6008 Chapter 1.md").path
    ))

    let (_, undone) = try Operations.undoBatch(workspace.db, changed, batchID)
    #expect(undone.allSatisfy { $0.status == "undone" })
    _ = original
}

@Test(arguments: ["apply", "auto_apply"])
func recoveryRestoresTopicAssociationAfterCrashImmediatelyAfterRename(operationKind: String) throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let moves = try Operations.previewMoves(workspace.db, workspace.settings, planID)

    // Simulate a crash between `rename(2)` and the SQLite writes that follow it.
    let member = try #require(try workspace.rows(
        "SELECT id,file_id,topic_key,source_fingerprint FROM plan_members WHERE plan_id=? AND excluded=0 ORDER BY id LIMIT 1",
        [planID]
    ).first)
    let move = try #require(moves.first { $0.memberID == member["id"].int })
    let batchID = try insertRunningBatch(workspace, planID: planID, kind: operationKind)
    try workspace.db.connection.run(
        """
        INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
        VALUES(?,?,?,?,?,'intent',1)
        """,
        [batchID, move.fileID, move.source.path, move.destination.path, move.fingerprint]
    )
    let logID = workspace.db.connection.lastInsertRowID
    try FileManager.default.createDirectory(at: move.destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: move.source, to: move.destination)

    let batch = try #require(try workspace.rows(
        "SELECT id,status,kind FROM operation_batches ORDER BY id DESC LIMIT 1"
    ).first)
    #expect(batch["status"].string == "running")
    #expect(batch["kind"].string == operationKind)
    #expect(try workspace.scalar("SELECT COUNT(*) FROM associations")?.int == 0)

    #expect(try workspace.db.recoverInterrupted() == 1)

    let recovered = try #require(try workspace.rows(
        "SELECT path,status FROM files WHERE id=?", [move.fileID]
    ).first)
    let association = try #require(try workspace.rows(
        "SELECT topic_key,active FROM associations WHERE file_fingerprint=?", [move.fingerprint]
    ).first)
    #expect(recovered["path"].string == move.destination.path)
    #expect(recovered["status"].string == "organized")
    #expect(association["topic_key"].string == member["topic_key"].string)
    #expect(association["active"].int == 1)
    _ = logID
}

private func insertRunningBatch(_ workspace: Workspace, planID: Int, kind: String) throws -> Int {
    try workspace.db.connection.run(
        "INSERT INTO operation_batches(plan_id,kind,status,created_at) VALUES(?,?,'running',1)",
        [planID, kind]
    )
    return workspace.db.connection.lastInsertRowID
}

@Test func splitAndMergeKeepMembersInThePlan() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let member = try #require(try workspace.rows(
        "SELECT id FROM plan_members WHERE plan_id=? ORDER BY id LIMIT 1", [planID]
    ).first)["id"].int

    let message = try Operations.editPlan(workspace.db, planID, command: "split",
                                          args: [String(member), "Split Topic"],
                                          organizedDir: workspace.settings.organizedDir)
    #expect(message.contains("拆分"))
    #expect(try workspace.scalar(
        "SELECT COUNT(*) FROM plan_members WHERE plan_id=? AND group_name='Split Topic'", [planID]
    )?.int == 1)

    _ = try Operations.editPlan(workspace.db, planID, command: "merge",
                                args: ["Split Topic", "ELEC6008"],
                                organizedDir: workspace.settings.organizedDir)
    #expect(try workspace.scalar(
        "SELECT COUNT(*) FROM plan_members WHERE plan_id=? AND group_name='ELEC6008'", [planID]
    )?.int == 2)
    #expect(try workspace.scalar(
        "SELECT COUNT(*) FROM plan_members WHERE plan_id=? AND group_name='Split Topic'", [planID]
    )?.int == 0)
}

@Test func folderCommandMovesOneTopicIntoAnExistingFolder() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlan(workspace)
    let folder = PyPath.join(workspace.settings.organizedDir, "Courses")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    _ = try Operations.editPlan(workspace.db, planID, command: "folder",
                                args: ["ELEC6008", folder.path],
                                organizedDir: workspace.settings.organizedDir)

    // Destinations are canonicalised (realpath), so compare resolved paths.
    let moves = try Operations.previewMoves(workspace.db, workspace.settings, planID)
    let expected = Paths.resolve(folder).path
    #expect(moves.allSatisfy { Paths.resolve($0.destination.deletingLastPathComponent()).path == expected })

    #expect(throws: (any Error).self) {
        _ = try Operations.editPlan(workspace.db, planID, command: "folder",
                                    args: ["ELEC6008", PyPath.join(workspace.root, "Outside").path],
                                    organizedDir: workspace.settings.organizedDir)
    }
}

@Test func safeTopicNameRejectsInvalidAndStripsComponents() throws {
    #expect(try Operations.safeTopicName("Power Conversion") == "Power Conversion")
    #expect(try Operations.safeTopicName("a/b:c") == "a-b-c")
    #expect(try Operations.safeTopicName("...hidden...") == "hidden")
    #expect(throws: (any Error).self) { _ = try Operations.safeTopicName("   ") }
    #expect(throws: (any Error).self) { _ = try Operations.safeTopicName("..") }
}

@Test func uniqueDestinationUsesPythonStyleStemAndSuffix() {
    #expect(Operations.pythonStem("archive.tar.gz") == "archive.tar")
    #expect(Operations.pythonSuffix("archive.tar.gz") == ".gz")
    #expect(Operations.pythonSuffix("README") == "")
    #expect(Operations.pythonSuffix("file.") == "")
    #expect(Operations.pythonSuffix(".bashrc") == "")
    #expect(Operations.pythonSuffix("..") == "")
}
