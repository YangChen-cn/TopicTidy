import AppKit
import QuickLook
import SwiftUI

struct OrganizerView: View {
    @Bindable var model: AppModel
    @State private var selection: String? = "all"
    @State private var selectedMemberIDs: Set<Int> = []
    @State private var search = ""
    @State private var showPreview = false
    @State private var previewMoves: [Move] = []
    @State private var showDismissed = false
    @State private var showInspector = false
    @State private var showExcludeConfirmation = false
    @State private var quickLookURL: URL?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groups: [TopicGroup] { TopicGroup.make(model.snapshot?.members ?? []) }
    private var dismissed: [DismissedGroup] { model.snapshot?.dismissed ?? [] }
    private var selectedDismissed: DismissedGroup? { dismissed.first { $0.id == selection } }
    private var selectedGroup: TopicGroup? { groups.first { $0.id == selection && !$0.isUnclassified } }
    private var visibleMembers: [Member] {
        let visible = Set(groups.map(\.id))
        return (model.snapshot?.members ?? []).filter { visible.contains($0.topic_key ?? "unclassified") }
    }
    private var members: [Member] {
        visibleMembers.filter {
            (selection == "all" || ($0.topic_key ?? "unclassified") == selection)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.topic?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }
    private var selectedMembers: [Member] {
        visibleMembers.filter { selectedMemberIDs.contains($0.id) }
    }
    private var editableSelection: [Member] {
        selectedMembers.filter { !$0.applied && !$0.excluded }
    }
    private var canEditSelection: Bool {
        !selectedMembers.isEmpty && editableSelection.count == selectedMembers.count
    }
    private var quickLookURLs: [URL] {
        selectedMembers.map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private var title: String {
        if selection == "history" { return "整理记录" }
        if selection == "all" { return "整理建议" }
        if let group = selectedDismissed { return group.name }
        return groups.first { $0.id == selection }?.name ?? "整理建议"
    }
    private var subtitle: String {
        if selection == "history" { return "查看与撤销每次整理" }
        if let group = selectedDismissed { return "已取消 · \(group.files.count) 个文件 · 不再提出" }
        return "\(members.count) 个文件 · 确认后移动"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .inspector(isPresented: $showInspector) { inspector }
        }
        .searchable(text: $search, prompt: "查找文件或主题")
        .toolbar {
            ToolbarItemGroup {
                Button("扫描", systemImage: "arrow.clockwise") { Task { await model.perform("scan") } }
                    .disabled(model.busy)
                    .keyboardShortcut("r", modifiers: .command)
                Button("预览整理", systemImage: "folder.badge.plus", action: previewAll)
                    .disabled(model.busy || !(model.snapshot?.members.contains {
                        $0.topic != nil && !$0.excluded && !$0.applied
                    } ?? false))
            }
            ToolbarItemGroup {
                Button("快速查看", systemImage: "eye", action: showQuickLook)
                    .disabled(quickLookURLs.isEmpty)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("快速查看所选文件 · 空格")
                Menu {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            selectedMembers.map { URL(fileURLWithPath: $0.path) }
                        )
                    }
                    .disabled(selectedMembers.isEmpty)
                    Divider()
                    ForEach(groups.filter { !$0.isUnclassified && !$0.isApplied }) { group in
                        Button("移至 \(group.name)") {
                            moveSelection(to: group.id)
                        }
                        .disabled(!canEditSelection || editableSelection.allSatisfy { $0.topic_key == group.id })
                    }
                    Divider()
                    Button("排除所选文件…", role: .destructive) { showExcludeConfirmation = true }
                        .disabled(!canEditSelection)
                } label: { Label("所选文件操作", systemImage: "ellipsis.circle") }
                    .disabled(model.busy || selectedMembers.isEmpty)
                Button("匹配依据", systemImage: "sidebar.right") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showInspector.toggle() }
                }
                .disabled(selectedGroup == nil && selectedMembers.isEmpty)
                .help("显示匹配依据与文件信息")
            }
            ToolbarItemGroup {
                SettingsLink { Label("设置", systemImage: "gearshape") }
                Button("关于", systemImage: "info.circle") { openWindow(id: "about") }
            }
        }
        .sheet(isPresented: $showPreview) {
            MovePreview(model: model, moves: previewMoves) { showPreview = false }
                .frame(width: 480)
        }
        .quickLookPreview($quickLookURL, in: quickLookURLs)
        .confirmationDialog("排除所选文件？", isPresented: $showExcludeConfirmation) {
            Button("排除 \(editableSelection.count) 个文件", role: .destructive) {
                Task { await model.excludeMembers(editableSelection.map(\.id)); selectedMemberIDs.removeAll() }
            }
        } message: {
            Text("排除后这些文件不会进入本次整理。可以重新扫描生成新建议。")
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: selection) { _, _ in selectedMemberIDs.removeAll() }
        .onChange(of: search) { _, _ in selectedMemberIDs.removeAll() }
        .onChange(of: model.snapshot?.plan_id) { _, _ in selectedMemberIDs.removeAll() }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("全部建议", systemImage: "tray.2").tag("all")
                Label("整理记录", systemImage: "clock.arrow.circlepath").tag("history")
            }
            Section("主题") {
                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Label(group.name, systemImage: group.isUnclassified ? "tray" : "folder")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.members.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                    .dropDestination(for: MemberDrag.self) { payloads, _ in
                        acceptDrop(payloads, onto: group)
                    }
                }
            }
            if !dismissed.isEmpty {
                Section("已取消", isExpanded: $showDismissed) {
                    ForEach(dismissed) { group in
                        Label(group.name, systemImage: "xmark.circle")
                            .foregroundStyle(.secondary).tag(group.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            Label("本机分析 · 确认后移动", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedMemberIDs.isEmpty {
                    Text("已选 \(selectedMemberIDs.count) 个")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            if model.busy { TaskProgressView(progress: model.progress).padding(.horizontal, 20).padding(.bottom, 10) }
            if selection == "history" {
                HistoryView(model: model)
            } else if let group = selectedDismissed {
                dismissedDetail(group)
            } else if model.snapshot?.plan_id == nil {
                emptyState
            } else {
                fileList
                if let group = selectedGroup { groupActions(group) }
            }
            HStack {
                Text(model.message).lineLimit(1).help(model.message)
                Spacer()
                if let plan = model.snapshot?.plan_id { Text("方案 #\(plan)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("从文件中发现主题", systemImage: "tray.and.arrow.down")
        } description: {
            Text("扫描后查看建议。确认前，文件会留在原位。")
        } actions: {
            Button("扫描文件夹") { Task { await model.perform("scan") } }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(selection: $selectedMemberIDs) {
            if selection == "all" {
                ForEach(TopicGroup.make(members)) { group in
                    Section {
                        ForEach(group.members) { member in fileRow(member) }
                    } header: {
                        HStack {
                            Label(group.name, systemImage: group.isUnclassified ? "tray" : "folder")
                            Spacer()
                            Text("\(group.members.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(members) { member in fileRow(member) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if members.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .accessibilityLabel("文件建议，支持 Command 多选和拖放到主题")
    }

    private func fileRow(_ member: Member) -> some View {
        MemberRow(member: member, model: model)
            .tag(member.id)
            .draggable(MemberDrag(
                planID: model.snapshot?.plan_id ?? -1,
                memberIDs: selectedMemberIDs.contains(member.id)
                    ? selectedMemberIDs.sorted() : [member.id]
            ))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let group = selectedGroup {
                    Text(group.name).font(.headline)
                    Text("匹配评分 \(Int(group.confidence * 100)) · 启发式")
                        .font(.caption).foregroundStyle(.secondary)
                    EvidenceList(evidence: group.evidence)
                }
                if let member = selectedMembers.first {
                    if selectedGroup != nil { Divider() }
                    Text(selectedMembers.count == 1 ? "文件" : "已选文件 · \(selectedMembers.count)")
                        .font(.headline)
                    Text(member.name).textSelection(.enabled)
                    Text(member.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !member.memberReason.isEmpty {
                        Text(member.memberReason).font(.callout)
                    }
                    ForEach(member.conflicts, id: \.self) { conflict in
                        Label(conflict, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .inspectorColumnWidth(min: 220, ideal: 270, max: 360)
    }

    private func groupActions(_ group: TopicGroup) -> some View {
        HStack {
            if group.isApplied {
                Label("这个主题已整理", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                Button("取消这个主题", role: .destructive) {
                    Task {
                        await model.edit("dismiss-topic", [group.id])
                        if !TopicGroup.make(model.snapshot?.members ?? []).contains(where: { $0.id == selection }) {
                            selection = "all"
                        }
                    }
                }
                .disabled(model.busy)
                Spacer()
                Button("确认这个主题…") { preview(group) }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .animation(.easeOut(duration: 0.18), value: group.isApplied)
    }

    private func dismissedDetail(_ group: DismissedGroup) -> some View {
        VStack(spacing: 0) {
            List(group.files) { file in
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                    Text(file.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Text("已取消的主题不会出现在新的建议里。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复主题") {
                    Task {
                        await model.restoreDismissed(group.name)
                        if model.snapshot?.dismissed.contains(where: { $0.id == selection }) != true {
                            selection = "all"
                        }
                    }
                }
                .disabled(model.busy)
            }
            .padding(12)
        }
    }

    private func acceptDrop(_ payloads: [MemberDrag], onto group: TopicGroup) -> Bool {
        guard !model.busy, !group.isUnclassified, !group.isApplied,
              let planID = model.snapshot?.plan_id,
              !payloads.isEmpty, payloads.allSatisfy({ $0.planID == planID }) else { return false }
        let ids = Set(payloads.flatMap(\.memberIDs))
        let available = visibleMembers.filter { ids.contains($0.id) && !$0.applied && !$0.excluded }
        guard available.count == ids.count else { return false }
        let toMove = available.filter { $0.topic_key != group.id }
        guard !toMove.isEmpty else { return false }
        Task {
            await model.moveMembers(toMove.map(\.id), to: group.id)
            selectedMemberIDs.removeAll()
        }
        return true
    }

    private func moveSelection(to topicKey: String) {
        let ids = editableSelection.filter { $0.topic_key != topicKey }.map(\.id)
        Task {
            await model.moveMembers(ids, to: topicKey)
            selectedMemberIDs.removeAll()
        }
    }

    private func showQuickLook() {
        quickLookURL = quickLookURLs.first
    }

    private func previewAll() {
        Task {
            if await model.perform("preview") {
                previewMoves = model.moves
                showPreview = true
            }
        }
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
