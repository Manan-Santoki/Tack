import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Carbon delivers hotkey events on the main thread.
private func hotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    nonisolated(unsafe) let pointer = userData
    MainActor.assumeIsolated {
        Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue().togglePopup()
    }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    let store: ClipboardStore

    let updateChecker = UpdateChecker()
    private let popup: PopupWindowController

    private var onboardingWindow: NSWindow?
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyHandlerRef: EventHandlerRef?
    private var clipboardTask: Task<Void, Never>?
    private var frontmostSource: SourceApp?

    private static let onboardingDoneKey = "onboardingComplete"

    override init() {
        LegacyMigration.moveHistory()
        store = ClipboardStore(maxCount: settings.maxItems)
        popup = PopupWindowController(store: store, settings: settings, updateChecker: updateChecker)
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings.onHotkeyChanged = { [weak self] in self?.registerHotkey() }
        settings.onMaxItemsChanged = { [weak self] in self?.store.updateMaxCount($0) }

        startTrackingFrontmostApp()
        startClipboardMonitoring()
        installHotkeyHandler()
        registerHotkey()

        if UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) {
            requestAccessibility()
        } else {
            showOnboarding()
        }

        updateChecker.start(
            shouldInstall: { [settings] in settings.installUpdatesAutomatically },
            canRestart: { [popup] in !popup.isOpen }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardTask?.cancel()
        store.saveNow()
    }

    func togglePopup() {
        popup.toggle()
    }

    private func requestAccessibility() {
        // The string value of kAXTrustedCheckOptionPrompt, which isn't concurrency-safe to read.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(settings: settings) { [weak self] in
            self?.onboardingWindow?.close()
        }))
        window.title = "Welcome to Tack"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
        onboardingWindow = nil
    }

    // MARK: - Source app

    private func startTrackingFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(updateFrontmostSource),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateFrontmostSource()
    }

    @objc private func updateFrontmostSource() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let name = app.localizedName
        else { return }
        frontmostSource = SourceApp(bundleID: bundleID, name: name)
    }

    // MARK: - Clipboard

    private func startClipboardMonitoring() {
        captureClipboard()
        clipboardTask = Task { [weak self] in
            var lastCount = NSPasteboard.general.changeCount
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let count = NSPasteboard.general.changeCount
                guard count != lastCount else { continue }
                lastCount = count
                self?.captureClipboard()
            }
        }
    }

    private func captureClipboard() {
        // The frontmost app didn't produce a clip from another device, so neither its
        // exclusion nor its name applies.
        if NSPasteboard.general.types?.contains(ClipPayload.otherDeviceType) == true {
            if settings.recordFromOtherDevices { store.capture(includeSensitive: settings.recordSensitive) }
            return
        }
        if let bundleID = frontmostSource?.bundleID, settings.excludedBundleIDs.contains(bundleID) { return }
        store.capture(source: frontmostSource, includeSensitive: settings.recordSensitive)
    }

    // MARK: - Hotkey

    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotkeyHandlerRef
        )
        if status != noErr { NSLog("Tack: failed to install hotkey handler: \(status)") }
    }

    private func registerHotkey() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        hotkeyRef = nil

        let id = EventHotKeyID(signature: 0x5441434B /* "TACK" */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(settings.hotkey.keyCode),
            settings.hotkey.carbonModifierFlags,
            id,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if status != noErr { NSLog("Tack: failed to register hotkey: \(status)") }
    }
}

private extension HotkeyShortcut {
    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
