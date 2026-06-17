import AppKit
import Foundation
import ForelCore

/// Checks GitHub Releases for a newer tagged version and surfaces it to the
/// UI. Forel ships ad-hoc signed (no Apple Developer ID, not notarized), so
/// unlike Sparkle this never installs anything in place — it only detects an
/// update and hands the user the release page to download and reinstall
/// manually, the same way Gatekeeper expects for an unsigned/ad-hoc app.
@MainActor
final class UpdaterManager: ObservableObject {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }

    private static let repo = "forel-app/forel"
    private static let checkInterval: TimeInterval = 12 * 60 * 60
    private static let settingKey = "auto_update_checks"

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var isChecking = false

    private let db: Database
    private var timer: Timer?

    init(db: Database) {
        self.db = db
        let stored = try? db.getSetting(Self.settingKey)
        autoCheck = stored.map { $0 != "0" } ?? true
        if autoCheck {
            scheduleAutomaticChecks()
            checkForUpdates()
        }
    }

    private var autoCheck: Bool

    var automaticallyChecksForUpdates: Bool {
        get { autoCheck }
        set {
            guard newValue != autoCheck else { return }
            autoCheck = newValue
            try? db.setSetting(Self.settingKey, newValue ? "1" : "0")
            if newValue {
                scheduleAutomaticChecks()
                checkForUpdates()
            } else {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            guard let release = await Self.fetchLatestRelease() else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isNewer(latest, than: current) {
                updateAvailable = true
                latestVersion = latest
                releaseURL = release.htmlUrl
            }
        }
    }

    func openReleasePage() {
        guard let releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }

    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    private static func fetchLatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Compares dot-separated numeric version strings (e.g. "1.2.10" vs "1.2.3").
    /// Missing components are treated as 0, non-numeric components as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }
}
