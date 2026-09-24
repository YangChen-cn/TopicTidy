import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var tab = "review"
    @State private var showPreview = false
    @State private var previewMoves: [Move] = []
    @State private var showDismissed = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var groups: [TopicGroup] { TopicGroup.make(model.snapshot?.members ?? []) }
    private var dismissed: [DismissedGroup] { model.snapshot?.dismissed ?? [] }
    private var movableCount: Int { model.snapshot?.members.filter { $0.topic != nil && !$0.excluded && !$0.applied }.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.incompatibleDatabase {
                // Nothing else in the panel can work until the database is rebuilt.
                RecoveryNotice(model: model, compact: true)
                footer
            } else if showPreview {
                MovePreview(model: model, moves: previewMoves) { showPreview = false }
            } else {
                if model.error != nil { RecoveryNotice(model: model, compact: true) }
                Picker("面板", selection: $tab) {
                    Text("建议").tag("review")
                    Text("记录").tag("history")
                    Text("设置").tag("settings")
                }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 12)
                switch tab {
                case "settings": PreferencesView(model: model, compact: true).frame(height: 430)
                case "history": HistoryView(model: model).frame(height: model.snapshot?.history.isEmpty ?? true ? 180 : 330)
                default: review
                }
                footer
            }
        }
        .controlSize(.small)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 460 : 340)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.perform("status") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("TopicTidy").font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.mini).accessibilityLabel("正在处理") }
            Button { openWindow(id: "organizer"); NSApplication.shared.activate() } label: {
                Label("打开窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            }.labelStyle(.iconOnly).buttonStyle(.borderless).help("打开完整窗口")
            Menu {
                Button("关于 TopicTidy") { openWindow(id: "about"); NSApplication.shared.activate() }
                Divider()
                Button("退出 TopicTidy") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("更多操作")
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var review: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.title).foregroundStyle(.secondary)
                    Text("让文件各归其处").font(.headline)
                    Text("发现相同课程和主题，确认后再整理。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("扫描文件夹") { Task { await model.perform("scan") } }
                        .buttonStyle(.borderedProminent).padding(.top, 3).disabled(model.busy)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                HStack {
                    Text("\(groups.filter { !$0.isUnclassified }.count) 个主题 · \(model.snapshot?.members.count ?? 0) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新扫描", systemImage: "arrow.clockwise") { Task { await model.perform("scan") } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("重新扫描文件夹").disabled(model.busy)
                }.padding(.horizontal, 14).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groups) { group in
                            TopicGroupView(group: group, model: model) { preview($0) }
                        }
                        if !dismissed.isEmpty { dismissedSection }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.frame(height: min(300, max(120, CGFloat(groups.count + (dismissed.isEmpty ? 0 : 1)) * 55)))
                HStack {
                    Text("确认前不移动文件").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("预览整理…") {
                        Task {
                            if await model.perform("preview") {
                                previewMoves = model.moves
                                showPreview = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(model.busy || movableCount == 0)
                }.padding(12)
            }
        }
    }

    /// Collapsed by default; a dismissed topic never returns on its own.
    private var dismissedSection: some View {
        DisclosureGroup(isExpanded: $showDismissed) {
            VStack(spacing: 0) {
                ForEach(dismissed) { group in
                    HStack {
                        Label(group.name, systemImage: "xmark.circle")
                            .font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.files.count)").font(.caption).foregroundStyle(.secondary)
                        Button("恢复") { Task { await model.restoreDismissed(group.name) } }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }.padding(.vertical, 5)
                }
            }.padding(.top, 4)
        } label: {
            Label("已取消 \(dismissed.count)", systemImage: "xmark.circle")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func preview(_ group: TopicGroup) {
        Task {
            if let moves = await model.preview(topicKey: group.id) {
                previewMoves = moves
                showPreview = true
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: model.busy ? "hourglass" : "lock.shield").font(.caption2)
                if model.busy {
                    TaskProgressView(progress: model.progress, compact: true)
                } else {
                    Text(model.message)
                        .font(.caption2).lineLimit(1).truncationMode(.tail).help(model.message)
                }
                Spacer(minLength: 0)
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
        }
    }
}
