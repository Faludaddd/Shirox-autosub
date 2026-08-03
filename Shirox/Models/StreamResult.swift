import Foundation

struct SubtitleTrack: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let headers: [String: String]

    init(title: String, url: URL, headers: [String: String]) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.headers = headers
    }
}

struct StreamResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
    let subtitle: String?
    let subtitleHeaders: [String: String]
    let allSubtitles: [SubtitleTrack]?

    var subtitleURL: URL? { subtitle.flatMap { URL(string: $0) } }

    init(title: String, url: URL, headers: [String: String], subtitle: String? = nil,
         subtitleHeaders: [String: String] = [:], allSubtitles: [SubtitleTrack]? = nil) {
        self.title = title
        self.url = url
        self.headers = headers
        self.subtitle = subtitle
        self.subtitleHeaders = subtitleHeaders
        self.allSubtitles = allSubtitles
    }
}

// MARK: - Sub/Dub stream preference

/// User-tunable preference for auto-picking a stream when a source exposes multiple
/// options (e.g. "SUB", "DUB", "Softsub", "Hardsub"). Persisted via `@AppStorage`
/// under the key `"autoPickSubDub"`.
///
/// - `off`: always show the picker sheet (original behavior)
/// - `sub`: auto-pick a subbed stream, preferring softsub > hardsub > any non-dub
/// - `dub`: auto-pick a dubbed stream
enum StreamSubDubPreference: String, CaseIterable {
    case off = "off"
    case sub = "sub"
    case dub = "dub"
}

/// Pure, testable matcher that resolves a preferred `StreamResult` from a list based
/// on the user's sub/dub preference. Returns `nil` when no confident match exists —
/// callers should fall back to showing the picker sheet in that case.
///
/// Matching is case-insensitive and tolerant of common title variants seen across
/// community modules: "SUB", "Sub", "Subbed", "Softsub", "Hardsub", "DUB", "Dub",
/// "Dubbed", etc. A title containing "dub" is never selected for the `sub` preference
/// (even if it also contains "sub", e.g. "Subbed (English Dub)").
enum StreamPreferenceMatcher {
    /// Reads the persisted preference from `UserDefaults`. Default is `.sub`.
    static func currentPreference() -> StreamSubDubPreference {
        let raw = UserDefaults.standard.string(forKey: "autoPickSubDub") ?? StreamSubDubPreference.sub.rawValue
        return StreamSubDubPreference(rawValue: raw) ?? .sub
    }

    /// Returns the best-matching stream for the given preference, or `nil` if the
    /// preference is `.off` or no stream in the list matches confidently.
    static func preferredStream(in streams: [StreamResult], preference: StreamSubDubPreference) -> StreamResult? {
        switch preference {
        case .off:
            return nil
        case .sub:
            return preferredSubStream(in: streams)
        case .dub:
            return preferredDubStream(in: streams)
        }
    }

    // MARK: - Sub

    /// Sub preference priority:
    /// 1. "Softsub" (switchable subtitle track — highest quality)
    /// 2. "Sub" / "Subbed" (generic sub, excluding anything with "dub")
    /// 3. "Hardsub" (burned-in subs — lower quality but still sub)
    /// 4. Fallback: first stream whose title doesn't contain "dub"
    private static func preferredSubStream(in streams: [StreamResult]) -> StreamResult? {
        // 1. Softsub
        if let s = streams.first(where: { $0.title.lowercased().contains("softsub") }) {
            return s
        }
        // 2. Generic sub (contains "sub" but not "dub")
        if let s = streams.first(where: {
            let t = $0.title.lowercased()
            return t.contains("sub") && !t.contains("dub")
        }) {
            return s
        }
        // 3. Hardsub (explicitly — contains "hardsub"; redundant with step 2 but documents intent)
        // Note: step 2 already catches "hardsub" via the "sub" substring. Kept for readability.
        // 4. Fallback: first non-dub stream (e.g. quality-only titles like "1080p")
        return streams.first { !$0.title.lowercased().contains("dub") }
    }

    // MARK: - Dub

    /// Dub preference: first stream whose title contains "dub".
    private static func preferredDubStream(in streams: [StreamResult]) -> StreamResult? {
        streams.first { $0.title.lowercased().contains("dub") }
    }
}
