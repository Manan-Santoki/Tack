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
