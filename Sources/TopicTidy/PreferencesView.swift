import AppKit
import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    var compact = false
    @State private var scanRoots: [String] = []
    @State private var destination = ""
    @State private var automatic = false
    @State private var threshold = 0.92
    @State private var daily = false
    @State private var at = "09:00"
    @State private var confirmAutomatic = false

    var body: some View {
        Group {
            if compact { compactBody }
            else { settingsBody }
        }
        .controlSize(compact ? .small : .regular)
        .disabled(model.busy)
        .task {
            await model.perform("status")
            loadPreferences()
        }
        .alert("启用自动整理？", isPresented: $confirmAutomatic) {
            Button("取消", role: .cancel) {
                automatic = model.snapshot?.preferences.auto_confirm_enabled ?? false
            }
            Button("明确授权并启用") {
                Task {
                    if !(await saveAutomatic()) {
                        automatic = model.snapshot?.preferences.auto_confirm_enabled ?? false
                    }
                }
            }
        } message: {
            Text("这是持续授权。每日任务可自动移动达到阈值的完整、无冲突主题；每次移动都会记录，之后可撤销。")
        }
    }

    /// The dedicated Settings window keeps one native, scrollable Form.
    private var settingsBody: some View {
        Form {
            Section("扫描目录") { scanRootRows }
            Section("整理目录") { destinationRows }
            Section("自动整理") { automationRows }
            Section("每日扫描") { scheduleRows }
        }
        .formStyle(.grouped)
    }

    /// The menu bar panel uses one scroll surface, with every setting visible
    /// in document order instead of another layer of tabs or nested lists.
    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                compactSection("扫描目录") { scanRootRows }
                compactSection("整理目录") { destinationRows }
                compactSection("自动整理") { automationRows }
                compactSection("每日扫描") { scheduleRows }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
    }

    private func compactSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var scanRootRows: some View {
        ForEach(scanRoots, id: \.self) { path in
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await saveScanRoots(scanRoots.filter { $0 != path }) }
                } label: {
                    Label("移除扫描目录 \(path)", systemImage: "minus.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(scanRoots.count <= 1)
            }
        }
        Button("添加扫描目录…", systemImage: "plus", action: addScanRoots)
        Text("只扫描顶层文件。更改目录会关闭自动整理，需要重新授权。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var destinationRows: some View {
        Text("目标文件夹路径").font(.subheadline.weight(.medium))
        TextField("目标文件夹路径", text: $destination)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("整理目录路径")
        HStack {
            Button("选择目录…", action: chooseFolder)
            Spacer()
            Button("保存整理目录") {
                Task {
                    if await model.perform("preferences", values: ["destination": destination]) {
                        destination = model.snapshot?.preferences.destination ?? destination
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("所有扫描目录共用这个位置；已有方案仍使用保存时的目录。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var automationRows: some View {
        Toggle("自动确认高评分主题", isOn: $automatic)
        if automatic {
            LabeledContent("最低评分") {
                HStack {
                    Slider(value: $threshold, in: 0.85...1, step: 0.01)
                        .accessibilityLabel("自动整理最低评分")
                    Text("\(Int(threshold * 100))")
                        .monospacedDigit().frame(minWidth: 28, alignment: .trailing)
                }
            }
        }
        LabeledContent("状态") {
            Text(model.snapshot?.preferences.auto_confirm_enabled == true ? "已启用" : "当前关闭")
                .foregroundStyle(.secondary)
        }
        Text("只移动完整、无冲突的主题。评分为启发式，建议先核对文件。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("保存自动整理") {
                if automatic { confirmAutomatic = true }
                else { Task { _ = await saveAutomatic() } }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var scheduleRows: some View {
        Toggle("每天扫描一次", isOn: $daily)
        if daily {
            TextField("执行时间（HH:mm）", text: $at)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("每日扫描时间，小时和分钟")
        }
        LabeledContent("状态") {
            Text(scheduleLabel).foregroundStyle(.secondary)
        }
        Text("按本机时间执行。启用自动整理后，每日扫描也会移动符合条件的文件。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("保存每日任务") {
                Task { await model.perform("schedule", values: ["enabled": daily, "at": at]) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var scheduleLabel: String {
        switch model.snapshot?.schedule.state {
        case "loaded": "已启用"
        case "configured_not_loaded": "未载入，请重新保存"
        default: "未设置"
        }
    }

    private func loadPreferences() {
        guard let snapshot = model.snapshot else { return }
        scanRoots = snapshot.preferences.scan_roots
        destination = snapshot.preferences.destination
        automatic = snapshot.preferences.auto_confirm_enabled
        threshold = snapshot.preferences.auto_confirm_threshold
        daily = snapshot.schedule.state != "not_configured"
        at = snapshot.schedule.time ?? "09:00"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    private func addScanRoots() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { await saveScanRoots(scanRoots + panel.urls.map(\.path)) }
        }
    }

    private func saveScanRoots(_ paths: [String]) async {
        if await model.perform("preferences", values: ["scan_roots": paths]) {
            loadPreferences()
        }
    }

    private func saveAutomatic() async -> Bool {
        let saved = await model.perform("preferences", values: ["enabled": automatic, "threshold": threshold])
        if saved { loadPreferences() }
        return saved
    }
}
