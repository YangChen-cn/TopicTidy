import Foundation

struct Evidence: Decodable, Identifiable, Sendable {
    var kind: String
    var strength: String
    var detail: String
    var id: String { kind }
}
struct Member: Decodable, Identifiable, Sendable {
    var id: Int
    var name: String
    var path: String
    var topic: String?
    var topic_key: String?
    var confidence: Double
    var excluded: Bool
    var evidence: [Evidence]
    var conflicts: [String]
}
struct Batch: Decodable, Identifiable, Sendable {
    var id: Int
    var kind: String
    var status: String
    var created_at: Double
}
struct Preferences: Decodable, Sendable {
    var destination: String
    var auto_confirm_enabled: Bool
    var auto_confirm_threshold: Double
}
struct Schedule: Decodable, Sendable {
    var state: String
    var time: String?
    var loaded: Bool
}
struct Snapshot: Decodable, Sendable {
    var plan_id: Int?
    var members: [Member]
    var history: [Batch]
    var preferences: Preferences
    var schedule: Schedule
    var downloads: String
}
struct Move: Codable, Identifiable, Sendable {
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
struct Response: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var snapshot: Snapshot?
    var message: String?
    var moves: [Move]?
}
