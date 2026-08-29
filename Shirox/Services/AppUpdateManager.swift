import Foundation
import Combine
import SwiftUI

/// Update checker — v2.10 from-scratch rework.
///
/// The old checker fetched the manifest from a single URL and swallowed
/// every network failure, which made a dead check indistinguishable from
/// "up to date" — the app showed a green checkmark even when it had never
/// reached the server. This rework fixes both problems:
///
/// **Triple-source manifest fetch.** The same apps.json is fetched from
/// three independent hosts, in order, and the first one that responds wins:
///   1. raw.githubusercontent.com  (primary, as before)
///   2. api.github.com contents API (different host, survives raw CDN blocks)
///   3. cdn.jsdelivr.net mirror    (independent CDN, survives GitHub issues)
/// A check only fails when ALL three sources are unreachable.
///
/// **Honest state machine.** `state` is exactly one of:
///   idle → checking → current | available | dismissed | failed
/// "current" is only ever set after a real, successful comparison, and
/// "failed" is surfaced to the UI (with a retry) instead of being logged
/// away. The About page renders every state distinctly.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    // MARK: - State

    /// The single source of truth for the UI. See the class doc for the
    /// exact transitions.
    enum CheckState: Equatable {
        /// No check has completed this session (fresh launch).
        case idle
        /// A check is in flight right now.
        case checking
        /// A check SUCCEEDED and the installed version is the latest.
        case current
        /// A check succeeded and a newer version exists (and wasn't dismissed).
        case available(UpdateInfo)
        /// A newer version exists but the user dismissed the prompt. Still
        /// shown in About with an install button in case the sideload failed.
        case dismissed(UpdateInfo)
        /// Every manifest source failed — the installed version is UNKNOWN,
        /// never "up to date".
        case failed
    }

    @Published private(set) var state: CheckState = .idle
    /// Timestamp of the last check that actually reached a manifest source.
    @Published private(set) var lastSuccessfulCheck: Date?

    /// Persistent in-app notification integration. When an update is
    /// detected, a notification is posted so it shows in the app's
    /// Notification Center alongside airing/follow notifications.
    @Published var updateNotificationId: String?

    /// True while a network check is in flight (computed for convenience).
    var isChecking: Bool { state == .checking }

    /// The detected update, if any (computed for convenience — the About
    /// page and notification flow read this).
    var availableUpdate: UpdateInfo? {
        if case .available(let info) = state { return info }
        return nil
    }

    // MARK: - Preferences

    @AppStorage("update.lastDismissedVersion") var lastDismissedVersion: String = ""
    @AppStorage("update.checkIntervalSeconds") var checkIntervalSeconds: Int = 3600

    // MARK: - Manifest sources

    private struct ManifestSource {
        enum Kind {
            case raw        // plain JSON body
            case githubAPI  // JSON envelope with base64 content field
        }
        let url: URL
        let kind: Kind
    }

    /// Same manifest, three independent hosts. Order = try order.
    private let manifestSources: [ManifestSource] = [
        ManifestSource(url: URL(string: "https://raw.githubusercontent.com/Faludaddd/Shirox-autosub/main/apps.json")!, kind: .raw),
        ManifestSource(url: URL(string: "https://api.github.com/repos/Faludaddd/Shirox-autosub/contents/apps.json")!, kind: .githubAPI),
        ManifestSource(url: URL(string: "https://cdn.jsdelivr.net/gh/Faludaddd/Shirox-autosub@main/apps.json")!, kind: .raw),
    ]

    /// Dedicated session: short timeouts so a dead host doesn't stall the
    /// check, and no URL cache so the manifest is always fresh.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 25
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private var inFlight = false

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

        static func == (lhs: UpdateInfo, rhs: UpdateInfo) -> Bool {
            lhs.id == rhs.id && lhs.newVersion == rhs.newVersion
        }
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
    /// right ("2.10" IS newer than "2.9"). Returns false if either string is
    /// empty or unparseable.
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
    /// that the user MUST update before continuing. We treat a gap of >= 3
    /// minor versions as critical (e.g. installed 2.6, latest 2.9). Major
    /// version bumps are always critical.
    static func isCriticalGap(_ newVersion: String, vs currentVersion: String) -> Bool {
        let newParts = newVersion.split(separator: ".").compactMap { Int($0) }
        let curParts = currentVersion.split(separator: ".").compactMap { Int($0) }
        guard newParts.count >= 2, curParts.count >= 2 else { return false }
        if newParts[0] != curParts[0] { return true }
        return newParts[1] - curParts[1] >= 3
    }

    // MARK: - URL Validation

    /// Validates a download URL is well-formed and points to a trusted host.
    /// Only HTTPS URLs on github.com (the release host) are accepted.
    static func isValidDownloadURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    // MARK: - Check

    /// Fetches the manifest (trying each source in order until one
    /// responds) and compares versions. No-ops if a check is already in
    /// flight, or if the last SUCCESSFUL check was less than
    /// `checkIntervalSeconds` ago (unless `force` is true).
    func checkForUpdates(force: Bool = false) async {
        guard !inFlight else { return }
        if !force, let last = lastSuccessfulCheck,
           Date().timeIntervalSince(last) < TimeInterval(checkIntervalSeconds) {
            return
        }
        inFlight = true
        state = .checking
        defer { inFlight = false }

        // Try every source; first one that decodes wins.
        var latest: VersionEntry?
        for (index, source) in manifestSources.enumerated() {
            do {
                latest = try await fetchLatestVersion(from: source)
                if index > 0 {
                    Logger.shared.log("[Update] primary source unreachable — fell back to source #\(index + 1)", type: "Debug")
                }
                break
            } catch {
                Logger.shared.log("[Update] source #\(index + 1) failed: \(error.localizedDescription)", type: "Debug")
            }
        }

        guard let latest else {
            // All sources failed. If we already KNOW an update exists (from
            // an earlier successful check), keep that knowledge — a flaky
            // re-check must never hide a known update. Otherwise this is an
            // honest "couldn't verify" failure.
            switch state {
            case .available, .dismissed:
                break
            default:
                state = .failed
            }
            return
        }

        lastSuccessfulCheck = Date()

        guard Self.isNewer(latest.version, than: currentVersion) else {
            state = .current
            return
        }

        // A newer version exists. Don't re-prompt for one the user already
        // dismissed (non-forced checks only).
        if !force, latest.version == lastDismissedVersion {
            state = .dismissed(info(from: latest))
            return
        }

        guard Self.isValidDownloadURL(latest.downloadURL) else {
            Logger.shared.log("[Update] manifest downloadURL failed validation: \(latest.downloadURL)", type: "Error")
            state = .failed
            return
        }

        let info = info(from: latest)
        state = .available(info)
        postUpdateNotification(info)
    }

    /// Marks the current available update as dismissed so non-forced checks
    /// don't re-prompt. The info stays visible in About (dismissed state)
    /// with an install button in case the sideload failed.
    func dismiss() {
        guard case .available(let info) = state, !info.isCritical else { return }
        lastDismissedVersion = info.newVersion
        state = .dismissed(info)
    }

    /// Called after the user starts the download flow. The update stays
    /// visible (available/dismissed) so it can be re-triggered if the
    /// sideload fails; the in-app notification also stays.
    func markDownloadStarted() {
        // Intentionally keeps `state` as-is. See method doc.
    }

    // MARK: - Manifest fetching

    private func info(from entry: VersionEntry) -> UpdateInfo {
        UpdateInfo(
            newVersion: entry.version,
            currentVersion: currentVersion,
            changelog: entry.localizedDescription,
            downloadURL: URL(string: entry.downloadURL)!,
            isCritical: Self.isCriticalGap(entry.version, vs: currentVersion),
            releaseDate: Self.parseDate(entry.date)
        )
    }

    private func fetchLatestVersion(from source: ManifestSource) async throws -> VersionEntry {
        var request = URLRequest(url: source.url)
        if source.kind == .githubAPI {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let manifest: Manifest
        switch source.kind {
        case .raw:
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        case .githubAPI:
            // Contents API wraps the file in a JSON envelope with base64 content.
            let envelope = try JSONDecoder().decode(GitHubContentEnvelope.self, from: data)
            let cleaned = envelope.content.replacingOccurrences(of: "\n", with: "")
            guard envelope.encoding == "base64",
                  let decoded = Data(base64Encoded: cleaned) else {
                throw URLError(.cannotParseResponse)
            }
            manifest = try JSONDecoder().decode(Manifest.self, from: decoded)
        }

        guard let latest = manifest.apps.first?.versions.first else {
            throw URLError(.cannotParseResponse)
        }
        return latest
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
    private struct GitHubContentEnvelope: Decodable {
        let content: String
        let encoding: String
    }
}

extension Notification.Name {
    static let appUpdateAvailable = Notification.Name("AppUpdateAvailable")
}
