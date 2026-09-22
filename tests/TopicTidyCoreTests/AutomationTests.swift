import Foundation
import Testing

@testable import TopicTidyCore

/// Ported from tests/test_automation.py and tests/test_preferences.py.
private func coursePlanForAutoTest(_ workspace: Workspace) throws -> Int {
    try workspace.put("ELEC6008 Lecture 1.md", "one")
    try workspace.put("ELEC6008 Lecture 2.md", "two")
    _ = try workspace.scan()
    return try workspace.proposePlan()
}

@Test func dailyRunAutoConfirmsOnlyHighConfidenceGroups() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    workspace.settings = workspace.settings.with(autoConfirmEnabled: true, autoConfirmThreshold: 0.92)
    try workspace.put("ELEC6008 Lecture 1.md", "power electronics")
    try workspace.put("ELEC6008 Lecture 2.md", "power conversion")
    try workspace.put("random.json", "{}")

    let result = try DailyAutomationService(workspace.db, workspace.settings).run(useSemantic: false)

    #expect(result.planID != nil)
    #expect(result.batchID != nil)
    #expect(result.eligibleTopics == ["ELEC6008"])
    #expect(result.moved == 2)
    #expect(FileManager.default.fileExists(atPath: PyPath.join(
        workspace.settings.organizedDir, "ELEC6008", "ELEC6008 Lecture 1.md").path))
    #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, "random.json").path))
    let batch = try #require(try workspace.rows(
        "SELECT kind FROM operation_batches WHERE id=?", [result.batchID ?? 0]
    ).first)
    #expect(batch["kind"].string == "auto_apply")
}

@Test func dailyRunWithoutAutoConfirmOnlyScans() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "one")
    try workspace.put("ELEC6008 Lecture 2.md", "two")

    let result = try DailyAutomationService(workspace.db, workspace.settings).run(useSemantic: false)

    #expect(result.autoConfirmEnabled == false)
    #expect(result.planID == nil)
    #expect(try workspace.scalar("SELECT COUNT(*) FROM plans")?.int == 0)
    #expect(try workspace.scalar("SELECT COUNT(*) FROM operation_batches")?.int == 0)
}

@Test func autoConfirmThresholdCanLeaveGroupForManualReview() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    workspace.settings = workspace.settings.with(autoConfirmEnabled: true, autoConfirmThreshold: 0.99)
    try workspace.put("ELEC6008 Lecture 1.md", "one")
    try workspace.put("ELEC6008 Lecture 2.md", "two")

    let result = try DailyAutomationService(workspace.db, workspace.settings).run(useSemantic: false)

    #expect(result.planID != nil)
    #expect(result.batchID == nil)
    #expect(result.moved == 0)
    #expect(FileManager.default.fileExists(atPath: PyPath.join(
        workspace.downloads, "ELEC6008 Lecture 1.md").path))
    let plan = try #require(try workspace.rows(
        "SELECT status FROM plans WHERE id=?", [result.planID ?? 0]
    ).first)
    #expect(plan["status"].string == "no_auto_matches")
}

@Test func autoConfirmNeverAppliesGroupWithConflict() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "one")
    try workspace.put("ELEC6008 Lecture 2.md", "two")
    _ = try workspace.scan()
    let planID = try workspace.proposePlan()
    try workspace.db.connection.run(
        "UPDATE plan_members SET conflicts='[\"人工注入的冲突\"]' WHERE plan_id=?", [planID]
    )

    let result = try Workflow.autoConfirmPlan(workspace.db, workspace.settings, planID, threshold: 0.90)

    #expect(result.batchID == nil)
    #expect(result.eligibleTopics.isEmpty)
    #expect(FileManager.default.fileExists(atPath: PyPath.join(
        workspace.downloads, "ELEC6008 Lecture 1.md").path))
}

@Test func autoConfirmRejectsTopicWithAnyPreexcludedMember() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let planID = try coursePlanForAutoTest(workspace)
    let member = try #require(try workspace.rows(
        "SELECT id FROM plan_members WHERE plan_id=? ORDER BY id LIMIT 1", [planID]
    ).first)["id"].int
    try workspace.db.connection.run("UPDATE plan_members SET excluded=1 WHERE id=?", [member])

    let result = try Workflow.autoConfirmPlan(workspace.db, workspace.settings, planID, threshold: 0.90)

    #expect(result.batchID == nil)
    #expect(result.eligibleTopics.isEmpty)
    for name in ["ELEC6008 Lecture 1.md", "ELEC6008 Lecture 2.md"] {
        #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, name).path))
    }
}

