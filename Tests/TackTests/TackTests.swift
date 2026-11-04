import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import Tack

// MARK: - Helpers

private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: .init("tack.test.\(UUID().uuidString)"))
}

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("tack-\(UUID().uuidString)")
}

private func makePNG(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Original formats

@Test func largeImageRoundTripsByteForByte() throws {
    let png = makePNG(width: 4000, height: 3000)
    let source = makePasteboard()
    source.clearContents()
    source.setData(png, forType: .png)

    let payload = try #require(ClipPayload(pasteboard: source))
    #expect(payload.kind == .image)

    let target = makePasteboard()
    payload.write(to: target)
    #expect(target.data(forType: .png) == png)

    let restoredData = try #require(target.data(forType: .png))
    let restored = try #require(NSBitmapImageRep(data: restoredData))
    #expect(restored.pixelsWide == 4000 && restored.pixelsHigh == 3000)
}

@Test func thumbnailIsSmallButOriginalIsKept() throws {
    let png = makePNG(width: 4000, height: 3000)
    let source = makePasteboard()
    source.clearContents()
    source.setData(png, forType: .png)

    let payload = try #require(ClipPayload(pasteboard: source))
    let thumbnailData = try #require(payload.makeThumbnail())
    let thumbnail = try #require(NSBitmapImageRep(data: thumbnailData))
    #expect(max(thumbnail.pixelsWide, thumbnail.pixelsHigh) <= 256)
    #expect(payload.allRepresentations.contains { $0.data == png })
}

@Test func richTextKeepsEveryFormat() throws {
    let rtf = Data("{\\rtf1\\ansi {\\b bold}}".utf8)
    let html = Data("<b>bold</b>".utf8)
    let privateType = NSPasteboard.PasteboardType("com.example.private")
    let privateData = Data([0, 1, 2, 3])

    let source = makePasteboard()
    source.clearContents()
    source.setData(rtf, forType: .rtf)
    source.setData(html, forType: .html)
    source.setString("bold", forType: .string)
    source.setData(privateData, forType: privateType)

    let payload = try #require(ClipPayload(pasteboard: source))
    #expect(payload.kind == .text("bold"))

    let target = makePasteboard()
    payload.write(to: target)
    #expect(target.data(forType: .rtf) == rtf)
    #expect(target.data(forType: .html) == html)
    #expect(target.string(forType: .string) == "bold")
    #expect(target.data(forType: privateType) == privateData)
}

@Test func multipleFilesStayAsFiles() throws {
    let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.zip")]
    let source = makePasteboard()
    source.clearContents()
    source.writeObjects(urls as [NSURL])

    let payload = try #require(ClipPayload(pasteboard: source))
    #expect(payload.kind == .files(["a.pdf", "b.zip"]))

    let target = makePasteboard()
    payload.write(to: target)
    let restored = target.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    #expect(restored == urls)
}

@Test(arguments: ClipPayload.ignoredTypes)
func sensitiveClipsAreNotCaptured(marker: String) {
    let source = makePasteboard()
    source.clearContents()
    source.setString("secret", forType: .string)
    source.setData(Data(), forType: .init(marker))
    #expect(ClipPayload(pasteboard: source) == nil)
}

@Test(arguments: ClipPayload.ignoredTypes)
func sensitiveClipsAreCapturedWhenAllowed(marker: String) throws {
    let source = makePasteboard()
    source.clearContents()
    source.setString("secret", forType: .string)
    source.setData(Data(), forType: .init(marker))
    let payload = try #require(ClipPayload(pasteboard: source, includeSensitive: true))
    #expect(payload.kind == .text("secret"))
}

@Test func blankTextIsNotListed() throws {
    let source = makePasteboard()
    source.clearContents()
    source.setString("  \n ", forType: .string)
    #expect(try #require(ClipPayload(pasteboard: source)).kind == nil)
}

// MARK: - Store

@MainActor
@Test func storedClipsSurviveReopenAndStayEncrypted() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let marker = "findable-plaintext-marker"

    let source = makePasteboard()
    source.clearContents()
    source.setString(marker, forType: .string)
    source.setData(Data("<i>\(marker)</i>".utf8), forType: .html)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: key)
    store.capture(from: source)
    store.saveNow()

    let reopened = ClipboardStore(maxCount: 10, directory: directory, key: key)
    let item = try #require(reopened.items.first)
    let target = makePasteboard()
    reopened.restore(item, to: target)
    #expect(target.string(forType: .string) == marker)
    #expect(target.data(forType: .html) == Data("<i>\(marker)</i>".utf8))

    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    for file in files where file.pathExtension == "enc" {
        let contents = try Data(contentsOf: file)
        #expect(contents.range(of: Data(marker.utf8)) == nil)
    }
}

