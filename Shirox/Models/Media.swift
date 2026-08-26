import Foundation

enum ProviderType: String, Codable, CaseIterable, Hashable {
    case anilist = "anilist"
    case mal = "mal"
    case local = "local"   // on-device-only title (module-scraped or imported file); never sign-in-able

    /// Providers a user can sign into. Use this for login / provider-selection UIs;
    /// `.local` is excluded because it has no account.
    static let userProviders: [ProviderType] = [.anilist, .mal]

    var displayName: String {
        switch self {
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        case .local: return "Local"
        }
    }

    var iconURL: String {
        switch self {
        case .anilist: return "https://anilist.co/img/icons/apple-touch-icon.png"
        case .mal: return "https://cdn.myanimelist.net/img/sp/icon/apple-touch-icon-256.png"
        case .local: return ""   // no remote icon
        }
    }
}

struct Media: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: Int
    let idMal: Int?
    let provider: ProviderType
    let title: MediaTitle
    let coverImage: MediaCoverImage
    var bannerImage: String?
    let description: String?
    let episodes: Int?
    let status: String?
    let averageScore: Int?   // 0–100
    let genres: [String]?
    let season: String?
    let seasonYear: Int?
    let nextAiringEpisode: MediaAiringEpisode?
    let relations: MediaRelations?
    let type: String?
    let format: String?

    // Extended fields (all optional — existing decode paths are unaffected)
    let studioNames: [String]?     // Animation studio names
    let source: String?            // "MANGA", "LIGHT_NOVEL", "ORIGINAL", etc.
    let duration: Int?             // Episode length in minutes
    let airDateRange: String?      // Pre-formatted "Oct 2007 – Mar 2008"
    // #131 — Manga-specific fields surfaced from AniList for the Statistics
    // grid on the manga detail page. Defaults to nil so existing Media init
    // call sites (which don't pass these) keep compiling unchanged.
    var volumes: Int? = nil        // Manga volume total
    var popularity: Int? = nil     // AniList popularity (user count)
    var countryOfOrigin: String? = nil  // "JP", "KR", "CN" etc.

    var uniqueId: String { "\(provider.rawValue)-\(id)" }

    var isManga: Bool { type == "MANGA" }

    func hash(into hasher: inout Hasher) { hasher.combine(uniqueId) }
    static func == (lhs: Media, rhs: Media) -> Bool { lhs.uniqueId == rhs.uniqueId }

    var plainDescription: String? {
        guard let desc = description else { return nil }
        return desc
            .replacingOccurrences(of: "<br><br>", with: "\n\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusDisplay: String? {
        switch status {
        case "RELEASING", "currently_airing": return "Airing"
        case "FINISHED", "finished_airing": return "Finished"
        case "NOT_YET_RELEASED", "not_yet_aired": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status
        }
    }

    /// Unified poster status line — "[Status], [count]" (e.g. "Airing, 8",
    /// "Finished, 12"). Replaces the old either/or poster logic ("N ep" when a
    /// count existed, otherwise the bare status word), which rendered
    /// inconsistently: AniList sets the *announced total* on some airing shows,
    /// so those posters showed a count while other airing shows showed
    /// "Airing".
    ///
    /// Spec (Round 8): status and count are ALWAYS shown together, separated
    /// by a comma, same size/font/position on every anime and manga poster.
    ///
    /// - Airing anime → "Airing, N" where N = episodes released so far
    ///   (`nextAiringEpisode.episode - 1`), NOT the announced total. If the
    ///   next airing episode is unknown there is no honest count, so the
    ///   status word is shown alone rather than guessing with the total.
    /// - Airing manga → "Airing, N" where N = chapters released so far
    ///   (AniList keeps `chapters` — stored in `episodes` — current while a
    ///   manga is RELEASING).
    /// - Every other status → "Status, N" with the total count, or the status
    ///   word alone when the count is unknown.
    var posterStatusText: String? {
        guard let statusWord = statusDisplay else { return nil }
        if statusWord == "Airing" {
            if isManga {
                // `episodes` holds the live chapter count for releasing
                // manga — exactly the "currently available" number.
                guard let chapters = episodes, chapters > 0 else { return statusWord }
                return "\(statusWord), \(chapters)"
            }
            // Anime: episodes available right now = next episode number - 1.
            // Never fall back to `episodes` here — that is the announced
            // total, which is precisely the wrong number the old either/or
            // logic displayed on airing posters.
            if let next = nextAiringEpisode, next.episode > 1 {
                return "\(statusWord), \(next.episode - 1)"
            }
            return statusWord
        }
        guard let count = episodes, count > 0 else { return statusWord }
        return "\(statusWord), \(count)"
    }

    /// Primary animation studio name (first one), if any.
    var mainStudioName: String? { studioNames?.first }

    /// Human-readable source material label.
    var sourceDisplay: String? {
        guard let source = source, !source.isEmpty else { return nil }
        return source.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Average Score Formatting (out-of-10)
//
// AniList's `averageScore` is a 0–100 integer. Every place the public/community
// rating is displayed anywhere in the app must render it out of 10 (e.g. 75 →
// "7.5", 80 → "8", 82 → "8.2"). The user's *personal* score is rendered via
// `ScoreFormat.displayString(for:)` and is already on the user's chosen scale
// (defaults to /10) — this extension is ONLY for the public `averageScore`.
extension Int {
    /// Formats an AniList average score (0–100) as an out-of-10 string.
    /// Whole numbers render without a decimal (e.g. 80 → "8", 90 → "9");
    /// non-whole values render with one decimal place (e.g. 75 → "7.5",
    /// 82 → "8.2"). 0 renders as "0".
    var averageScoreOutOf10: String {
        let value = Double(self) / 10.0
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

extension Media {
    /// Deterministic positive id for an on-device-only title, derived from a stable
    /// source key via FNV-1a (not Swift's per-launch-seeded hashValue), so the id and
    /// resulting uniqueId ("local-<id>") are reproducible across launches.
    static func localId(forKey key: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)   // clear sign bit → positive
    }

    /// Builds a `.local` Media for a module-scraped or imported title.
    static func local(source: LocalSource, title: String, imageUrl: String?, episodes: Int?) -> Media {
        let key: String
        switch source.kind {
        case .module:    key = "\(source.moduleId ?? "")|\(source.detailHref ?? title)"
        case .localFile: key = source.localImportName ?? title
        }
        return Media(
            id: localId(forKey: key), idMal: nil, provider: .local,
            title: MediaTitle(romaji: nil, english: title, native: nil),
            coverImage: MediaCoverImage(large: imageUrl, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: episodes,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil,
            studioNames: nil, source: nil, duration: nil, airDateRange: nil
        )
    }

    /// Builds a `.local` manga Media (`type: "MANGA"`). `chapters` populates the
    /// `episodes` field, reused as the chapter-count unit for manga.
    static func localManga(source: LocalSource, title: String, imageUrl: String?, chapters: Int?) -> Media {
        let base = local(source: source, title: title, imageUrl: imageUrl, episodes: chapters)
        return Media(
            id: base.id, idMal: base.idMal, provider: base.provider,
            title: base.title, coverImage: base.coverImage,
            bannerImage: nil, description: nil, episodes: chapters,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: "MANGA", format: nil,
            studioNames: nil, source: nil, duration: nil, airDateRange: nil
        )
    }
}

struct MediaTitle: Codable, Equatable, Hashable {
    let romaji: String?
    let english: String?
    let native: String?

    var displayTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        for lang in priority.components(separatedBy: ",") {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji,  !r.isEmpty { return r }
            case "native":  if let n = native,  !n.isEmpty { return n }
            default: break
            }
        }
        return english ?? romaji ?? native ?? "Unknown"
    }

    var searchTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        for lang in priority.components(separatedBy: ",") {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji,  !r.isEmpty { return r }
            case "native":  if let n = native,  !n.isEmpty { return n }
            default: break
            }
        }
        return romaji ?? english ?? native ?? ""
    }
}

