import SwiftUI
import TopicTidyCore

struct TaskProgressView: View {
    let progress: ServiceProgress?
    var compact = false

    private let stages: [(ServiceProgress, String)] = [
        (.scanningFiles, "扫描文件"),
        (.extractingContent, "提取内容"),
        (.semanticAnalysis, "语义分析"),
        (.generatingSuggestions, "生成建议"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let progress {
                Text(stages.first { $0.0 == progress }?.1 ?? "处理中")
                    .font(.caption.weight(.semibold))
                if !compact {
                    Text("·")
                    Text("扫描文件 → 提取内容 → 语义分析 → 生成建议")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                Text("正在处理…").font(.caption)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.map { stage in
            "正在\(stages.first { $0.0 == stage }?.1 ?? "处理")"
        } ?? "正在处理")
    }
}