@MainActor
@Test func wrongKeyLeavesStoredClipsUntouched() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)

    let source = makePasteboard()
    source.clearContents()
    source.setString("keep me", forType: .string)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: key)
    store.capture(from: source)
    store.saveNow()

    let locked = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))
    #expect(locked.items.isEmpty)

    let reopened = ClipboardStore(maxCount: 10, directory: directory, key: key)
    let item = try #require(reopened.items.first)
    let target = makePasteboard()
    reopened.restore(item, to: target)
    #expect(target.string(forType: .string) == "keep me")
}

@MainActor
@Test func plainTextPasteDropsFormatting() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = makePasteboard()
    source.clearContents()
    source.setString("hello", forType: .string)
    source.setData(Data("<b>hello</b>".utf8), forType: .html)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))
    store.capture(from: source)

    let target = makePasteboard()
    store.restore(try #require(store.items.first), asPlainText: true, to: target)
    #expect(target.string(forType: .string) == "hello")
    #expect(target.data(forType: .html) == nil)
}

@MainActor
@Test func ownPasteIsNotRecordedAgain() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("first", forType: .string)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))
    store.capture(from: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("second", forType: .string)
    store.capture(from: pasteboard)

    let first = try #require(store.items.last)
    store.restore(first, to: pasteboard)
    store.capture(from: pasteboard)
    #expect(store.items.first?.kind == .text("second"))
}

@MainActor
@Test func recopyingMovesClipToTopWithoutDuplicating() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pasteboard = makePasteboard()
    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))

    for text in ["a", "b", "a"] {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.capture(from: pasteboard)
    }
    #expect(store.items.map(\.kind) == [.text("a"), .text("b")])
}

@MainActor
@Test func pinsAreKeptAndTrimmedClipFilesAreDeleted() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pasteboard = makePasteboard()
    let store = ClipboardStore(maxCount: 5, directory: directory, key: SymmetricKey(size: .bits256))

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.capture(from: pasteboard)
    }

    copy("pinned")
    store.togglePin(id: try #require(store.items.first).id)
    for index in 0..<8 { copy("clip \(index)") }
    store.saveNow()

    #expect(store.items.first?.kind == .text("pinned"))
    #expect(store.items.count == 6)
    let blobs = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("clips").path)
    #expect(blobs.count == 6)
}

// MARK: - Migration

@MainActor
@Test func historyMovesFromTheOldFolderOnce() throws {
    let old = makeDirectory()
    let new = makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: new)
    }
    let key = SymmetricKey(size: .bits256)
    let source = makePasteboard()
    source.clearContents()
    source.setString("carried over", forType: .string)
    source.setData(Data("<b>carried over</b>".utf8), forType: .html)

    let store = ClipboardStore(maxCount: 10, directory: old, key: key)
    store.capture(from: source)
    store.saveNow()

    LegacyMigration.moveHistory(from: old, to: new)
    let moved = ClipboardStore(maxCount: 10, directory: new, key: key)
    let item = try #require(moved.items.first)
    let target = makePasteboard()
    moved.restore(item, to: target)
    #expect(target.data(forType: .html) == Data("<b>carried over</b>".utf8))

    // A second run with leftovers must not replace newer history.
    source.clearContents()
    source.setString("newer", forType: .string)
    moved.capture(from: source)
    moved.saveNow()
    let stale = ClipboardStore(maxCount: 10, directory: old, key: key)
    stale.capture(from: target)
    stale.saveNow()
    LegacyMigration.moveHistory(from: old, to: new)
    let again = ClipboardStore(maxCount: 10, directory: new, key: key)
    #expect(again.items.first?.kind == .text("newer"))
}

// MARK: - Placement

private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
private let popup = CGSize(width: 360, height: 400)

@Test func opensBelowCaretAlignedToIt() {
    let anchor = NSRect(x: 200, y: 600, width: 0, height: 16)
    #expect(PopupPlacement.origin(anchor: anchor, size: popup, visibleFrame: screen) == NSPoint(x: 200, y: 194))
}

@Test func opensAboveWhenNoRoomBelow() {
    let anchor = NSRect(x: 200, y: 100, width: 0, height: 16)
    #expect(PopupPlacement.origin(anchor: anchor, size: popup, visibleFrame: screen) == NSPoint(x: 200, y: 122))
}

