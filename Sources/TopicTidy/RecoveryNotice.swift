import SwiftUI

/// Inline recovery and error surface.
///
/// The confirmation used to be a `.alert` sheet. A `MenuBarExtra` panel is
/// transient: hosting a sheet makes the panel resign key, so it closed under the
/// pointer and the click never reached the destructive button — the database was
/// left untouched. The same sheet in the organizer window (a `NavigationSplitView`)
/// could also make AppKit abort its constraint pass with "more Update Constraints
/// passes than there are views in the window". Both come from presenting a sheet
/// here, so the recovery is a normal button in normal window content instead.
struct RecoveryNotice: View {
    @Bindable var model: AppModel
    /// The menu bar panel has far less room than the organizer window.
    var compact = false

    var body: some View {
        InlineNotice(
            systemImage: model.incompatibleDatabase
                ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill",
            title: model.incompatibleDatabase ? "旧数据库不兼容" : "操作未完成",
            message: detail,
            tint: model.incompatibleDatabase ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary),
            compact: compact,
            maxWidth: compact ? .infinity : 460
        ) {
            if model.incompatibleDatabase {
                Button("删除旧数据库并重扫", role: .destructive) {
                    Task { await model.perform("delete-incompatible-database") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.busy)
                Button("稍后") { model.dismissError() }
                    .disabled(model.busy)
            } else {
                Button("好") { model.dismissError() }
            }
        }
    }

    private var detail: String {
        guard model.incompatibleDatabase else { return model.error ?? "操作失败" }
        return "\(model.error ?? "")。删除会清空本机整理记录、人工修正和数据库中的设置，然后重新扫描。原文件不会移动或删除。"
    }
}

extension View {
    /// Replaces the content with the blocking recovery notice while the database
    /// cannot be opened, and shows one-line failures without taking over the window.
    func databaseRecoveryNotice(model: AppModel, compact: Bool = false) -> some View {
        modifier(DatabaseRecoveryNotice(model: model, compact: compact))
    }
}

private struct DatabaseRecoveryNotice: ViewModifier {
    @Bindable var model: AppModel
    var compact = false

    func body(content: Content) -> some View {
        if model.incompatibleDatabase {
            RecoveryNotice(model: model, compact: compact)
                .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        } else {
            VStack(spacing: 0) {
                if model.error != nil {
                    RecoveryNotice(model: model, compact: compact)
                }
                content
            }
        }
    }
}
