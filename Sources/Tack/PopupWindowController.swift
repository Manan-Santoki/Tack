import AppKit
import SwiftUI

/// Takes keyboard focus without activating Tack, so the app being pasted into
/// stays frontmost and keeps its text cursor.
private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupWindowController: NSObject, NSWindowDelegate {
    private static let size = CGSize(width: 360, height: 400)
    /// Clear space around the popup in the window, so its shadow isn't cut off.
    private static let shadowMargin: CGFloat = 40

    private let store: ClipboardStore
    private let settings: AppSettings
    private let updateChecker: UpdateChecker
    private let state = PopupState()
    private let searchField = SearchTextField()

    private var panel: PopupPanel?
    private var keyMonitor: Any?

    init(store: ClipboardStore, settings: AppSettings, updateChecker: UpdateChecker) {
        self.store = store
        self.settings = settings
        self.updateChecker = updateChecker
    }

    // MARK: - Show / hide

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        // Read the cursor first, while the target app still has focus.
        let anchor = CaretLocator.currentAnchor()

        state.reset(keepSelection: settings.rememberScrollPosition)
        state.selectedIndex = min(state.selectedIndex, max(0, visibleItems.count - 1))

        let panel = panel ?? makePanel()
        self.panel = panel

        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let origin = PopupPlacement.origin(
            anchor: anchor,
            size: Self.size,
            visibleFrame: screen?.visibleFrame ?? anchor
        )
        let frame = NSRect(origin: origin, size: Self.size).insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        state.isOpen = true
        startKeyMonitor()
    }

    private func hide() {
        stopKeyMonitor()
        state.isOpen = false
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Paste

    private func paste(_ item: ClipItem, asPlainText: Bool) {
        store.restore(item, asPlainText: asPlainText)
        hide()

        // Without Accessibility access the clip stays on the clipboard for a manual ⌘V.
        guard AXIsProcessTrusted() else { return }
        Task {
            // Let focus return to the target app before sending ⌘V.
            try? await Task.sleep(for: .milliseconds(80))
            Self.sendCommandV()
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let virtualKeyV: CGKeyCode = 0x09
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Items

    private var visibleItems: [ClipItem] {
        store.filtered(query: state.searchText, showImages: !settings.hideImages)
    }

    private var selectedItem: ClipItem? {
        visibleItems[safe: state.selectedIndex]
    }

    private func moveSelection(by offset: Int) {
        let last = max(0, visibleItems.count - 1)
        state.selectedIndex = min(max(0, state.selectedIndex + offset), last)
    }

    private func remove(_ item: ClipItem) {
        store.remove(id: item.id)
        moveSelection(by: 0)
    }

    // MARK: - Panel

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // Setting isFloatingPanel also sets the level, so it has to come first.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow and outline follow the window's alpha, which doesn't include the
        // glass, so they'd draw a dark rectangular edge. PopupView draws its own shadow instead.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let hostingView = NSHostingView(rootView: PopupView(
            store: store,
            settings: settings,
            state: state,
            searchField: searchField,
            shadowMargin: Self.shadowMargin,
            updateChecker: updateChecker,
            onPaste: { [weak self] item, asPlainText in self?.paste(item, asPlainText: asPlainText) },
            onTogglePin: { [weak self] item in self?.store.togglePin(id: item.id) },
            onRemove: { [weak self] item in self?.remove(item) }
        ))
        // Keep the panel's size instead of shrinking it to fit a short list.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }

    // MARK: - Keyboard

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled here. Anything else reaches the search field.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)

        switch event.keyCode {
        case 53: // Escape
            hide()
        case 126: // Up
            moveSelection(by: settings.layout == .grid ? -PopupLayout.gridColumns : -1)
        case 125: // Down
            moveSelection(by: settings.layout == .grid ? PopupLayout.gridColumns : 1)
        case 123 where settings.layout == .grid && state.searchText.isEmpty: // Left
            moveSelection(by: -1)
        case 124 where settings.layout == .grid && state.searchText.isEmpty: // Right
            moveSelection(by: 1)
        case 37 where command: // ⌘L
            settings.layout = settings.layout == .grid ? .list : .grid
        case 36, 76: // Return, Enter
            if let item = selectedItem { paste(item, asPlainText: modifiers.contains(.shift)) }
        case 51 where command: // ⌘⌫
            if let item = selectedItem { remove(item) }
        case 35 where command: // ⌘P
            if let item = selectedItem { store.togglePin(id: item.id) }
        default:
            // ⌘1 to ⌘9 paste by position.
            guard command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit > 0,
                  let item = visibleItems[safe: digit - 1]
            else { return false }
            paste(item, asPlainText: false)
        }
        return true
    }
}
