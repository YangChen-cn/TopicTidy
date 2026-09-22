import AppKit
import SwiftUI
import TopicTidyCore

/// Apple-style About window: identity, the handful of things that make the app
/// worth trusting with a Downloads folder, and where it comes from.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            masthead
            Divider()
            features
            Divider()
            footer
        }
        .frame(width: 400)
        .background(.background)
    }

    private var masthead: some View {
        VStack(spacing: 9) {
            Group {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon).resizable()
                } else {
                    // Running from a bare SwiftPM build without a bundle.
                    Image(systemName: "tray.2").resizable().padding(16)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityHidden(true)
            Text(AppInfo.name)
                .font(.system(size: 23, weight: .semibold))
            Text("版本 \(AppInfo.displayVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
            Text(AppInfo.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Feature.all, id: \.title) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.system(size: 12.5, weight: .medium))
                        Text(feature.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("作者 \(AppInfo.author)").font(.caption)
                Text("\(AppInfo.license) 许可证 · 本机分析，不联网")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                if let url = URL(string: AppInfo.repository) { openURL(url) }
            } label: {
                Label("GitHub", systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(AppInfo.repository)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private struct Feature {
        let symbol: String
        let title: String
        let detail: String

        static let all: [Feature] = [
            Feature(symbol: "text.magnifyingglass",
                    title: "多信号判断",
                    detail: "课程号、文件名、来源 URL、正文关键词与本地语义共同决定分组。"),
            Feature(symbol: "brain",
                    title: "Apple 本地语义",
                    detail: "使用系统 NaturalLanguage embedding，可选已安装的本地翻译。"),
            Feature(symbol: "doc.text",
                    title: "文档正文提取",
                    detail: "PDF、DOCX、PPTX、Markdown 与纯文本，只读分类所需的片段。"),
            Feature(symbol: "checkmark.circle",
                    title: "确认前不动文件",
                    detail: "按主题预览、确认或取消；每个建议都给出可读依据。"),
            Feature(symbol: "xmark.circle",
                    title: "取消即不再打扰",
                    detail: "取消的主题收进“已取消”，下次扫描不再提出，可随时恢复。"),
            Feature(symbol: "arrow.uturn.backward",
                    title: "随时撤销",
                    detail: "移动前校验指纹，撤销会恢复原路径并保留完整记录。"),
        ]
    }
}
