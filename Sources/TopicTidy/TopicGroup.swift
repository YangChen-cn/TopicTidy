import Foundation

struct TopicGroup: Identifiable {
    let id: String
    let name: String
    let members: [Member]
    var isUnclassified: Bool { id == "unclassified" }
    var isApplied: Bool { !isUnclassified && members.allSatisfy(\.applied) }
    var isDismissed: Bool { !isApplied && !isUnclassified && members.allSatisfy(\.excluded) }
    var isPending: Bool { !isUnclassified && members.contains { !$0.applied && !$0.excluded } }
    var pendingCount: Int { members.count { !$0.applied && !$0.excluded } }
    var confidence: Double { members.map(\.confidence).min() ?? 0 }
    var evidence: [Evidence] { members.first?.evidence ?? [] }

    static func make(_ members: [Member]) -> [TopicGroup] {
        Dictionary(grouping: members, by: { $0.topic_key ?? "unclassified" })
            .map { key, files in TopicGroup(id: key, name: files.first?.topic ?? "未分类", members: files) }
            .sorted {
                if $0.isUnclassified != $1.isUnclassified { return !$0.isUnclassified }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
