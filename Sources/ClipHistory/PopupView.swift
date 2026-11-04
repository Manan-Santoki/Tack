import SwiftUI

struct PopupView: View {
    let store: ClipboardStore
    @Bindable var settings: AppSettings
    @Bindable var state: PopupState
    let searchField: SearchTextField
    let shadowMargin: CGFloat
    let updateChecker: UpdateChecker
    let onPaste: (ClipItem, _ asPlainText: Bool) -> Void
    let onTogglePin: (ClipItem) -> Void
    let onRemove: (ClipItem) -> Void

    @State private var lastHoverPoint: CGPoint?
    @State private var hoverEnabled = false

    private var items: [ClipItem] {
        store.filtered(query: state.searchText, showImages: !settings.hideImages)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(field: searchField, text: $state.searchText)
                layoutButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            list

            if updateChecker.updateAvailable, let url = updateChecker.releaseURL {
                Divider()
                Link("Update available: \(updateChecker.latestVersion ?? "")", destination: url)
                    .font(.caption)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .padding(shadowMargin)
        .onChange(of: state.searchText) { state.selectedIndex = 0 }
        .onChange(of: state.isOpen) {
            lastHoverPoint = nil
            hoverEnabled = false
        }
    }

    // MARK: - Layout

    private static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: PopupLayout.gridColumns
    )

    private var layoutButton: some View {
        let isGrid = settings.layout == .grid
        return Button {
            settings.layout = isGrid ? .list : .grid
        } label: {
            Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isGrid ? "Show as List (⌘L)" : "Show as Grid (⌘L)")
        .accessibilityLabel(isGrid ? "Show as List" : "Show as Grid")
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            if state.searchText.isEmpty {
                ContentUnavailableView("Nothing copied yet", systemImage: "list.clipboard")
            } else {
                ContentUnavailableView.search(text: state.searchText)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if settings.layout == .grid {
                            LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    tile(item, index: index).id(item.id)
                                }
                            }
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    row(item, index: index).id(item.id)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .onContinuousHover(perform: trackHover)
                .onChange(of: state.selectedIndex) { scrollToSelection(proxy) }
                .onChange(of: state.isOpen) { scrollToSelection(proxy) }
            }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let item = items[safe: state.selectedIndex] {
            proxy.scrollTo(item.id)
        }
    }

    /// The pointer often rests where the popup opens, so a row is only
    /// selected by hovering once the mouse has actually moved.
    private func trackHover(_ phase: HoverPhase) {
        guard case .active(let point) = phase else { return }
        if let last = lastHoverPoint, hypot(point.x - last.x, point.y - last.y) >= 6 {
            hoverEnabled = true
        } else if lastHoverPoint == nil {
            lastHoverPoint = point
        }
    }

    // MARK: - Row

    private func row(_ item: ClipItem, index: Int) -> some View {
        clipButton(item, index: index) {
            HStack(spacing: 10) {
                icon(for: item)

                previewText(item)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }

                Text(shortAge(item.date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func tile(_ item: ClipItem, index: Int) -> some View {
        clipButton(item, index: index) {
            VStack(spacing: 4) {
                Color.clear
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        if let thumbnail = store.thumbnail(for: item) {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            previewText(item, size: NSFont.smallSystemFontSize)
                                .lineLimit(5)
                                .padding(4)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 4) {
                    if let symbol = typeSymbol(for: item) {
                        Image(systemName: symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 0)
                    Text(shortAge(item.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(5)
        }
    }

    private func clipButton<Label: View>(
        _ item: ClipItem,
        index: Int,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            onPaste(item, false)
        } label: {
            label()
                .background {
                    if index == state.selectedIndex {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(item.sourceApp?.name ?? "")
        .onHover { hovering in
            if hovering && hoverEnabled { state.selectedIndex = index }
        }
        .contextMenu {
            Button("Paste") { onPaste(item, false) }
            Button("Paste as Plain Text") { onPaste(item, true) }
            if let url = item.linkURL {
                Button(item.textKind == .email ? "New Email" : "Open Link") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin") { onTogglePin(item) }
            Button("Delete", role: .destructive) { onRemove(item) }
        }
    }

    @ViewBuilder
    private func icon(for item: ClipItem) -> some View {
        Group {
            if let thumbnail = store.thumbnail(for: item) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(.rect(cornerRadius: 4))
            } else if let symbol = typeSymbol(for: item) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(item.textKind?.rawValue ?? "")
            } else if let appIcon = item.sourceApp?.icon {
                Image(nsImage: appIcon).resizable()
            } else {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func typeSymbol(for item: ClipItem) -> String? {
        switch item.textKind {
        case .link: "link"
        case .email: "envelope"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .plain, nil: nil
        }
    }

    private func previewText(_ item: ClipItem, size: CGFloat = NSFont.systemFontSize) -> Text {
        switch item.textKind {
        case .code:
            Text(item.preview).font(.system(size: size, design: .monospaced))
        case .link, .email:
            Text(item.preview).font(.system(size: size)).foregroundStyle(.link)
        case .plain, nil:
            Text(item.preview).font(.system(size: size))
        }
    }

    private func shortAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        case ..<604800: return "\(seconds / 86400)d"
        default: return "\(seconds / 604800)w"
        }
    }
}

/// Takes focus when first attached, since on the panel's first show it isn't in the window
/// yet when the controller focuses it.
final class SearchTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// An AppKit field, because the window controller has to focus it directly: the panel never
/// activates the app, and SwiftUI's focus requests don't reliably take effect in that state.
private struct SearchField: NSViewRepresentable {
    let field: SearchTextField
    @Binding var text: String

    func makeNSView(context: Context) -> SearchTextField {
        field.placeholderString = "Search"
        field.font = .preferredFont(forTextStyle: .title3)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
