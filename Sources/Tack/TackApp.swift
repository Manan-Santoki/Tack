import SwiftUI

@main
struct TackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate, settings: delegate.settings)
        } label: {
            Image(nsImage: .tackMenuBar)
                .accessibilityLabel("Tack")
        }

        Settings {
            SettingsView(settings: delegate.settings, store: delegate.store, updateChecker: delegate.updateChecker)
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
