import Foundation

// MARK: - Franchise / season normalization (Batch 27)
//
// STRUCTURAL title analysis — no series is ever special-cased. These
// rules look at the SHAPE of a title (season/part/cour markers, sequel
// numerals, year parentheses) and apply uniformly to everything:
//   "Attack on Titan Season 2" → "attack on titan"
//   "Re:ZERO Part II"          → "re:zero"
//   "Frieren 2"                → "frieren"
//   "One Piece (2023)"         → "one piece"
// One canonical key per FRANCHISE means:
//   • the carousel never shows two seasons of the same show back to back
//   • Surprise Me never hands back a random sequel when the user expects
//     "a show" (the franchise's base entry is preferred)
//   • provider-merged duplicates collapse (AniList "Season 2" + Kitsu
//     "2nd Season" of the same show share the key)

enum FranchiseNormalizer {

    /// True when the title carries an explicit sequel/continuation marker.
    static func isLikelySequel(_ rawTitle: String) -> Bool {
        let t = rawTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Explicit season/part/cour markers ALWAYS mark a continuation.
        if explicitMarkerRange(in: t) != nil { return true }
        // Trailing roman numeral (word-boundary, II..X range) or trailing
        // digit 2-9 — the classic sequel shapes.
        if trailingSequelNumeral(in: t) != nil { return true }
        return false
    }

    /// The franchise key — the base title with every continuation marker
    /// and year annotation stripped, lowercased, whitespace-collapsed.
    /// Two titles from the same franchise produce the SAME key.
    static func canonicalKey(_ rawTitle: String) -> String {
        var t = rawTitle.trimmingCharacters(in: .whitespaces)
        // 1. Strip parentheses that contain TV/season/year annotations:
        //    "(TV)", "(TV 2)", "(2023)", "(Season 2)".
        if let range = t.range(of: #"\((TV|Season \d+|\d{4}|TV \d+)\)"#, options: .regularExpression) {
            t = t.replacingCharacters(in: range, with: "")
        }
        // 2. Strip explicit continuation markers:
        //    "Season 2", "2nd Season", "Part 2", "Part II", "Cour 2",
        //    "Final Season", "2nd Cour", "- Season 2" etc.
        while let range = explicitMarkerRange(in: t) {
            t = t.replacingCharacters(in: range, with: " ")
        }
        // 3. Strip a trailing sequel numeral ("Frieren 2", "Frieren II").
        if let range = trailingSequelNumeral(in: t) {
            t = t.replacingCharacters(in: range, with: "")
        }
        return t
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            // Trailing separator dashes/colons collapse: the base title
            // "Re:ZERO -Starting Life in Another World-" and its sequel
            // "...World- Part II" (whose marker strip leaves a dangling
            // "- ") must produce the SAME key.
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{2013}\u{2014}-:"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Range of an explicit season/part/cour/final-season marker, if any.
    private static func explicitMarkerRange(in title: String) -> Range<String.Index>? {
        let patterns = [
            #"(?i)(-?\s*season\s+\d+)"#,          // Season 2
            #"(?i)(-?\s*\d{1,2}(st|nd|rd|th)\s+season)"#, // 2nd Season
            #"(?i)(-?\s*part\s+(\d+|[ivx]+))"#,   // Part 2 / Part II
            #"(?i)(-?\s*cour\s+\d+)"#,            // Cour 2
            #"(?i)(-?\s*\d{1,2}(st|nd|rd|th)\s+cour)"#, // 2nd Cour
            #"(?i)(-?\s*(the\s+)?final\s+season)"# // Final Season
        ]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: .regularExpression) {
                return range
            }
        }
        return nil
    }

    /// Range of a TRAILING sequel numeral ("...2" or "...II"), if any.
    /// Never matches a leading digit ("2.5 Dimensional Seduction") or a
    /// digit embedded mid-title ("Room 205") — only the final token.
    private static func trailingSequelNumeral(in title: String) -> Range<String.Index>? {
        let patterns = [
            #"\s+\d{1}\s*$"#,        // trailing single digit
            #"\s+(II|III|IV|V|VI|VII|VIII|IX|X)\s*$"# // trailing roman numeral (2+ chars)
        ]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                // Guard: a trailing single digit is only a sequel marker,
                // not part of a real name ("007" style names end in 7 but
                // those are single-token titles — require a word before it).
                let before = title[title.startIndex..<range.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if before.isEmpty { return nil }
                return range
            }
        }
        return nil
    }
}

