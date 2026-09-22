import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PreferencesView(model: model)
            Divider()
            Text(model.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: 400, height: 490)
            .alert("设置未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}