@Test func staysOnScreenAtRightEdge() {
    let anchor = NSRect(x: 990, y: 600, width: 0, height: 16)
    #expect(PopupPlacement.origin(anchor: anchor, size: popup, visibleFrame: screen).x == 632)
}

@Test func staysOnScreenWhenNeitherSideFits() {
    let short = NSRect(x: 0, y: 0, width: 1000, height: 420)
    let anchor = NSRect(x: 100, y: 200, width: 0, height: 16)
    let origin = PopupPlacement.origin(anchor: anchor, size: popup, visibleFrame: short)
    #expect(origin.y >= 8 && origin.y + popup.height <= 420)
}

@Test func convertsAccessibilityCoordinates() {
    let rect = PopupPlacement.appKitRect(fromAccessibility: CGRect(x: 10, y: 20, width: 5, height: 16), primaryScreenHeight: 800)
    #expect(rect == NSRect(x: 10, y: 764, width: 5, height: 16))
}

// MARK: - Detection

@Test(arguments: [
    "https://www.instagram.com/p/DfQV6ZgiAua/?rpxt=abc",
    "http://localhost:3000/health",
    "www.example.com",
    "example.com",
    "github.com/Manan-Santoki/Tack",
    "  https://example.com  \n",
])
func detectsLinks(text: String) {
    #expect(TextClassifier.classify(text) == .link)
}

@Test func detectsEmail() {
    #expect(TextClassifier.classify("someone@example.com") == .email)
}

@Test(arguments: [
    "let total = items.count",
    "import Foundation",
    "func add(a: Int) -> Int {\n    return a + 1;\n}",
    "def main():\n    print(\"hi\")",
    "const x = () => 1;",
    "{\"name\": \"clip\", \"count\": 2}",
    "[1, 2, 3]",
    "git status",
    "npm install react",
    "$ ls -la",
    "SELECT id FROM users WHERE id = 1",
    "<div class=\"row\">hello</div>",
])
func detectsCode(text: String) {
    #expect(TextClassifier.classify(text) == .code)
}

@Test(arguments: [
    "CLIPTEST plain text for search",
    "Hello, how are you?",
    "I think we should import more coffee.",
    "Let me know if that works for you",
    "Return the form by Friday",
    "For example, see the notes below.",
    "main.py",
    "README.md",
    "Dear team,\nPlease review the attached notes.\nThanks,\nSam",
    "Version 2 is out (finally)",
    "",
])
func leavesPlainTextAlone(text: String) {
    #expect(TextClassifier.classify(text) == .plain)
}

@Test func bareLinkOpensOverHTTPS() {
    #expect(TextClassifier.url(for: "example.com", kind: .link)?.absoluteString == "https://example.com")
    #expect(TextClassifier.url(for: "http://a.com", kind: .link)?.absoluteString == "http://a.com")
    #expect(TextClassifier.url(for: "a@b.com", kind: .email)?.absoluteString == "mailto:a@b.com")
    #expect(TextClassifier.url(for: "hello", kind: .plain) == nil)
}

@MainActor
@Test func searchFindsClipsByTypeAndPasteIsUnchanged() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pasteboard = makePasteboard()
    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))

    for text in ["  https://example.com/a  ", "let x = 1", "just words"] {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.capture(from: pasteboard)
    }
    #expect(store.filtered(query: "code").map(\.textKind) == [.code])
    #expect(store.filtered(query: "link").map(\.textKind) == [.link])

    let link = try #require(store.filtered(query: "link").first)
    let target = makePasteboard()
    store.restore(link, to: target)
    #expect(target.string(forType: .string) == "  https://example.com/a  ")
}

// MARK: - Search

private func fuzzyMatches(_ query: String, _ text: String, typos: Bool = false) -> Bool {
    FuzzySearch.score(tokens: FuzzySearch.tokens(in: query), in: FuzzySearch.fold(text), allowTypos: typos) != nil
}

@Test(arguments: [
    ("gtst", "git status"),
    ("STATUS", "git status"),
    ("resume", "Résumé final"),
    ("clipbrd", "clipboard manager"),
    ("status git", "git status"),
])
func findsLettersInOrder(query: String, text: String) {
    #expect(fuzzyMatches(query, text))
}

@Test(arguments: [
    ("zzzz", "git status"),
    ("stg", "git status"),
    ("git zebra", "git status"),
    ("ab", "a long way to b"),
])
func rejectsPoorMatches(query: String, text: String) {
    #expect(!fuzzyMatches(query, text))
}

