import SwiftUI

@main
struct TackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Tack", systemImage: "list.clipboard") {
            MenuContent(delegate: delegate, settings: delegate.settings)
        }

        Settings {
            SettingsView(settings: delegate.settings, store: delegate.store)
        }
    }
}

private struct MenuContent: View {
    let delegate: AppDelegate
    let settings: AppSettings

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Show History (\(settings.hotkey.displayString))") {
            delegate.togglePopup()
        }

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Tack") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
