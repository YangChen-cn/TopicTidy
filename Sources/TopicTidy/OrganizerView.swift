import SwiftUI

struct OrganizerView: View {
    @Bindable var model: AppModel
    @State private var selection: String? = "all"
    @State private var search = ""
    @State private var showPreview = false
    @State private var previewMoves: [Move] = []
    private var groups: [TopicGroup] { TopicGroup.make(model.snapshot?.members ?? []) }
    /// Members of dismissed topics leave the window along with their topic.
    private var visibleMembers: [Member] {
        let visible = Set(groups.map(\.id))
        return (model.snapshot?.members ?? []).filter { visible.contains($0.topic_key ?? "unclassified") }
    }
    private var members: [Member] {
        visibleMembers.filter {
            (selection == "all" || ($0.topic_key ?? "unclassified") == selection)
            && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }
    private var title: String {
        if selection == "history" { return "整理记录" }
        if selection == "all" { return "整理建议" }
        return groups.first { $0.id == selection }?.name ?? "整理建议"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("全部建议", systemImage: "tray.2").tag("all")
                    Label("整理记录", systemImage: "clock.arrow.circlepath").tag("history")
                }
                Section("主题") {
                    ForEach(groups) { group in
                        HStack {
                            Label(group.name, systemImage: group.isUnclassified ? "tray" : "folder")
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.members.count)").font(.caption).foregroundStyle(.secondary)
                        }.tag(group.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
            .safeAreaInset(edge: .bottom) {
                Label("本机分析", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.title2).fontWeight(.semibold)
                        Text(selection == "history" ? "查看与撤销每次整理" : "\(members.count) 个文件 · 确认后移动")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(18)
                Divider()
                if selection == "history" {
                    HistoryView(model: model)
                } else if model.snapshot?.plan_id == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                        Text("从下载文件中发现主题").font(.headline)
                        Text("扫描后查看建议，确认前文件保留原位。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("扫描下载文件") { Task { await model.perform("scan") } }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if selection == "all" {
                                ForEach(TopicGroup.make(members)) { group in
                                    TopicGroupView(group: group, model: model) { preview($0) }
                                }
                            } else {
                                if let group = groups.first(where: { $0.id == selection }), !group.isUnclassified {
                                    DisclosureGroup("匹配依据 · 评分 \(Int(group.confidence * 100))") {
                                        EvidenceList(evidence: group.evidence)
                                    }.font(.caption).padding(.bottom, 8)
                                }
                                ForEach(members) { MemberRow(member: $0, model: model) }
                            }
                        }.padding(16)
                    }
                    .searchable(text: $search, prompt: "查找文件")
                    .overlay {
                        if members.isEmpty {
                            Text("没有匹配的文件").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let group = groups.first(where: { $0.id == selection }), !group.isUnclassified {
                        Divider()
                        HStack {
                            if group.isApplied {
                                Label("这个主题已整理", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("取消这个主题", role: .destructive) {
                                    Task {
                                        await model.edit("dismiss-topic", [group.id])
                                        // The topic leaves the list, so fall back to "all".
                                        if !TopicGroup.make(model.snapshot?.members ?? []).contains(where: { $0.id == selection }) {
                                            selection = "all"
                                        }
                                    }
                                }
                                Spacer()
                                Button("确认这个主题…") { preview(group) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 11)
                    }
                }
                Divider()
                HStack {
                    Text(model.message).lineLimit(1).help(model.message)
                    Spacer()
                    if let plan = model.snapshot?.plan_id { Text("方案 #\(plan)") }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .toolbar {
            Button("扫描", systemImage: "arrow.clockwise") { Task { await model.perform("scan") } }
                .disabled(model.busy)
            Button("预览整理", systemImage: "folder.badge.plus") {
                Task {
                    if await model.perform("preview") {
                        previewMoves = model.moves
                        showPreview = true
                    }
                }
            }.disabled(model.busy || !(model.snapshot?.members.contains { $0.topic != nil && !$0.excluded } ?? false))
            SettingsLink { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showPreview) { MovePreview(model: model, moves: previewMoves) { showPreview = false }.frame(width: 450) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .frame(minWidth: 620, minHeight: 400)
    }

    private func preview(_ group: TopicGroup) {
        Task {
            if let moves = await model.preview(topicKey: group.id) {
                previewMoves = moves
                showPreview = true
            }
        }
    }
}