@Test(arguments: [("stauts", "git status"), ("recieve", "please receive this"), ("swtich", "network switch")])
func typosMatchOnlyWhenAllowed(query: String, text: String) {
    #expect(!fuzzyMatches(query, text))
    #expect(fuzzyMatches(query, text, typos: true))
}

@MainActor
private func makeStore(with texts: [String], key: SymmetricKey = SymmetricKey(size: .bits256), in directory: URL) -> ClipboardStore {
    let store = ClipboardStore(maxCount: 1000, directory: directory, key: key)
    let pasteboard = makePasteboard()
    for text in texts {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.capture(from: pasteboard)
    }
    return store
}

@MainActor
@Test func bestMatchesComeFirst() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The loosest match is copied last, so plain recency would put it first.
    let store = makeStore(with: ["my status report", "unstatused", "s t a t u s x"], in: directory)
    let results = store.filtered(query: "status").map(\.kind)
    #expect(results.first == .text("my status report"))
    #expect(results.contains(.text("unstatused")))
}

@MainActor
@Test func typoSearchFindsClipWhenNothingElseMatches() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(with: ["git status", "unrelated words"], in: directory)
    #expect(store.filtered(query: "stauts").map(\.kind) == [.text("git status")])
}

@MainActor
@Test func wholeClipIsSearchableAndStaysEncrypted() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let marker = "deepmarkerword"
    let long = String(repeating: "filler text ", count: 20_000) + marker

    let store = makeStore(with: [long], key: key, in: directory)
    #expect(store.filtered(query: marker).count == 1)
    store.saveNow()

    let reopened = ClipboardStore(maxCount: 10, directory: directory, key: key)
    await reopened.finishIndexing()
    #expect(reopened.filtered(query: marker).count == 1)

    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    #expect(files.contains { $0.path.contains("/search/") })
    for file in files where file.pathExtension == "enc" {
        #expect(try Data(contentsOf: file).range(of: Data(marker.utf8)) == nil)
    }
}

@MainActor
@Test func clipsSavedBeforeSearchFilesExistGetIndexed() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let marker = "olderclipmarker"
    let store = makeStore(with: [String(repeating: "padding ", count: 1000) + marker], key: key, in: directory)
    store.saveNow()
    try FileManager.default.removeItem(at: directory.appendingPathComponent("search"))

    let reopened = ClipboardStore(maxCount: 10, directory: directory, key: key)
    await reopened.finishIndexing()
    #expect(reopened.filtered(query: marker).count == 1)
}

@MainActor
@Test func deletingAClipRemovesItsSearchFile() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(with: ["goes away"], in: directory)
    store.remove(id: try #require(store.items.first).id)
    store.saveNow()
    let search = directory.appendingPathComponent("search")
    #expect(try FileManager.default.contentsOfDirectory(atPath: search.path).isEmpty)
    #expect(store.filtered(query: "goes").isEmpty)
}

private func makeImageWithText(_ text: String) throws -> Data {
    let image = NSImage(size: NSSize(width: 1200, height: 300), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        (text as NSString).draw(at: NSPoint(x: 60, y: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        return true
    }
    let tiff = try #require(image.tiffRepresentation)
    return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
}

@MainActor
@Test func imagesAreSearchableByTheirText() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let source = makePasteboard()
    source.clearContents()
    source.setData(try makeImageWithText("INVOICE 4821"), forType: .png)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: key)
    store.capture(from: source)
    #expect(store.filtered(query: "invoice").isEmpty)
    await store.finishIndexing()
    #expect(store.filtered(query: "invoice").count == 1)
    #expect(store.filtered(query: "4821").count == 1)
    store.saveNow()

    let reopened = ClipboardStore(maxCount: 10, directory: directory, key: key)
    await reopened.finishIndexing()
    #expect(reopened.filtered(query: "invoice").map(\.isImage) == [true])
}

@MainActor
@Test func recognizedTextDoesNotChangeThePastedImage() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = try makeImageWithText("RECEIPT")
    let source = makePasteboard()
    source.clearContents()
    source.setData(png, forType: .png)

    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))
    store.capture(from: source)
    await store.finishIndexing()

    let target = makePasteboard()
    store.restore(try #require(store.items.first), to: target)
    #expect(target.data(forType: .png) == png)
    #expect(target.string(forType: .string) == nil)
}

