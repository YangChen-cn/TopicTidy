import SwiftUI

struct TopicGroupView: View {
    let group: TopicGroup
    @Bindable var model: AppModel
    let onPreview: (TopicGroup) -> Void
    @State private var expanded = false
    @State private var showEvidence = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded },
            set: { value in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded = value }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.members) { MemberRow(member: $0, model: model) }
                if !group.isUnclassified {
                    DisclosureGroup("匹配依据", isExpanded: $showEvidence) {
                        EvidenceList(evidence: group.evidence)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                }
                if !group.isUnclassified && group.isPending {
                    HStack {
                        Button("取消此主题", role: .destructive) {
                            Task { await model.edit("dismiss-topic", [group.id]) }
                        }
                        Spacer()
                        Button("确认此主题…") { onPreview(group) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.leading, 22)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: group.isApplied ? "checkmark.circle.fill" : group.isUnclassified ? "tray" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .help("展开文件与匹配依据；评分为启发式")
        .padding(.vertical, 6)
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
