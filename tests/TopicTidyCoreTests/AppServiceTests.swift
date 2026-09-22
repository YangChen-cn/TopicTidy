import Foundation
import Testing

@testable import TopicTidyCore

/// Ported from tests/test_gui_bridge.py: the request/response contract the
/// SwiftUI client relies on.
private func makeService(_ workspace: Workspace) -> AppService {
    AppService(base: workspace.settings)
}

private func request(_ action: String, _ configure: (inout ServiceRequest) -> Void = { _ in }) -> ServiceRequest {
    var value = ServiceRequest()
    value.action = action
    configure(&value)
    return value
}

@Test func servicePreviewConfirmationApplyAndUndo() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "Chapter 1")
    try workspace.put("ELEC6008 Lecture 2.md", "Chapter 2")
    let service = makeService(workspace)

    // A superseded draft must not reappear after apply.
    _ = await service.dispatch(request("scan") { $0.semantic = false })
    let proposal = await service.dispatch(request("scan") { $0.semantic = false })
    let plan = try #require(proposal.snapshot?.planID)
    #expect(proposal.snapshot?.members.count == 2)

    let refused = await service.dispatch(request("apply") { $0.planID = plan; $0.confirmed = false })
    #expect(refused.ok == false)
    #expect(refused.error?.contains("确认") == true)

    let preview = await service.dispatch(request("preview") { $0.planID = plan })
    let moves = preview.moves
    #expect(moves.count == 2)

    let empty = await service.dispatch(request("apply") {
        $0.planID = plan; $0.confirmed = true; $0.moves = []
    })
    #expect(empty.ok == false)
    #expect(empty.error?.contains("清单已变化") == true)

    let applied = await service.dispatch(request("apply") {
        $0.planID = plan; $0.confirmed = true; $0.moves = moves
    })
    #expect(applied.ok)
    #expect(applied.snapshot?.planID == nil)
    let batch = try #require(applied.snapshot?.history.first?.id)
    for move in moves {
        #expect(FileManager.default.fileExists(atPath: move.destination))
    }

    let undone = await service.dispatch(request("undo") { $0.batchID = batch; $0.confirmed = true })
    #expect(undone.ok)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: workspace.downloads.path)
        .filter { $0.hasSuffix(".md") }
    #expect(remaining.count == 2)
}

@Test func serviceEditAndPreferences() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "Chapter 1")
    try workspace.put("ELEC6008 Lecture 2.md", "Chapter 2")
    let service = makeService(workspace)

    let proposal = await service.dispatch(request("scan") { $0.semantic = false })
    let plan = try #require(proposal.snapshot?.planID)
    let original = try #require(proposal.snapshot?.members.first?.topicKey)

    let edited = await service.dispatch(request("edit") {
        $0.planID = plan; $0.command = "rename"; $0.args = ["ELEC6008", "My Course"]
    })
    #expect(edited.ok)
    #expect(edited.snapshot?.members.first?.topic == "My Course")
    #expect(edited.snapshot?.members.first?.topicKey == original)

    let settingsChanged = await service.dispatch(request("preferences") {
        $0.enabled = false; $0.threshold = 0.95
    })
    #expect(settingsChanged.ok)
    #expect(settingsChanged.snapshot?.preferences.autoConfirmThreshold == 0.95)
}

@Test func servicePreviewsAppliesAndDismissesTopicsIndependently() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    for index in 1...2 {
        try workspace.put("ELEC6008 Lecture \(index).md", "Chapter \(index)")
        try workspace.put("ELEC6103 Lecture \(index).md", "Other \(index)")
    }
    let service = makeService(workspace)

    let proposal = await service.dispatch(request("scan") { $0.semantic = false })
    let plan = try #require(proposal.snapshot?.planID)
    let members = try #require(proposal.snapshot?.members)
    var grouped: [String: [SessionMember]] = [:]
    for member in members { grouped[member.topicKey ?? "", default: []].append(member) }
    #expect(grouped.count == 2)
    let topics = grouped.keys.sorted()
    let first = topics[0]
    let second = topics[1]

    let preview = await service.dispatch(request("preview") { $0.planID = plan; $0.topicKey = first })
    #expect(Set(preview.moves.map(\.topicKey)) == [first])

    let partial = await service.dispatch(request("apply") {
        $0.planID = plan; $0.confirmed = true; $0.moves = Array(preview.moves.dropLast())
    })
    #expect(partial.ok == false)
    #expect(partial.error?.contains("完整主题") == true)

    let applied = await service.dispatch(request("apply") {
        $0.planID = plan; $0.confirmed = true; $0.moves = preview.moves
    })
    #expect(applied.ok)
    #expect(applied.snapshot?.planID == plan)
    #expect(applied.snapshot?.members.filter { $0.topicKey == first }.allSatisfy(\.applied) == true)

    let dismissed = await service.dispatch(request("edit") {
        $0.planID = plan; $0.command = "dismiss-topic"; $0.args = [second]
    })
    #expect(dismissed.ok)
    #expect(dismissed.snapshot?.members.filter { $0.topicKey == second }.allSatisfy(\.excluded) == true)

    let restored = await service.dispatch(request("edit") {
        $0.planID = plan; $0.command = "restore-topic"; $0.args = [second]
    })
    #expect(restored.ok)
    #expect(restored.snapshot?.members.filter { $0.topicKey == second }.allSatisfy { !$0.excluded } == true)
}

@Test func serviceRejectsActingOnAFinishedPlan() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    try workspace.put("ELEC6008 Lecture 1.md", "Chapter 1")
    try workspace.put("ELEC6008 Lecture 2.md", "Chapter 2")
    let service = makeService(workspace)

    let proposal = await service.dispatch(request("scan") { $0.semantic = false })
    let plan = try #require(proposal.snapshot?.planID)
    let preview = await service.dispatch(request("preview") { $0.planID = plan })
    _ = await service.dispatch(request("apply") {
        $0.planID = plan; $0.confirmed = true; $0.moves = preview.moves
    })

    let stale = await service.dispatch(request("preview") { $0.planID = plan })
    #expect(stale.ok == false)
    #expect(stale.error?.contains("方案已执行或不存在") == true)
}

@Test func serviceReportsUnknownAction() async throws {
    let workspace = try Workspace()
    defer { workspace.close() }
    let service = makeService(workspace)

    let response = await service.dispatch(request("nonsense"))
    #expect(response.ok == false)
    #expect(response.error?.contains("未知操作") == true)
}
