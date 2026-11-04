import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    let onDone: () -> Void

    var body: some View {
        Form {
            Section {
                AccessibilityStatusRow()
            } footer: {
                Text("Lets ClipHistory paste for you and open at your text cursor.")
            }

            Section {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.hotkey)
                }
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420, height: 196)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}
