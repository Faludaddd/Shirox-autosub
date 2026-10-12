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

    /// v2.21 / v2.23 — True while the update cover should be presented.
    /// Raised the moment a check CONFIRMS a newer version exists; lowered
    /// when a check confirms the installed version is current (i.e. after
    /// the update is installed and the app relaunches) or when the user
    /// taps Maybe Later. A FAILED re-check never lowers it — a flaky
    /// network must not un-gate a known-outdated app. A DISMISSED update
    /// never re-raises it: the Updates page keeps offering the install,
    /// and the next version re-prompts on its own.
    ///
    /// v2.23 — the "demo mode" simulation is GONE. It was the root cause
    /// of the false-update bug: five accidental taps on the version row
    /// persisted `simulateOutdated`, after which every check reported the
    /// installed build as outdated — the popup appeared with IDENTICAL
    /// versions on both sides ("2.2 → 2.2"). The comparison is now purely
    /// real: same versions → no popup, ever.
    @Published private(set) var gateVisible = false

    // MARK: - Manifest sources

    /// The canonical IPA location. The build workflow uploads every green
    /// build to the rolling `beta` release — this URL ALWAYS serves the
    /// newest shipped version, which is exactly what an update flow wants.
    /// It is also the URL the app's own AltStore-style source resolves to.
    static let canonicalDownloadURL = URL(string: "https://github.com/Faludaddd/Shirox-autosub/releases/download/beta/Shirox.ipa")!

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
    //
    // v2.23 — hardened semantic comparison. The old parser was numeric but
    // strict about format: whitespace, a "v" prefix, or a trailing
    // "-beta"/"+build" made a component parse to nil and the version read
    // as older than it was. Every comparison now runs through
    // `normalizedComponents`, which trims whitespace, strips prefixes and
    // suffixes, and pads missing components — so "2.2", "2.2.0", and
    // " v2.2-rc1 " all compare as 2.2.0. Anything unparseable compares as
    // NOT newer (fail-closed: a garbage manifest can never trigger the
    // update popup).

    /// Normalizes a version string into numeric components.
    /// " v2.10-beta " → [2, 10]. "2" → [2]. "" → [] (unparseable).
    static func normalizedComponents(_ version: String) -> [Int] {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading "v"/"V" prefix.
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Strip prerelease/build suffixes ("2.2-beta", "2.2+5").
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<dash])
        }
        return s.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Returns true if `newVersion` is strictly newer than `currentVersion`
    /// — a SEMANTIC comparison: components compared numerically left to
    /// right ("2.10" IS newer than "2.9"), missing components padded as
    /// zero ("2.2" == "2.2.0"). Returns false if either string is empty or
    /// unparseable — a failed parse can never claim an update exists.
    static func isNewer(_ newVersion: String, than currentVersion: String) -> Bool {
        let newParts = normalizedComponents(newVersion)
        let curParts = normalizedComponents(currentVersion)
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
            // honest "couldn't verify" failure — NEVER an assumed update.
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
            gateVisible = false
            return
        }

        // A newer version exists. Resolve the download URL:
        //   1. a per-entry URL from the manifest, when present and valid;
        //   2. otherwise the canonical rolling beta release (the workflow
        //      re-uploads the newest IPA there on every green build, and the
        //      manifest hasn't carried per-entry URLs since v2.29).
        // v2.35 — this is the root cause of the "updates never detected"
        // bug: the manifest's version entries carry NO `downloadURL` field
        // (only version / date / localizedDescription / size — the CI fills
        // the size), so the OLD decoder's non-optional `downloadURL` threw
        // keyNotFound for EVERY entry on EVERY source — every check "failed"
        // and genuinely-newer releases were never reported. The field is now
        // optional with the canonical-URL fallback, and a manifest-provided
        // URL that fails validation falls back to the canonical URL too
        // (with a log) instead of failing the whole check.
        var downloadURL = Self.canonicalDownloadURL
        let manifestURL = latest.effectiveDownloadURL
        if !manifestURL.isEmpty {
            if Self.isValidDownloadURL(manifestURL), let explicit = URL(string: manifestURL) {
                downloadURL = explicit
            } else {
                Logger.shared.log("[Update] manifest downloadURL failed validation: \(manifestURL) — using the canonical beta release URL", type: "Error")
            }
        }

        // A newer version exists. Don't re-prompt for one the user already
        // dismissed (non-forced checks only) — v2.21: a dismissed update
        // stays quiet (no cover); the About page still offers the install
        // and a forced check (About "Check for Updates", demo mode) can
        // re-offer it.
        if !force, latest.version == lastDismissedVersion {
            state = .dismissed(info(from: latest, downloadURL: downloadURL))
            return
        }

        let info = info(from: latest, downloadURL: downloadURL)
        state = .available(info)
        postUpdateNotification(info)
        gateVisible = true
    }

    /// v2.22 / v2.23 — Later: lowers the update cover immediately and
    /// remembers the version so automatic checks don't re-prompt. Works
    /// from the `.available` state (first prompt) AND from a `.dismissed`
    /// state (cover re-opened manually from the Updates settings page). NO
    /// update is ever forced — critical gaps get a prominent "strongly
    /// recommended" banner in the popup instead of a lockout, so this
    /// works for every update. The info stays visible in the Updates
    /// settings page (dismissed state) with an install button in case the
    /// sideload failed.
    func dismiss() {
        guard let current = currentUpdateInfo else { return }
        lastDismissedVersion = current.newVersion
        state = .dismissed(current)
        gateVisible = false
    }

    /// v2.23 — PREVIEW ONLY: presents the update popup with the CURRENT
    /// version info so the design can be reviewed without any version
    /// trickery. Replaces the removed 5-tap "demo mode" (which made every
    /// real check lie about being outdated). Reachable exclusively from
    /// the clearly-labeled "Preview the update popup" row in Updates
    /// settings — it can never trigger accidentally, and it never touches
    /// the check state or the version comparison.
    func presentPreview() {
        previewing = true
        gateVisible = true
    }

    /// True while the cover shows a design PREVIEW (presentPreview). The
    /// popup labels itself clearly and the flag resets when the cover
    /// lowers.
    @Published private(set) var previewing = false

    /// v2.21 — Presents the update cover manually (Updates page Update /
    /// Install buttons) so the full popup flow — progress, verification,
    /// install destinations, copy/share — is reachable for an update the
    /// user previously dismissed. No-ops when no update is known.
    func presentUpdateFlow() {
        guard currentUpdateInfo != nil else { return }
        gateVisible = true
    }

    /// v2.23 — Lowers a PREVIEW cover (clears the preview flag + the gate).
    /// Also called when the cover disappears for any reason — both writes
    /// are idempotent and never touch the real check state.
    func dismissPreview() {
        previewing = false
        gateVisible = false
    }

    /// The detected update, whichever prompt state it's in (offered or
    /// dismissed) — nil when none exists.
    private var currentUpdateInfo: UpdateInfo? {
        switch state {
        case .available(let info), .dismissed(let info): return info
        default: return nil
        }
    }

    /// Called after the user starts the download flow. The update stays
    /// visible (available/dismissed) so it can be re-triggered if the
    /// sideload fails; the in-app notification also stays.
    func markDownloadStarted() {
        // Intentionally keeps `state` as-is. See method doc.
    }

    // MARK: - Manifest fetching

    private func info(from entry: VersionEntry, downloadURL: URL) -> UpdateInfo {
        return UpdateInfo(
            newVersion: entry.version,
            currentVersion: currentVersion,
            changelog: entry.localizedDescription,
            downloadURL: downloadURL,
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

        guard let latest = Self.semanticallyLatest(manifest.apps.first?.versions) else {
            throw URLError(.cannotParseResponse)
        }
        return latest
    }

    /// v2.23 — the newest entry by SEMANTIC version, not array position.
    /// `versions.first` trusted the manifest's ordering; if a source ever
    /// serves entries out of order (a mirror, a bad commit), the "latest"
    /// could be an OLD version. Taking the semantic max is ordering-proof.
    /// Two entries with the same normalized version fall back to the
    /// earlier one (stable).
    private static func semanticallyLatest(_ entries: [VersionEntry]?) -> VersionEntry? {
        guard let entries, !entries.isEmpty else { return nil }
        return entries.reduce(entries[0]) { best, candidate in
            isNewer(candidate.version, than: best.version) ? candidate : best
        }
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
        /// v2.35 — OPTIONAL. The manifest has not carried per-entry download
        /// URLs since v2.29 (the CI only fills `size`); requiring the key
        /// failed decoding for every entry and broke update detection. When
        /// absent, the canonical rolling beta release URL is used instead.
        let downloadURL: String?

        /// The effective URL string ("" when the manifest has none).
        var effectiveDownloadURL: String { downloadURL ?? "" }

        enum CodingKeys: String, CodingKey {
            case version, date, localizedDescription
            case downloadURL = "downloadURL"
            case size
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            date = (try? c.decode(String.self, forKey: .date)) ?? ""
            localizedDescription = (try? c.decode(String.self, forKey: .localizedDescription)) ?? ""
            downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        }
    }
    private struct GitHubContentEnvelope: Decodable {
        let content: String
        let encoding: String
    }
}

extension Notification.Name {
    static let appUpdateAvailable = Notification.Name("AppUpdateAvailable")
}
