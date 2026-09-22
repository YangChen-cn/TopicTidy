import SwiftUI

struct MovePreview: View {
    @Bindable var model: AppModel
    let moves: [Move]
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("整理 \(moves.count) 个文件").font(.system(size: 15, weight: .semibold))
                Text("核对以下位置，整理后可在记录中撤销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(moves) { move in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(URL(fileURLWithPath: move.source).lastPathComponent, systemImage: "doc")
                                .font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(move.source).foregroundStyle(.secondary)
                            Label(move.destination, systemImage: "arrow.turn.down.right")
                            if move.stale { Text("文件已改变，将跳过").foregroundStyle(.orange) }
                        }.font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                }
            }.frame(height: min(300, max(120, CGFloat(moves.count) * 110)))
            HStack {
                Button("返回", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认移动") {
                    close()
                    Task { await model.apply(moves) }
                }.buttonStyle(.borderedProminent).disabled(moves.isEmpty || model.busy)
            }
        }.padding(16).controlSize(.small)
    }
}
