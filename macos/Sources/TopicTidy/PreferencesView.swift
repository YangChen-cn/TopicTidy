import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var destination = ""
    @State private var automatic = false
    @State private var threshold = 0.92
    @State private var daily = false
    @State private var at = "09:00"
    @State private var confirmAutomatic = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("整理位置", icon: "folder")
                    TextField("目标文件夹路径", text: $destination).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("新方案使用此位置").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("选择…", action: chooseFolder)
                        Button("保存") { Task { await model.perform("preferences", values: ["destination": destination]) } }
                            .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("自动整理", icon: "checkmark.shield")
                    Toggle("自动确认高评分主题", isOn: $automatic).toggleStyle(.switch)
                    if automatic {
                        HStack {
                            Text("最低评分").foregroundStyle(.secondary)
                            Slider(value: $threshold, in: 0.85...1, step: 0.01)
                            Text("\(Int(threshold * 100))").monospacedDigit().frame(width: 24)
                        }
                    }
                    Text("只移动完整、无冲突的主题。评分为启发式。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(model.snapshot?.preferences.auto_confirm_enabled == true ? "已启用" : "当前关闭")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存自动整理") {
                            if automatic { confirmAutomatic = true }
                            else { Task { await saveAutomatic() } }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("每日扫描", icon: "clock")
                    Toggle("每天扫描一次", isOn: $daily).toggleStyle(.switch)
                    HStack {
                        if daily {
                            TextField("09:00", text: $at).textFieldStyle(.roundedBorder).frame(width: 62)
                                .accessibilityLabel("每日扫描时间，小时和分钟")
                        }
                        Text(scheduleLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存任务") {
                            Task { await model.perform("schedule", values: ["enabled": daily, "at": at]) }
                        }
                    }
                    Text("\(daily ? "按本机时间执行。" : "")启用自动整理后，每日扫描也会移动符合条件的文件。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
        }
        .font(.system(size: 12)).controlSize(.small).disabled(model.busy)
        .task {
            await model.perform("status")
            if let s = model.snapshot {
                destination = s.preferences.destination
                automatic = s.preferences.auto_confirm_enabled
                threshold = s.preferences.auto_confirm_threshold
                daily = s.schedule.state != "not_configured"
                at = s.schedule.time ?? "09:00"
            }
        }
        .confirmationDialog("允许今后自动移动文件？", isPresented: $confirmAutomatic) {
            Button("启用自动整理") { Task { await saveAutomatic() } }
        } message: { Text("这是一项持续授权。每日任务会移动符合条件的完整主题，并保留撤销记录。") }
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold))
    }
    private var scheduleLabel: String {
        switch model.snapshot?.schedule.state {
        case "loaded": "已启用"
        case "configured_not_loaded": "未载入，请重新保存"
        default: "未设置"
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }
    private func saveAutomatic() async {
        await model.perform("preferences", values: ["enabled": automatic, "threshold": threshold])
    }
}
