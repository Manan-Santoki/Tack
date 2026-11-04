import Foundation
import Observation

/// Checks this fork's GitHub releases once per launch.
@MainActor
@Observable
final class UpdateChecker {
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?

    var updateAvailable: Bool { latestVersion != nil }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    func checkForUpdate() {
        Task {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Manan-Santoki/Tack/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = try? JSONDecoder().decode(Release.self, from: data)
            else { return }

            let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            if Self.isNewer(remote, than: Self.currentVersion) {
                latestVersion = remote
                releaseURL = release.html_url
            }
        }
    }

    nonisolated static func isNewer(_ remote: String, than current: String) -> Bool {
        remote.compare(current, options: .numeric) == .orderedDescending
    }
}
