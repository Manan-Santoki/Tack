import AppKit
import CryptoKit
import Foundation
import Security

/// Downloads, checks and swaps in a new version of the app.
///
/// A new build only gets installed if it's signed with the same certificate as the running
/// app, so a tampered download or a compromised release page can't replace it with anything else.
enum Updater {
    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let assets: [Asset]

        var version: String {
            tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        }

        func assetURL(named name: String) -> URL? {
            assets.first { $0.name == name }?.browser_download_url
        }
    }

    enum UpdateError: Error, Equatable {
        case missingAsset, checksumMismatch, invalidSignature, unsignedApp, commandFailed(String)
    }

    private static let dmgName = "Tack.dmg"

    /// Downloads a release and returns a verified copy of the new app, ready to install.
    static func stage(_ release: Release, replacing current: URL) async throws -> URL {
        guard let dmgURL = release.assetURL(named: dmgName),
              let checksumURL = release.assetURL(named: dmgName + ".sha256")
        else { throw UpdateError.missingAsset }

        let requirement = try requirement(ofAppAt: current)

        let (dmg, _) = try await URLSession.shared.download(from: dmgURL)
        defer { try? FileManager.default.removeItem(at: dmg) }
        let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
        try verifyChecksum(of: dmg, against: String(decoding: checksumData, as: UTF8.self))

        let files = FileManager.default
        // Same volume as the installed app, so the final swap is a simple rename.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        let mount = staging.appendingPathComponent("mount", isDirectory: true)
        let staged = staging.appendingPathComponent(current.lastPathComponent, isDirectory: true)
        try files.createDirectory(at: mount, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        try run("/usr/bin/ditto", [mount.appendingPathComponent(current.lastPathComponent).path, staged.path])

        try verify(appAt: staged, requirement: requirement)
        return staged
    }

    // MARK: - Verifying

    /// The expected value is a `shasum` line: the hash, then the file name.
    static func verifyChecksum(of file: URL, against expected: String) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard expected.split(whereSeparator: \.isWhitespace).first?.lowercased() == actual else {
            throw UpdateError.checksumMismatch
        }
    }

    /// What the app at this path has to satisfy: its identifier and signing certificate.
    /// Ad-hoc builds are refused, since their identity is only valid for that exact build.
    static func requirement(ofAppAt app: URL) throws -> SecRequirement {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError.unsignedApp }

        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        guard let text, (text as String).contains("certificate") else { throw UpdateError.unsignedApp }
        return requirement
    }

    static func verify(appAt app: URL, requirement: SecRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw UpdateError.invalidSignature }
    }

    // MARK: - Installing

    /// Swaps in the new app, putting the old one back if that fails partway.
    static func install(_ staged: URL, over current: URL) throws {
        let files = FileManager.default
        let backup = staged.deletingLastPathComponent().appendingPathComponent("previous-\(UUID().uuidString).app")
        try files.moveItem(at: current, to: backup)
        do {
            try files.moveItem(at: staged, to: current)
        } catch {
            try? files.moveItem(at: backup, to: current)
            throw error
        }
        try? files.removeItem(at: backup)
        try? files.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Opens the app again just after this copy has quit.
    static func scheduleRelaunch(of app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try process.run()
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(URL(fileURLWithPath: path).lastPathComponent)
        }
    }
}
