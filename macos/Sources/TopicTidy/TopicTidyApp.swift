import SwiftUI

@main struct TopicTidyApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        MenuBarExtra("TopicTidy", systemImage: "tray.2") {
            PanelView(model: model)
        }
        .menuBarExtraStyle(.window)
        Window("TopicTidy", id: "organizer") {
            OrganizerView(model: model)
                .task { await model.perform("status") }
        }
        .defaultSize(width: 720, height: 480)
        Settings { SettingsView(model: model) }
    }
}
