import Foundation

/// Brings history over from when this app was called ClipHistory.
enum LegacyMigration {
    static let keychainService = "io.github.manan-santoki.cliphistory"

    private static var legacyDirectory: URL {
        ClipboardStore.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("ClipHistory", isDirectory: true)
    }

    static func moveHistory() {
        moveHistory(from: legacyDirectory, to: ClipboardStore.defaultDirectory)
    }

    /// Does nothing once the new folder has a history, so it can't overwrite newer clips.
    static func moveHistory(from legacy: URL, to current: URL) {
        let files = FileManager.default
        let index = "index.enc"
        guard files.fileExists(atPath: legacy.appendingPathComponent(index).path),
              !files.fileExists(atPath: current.appendingPathComponent(index).path)
        else { return }

        try? files.createDirectory(at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The index goes last: it marks the move as done, and clip files without one get cleaned up.
        for name in ["clips", index] {
            let target = current.appendingPathComponent(name)
            try? files.removeItem(at: target)
            try? files.moveItem(at: legacy.appendingPathComponent(name), to: target)
        }
    }
}
