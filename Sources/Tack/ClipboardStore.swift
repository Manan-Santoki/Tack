import AppKit
import CryptoKit
import Observation

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
    /// Nil for clips that aren't text.
    var textKind: TextKind?

    /// The address behind a link or email clip.
    var linkURL: URL? {
        guard case .text(let text) = kind, let textKind else { return nil }
        return TextClassifier.url(for: text, kind: textKind)
    }

    mutating func classify() {
        if case .text(let text) = kind { textKind = TextClassifier.classify(text) }
    }

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
    private(set) var items: [ClipItem] = [] {
        didSet { lastSearch = nil }
    }
    /// Bumped as text arrives from background indexing, so an open popup refreshes its results.
    private(set) var searchGeneration = 0

    /// Everything searchable about each clip, kept only in memory.
    @ObservationIgnored private var searchIndex: [UUID: [UInt16]] = [:]
    /// The popup asks for results several times per update, so the latest search is kept.
    @ObservationIgnored private var lastSearch: (query: String, showImages: Bool, results: [ClipItem])?
    @ObservationIgnored private var indexingTasks: [Task<Void, Never>] = []

    private var maxCount: Int
    /// The change count of our own last paste, so it isn't recorded as a new copy.
    private var ownChangeCount: Int?
    private var pendingSave: Task<Void, Never>?

    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private let directory: URL
    private let blobDirectory: URL
    private let searchDirectory: URL
    private let key: SymmetricKey

    // All disk access is serial, so reading a clip always sees its finished write.
    private let diskQueue = DispatchQueue(label: "tack.disk", qos: .utility)

    private var indexURL: URL { directory.appendingPathComponent("index.enc") }

    init(maxCount: Int, directory: URL = ClipboardStore.defaultDirectory, key: SymmetricKey? = nil) {
        // If the key can't be loaded, run from a temporary folder until the next
        // launch. The saved history can't be read, but it stays intact for when it can.
        let resolvedKey = key ?? HistoryKey.loadOrCreate(in: directory)
        let directory = resolvedKey == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Tack-\(UUID().uuidString)")
            : directory

        self.maxCount = maxCount
        self.directory = directory
        self.blobDirectory = directory.appendingPathComponent("clips", isDirectory: true)
        self.searchDirectory = directory.appendingPathComponent("search", isDirectory: true)
        self.key = resolvedKey ?? SymmetricKey(size: .bits256)
        for folder in [blobDirectory, searchDirectory] {
            try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tack", isDirectory: true)
    }

    // MARK: - Capture

    func capture(from pasteboard: NSPasteboard = .general, source: SourceApp? = nil, includeSensitive: Bool = false) {
        guard pasteboard.changeCount != ownChangeCount,
              let payload = ClipPayload(pasteboard: pasteboard, includeSensitive: includeSensitive),
              let kind = payload.kind
        else { return }

        let hash = payload.contentHash
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            items[index].date = .now
            items.insert(items.remove(at: index), at: 0)
        } else {
            var item = ClipItem(kind: kind, thumbnail: payload.makeThumbnail(), contentHash: hash, sourceApp: source)
            item.classify()
            items.insert(item, at: 0)
            writeBlob(payload, id: item.id)
            index(item, payload: payload)
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

    /// With a search, the best matches come first. Without one, the list keeps its usual order.
    func filtered(query: String, showImages: Bool = true) -> [ClipItem] {
        _ = searchGeneration
        let candidates = showImages ? items : items.filter { !$0.isImage }
        let tokens = FuzzySearch.tokens(in: query)
        guard !tokens.isEmpty else { return candidates }

        if let lastSearch, lastSearch.query == query, lastSearch.showImages == showImages {
            return lastSearch.results
        }

        var matches = rank(candidates, tokens: tokens, allowTypos: false)
        // Typo matching is slower and looser, so it's only for searches that found very little.
        if matches.count < 3, FuzzySearch.canMatchTypos(tokens) {
            matches = rank(candidates, tokens: tokens, allowTypos: true)
        }
        lastSearch = (query, showImages, matches)
        return matches
    }

    private func rank(_ candidates: [ClipItem], tokens: [[UInt16]], allowTypos: Bool) -> [ClipItem] {
        candidates.enumerated()
            .compactMap { position, item -> (item: ClipItem, score: Int, position: Int)? in
                let text = searchIndex[item.id] ?? searchKey(for: item, text: nil)
                guard let score = FuzzySearch.score(tokens: tokens, in: text, allowTypos: allowTypos) else { return nil }
                return (item, score, position)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
            .map(\.item)
    }

    /// Resolves once all text recognition and loading of searchable text has finished.
    func finishIndexing() async {
        while let task = indexingTasks.popLast() {
            await task.value
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
        searchIndex[item.id] = nil
        let urls = [blobURL(id: item.id), searchURL(id: item.id)]
        diskQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Search index

    private func searchURL(id: UUID) -> URL {
        searchDirectory.appendingPathComponent(id.uuidString + ".enc")
    }

    private func searchKey(for item: ClipItem, text: String?) -> [UInt16] {
        let parts = [text ?? item.preview, text == nil ? nil : item.preview, item.sourceApp?.name, item.textKind?.searchName]
        return FuzzySearch.fold(parts.compactMap { $0 }.joined(separator: "\n"))
    }

    /// Makes a new clip searchable: its text right away, the text in an image once it's been read.
    private func index(_ item: ClipItem, payload: ClipPayload) {
        guard payload.needsTextRecognition else {
            applySearchText(payload.plainText ?? "", to: item.id)
            return
        }
        searchIndex[item.id] = searchKey(for: item, text: nil)
        let id = item.id
        indexingTasks.append(Task.detached(priority: .utility) { [weak self] in
            let text = payload.recognizedText() ?? ""
            await self?.applySearchText(text, to: id)
        })
    }

    private func applySearchText(_ text: String, to id: UUID, persist: Bool = true) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        searchIndex[id] = searchKey(for: item, text: text.isEmpty ? nil : text)
        lastSearch = nil
        searchGeneration &+= 1

        guard persist else { return }
        let url = searchURL(id: id)
        let key = key
        diskQueue.async { Self.seal(Data(text.utf8), key: key, to: url) }
    }

    /// Loads searchable text for saved clips, working it out for any clip that doesn't have it yet.
    private func loadSearchIndex() {
        for item in items {
            searchIndex[item.id] = searchKey(for: item, text: nil)
        }
        let saved = items.map(\.id)
        let searchDirectory = searchDirectory
        let blobDirectory = blobDirectory
        let key = key
        indexingTasks.append(Task.detached(priority: .utility) { [weak self] in
            for id in saved {
                let name = id.uuidString + ".enc"
                if let data = Self.open(searchDirectory.appendingPathComponent(name), key: key) {
                    let text = String(decoding: data, as: UTF8.self)
                    await self?.applySearchText(text, to: id, persist: false)
                } else if let plain = Self.open(blobDirectory.appendingPathComponent(name), key: key),
                          let payload = try? PropertyListDecoder().decode(ClipPayload.self, from: plain) {
                    let text = payload.needsTextRecognition ? payload.recognizedText() : payload.plainText
                    await self?.applySearchText(text ?? "", to: id)
                }
            }
        })
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
            // Clips saved before detection existed have no type yet.
            for index in items.indices where items[index].textKind == nil {
                items[index].classify()
            }
        }
        removeOrphanedBlobs()
        loadSearchIndex()
    }

    /// Clip files with no index entry are left over from a crash before the index saved.
    private func removeOrphanedBlobs() {
        let known = Set(items.map(\.id.uuidString))
        for folder in [blobDirectory, searchDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !known.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
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
}
