import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: ClipboardStore

    @State private var confirmingClear = false

    private var sourceApps: [SourceApp] {
        var seen = Set<String>()
        return store.items
            .compactMap(\.sourceApp)
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.hotkey)
                }
                AccessibilityStatusRow()
            }

            Section("History") {
                Picker("Layout", selection: $settings.layout) {
                    Text("List").tag(PopupLayout.list)
                    Text("Grid").tag(PopupLayout.grid)
                }
                Stepper("Keep \(settings.maxItems) clips", value: $settings.maxItems, in: 5...500, step: 5)
                Toggle("Show images", isOn: Binding(
                    get: { !settings.hideImages },
                    set: { settings.hideImages = !$0 }
                ))
                Toggle("Reopen at last position", isOn: $settings.rememberScrollPosition)
                LabeledContent("\(store.items.count) clips stored") {
                    Button("Clear…", role: .destructive) { confirmingClear = true }
                }
            }

            Section {
                Toggle("Record from iPhone and other devices", isOn: $settings.recordFromOtherDevices)
            } footer: {
                Text("Clips from other devices can still be pasted with ⌘V. To stop them reaching this Mac at all, turn off Handoff in System Settings.")
            }

            Section {
                Toggle("Record passwords and sensitive clips", isOn: $settings.recordSensitive)
            } footer: {
                Text("Off by default. When on, copied passwords are saved in your encrypted history and appear in the popup in plain view, and they stay until deleted or trimmed.")
            }

            Section {
                if sourceApps.isEmpty {
                    Text("Apps appear here after you copy from them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sourceApps, id: \.bundleID) { app in
                        Toggle(app.name, isOn: Binding(
                            get: { !settings.excludedBundleIDs.contains(app.bundleID) },
                            set: { record in
                                if record {
                                    settings.excludedBundleIDs.remove(app.bundleID)
                                } else {
                                    settings.excludedBundleIDs.insert(app.bundleID)
                                }
                            }
                        ))
                    }
                }
            } header: {
                Text("Record from")
            } footer: {
                Text("Copies from apps turned off here aren't recorded.")
            }

            Section {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear All", role: .destructive) { store.clearAll() }
        } message: {
            Text("This permanently deletes all \(store.items.count) clips, including pinned ones.")
        }
    }
}

/// Accessibility is needed to paste automatically and to find the text cursor.
struct AccessibilityStatusRow: View {
    @State private var granted = AXIsProcessTrusted()

    var body: some View {
        LabeledContent("Accessibility") {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open System Settings…") {
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                granted = AXIsProcessTrusted()
            }
        }
    }
}
