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
        Window("关于 TopicTidy", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
        }
        Settings { SettingsView(model: model) }
    }
}

/// The standard "About TopicTidy" menu item, opening the About window.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("关于 TopicTidy") { openWindow(id: "about") }
    }
}
