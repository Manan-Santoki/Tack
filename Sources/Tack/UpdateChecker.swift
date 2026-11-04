import AppKit
import Foundation
import Observation

/// Checks this project's GitHub releases at launch and every few hours, and installs new ones.
@MainActor
@Observable
final class UpdateChecker {
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static let checkInterval = Duration.seconds(6 * 60 * 60)
    private static let latestRelease = URL(string: "https://api.github.com/repos/Manan-Santoki/Tack/releases/latest")!

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?
    private(set) var status: String?

    @ObservationIgnored private var isInstalling = false
    @ObservationIgnored private var shouldInstall: () -> Bool = { false }
    @ObservationIgnored private var canRestart: () -> Bool = { true }

    var updateAvailable: Bool { latestVersion != nil }

    /// - Parameters:
    ///   - shouldInstall: Whether automatic updates are turned on.
    ///   - canRestart: False while the app is busy, such as when the popup is open.
    func start(shouldInstall: @escaping () -> Bool, canRestart: @escaping () -> Bool) {
        self.shouldInstall = shouldInstall
        self.canRestart = canRestart
        Task {
            while !Task.isCancelled {
                await check(install: shouldInstall())
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Checks right away and installs whatever it finds.
    func checkNow() {
        Task { await check(install: true, reportResult: true) }
    }

    private func check(install: Bool, reportResult: Bool = false) async {
        guard !isInstalling else { return }

        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONDecoder().decode(Updater.Release.self, from: data)
        else {
            if reportResult { status = "Couldn't check for updates." }
            return
        }

        guard Self.isNewer(release.version, than: Self.currentVersion) else {
            latestVersion = nil
            if reportResult { status = "Tack is up to date." }
            return
        }
        latestVersion = release.version
        releaseURL = release.html_url
        if install { await self.install(release) }
    }

    private func install(_ release: Updater.Release) async {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { return }

        isInstalling = true
        defer { isInstalling = false }
        status = "Downloading \(release.version)…"
        do {
            let staged = try await Updater.stage(release, replacing: current)
            status = "Installing \(release.version)…"
            // Don't restart in the middle of someone picking a clip.
            while !canRestart() {
                try await Task.sleep(for: .seconds(5))
            }
            try Updater.install(staged, over: current)
            try Updater.scheduleRelaunch(of: current)
            NSApp.terminate(nil)
        } catch {
            NSLog("Tack: update to \(release.version) failed: \(error)")
            status = "Couldn't install \(release.version) automatically."
        }
    }

    nonisolated static func isNewer(_ remote: String, than current: String) -> Bool {
        remote.compare(current, options: .numeric) == .orderedDescending
    }
}
