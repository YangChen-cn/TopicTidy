import SwiftUI

@MainActor @Observable final class AppModel {
    var snapshot: Snapshot?
    var busy = false
    var message = "本机分析 · 确认后移动"
    var error: String?
    var moves: [Move] = []
    private let backend = Backend()

    func perform(_ action: String, values: [String: Any] = [:]) async {
        guard !busy else { return }
        error = nil
        busy = true
        defer { busy = false }
        do {
            var request = values
            request["action"] = action
            if request["plan_id"] == nil, let plan = snapshot?.plan_id { request["plan_id"] = plan }
            let data = try JSONSerialization.data(withJSONObject: request)
            let response = try await backend.request(data)
            guard response.ok else { error = response.error ?? "操作失败"; return }
            snapshot = response.snapshot
            if let text = response.message { message = text }
            if action == "preview" {
                moves = response.moves ?? []
            }
        } catch { self.error = error.localizedDescription }
    }

    func apply(_ moves: [Move]) async {
        do {
            let encoded = try JSONEncoder().encode(moves)
            let list = try JSONSerialization.jsonObject(with: encoded)
            await perform("apply", values: ["confirmed": true, "moves": list])
        } catch { self.error = error.localizedDescription }
    }

    func edit(_ command: String, _ args: [String]) async {
        await perform("edit", values: ["command": command, "args": args])
    }
}