// MARK: - Carousel / shelf normalization (Batch 27)
//
// The ONE normalization pass every carousel row (anime AND manga) runs
// before rendering. Guarantees:
//   • every slide is a real, displayable object (title + artwork)
//   • no empty / invalid media objects
//   • anime rows: the Japanese-anime catalog (donghua and other non-JP
//     entries are dropped when the provider knows the origin — same
//     policy the pipeline has enforced since v2.20, applied here too)
//   • no duplicate entries (same uniqueId twice)
//   • no duplicate FRANCHISES (two seasons of the same show collapse to
//     one — the base season is preferred)
//   • manga rows keep manga metadata intact (no anime-only fields forced)
enum MediaNormalizer {

    /// Normalized carousel items: valid, deduped, franchise-deduped,
    /// capped at `limit` slides.
    static func carouselItems(from items: [Media], isManga: Bool, limit: Int = 8) -> [Media] {
        var seenIds = Set<String>()
        var byFranchise: [String: Media] = [:]
        var order: [String] = []   // franchise keys in first-seen order

        for media in items {
            // 1. Validity: a displayable title and at least one artwork URL.
            let title = media.title.displayTitle
            guard !title.isEmpty, title != "Unknown" else { continue }
            guard (media.coverImage.best ?? media.coverImage.large ?? media.bannerImage) != nil else { continue }
            // 2. Structural junk filter: music videos and explicit "short
            //    film" listings never belong in a hero row.
            let lower = title.lowercased()
            if lower.contains("short film") || lower.contains("short movie") { continue }
            if media.format == "MUSIC" { continue }
            // 3. Catalog policy (anime only): non-JP origin drops out when
            //    the provider actually knows the origin; unknown passes.
            if !isManga, let country = media.countryOfOrigin, country != "JP" { continue }
            // 4. Plain duplicates (same provider id — provider-merge noise).
            guard seenIds.insert(media.uniqueId).inserted else { continue }

            // 5. Franchise dedup: one slide per franchise. When two
            //    entries share the franchise key, the BASE entry (no
            //    sequel marker) wins; a base entry always displaces a
            //    sequel, and between two sequels the first stays.
            let key = FranchiseNormalizer.canonicalKey(title)
            guard !key.isEmpty else { continue }
            if let existing = byFranchise[key] {
                let existingIsSequel = FranchiseNormalizer.isLikelySequel(existing.title.displayTitle)
                let newIsSequel = FranchiseNormalizer.isLikelySequel(title)
                if existingIsSequel && !newIsSequel {
                    byFranchise[key] = media
                }
                continue
            }
            byFranchise[key] = media
            order.append(key)
        }

        return order.prefix(limit).compactMap { byFranchise[$0] }
    }

    /// Franchise-deduped pool for Surprise Me — same rules, no cap, and
    /// sequel entries are replaced by their franchise's base entry when
    /// the pool contains both (the user asked for "a show", not "season 3").
    static func franchiseBasePool(from items: [Media]) -> [Media] {
        var seenIds = Set<String>()
        var byFranchise: [String: Media] = [:]
        var order: [String] = []
        for media in items {
            let title = media.title.displayTitle
            guard !title.isEmpty, title != "Unknown" else { continue }
            guard seenIds.insert(media.uniqueId).inserted else { continue }
            let key = FranchiseNormalizer.canonicalKey(title)
            guard !key.isEmpty else { continue }
            if let existing = byFranchise[key] {
                let existingIsSequel = FranchiseNormalizer.isLikelySequel(existing.title.displayTitle)
                let newIsSequel = FranchiseNormalizer.isLikelySequel(title)
                if existingIsSequel && !newIsSequel {
                    byFranchise[key] = media
                }
                continue
            }
            byFranchise[key] = media
            order.append(key)
        }
        return order.compactMap { byFranchise[$0] }
    }
}
