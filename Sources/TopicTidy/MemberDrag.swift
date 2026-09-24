import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let topicTidyMembers = UTType(exportedAs: "cn.yangchen.topictidy.plan-members")
}

/// Drag data is only a request to edit the active plan, never a file move.
struct MemberDrag: Codable, Transferable {
    let planID: Int
    let memberIDs: [Int]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .topicTidyMembers)
    }
}
