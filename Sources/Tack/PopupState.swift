import Observation

/// Shared between PopupWindowController and PopupView.
@MainActor
@Observable
final class PopupState {
    /// True only once the panel is the key window, because SwiftUI ignores focus requests before that.
    var isOpen = false
    var searchText = ""
    var selectedIndex = 0

    func reset(keepSelection: Bool) {
        searchText = ""
        if !keepSelection { selectedIndex = 0 }
    }
}