struct MediaCoverImage: Codable, Equatable, Hashable {
    let large: String?
    let extraLarge: String?
    var best: String? { extraLarge ?? large }
}

struct MediaAiringEpisode: Codable, Equatable, Hashable {
    let episode: Int
    let airingAt: Int?        // Unix timestamp
    let timeUntilAiring: Int? // Seconds until airing

    /// Formatted countdown (e.g. "in 2d 5h").
    var countdownDisplay: String? {
        guard let seconds = timeUntilAiring, seconds > 0 else { return nil }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(mins)m"
    }
}

struct MediaRelations: Codable, Equatable, Hashable {
    let edges: [MediaRelationEdge]
}

struct MediaRelationEdge: Codable, Identifiable, Equatable, Hashable {
    var id: Int { node.id }
    let relationType: String
    let node: Media

    func hash(into hasher: inout Hasher) { hasher.combine(relationType); hasher.combine(node.uniqueId) }
    static func == (lhs: MediaRelationEdge, rhs: MediaRelationEdge) -> Bool {
        lhs.relationType == rhs.relationType && lhs.node == rhs.node
    }

    var formattedRelation: String {
        relationType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - HTML Entity Decoding (item 19)

extension String {
    /// Decodes common HTML entities (&quot;, &amp;, &#039;, etc.) to their
    /// actual characters so they don't appear literally in displayed text.
    func decodingHTMLEntities() -> String {
        var result = self
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&amp;", "&"), ("&apos;", "'"),
            ("&#039;", "'"), ("&#39;", "'"), ("&lt;", "<"),
            ("&gt;", ">"), ("&hellip;", "…"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&nbsp;", " "), ("&laquo;", "«"),
            ("&raquo;", "»"), ("&trade;", "™"), ("&copy;", "©"),
            ("&reg;", "®"), ("&deg;", "°"), ("&para;", "¶"),
            ("&middot;", "·"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""), ("&sbquo;", ","),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode numeric entities like &#1234; and &#x4D2;
        while let range = result.range(of: #"&#x?[0-9a-fA-F]+;"#, options: .regularExpression) {
            let entity = String(result[range])
            let hex = entity.hasPrefix("&#x")
            let numStr = entity
                .replacingOccurrences(of: "&#", with: "")
                .replacingOccurrences(of: "x", with: "")
                .replacingOccurrences(of: ";", with: "")
            if let scalar = UInt32(hex ? numStr : String(Int(numStr) ?? 0), radix: hex ? 16 : 10),
               let char = Unicode.Scalar(scalar) {
                result = result.replacingCharacters(in: range, with: String(char))
            } else {
                break
            }
        }
        return result
    }

    /// Strips Markdown formatting artifacts (__, ~, !, *, etc.) and HTML
    /// tags from text (e.g. MAL/Jikan character "about" fields). Converts
    /// __bold__ to just the text, removes ~~strikethrough~~, strips
    /// !~...!~ wrappers, removes remaining HTML tags, and decodes entities.
    func cleanMarkdownAndHTML() -> String {
        var result = self
        // Remove Markdown bold/underline markers: __text__ → text
        result = result.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        // Remove Markdown strikethrough: ~~text~~ → text
        result = result.replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)
        // Remove !~...!~ wrappers (MAL's custom spoiler/strikethrough)
        result = result.replacingOccurrences(of: #"!~([^!]+)!~"#, with: "$1", options: .regularExpression)
        // Remove single * markers (italic/bold)
        result = result.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        // Remove remaining HTML tags
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Remove Markdown links [text](url) → text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Decode HTML entities
        result = result.decodingHTMLEntities()
        // Clean up multiple consecutive newlines
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
