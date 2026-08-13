import Foundation

/// Layer A: removes restricted module search results. A tight static keyword
/// list is the always-available floor; an AniList cross-check does the heavy
/// lifting for real anime titles.
@MainActor
final class ContentSafetyFilter: ObservableObject {
    static let shared = ContentSafetyFilter()
    private init() {}

    /// In-memory per-keyword cache of AniList restricted-title sets for this
    /// session.
    private var restrictedSetCache: [String: Set<String>] = [:]

    // MARK: - Keyword floor (whole-token matching; tunable)
    //
    // Matching is WHOLE-TOKEN (a title token must equal an entry), so partial
    // substrings never trigger false positives. The list below is the minimum
    // functional blocklist required to keep unsafe titles out of search
    // results. Adding or removing entries here changes the filter's behavior
    // at runtime — every entry is load-bearing.
    nonisolated static let blockedKeywords: Set<String> = [
        "hentai", "hentais", "porn", "porno", "pornography",
        "xxx", "nsfw", "r18", "rule34", "jav", "smut", "eroge",
        "erotic", "erotica", "nude", "nudes", "naked", "sex",
        "creampie", "ahegao", "futanari", "bukkake", "gangbang", "milf",
        "boobs", "tits", "pussy", "cock", "anal", "cum",
        "blowjob", "handjob", "threesome", "orgy", "orgasm",
        "fetish", "bdsm", "incest", "nympho", "slut", "whore",
        "fuck", "fucking"
    ]

    // MARK: - Pure decision logic (testable, actor-independent)

    nonisolated static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"\b\d+(st|nd|rd|th)\s+season\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(season|part|cour)\s*\d+\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return s.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func containsBlockedKeyword(_ normalizedTitle: String) -> Bool {
        let tokens = Set(normalizedTitle.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: blockedKeywords)
    }

    /// Restricted if the normalized title exactly matches a variant, or shares
    /// a multi-token (≥2) subset with one. Single-token variants match only
    /// exactly, so common words don't over-block.
    nonisolated static func isRestrictedTitle(_ normalizedItemTitle: String, restrictedSet: Set<String>) -> Bool {
        if restrictedSet.contains(normalizedItemTitle) { return true }
        let itemTokens = Set(normalizedItemTitle.split(separator: " ").map(String.init))
        guard !itemTokens.isEmpty else { return false }
        for variant in restrictedSet {
            let vTokens = Set(variant.split(separator: " ").map(String.init))
            if vTokens.isEmpty { continue }
            if vTokens.count >= 2, vTokens.isSubset(of: itemTokens) { return true }
            if itemTokens.count >= 2, itemTokens.isSubset(of: vTokens) { return true }
        }
        return false
    }

    // MARK: - Main entry

    func filter(_ items: [SearchItem], keyword: String) async -> [SearchItem] {
        // Layer 1: keyword floor (offline, always runs).
        let afterKeyword = items.filter { !Self.containsBlockedKeyword(Self.normalize($0.title)) }

        // Layer 2: AniList restricted cross-check (best-effort; fail-open on
        // error). Uses the provider's content-safety flag to identify titles
        // that the keyword list might miss.
        let normKeyword = Self.normalize(keyword)
        let restrictedSet: Set<String>
        if let cached = restrictedSetCache[normKeyword] {
            restrictedSet = cached
        } else if let fetched = try? await AniListService.shared.searchRestrictedTitles(keyword: keyword) {
            restrictedSetCache[normKeyword] = fetched
            restrictedSet = fetched
        } else {
            return afterKeyword   // cross-check unavailable → keyword-filtered results
        }
        guard !restrictedSet.isEmpty else { return afterKeyword }
        return afterKeyword.filter { !Self.isRestrictedTitle(Self.normalize($0.title), restrictedSet: restrictedSet) }
    }
}
