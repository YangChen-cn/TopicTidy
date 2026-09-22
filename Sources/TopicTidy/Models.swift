import Foundation

/// Presentation models. Field names stay in the `snake_case` shape the views
/// already use; they are built directly from `TopicTidyCore` values now that the
/// JSON bridge is gone.
struct Evidence: Identifiable, Sendable {
    var kind: String
    var strength: String
    var detail: String
    var id: String { kind }
}

struct Member: Identifiable, Sendable {
    var id: Int
    var name: String
    var path: String
    var topic: String?
    var topic_key: String?
    var confidence: Double
    var excluded: Bool
    var applied: Bool
    var evidence: [Evidence]
    var conflicts: [String]
}

struct Batch: Identifiable, Sendable {
    var id: Int
    var kind: String
    var status: String
    var created_at: Double
}

struct Preferences: Sendable {
    var destination: String
    var auto_confirm_enabled: Bool
    var auto_confirm_threshold: Double
}

struct Schedule: Sendable {
    var state: String
    var time: String?
    var loaded: Bool
}

struct Snapshot: Sendable {
    var plan_id: Int?
    var members: [Member]
    var history: [Batch]
    var preferences: Preferences
    var schedule: Schedule
    var downloads: String
}

struct Move: Identifiable, Equatable, Sendable {
    var member_id: Int
    var file_id: Int
    var source: String
    var destination: String
    var fingerprint: String
    var stale: Bool
    var topic: String
    var topic_key: String
    var id: Int { member_id }
}
