import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var tab = "review"
    @State private var showPreview = false
    @State private var previewMoves: [Move] = []
    @Environment(\.openWindow) private var openWindow
    private var groups: [TopicGroup] { TopicGroup.make(model.snapshot?.members ?? []) }
    private var movableCount: Int { model.snapshot?.members.filter { $0.topic != nil && !$0.excluded && !$0.applied }.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showPreview {
                MovePreview(model: model, moves: previewMoves) { showPreview = false }
            } else {
                Picker("面板", selection: $tab) {
                    Text("建议").tag("review")
                    Text("记录").tag("history")
                    Text("设置").tag("settings")
                }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 12)
                Divider()
                switch tab {
                case "settings": PreferencesView(model: model).frame(height: 430)
                case "history": HistoryView(model: model).frame(height: model.snapshot?.history.isEmpty ?? true ? 180 : 330)
                default: review
                }
                footer
            }
        }
        .font(.system(size: 13)).controlSize(.small)
        .frame(width: 380).fixedSize(horizontal: false, vertical: true)
        .task { await model.perform("status") }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("TopicTidy").font(.system(size: 14, weight: .semibold))
            Spacer()
            if model.busy { ProgressView().controlSize(.mini) }
            Button { openWindow(id: "organizer"); NSApplication.shared.activate() } label: {
                Label("打开窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            }.labelStyle(.iconOnly).buttonStyle(.borderless).help("打开完整窗口")
            Menu {
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
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("给下载文件一个归处").font(.system(size: 14, weight: .medium))
                    Text("发现相同课程和主题，确认后再整理。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("扫描下载文件") { Task { await model.perform("scan") } }
                        .buttonStyle(.borderedProminent).padding(.top, 3).disabled(model.busy)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                HStack {
                    Text("\(groups.filter { !$0.isUnclassified }.count) 个主题 · \(model.snapshot?.members.count ?? 0) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新扫描", systemImage: "arrow.clockwise") { Task { await model.perform("scan") } }
                        .buttonStyle(.borderless).disabled(model.busy)
                }.padding(.horizontal, 14).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(groups) { group in
                            TopicGroupView(group: group, model: model) { preview($0) }
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.frame(height: min(320, max(150, CGFloat(groups.count) * 64)))
                HStack {
                    Text("确认前不移动文件").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("整理全部 \(movableCount) 个…") {
                        Task {
                            if await model.perform("preview") {
                                previewMoves = model.moves
                                showPreview = true
                            }
                        }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || movableCount == 0)
                }.padding(12)
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

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.busy ? "hourglass" : "lock.shield").font(.caption2)
                Text(model.busy ? "正在处理…" : model.message)
                    .font(.caption2).lineLimit(1).truncationMode(.tail).help(model.message)
                Spacer(minLength: 0)
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
        }
    }
}
