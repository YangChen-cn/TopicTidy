import SwiftUI

struct TopicGroupView: View {
    let group: TopicGroup
    @Bindable var model: AppModel
    let onPreview: (TopicGroup) -> Void
    @State private var expanded = false
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: group.isApplied ? "checkmark.circle.fill" : group.isUnclassified ? "tray" : "folder.fill")
                        .foregroundStyle(group.isUnclassified ? Color.secondary : Color.accentColor)
                        .font(.system(size: 16)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(statusText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }.padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("展开文件与匹配依据；评分为启发式，不是准确率")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach(group.members) { MemberRow(member: $0, model: model) }
                    if !group.isUnclassified {
                        DisclosureGroup("匹配依据", isExpanded: $showEvidence) {
                            EvidenceList(evidence: group.evidence)
                        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    if !group.isUnclassified && group.isPending {
                        HStack {
                            Button("取消此主题", role: .destructive) {
                                Task { await model.edit("dismiss-topic", [group.id]) }
                            }
                            Spacer()
                            Button("确认此主题…") { onPreview(group) }
                                .buttonStyle(.borderedProminent)
                        }.padding(.vertical, 8)
                    }
                }.padding(.horizontal, 10)
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusText: String {
        if group.isUnclassified { return "\(group.members.count) 个文件 · 保留原位" }
        if group.isApplied { return "已整理 · \(group.members.count) 个文件" }
        if group.members.contains(where: \.reviewRequired) {
            return "\(group.pendingCount) 个文件 · 需确认 · 评分 \(Int(group.confidence * 100))"
        }
        return "\(group.pendingCount) 个文件 · 评分 \(Int(group.confidence * 100))"
    }
}