@MainActor
@Test func searchStaysFastAcrossAFullHistory() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let body = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 90)
    let store = makeStore(with: (0..<500).map { "\($0) \(body)" }, in: directory)
    #expect(store.items.count == 500)

    for query in ["jmps", "qzxv nothing", "stauts lazzy", "brown fox"] {
        let started = ContinuousClock.now
        _ = store.filtered(query: query)
        let elapsed = started.duration(to: .now)
        print("search-timing \(query): \(elapsed)")
        #expect(elapsed < .seconds(5))
    }
}

// MARK: - Popup layout

@MainActor
private func searchFieldTopGap(query: String, layout: PopupLayout = .list) throws -> CGFloat {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "tack.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    settings.layout = layout
    let state = PopupState()
    state.searchText = query
    let field = SearchTextField()
    let host = NSHostingView(rootView: PopupView(
        store: ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256)),
        settings: settings,
        state: state,
        searchField: field,
        shadowMargin: 40,
        updateChecker: UpdateChecker(),
        onPaste: { _, _ in },
        onTogglePin: { _ in },
        onRemove: { _ in }
    ))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 480)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    host.layoutSubtreeIfNeeded()

    #expect(field.window != nil)
    let frame = field.convert(field.bounds, to: host)
    return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
}

@MainActor
@Test(arguments: ["", "no clip matches this"])
func searchFieldStaysAtTopWithNothingToShow(query: String) throws {
    // 40 of shadow margin plus the search row's padding.
    #expect(try searchFieldTopGap(query: query) < 70)
}

@MainActor
@Test func wideThumbnailStaysInsideItsSlot() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "tack.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // A pure red, very wide image, so its pixels are easy to find in the render.
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 200,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    for x in 0..<2000 {
        for y in 0..<200 {
            rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
        }
    }
    let source = makePasteboard()
    source.clearContents()
    source.setData(try #require(rep.representation(using: .png, properties: [:])), forType: .png)
    let store = ClipboardStore(maxCount: 10, directory: directory, key: SymmetricKey(size: .bits256))
    store.capture(from: source)

    let host = NSHostingView(rootView: PopupView(
        store: store,
        settings: AppSettings(defaults: defaults),
        state: PopupState(),
        searchField: SearchTextField(),
        shadowMargin: 0,
        updateChecker: UpdateChecker(),
        onPaste: { _, _ in },
        onTogglePin: { _ in },
        onRemove: { _ in }
    ))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    // Rows are built lazily, so keep rendering until the image shows up.
    var redWidth: CGFloat?
    for _ in 0..<40 where redWidth == nil {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        redWidth = try redPixelWidth(in: host)
    }
    let width = try #require(redWidth, "the thumbnail should be visible")
    #expect(width <= 24)
}

@MainActor
private func redPixelWidth(in host: NSView) throws -> CGFloat? {
    let render = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: render)
    let scale = CGFloat(render.pixelsWide) / host.bounds.width

    var minX: Int?
    var maxX: Int?
    for y in 0..<render.pixelsHigh {
        for x in 0..<render.pixelsWide {
            guard let color = render.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.redComponent > 0.7, color.greenComponent < 0.45, color.blueComponent < 0.45
            else { continue }
            minX = min(minX ?? x, x)
            maxX = max(maxX ?? x, x)
        }
    }
    guard let minX, let maxX else { return nil }
    return CGFloat(maxX - minX + 1) / scale
}

// MARK: - Settings

@MainActor
@Test func loadingSettingsDoesNotWipeThem() throws {
    let suite = "tack.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    settings.maxItems = 120
    settings.hideImages = true
    settings.excludedBundleIDs = ["com.example.secret"]

    settings.layout = .grid
    settings.recordFromOtherDevices = false
    settings.recordSensitive = true

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.layout == .grid)
    #expect(!reloaded.recordFromOtherDevices)
    #expect(reloaded.recordSensitive)
    #expect(reloaded.maxItems == 120)
    #expect(reloaded.hideImages)
    #expect(reloaded.excludedBundleIDs == ["com.example.secret"])

    let again = AppSettings(defaults: defaults)
    #expect(again.excludedBundleIDs == ["com.example.secret"])
}

@MainActor
@Test func otherDevicesAreRecordedByDefault() throws {
    let suite = "tack.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.recordFromOtherDevices)
    #expect(!settings.recordSensitive)
}

@Test func comparesVersionsNumerically() {
    #expect(UpdateChecker.isNewer("2.10.0", than: "2.9.0"))
    #expect(!UpdateChecker.isNewer("2.0.0", than: "2.0.0"))
    #expect(!UpdateChecker.isNewer("1.9.9", than: "2.0.0"))
}
