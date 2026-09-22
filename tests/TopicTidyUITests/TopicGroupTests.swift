import Foundation
import Testing

@testable import TopicTidy

private func member(_ id: Int, topic: String?, topicKey: String?, excluded: Bool = false,
                    applied: Bool = false) -> Member {
    Member(
        id: id, name: "file-\(id).md", path: "/tmp/file-\(id).md", topic: topic, topic_key: topicKey,
        confidence: 0.9, excluded: excluded, applied: applied,
        evidence: [], conflicts: []
    )
}

@Test func dismissedTopicsLeaveTheList() {
    let members = [
        member(1, topic: "Attachments Json", topicKey: "cluster:a", excluded: true),
        member(2, topic: "Attachments Json", topicKey: "cluster:a", excluded: true),
        member(3, topic: "ELEC6008", topicKey: "course:ELEC6008"),
        member(4, topic: "ELEC6008", topicKey: "course:ELEC6008"),
    ]

    let groups = TopicGroup.make(members)

    #expect(groups.map(\.id) == ["course:ELEC6008"])
    #expect(groups.first?.members.count == 2)
}

@Test func unclassifiedGroupIsNeverTreatedAsDismissed() {
    let groups = TopicGroup.make([member(1, topic: nil, topicKey: nil)])

    #expect(groups.map(\.id) == ["unclassified"])
    #expect(groups.first?.isDismissed == false)
}

@Test func appliedTopicsStayVisible() {
    let groups = TopicGroup.make([
        member(1, topic: "ELEC6008", topicKey: "course:ELEC6008", applied: true),
        member(2, topic: "ELEC6008", topicKey: "course:ELEC6008", applied: true),
    ])

    #expect(groups.count == 1)
    #expect(groups.first?.isApplied == true)
}

@Test func partiallyExcludedTopicStaysVisible() {
    let groups = TopicGroup.make([
        member(1, topic: "ELEC6008", topicKey: "course:ELEC6008", excluded: true),
        member(2, topic: "ELEC6008", topicKey: "course:ELEC6008"),
    ])

    #expect(groups.count == 1)
    #expect(groups.first?.isPending == true)
    #expect(groups.first?.pendingCount == 1)
}

@Test func unclassifiedSortsLast() {
    let groups = TopicGroup.make([
        member(1, topic: nil, topicKey: nil),
        member(2, topic: "Beta", topicKey: "cluster:b"),
        member(3, topic: "Alpha", topicKey: "cluster:a"),
    ])

    #expect(groups.map(\.id) == ["cluster:a", "cluster:b", "unclassified"])
}