@Test func documentLinksAloneNeverAutoConfirm() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("README.md", "# Mixed downloads\n"
        + "[Taxes](taxes.md)\n[Holiday](holiday.md)\n[Cooking](cooking.md)\n")
    try workspace.put("taxes.md", "annual tax receipt")
    try workspace.put("holiday.md", "hotel itinerary")
    try workspace.put("cooking.md", "bread recipe")
    _ = try workspace.scan()
    let result = try workspace.cluster()
    #expect(result.groups.count == 1)
    #expect(result.unclassified.isEmpty)
    let group = try #require(result.groups.first)
    #expect(group.evidence.contains { $0.kind == "document_links" })
    #expect(!group.evidence.contains {
        autoConfirmSupportKinds.contains($0.kind) && $0.strength == "strong"
    })

    let planID = try ClusterEngine.savePlan(workspace.db, workspace.settings,
                                            groups: result.groups, unclassified: result.unclassified)
    try workspace.db.connection.run("UPDATE plan_members SET confidence=0.99 WHERE plan_id=?", [planID])

    let confirmed = try Workflow.autoConfirmPlan(workspace.db, workspace.settings, planID, threshold: 0.92)

    #expect(confirmed.batchID == nil)
    #expect(confirmed.eligibleTopics.isEmpty)
    for name in ["README.md", "taxes.md", "holiday.md", "cooking.md"] {
        #expect(FileManager.default.fileExists(atPath: PyPath.join(workspace.downloads, name).path))
    }
}

@Test func documentLinksWithIndependentSeriesIdentifierCanAutoConfirm() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("README.md", "# Atlas42 Project Index\n[Design](Atlas42-design.md)\n"
        + "[Tests](Atlas42-tests.md)\n[Release](Atlas42-release.md)\n")
    try workspace.put("Atlas42-design.md", "# Atlas42 Design\nmechanical enclosure")
    try workspace.put("Atlas42-tests.md", "# Atlas42 Tests\nvalidation protocol")
    try workspace.put("Atlas42-release.md", "# Atlas42 Release\nshipping checklist")
    _ = try workspace.scan()
    let result = try workspace.cluster()
    #expect(result.groups.count == 1)
    #expect(result.unclassified.isEmpty)
    let group = try #require(result.groups.first)
    #expect(group.confidence >= 0.92)
    #expect(group.evidence.contains { $0.kind == "series_identifier" && $0.strength == "strong" })

    let planID = try ClusterEngine.savePlan(workspace.db, workspace.settings,
                                            groups: result.groups, unclassified: result.unclassified)
    let confirmed = try Workflow.autoConfirmPlan(workspace.db, workspace.settings, planID, threshold: 0.92)

    #expect(confirmed.moved == 4)
    #expect(confirmed.batchID != nil)
}

@Test func preferencesPersistDestinationAndAutoConfirm() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let destination = PyPath.join(workspace.root, "Course Archive")
    let store = PreferenceStore(workspace.db, base: workspace.settings)

    try store.setDestination(destination)
    try store.setAutoConfirm(true, threshold: 0.94)
    let resolved = store.resolvedSettings()

    #expect(resolved.organizedDir.path == Paths.resolve(destination).path)
    #expect(resolved.autoConfirmEnabled)
    #expect(abs(resolved.autoConfirmThreshold - 0.94) < 0.0001)
}

@Test func preferencesRejectDownloadsAsDestinationAndLowThreshold() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let store = PreferenceStore(workspace.db, base: workspace.settings)

    #expect(throws: (any Error).self) { _ = try store.setDestination(workspace.settings.downloads) }
    #expect(throws: (any Error).self) { _ = try store.setAutoConfirm(true, threshold: 0.5) }
}

@Test func preferencesRejectFileAsDestination() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let destination = PyPath.join(workspace.root, "not-a-directory")
    try "occupied".write(to: destination, atomically: true, encoding: .utf8)

    #expect(throws: (any Error).self) {
        _ = try PreferenceStore(workspace.db, base: workspace.settings).setDestination(destination)
    }
}

@Test func launchAgentTimeParserRejectsInvalidValues() throws {
    #expect(try LaunchAgentScheduler.parseDailyTime("09:00") == (9, 0))
    #expect(try LaunchAgentScheduler.parseDailyTime("23:59") == (23, 59))
    #expect(throws: (any Error).self) { _ = try LaunchAgentScheduler.parseDailyTime("24:00") }
    #expect(throws: (any Error).self) { _ = try LaunchAgentScheduler.parseDailyTime("9am") }
}

@Test func launchAgentPlistRoundTripsStatusAndCommand() throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let plistPath = PyPath.join(workspace.root, "com.topictidy.daily.plist")
    let scheduler = LaunchAgentScheduler(workspace.settings, plistPath: plistPath)

    #expect(scheduler.status().state == "not_configured")
    // The daily task must invoke the native binary, never the removed runtime.
    #expect(scheduler.command.count == 3)
    #expect(scheduler.command.dropFirst() == ["auto", "run"])
    #expect(!scheduler.command[0].contains("python"))
    #expect(scheduler.command[0].hasPrefix("/"))
}
