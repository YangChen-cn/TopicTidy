import SwiftUI

struct DatabaseRecoveryAlert: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            model.incompatibleDatabase ? "旧数据库不兼容" : "操作未完成",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )
        ) {
            if model.incompatibleDatabase {
                Button("删除旧数据库并重扫", role: .destructive) {
                    Task { await model.perform("delete-incompatible-database") }
                }
                Button("取消", role: .cancel) { model.error = nil }
            } else {
                Button("好") { model.error = nil }
            }
        } message: {
            if model.incompatibleDatabase {
                Text("\(model.error ?? "")。删除会清空本机整理记录、人工修正和数据库中的设置，然后重新扫描。原文件不会移动或删除。")
            } else {
                Text(model.error ?? "")
            }
        }
    }
}

extension View {
    func databaseRecoveryAlert(model: AppModel) -> some View {
        modifier(DatabaseRecoveryAlert(model: model))
    }
}
