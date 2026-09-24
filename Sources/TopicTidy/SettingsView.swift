import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PreferencesView(model: model)
            HStack {
                Text(model.message).lineLimit(2)
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .databaseRecoveryNotice(model: model)
        .frame(width: 520, height: 520)
    }
}
