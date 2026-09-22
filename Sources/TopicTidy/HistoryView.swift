import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var undoID: Int?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.snapshot?.history.isEmpty ?? true {
                    VStack(spacing: 9) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 25, weight: .light))
                        Text("还没有整理记录").font(.system(size: 13, weight: .medium))
                        Text("每次移动都会记录，可在这里撤销。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(model.snapshot?.history ?? []) { batch in
                    HStack(spacing: 10) {
                        Image(systemName: batch.kind == "undo" ? "arrow.uturn.backward" : "folder")
                            .foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(batch.kind == "undo" ? "撤销" : batch.kind == "auto_apply" ? "自动整理" : "手动整理") · #\(batch.id)")
                                .font(.system(size: 12, weight: .medium))
                            Text(Date(timeIntervalSince1970: batch.created_at), format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(statusLabel(batch.status)).font(.caption).foregroundStyle(.secondary)
                        if batch.kind != "undo" {
                            Button("撤销") { undoID = batch.id }.disabled(model.busy).controlSize(.small)
                        }
                    }.padding(.vertical, 11)
                    Divider()
                }
            }.padding(.horizontal, 14)
        }
        .confirmationDialog("撤销此批次？", isPresented: Binding(get: { undoID != nil }, set: { if !$0 { undoID = nil } })) {
            Button("验证并撤销") {
                if let id = undoID { Task { await model.perform("undo", values: ["batch_id": id, "confirmed": true]) } }
                undoID = nil
            }
        } message: { Text("验证文件后恢复原路径。路径被占用或文件已改变时跳过。") }
    }
    private func statusLabel(_ value: String) -> String {
        switch value {
        case "completed", "complete": "已完成"
        case "partial": "部分完成"
        case "running": "处理中"
        case "recovered": "已恢复"
        case "undone": "已撤销"
        case "failed": "失败"
        default: value
        }
    }
}
