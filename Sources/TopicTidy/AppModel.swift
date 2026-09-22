import SwiftUI
import TopicTidyCore

@MainActor @Observable final class AppModel {
    var snapshot: Snapshot?
    var busy = false
    var message = "本机分析 · 确认后移动"
    var error: String?
    var moves: [Move] = []
    private let service = CoreService()

    @discardableResult
    func perform(_ action: String, values: [String: Any] = [:]) async -> Bool {
        guard !busy else { return false }
        error = nil
        busy = true
        defer { busy = false }
        var request = ServiceRequest()
        apply(values, to: &request)
        request.action = action
        if request.planID == nil, let plan = snapshot?.plan_id { request.planID = plan }
        let response = await service.dispatch(request)
        guard response.ok else {
            error = response.error ?? "操作失败"
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

    func edit(_ command: String, _ args: [String]) async {
        await perform("edit", values: ["command": command, "args": args])
    }

    func preview(topicKey: String) async -> [Move]? {
        guard await perform("preview", values: ["topic_key": topicKey]) else { return nil }
        return moves
    }
}
