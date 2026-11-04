import AppKit

extension NSImage {
    /// The app icon's clipboard as a template image, so macOS can tint it for the menu bar.
    static let tackMenuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let board = NSRect(x: 3.25, y: 1, width: 11.5, height: 14)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: board, xRadius: 2.2, yRadius: 2.2).fill()

            // Cut a gap around the clip and the two text lines out of the board.
            let clip = NSRect(x: board.midX - 2.9, y: board.maxY - 1.3, width: 5.8, height: 2.9)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: clip.insetBy(dx: -1, dy: -1), xRadius: 2.4, yRadius: 2.4).fill()
            for (y, width) in [(CGFloat(7.4), CGFloat(6.6)), (CGFloat(4.3), CGFloat(4.2))] {
                let line = NSRect(x: board.minX + 2.45, y: y, width: width, height: 1.45)
                NSBezierPath(roundedRect: line, xRadius: 0.72, yRadius: 0.72).fill()
            }

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: clip, xRadius: 1.45, yRadius: 1.45).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
