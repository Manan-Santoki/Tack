import AppKit
import ApplicationServices

/// Finds where the popup should open: the text cursor, else the focused input field,
/// else the mouse pointer. Not every app reports its cursor through Accessibility.
@MainActor
enum CaretLocator {
    /// Stops an unresponsive app from delaying the popup.
    private static let timeout: Float = 0.15
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Taller than this, a field is a whole editor, and its edge says little about the cursor.
    private static let maxFieldHeight: CGFloat = 120

    static func currentAnchor() -> NSRect {
        focusedAnchor() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    private static func focusedAnchor() -> NSRect? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        return caretRect(of: element) ?? fieldRect(of: element)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)

        var app: AXUIElement?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, timeout)
            // Electron apps only build their accessibility tree when asked. Others ignore this.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = element
        }

        return copyElement(systemWide, attribute: kAXFocusedUIElementAttribute)
            ?? app.flatMap { copyElement($0, attribute: kAXFocusedUIElementAttribute) }
    }

    // MARK: - Text cursor

    private static func caretRect(of element: AXUIElement) -> NSRect? {
        var selection = CFRange()
        guard let value = copyAXValue(element, attribute: kAXSelectedTextRangeAttribute),
              AXValueGetValue(value, .cfRange, &selection)
        else { return nil }

        // Measure a real character first. Empty ranges are unreliable: some apps return nothing,
        // and TextEdit reports a position one line too high.
        var count: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
        let length = (count as? Int) ?? 0

        if selection.location < length,
           let next = bounds(of: element, location: selection.location, length: 1) {
            return NSRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if selection.location > 0,
           let previous = bounds(of: element, location: selection.location - 1, length: 1) {
            if character(of: element, at: selection.location - 1)?.isNewline == true {
                // At the end of the text on a new line, so the cursor sits one line lower.
                let x = bounds(of: element, location: selection.location, length: 0)?.minX ?? previous.minX
                return NSRect(x: x, y: previous.minY - previous.height, width: 0, height: previous.height)
            }
            return NSRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return bounds(of: element, location: selection.location, length: 0)
    }

    private static func character(of element: AXUIElement, at location: Int) -> Character? {
        var range = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success else { return nil }
        return (result as? String)?.first
    }

    private static func bounds(of element: AXUIElement, location: Int, length: Int) -> NSRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return onScreen(PopupPlacement.appKitRect(fromAccessibility: rect, primaryScreenHeight: primaryScreenHeight))
    }

    // MARK: - Input field

    private static func fieldRect(of element: AXUIElement) -> NSRect? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard let role = role as? String, textRoles.contains(role),
              let positionValue = copyAXValue(element, attribute: kAXPositionAttribute),
              let sizeValue = copyAXValue(element, attribute: kAXSizeAttribute)
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.height > 0, size.height <= maxFieldHeight
        else { return nil }

        let rect = CGRect(origin: position, size: size)
        return onScreen(PopupPlacement.appKitRect(fromAccessibility: rect, primaryScreenHeight: primaryScreenHeight))
    }

    // MARK: - Helpers

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Some apps report a zero or off-screen rect instead of an error.
    private static func onScreen(_ rect: NSRect) -> NSRect? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.contains { $0.frame.contains(center) } ? rect : nil
    }

    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyAXValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}

/// Pure geometry for positioning the popup.
enum PopupPlacement {
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// Accessibility measures from the top-left of the primary screen; AppKit from its bottom-left.
    static func appKitRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Opens below the anchor, or above it when there's no room, always fully on screen.
    static func origin(anchor: NSRect, size: CGSize, visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - size.width - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - size.height - margin

        var y = anchor.minY - gap - size.height
        if y < minY { y = anchor.maxY + gap }

        return NSPoint(
            x: min(max(anchor.minX, minX), maxX),
            y: min(max(y, minY), maxY)
        )
    }
}
