import SwiftUI
import TopicTidyCore

@MainActor @Observable final class AppModel {
    var snapshot: Snapshot?
    var busy = false
    var progress: ServiceProgress?
    var message = "本机分析 · 确认后移动"
    var error: String?
    var incompatibleDatabase = false
    var moves: [Move] = []
    private var activeOperationID: UUID?
    private let service = CoreService()

    @discardableResult
    func perform(_ action: String, values: [String: Any] = [:]) async -> Bool {
        guard !busy else { return false }
        error = nil
        incompatibleDatabase = false
        busy = true
        progress = nil
        let operationID = UUID()
        activeOperationID = operationID
        defer { busy = false; progress = nil; activeOperationID = nil }
        var request = ServiceRequest()
        apply(values, to: &request)
        request.action = action
        if request.planID == nil, let plan = snapshot?.plan_id { request.planID = plan }
        let response = await service.dispatch(request) { stage in
            Task { @MainActor in
                guard self.activeOperationID == operationID else { return }
                if let current = self.progress, stage.order < current.order { return }
                self.progress = stage
            }
        }
        guard response.ok else {
            error = response.error ?? "操作失败"
            incompatibleDatabase = response.incompatibleDatabase
            return false
        }
        snapshot = response.snapshot.map(Snapshot.init)
        if let text = response.message { message = text }
        if action == "preview" { moves = response.moves.map(Move.init) }
        return true
    }

    /// Keeps the call sites that previously built a JSON payload working.
    private func apply(_ values: [String: Any], to request: inout ServiceRequest) {
        if let plan = values["plan_id"] as? Int { request.planID = plan }
        if let topicKey = values["topic_key"] as? String { request.topicKey = topicKey }
        if let command = values["command"] as? String { request.command = command }
        if let args = values["args"] as? [String] { request.args = args }
        if let confirmed = values["confirmed"] as? Bool { request.confirmed = confirmed }
        if let destination = values["destination"] as? String { request.destination = destination }
        if let scanRoots = values["scan_roots"] as? [String] { request.scanRoots = scanRoots }
        if let enabled = values["enabled"] as? Bool { request.enabled = enabled }
        if let threshold = values["threshold"] as? Double { request.threshold = threshold }
        if let at = values["at"] as? String { request.at = at }
        if let batch = values["batch_id"] as? Int { request.batchID = batch }
        if let semantic = values["semantic"] as? Bool { request.semantic = semantic }
        if let list = values["moves"] as? [Move] { request.moves = list.map(\.asSessionMove) }
    }

    func apply(_ moves: [Move]) async {
        await perform("apply", values: ["confirmed": true, "moves": moves])
    }

    @discardableResult
    func edit(_ command: String, _ args: [String]) async -> Bool {
        await perform("edit", values: ["command": command, "args": args])
    }

    /// Re-opens a topic that was dismissed in this or an earlier plan.
    func restoreDismissed(_ name: String) async {
        await edit("restore-dismissed", [name])
    }

    func preview(topicKey: String) async -> [Move]? {
        guard await perform("preview", values: ["topic_key": topicKey]) else { return nil }
        return moves
    }

    /// Plan edits never touch files. AppService applies the whole selection in
    /// one database transaction, so a failed member does not leave a partial edit.
    func moveMembers(_ ids: [Int], to topicKey: String) async {
        let selected = Set(ids).sorted()
        guard !selected.isEmpty else { return }
        await edit("move-members-to-topic-key", [topicKey] + selected.map(String.init))
    }

    func excludeMembers(_ ids: [Int]) async {
        let selected = Set(ids).sorted()
        guard !selected.isEmpty else { return }
        await edit("exclude-members", selected.map(String.init))
    }
}

private extension ServiceProgress {
    var order: Int {
        switch self {
        case .scanningFiles: 0
        case .extractingContent: 1
        case .semanticAnalysis: 2
        case .generatingSuggestions: 3
        }
    }
}
