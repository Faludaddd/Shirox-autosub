import Foundation
import Combine
import SwiftUI

/// Global update detection system. Checks the latest version released on the
/// Faludaddd/Shirox-autosub fork against the currently installed version.
/// On launch (and periodically in the background), it fetches the apps.json
/// manifest from the repo, compares the latest `version` field against the
/// bundle's `CFBundleShortVersionString`, and — if a newer version exists —
/// publishes an `UpdateInfo` that the root view renders as a popup modal.
///
/// Forced-update mode: if the installed version is older than the manifest's
/// `minCompatibleVersion` (or by more than N minor versions), the popup
/// becomes non-dismissible — only "Download Update" and "Exit" are offered.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    /// Latest version info fetched from the manifest. Nil until the first
    /// successful check completes. The root view observes this and shows the
    /// popup when it becomes non-nil AND the installed version is older.
    @Published var availableUpdate: UpdateInfo?
    @Published var isChecking = false
    @Published var lastCheckAt: Date?

    /// Persistent in-app notification integration. When an update is
    /// detected, a notification is posted so it shows in the app's
    /// Notification Center alongside airing/follow notifications.
    @Published var updateNotificationId: String?

    private let manifestURL = URL(string: "https://raw.githubusercontent.com/Faludaddd/Shirox-autosub/main/apps.json")!

    /// AppStorage-backed user preferences for the update system. All keys
    /// are prefixed `update.` so they live in their own namespace and never
    /// collide with anime or manga settings.
    @AppStorage("update.autoDownloadEnabled") var autoDownloadEnabled: Bool = false
    @AppStorage("update.lastDismissedVersion") var lastDismissedVersion: String = ""
    @AppStorage("update.checkIntervalSeconds") var checkIntervalSeconds: Int = 3600

    private init() {}

    // MARK: - Update Info

    struct UpdateInfo: Identifiable, Equatable {
        let id = UUID()
        let newVersion: String
        let currentVersion: String
        let changelog: String
        let downloadURL: URL
        let isCritical: Bool
        let releaseDate: Date?
    }

    // MARK: - Current Version

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Version Comparison

    /// Returns true if `newVersion` is strictly newer than `currentVersion`.
    /// Compares by splitting on `.` and comparing numeric components left to
    /// right. Returns false if either string is empty or unparseable.
    static func isNewer(_ newVersion: String, than currentVersion: String) -> Bool {
        let newParts = newVersion.split(separator: ".").compactMap { Int($0) }
        let curParts = currentVersion.split(separator: ".").compactMap { Int($0) }
        guard !newParts.isEmpty, !curParts.isEmpty else { return false }
        let maxLen = max(newParts.count, curParts.count)
        for i in 0..<maxLen {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < curParts.count ? curParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }

    /// Returns true if the installed version is so far behind the latest
    /// that the user MUST update before continuing. We treat a gap of ≥ 3
    /// minor versions as critical (e.g. installed 1.10, latest 1.13).
    static func isCriticalGap(_ newVersion: String, vs currentVersion: String) -> Bool {
        let newParts = newVersion.split(separator: ".").compactMap { Int($0) }
        let curParts = currentVersion.split(separator: ".").compactMap { Int($0) }
        guard newParts.count >= 2, curParts.count >= 2 else { return false }
        // Only consider the minor component for the gap calculation. Major
        // version bumps (1.x → 2.x) are always critical.
        if newParts[0] != curParts[0] { return true }
        let gap = newParts[1] - curParts[1]
        return gap >= 3
    }

    // MARK: - URL Validation

    /// Validates a download URL is well-formed and points to a trusted host.
    /// Only HTTPS URLs on github.com (the release host) are accepted. This
    /// prevents malformed or unsafe URLs from being opened or copied.
    static func isValidDownloadURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    // MARK: - Check

    /// Fetches the manifest and compares versions. Safe to call repeatedly —
    /// no-ops if a check is already in flight or if the last check was less
    /// than `checkIntervalSeconds` ago (unless `force` is true).
    func checkForUpdates(force: Bool = false) async {
        if isChecking { return }
        if !force, let last = lastCheckAt,
           Date().timeIntervalSince(last) < TimeInterval(checkIntervalSeconds) {
            return
        }
        isChecking = true
        defer { isChecking = false; lastCheckAt = Date() }

        do {
            let (data, _) = try await URLSession.shared.data(from: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard let latest = manifest.apps.first?.versions.first else { return }
            guard Self.isNewer(latest.version, than: currentVersion) else {
                // Up to date — clear any previously-detected update.
                if availableUpdate != nil { availableUpdate = nil }
                return
            }
            // Don't re-prompt for a version the user already dismissed.
            if !force && latest.version == lastDismissedVersion { return }

            guard Self.isValidDownloadURL(latest.downloadURL) else { return }
            let releaseDate = Self.parseDate(latest.date)

            let info = UpdateInfo(
                newVersion: latest.version,
                currentVersion: currentVersion,
                changelog: latest.localizedDescription,
                downloadURL: URL(string: latest.downloadURL)!,
                isCritical: Self.isCriticalGap(latest.version, vs: currentVersion),
                releaseDate: releaseDate
            )
            availableUpdate = info

            // Post an in-app notification so the update shows in the
            // Notification Center alongside other notifications.
            postUpdateNotification(info)
        } catch {
            // Network/parse failure — silent. Don't bother the user with
            // update-check errors.
            Logger.shared.log("[Update] check failed: \(error.localizedDescription)", type: "Debug")
        }
    }

    /// Marks the current available update as dismissed so we don't re-prompt
    /// on the next launch. Forced updates can't be dismissed.
    func dismiss() {
        guard let info = availableUpdate, !info.isCritical else { return }
        lastDismissedVersion = info.newVersion
        availableUpdate = nil
        // Keep the in-app notification so the user can still find the update
        // later from the Notification Center.
    }

    /// Clears the available update after the user has started the download
    /// flow (download / copy / share). The in-app notification stays so the
    /// user can re-trigger if the sideload fails.
    func markDownloadStarted() {
        availableUpdate = nil
    }

    // MARK: - Notification Integration

    private func postUpdateNotification(_ info: UpdateInfo) {
        let id = "update-\(info.newVersion)"
        updateNotificationId = id
        // Defer to the next runloop so any observing ProfileViewModel picks
        // up the change without re-entrancy issues.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .appUpdateAvailable,
                object: nil,
                userInfo: [
                    "version": info.newVersion,
                    "changelog": info.changelog,
                    "url": info.downloadURL.absoluteString,
                    "id": id
                ]
            )
        }
    }

    // MARK: - Date Parsing

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    // MARK: - Manifest Model

    private struct Manifest: Decodable {
        let apps: [AppEntry]
    }
    private struct AppEntry: Decodable {
        let versions: [VersionEntry]
    }
    private struct VersionEntry: Decodable {
        let version: String
        let date: String
        let localizedDescription: String
        let downloadURL: String
    }
}

extension Notification.Name {
    static let appUpdateAvailable = Notification.Name("AppUpdateAvailable")
}
