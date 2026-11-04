import AppKit
import CryptoKit
import Observation
import Security

// MARK: - Source app

struct SourceApp: Codable, Equatable, Sendable {
    let bundleID: String
    let name: String

    var icon: NSImage? {
        if let hit = Self.iconCache.object(forKey: bundleID as NSString) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    // NSCache is thread-safe.
    private nonisolated(unsafe) static let iconCache = NSCache<NSString, NSImage>()
}

// MARK: - Clip item

/// What the list needs to show a clip. The clip's full data lives in its own encrypted file.
struct ClipItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let kind: ClipKind
    let thumbnail: Data?
    let contentHash: String
    var date = Date.now
    var sourceApp: SourceApp?
    var pinned = false

    var preview: String {
        switch kind {
        case .text(let text): text
        case .image: "Image"
        case .files(let names): names.count == 1 ? names[0] : "\(names.count) files: \(names.joined(separator: ", "))"
        case .other(let description): description
        }
    }

    var isImage: Bool { kind == .image }
}

// MARK: - Store

@MainActor
@Observable
final class ClipboardStore {
    private(set) var items: [ClipItem] = []

    private var maxCount: Int
    /// The change count of our own last paste, so it isn't recorded as a new copy.
    private var ownChangeCount: Int?
    private var pendingSave: Task<Void, Never>?

    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private let directory: URL
    private let blobDirectory: URL
    private let key: SymmetricKey

    // All disk access is serial, so reading a clip always sees its finished write.
    private let diskQueue = DispatchQueue(label: "cliphistory.disk", qos: .utility)

    private var indexURL: URL { directory.appendingPathComponent("index.enc") }

    init(maxCount: Int, directory: URL = ClipboardStore.defaultDirectory, key: SymmetricKey? = nil) {
        // If the Keychain refuses the key, run from a temporary folder until the next
        // launch. The saved history can't be read, but it stays intact for when it can.
        let resolvedKey = key ?? ClipboardStore.loadOrCreateKey()
        let directory = resolvedKey == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ClipHistory-\(UUID().uuidString)")
            : directory

        self.maxCount = maxCount
        self.directory = directory
        self.blobDirectory = directory.appendingPathComponent("clips", isDirectory: true)
        self.key = resolvedKey ?? SymmetricKey(size: .bits256)
        try? FileManager.default.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHistory", isDirectory: true)
    }

    // MARK: - Capture

    func capture(from pasteboard: NSPasteboard = .general, source: SourceApp? = nil) {
        guard pasteboard.changeCount != ownChangeCount,
              let payload = ClipPayload(pasteboard: pasteboard),
              let kind = payload.kind
        else { return }

        let hash = payload.contentHash
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            items[index].date = .now
            items.insert(items.remove(at: index), at: 0)
        } else {
            let item = ClipItem(kind: kind, thumbnail: payload.makeThumbnail(), contentHash: hash, sourceApp: source)
            items.insert(item, at: 0)
            writeBlob(payload, id: item.id)
        }
        pinnedFirst()
        trimToLimit()
        scheduleSave()
    }

    // MARK: - Paste

    /// Puts a clip back on the pasteboard exactly as it was copied, or as plain text only.
    func restore(_ item: ClipItem, asPlainText: Bool = false, to pasteboard: NSPasteboard = .general) {
        let payload = readBlob(id: item.id)
        let plainText = payload?.plainText ?? {
            if case .text(let text) = item.kind { return text }
            return nil
        }()

        if let payload, !asPlainText || plainText == nil {
            payload.write(to: pasteboard)
        } else if let plainText {
            pasteboard.clearContents()
            pasteboard.setString(plainText, forType: .string)
        } else {
            return
        }
        ownChangeCount = pasteboard.changeCount
    }

    // MARK: - Editing

    func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        pinnedFirst()
        trimToLimit()
        scheduleSave()
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        forget(items.remove(at: index))
        scheduleSave()
    }

    func clearAll() {
        items.forEach(forget)
        items = []
        saveNow()
    }

    func updateMaxCount(_ count: Int) {
        maxCount = count
        trimToLimit()
        scheduleSave()
    }

    // MARK: - Reading

    func filtered(query: String, showImages: Bool = true) -> [ClipItem] {
        items.filter { item in
            guard showImages || !item.isImage else { return false }
            guard !query.isEmpty else { return true }
            return item.preview.localizedCaseInsensitiveContains(query)
                || item.sourceApp?.name.localizedCaseInsensitiveContains(query) == true
        }
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = item.id as NSUUID
        if let hit = thumbnailCache.object(forKey: key) { return hit }
        guard let data = item.thumbnail, let image = NSImage(data: data) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - List upkeep

    private func pinnedFirst() {
        items = items.filter(\.pinned) + items.filter { !$0.pinned }
    }

    /// Only unpinned clips are evicted; pins stay until removed by hand.
    private func trimToLimit() {
        var unpinnedSeen = 0
        items.removeAll { item in
            guard !item.pinned else { return false }
            unpinnedSeen += 1
            guard unpinnedSeen > maxCount else { return false }
            forget(item)
            return true
        }
    }

    private func forget(_ item: ClipItem) {
        thumbnailCache.removeObject(forKey: item.id as NSUUID)
        let url = blobURL(id: item.id)
        diskQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Clip files

    private func blobURL(id: UUID) -> URL {
        blobDirectory.appendingPathComponent(id.uuidString + ".enc")
    }

    private func writeBlob(_ payload: ClipPayload, id: UUID) {
        let url = blobURL(id: id)
        let key = key
        diskQueue.async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let plain = try? encoder.encode(payload) else { return }
            Self.seal(plain, key: key, to: url)
        }
    }

    private func readBlob(id: UUID) -> ClipPayload? {
        let url = blobURL(id: id)
        let key = key
        return diskQueue.sync {
            guard let plain = Self.open(url, key: key) else { return nil }
            return try? PropertyListDecoder().decode(ClipPayload.self, from: plain)
        }
    }

    // MARK: - Index

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        pendingSave = nil
        guard let plain = try? JSONEncoder().encode(items) else { return }
        let url = indexURL
        let key = key
        diskQueue.async { Self.seal(plain, key: key, to: url) }
    }

    /// Writes everything now and waits until it's on disk.
    func saveNow() {
        pendingSave?.cancel()
        save()
        diskQueue.sync {}
    }

    private func load() {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            // An unreadable index says nothing about which clip files are in use, so keep them all.
            guard let plain = Self.open(indexURL, key: key),
                  let saved = try? JSONDecoder().decode([ClipItem].self, from: plain)
            else { return }
            items = saved
        }
        removeOrphanedBlobs()
    }

    /// Clip files with no index entry are left over from a crash before the index saved.
    private func removeOrphanedBlobs() {
        let known = Set(items.map(\.id.uuidString))
        let files = (try? FileManager.default.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !known.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Encryption

    private nonisolated static func seal(_ plain: Data, key: SymmetricKey, to url: URL) {
        guard let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private nonisolated static func open(_ url: URL, key: SymmetricKey) -> Data? {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed)
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: - Keychain

    /// Returns nil when a key exists but the Keychain won't release it, for example when denied.
    private nonisolated static func loadOrCreateKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "io.github.manan-santoki.cliphistory",
            kSecAttrAccount: "history-encryption-key",
        ]

        var lookup = query
        lookup[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            NSLog("ClipHistory: Keychain denied the history key: \(status)")
            return nil
        }

        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}
