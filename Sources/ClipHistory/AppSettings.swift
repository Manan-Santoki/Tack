import AppKit
import Observation
import ServiceManagement

enum PopupLayout: String, CaseIterable {
    /// More text: one row per clip, with a small preview.
    case list
    /// More images: tiles with large previews.
    case grid

    static let gridColumns = 3
}

@MainActor
@Observable
final class AppSettings {
    var hotkey: HotkeyShortcut = .default {
        didSet { save(); onHotkeyChanged?() }
    }

    var maxItems = 50 {
        didSet { save(); onMaxItemsChanged?(maxItems) }
    }

    var launchAtLogin = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    var hideImages = false {
        didSet { save() }
    }

    /// Reopen at the previous selection instead of the newest clip.
    var rememberScrollPosition = false {
        didSet { save() }
    }

    var layout = PopupLayout.list {
        didSet { save() }
    }

    /// Record clips arriving through Universal Clipboard from an iPhone, iPad or other Mac.
    var recordFromOtherDevices = true {
        didSet { save() }
    }

    /// Bundle IDs of apps whose copies are not recorded.
    var excludedBundleIDs: Set<String> = [] {
        didSet { save() }
    }

    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    @ObservationIgnored var onMaxItemsChanged: ((Int) -> Void)?

    private let defaults: UserDefaults
    /// Each property's didSet saves everything, so saving while loading would
    /// overwrite the values not yet read with their defaults.
    private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let maxItems = "maxItems"
        static let hideImages = "hideImages"
        static let rememberScrollPosition = "rememberScrollPosition"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let layout = "layout"
        static let recordFromOtherDevices = "recordFromOtherDevices"
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        if let data = defaults.data(forKey: Keys.hotkey),
           let saved = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            hotkey = saved
        }
        let count = defaults.integer(forKey: Keys.maxItems)
        if count >= 5 { maxItems = count }
        hideImages = defaults.bool(forKey: Keys.hideImages)
        rememberScrollPosition = defaults.bool(forKey: Keys.rememberScrollPosition)
        if let ids = defaults.stringArray(forKey: Keys.excludedBundleIDs) {
            excludedBundleIDs = Set(ids)
        }
        if let saved = defaults.string(forKey: Keys.layout).flatMap(PopupLayout.init) {
            layout = saved
        }
        recordFromOtherDevices = defaults.object(forKey: Keys.recordFromOtherDevices) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Keys.hotkey)
        }
        defaults.set(maxItems, forKey: Keys.maxItems)
        defaults.set(hideImages, forKey: Keys.hideImages)
        defaults.set(rememberScrollPosition, forKey: Keys.rememberScrollPosition)
        defaults.set(Array(excludedBundleIDs), forKey: Keys.excludedBundleIDs)
        defaults.set(layout.rawValue, forKey: Keys.layout)
        defaults.set(recordFromOtherDevices, forKey: Keys.recordFromOtherDevices)
    }

    private func applyLaunchAtLogin() {
        guard !isLoading else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClipHistory: launch at login update failed: \(error.localizedDescription)")
        }
    }
}
