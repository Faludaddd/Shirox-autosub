import Foundation

struct AniListMedia: Identifiable, Codable {
    let id: Int
    let idMal: Int?
    let title: AniListTitle
    let coverImage: AniListCoverImage
    let bannerImage: String?
    let description: String?
    let episodes: Int?
    let chapters: Int?        // manga total; nil for anime or ongoing manga
    let volumes: Int?         // #131 — manga volume total; nil for anime
    let status: String?
    let averageScore: Int?
    let popularity: Int?      // #131 — AniList popularity rank (user count)
    let genres: [String]?
    let season: String?
    let seasonYear: Int?
    let nextAiringEpisode: AniListAiringEpisode?
    let relations: AniListRelations?
    let type: String?
    let format: String?

    // Extended fields (all optional — existing decode paths are unaffected)
    let studios: AniListStudios?
    let characters: AniListCharacterConnection?
    let recommendations: AniListRecommendationConnection?
    let trailer: AniListTrailer?
    let source: String?           // "MANGA", "LIGHT_NOVEL", "ORIGINAL", etc.
    let duration: Int?            // episode length in minutes
    let startDate: AniListFuzzyDate?
    let endDate: AniListFuzzyDate?
    let countryOfOrigin: String?  // #131 — "JP", "KR", "CN" etc.

    var plainDescription: String? {
        guard let desc = description else { return nil }
        return desc
            .replacingOccurrences(of: "<br><br>", with: "\n\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusDisplay: String? {
        switch status {
        case "RELEASING": return "Airing"
        case "FINISHED": return "Finished"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status
        }
    }

    /// Primary studio (the one with isAnimation = true), if any.
    var mainStudio: AniListStudio? {
        studios?.edges.first { $0.isMain }?.node ?? studios?.edges.first?.node
    }

    /// Human-readable source material label.
    var sourceDisplay: String? {
        guard let source = source, !source.isEmpty else { return nil }
        return source.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Formatted air date range (e.g. "Oct 2007 – Mar 2008" or "Oct 2007").
    var airDateRange: String? {
        let start = startDate?.formatted ?? ""
        let end = endDate?.formatted ?? ""
        if start.isEmpty && end.isEmpty { return nil }
        if start.isEmpty { return end }
        if end.isEmpty { return start }
        if start == end { return start }
        return "\(start) – \(end)"
    }
}

struct AniListTitle: Codable {
    let romaji: String?
    let english: String?
    let native: String?

    var displayTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        let ordered = priority.components(separatedBy: ",")
        for lang in ordered {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji, !r.isEmpty { return r }
            case "native":  if let n = native, !n.isEmpty { return n }
            default: break
            }
        }
        return english ?? romaji ?? native ?? "Unknown"
    }

    var searchTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        let ordered = priority.components(separatedBy: ",")
        for lang in ordered {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji, !r.isEmpty { return r }
            case "native":  if let n = native, !n.isEmpty { return n }
            default: break
            }
        }
        return romaji ?? english ?? native ?? ""
    }
}

struct AniListCoverImage: Codable {
    let large: String?
    let extraLarge: String?

    var best: String? { extraLarge ?? large }
}

struct AniListAiringEpisode: Codable {
    let episode: Int
    let airingAt: Int?        // Unix timestamp of next airing
    let timeUntilAiring: Int? // Seconds until next airing

    /// Formatted countdown string (e.g. "in 2d 5h" or "in 3h 20m").
    var countdownDisplay: String? {
        guard let seconds = timeUntilAiring, seconds > 0 else { return nil }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(mins)m"
    }

    /// Absolute air date string (e.g. "Apr 15, 2025 3:00 PM").
    var airDateDisplay: String? {
        guard let ts = airingAt, ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

enum AniListSeason: String {
    case winter = "WINTER"
    case spring = "SPRING"
    case summer = "SUMMER"
    case fall = "FALL"

    static func current() -> (AniListSeason, Int) {
        let month = Calendar.current.component(.month, from: Date())
        let year = Calendar.current.component(.year, from: Date())
        let season: AniListSeason
        switch month {
        case 1...3: season = .winter
        case 4...6: season = .spring
        case 7...9: season = .summer
        default: season = .fall
        }
        return (season, year)
    }

    /// Returns the previous season and its year.
    /// e.g. if current is Spring 2025, returns Winter 2025.
    /// If current is Winter 2025, returns Fall 2024.
    static func previous() -> (AniListSeason, Int) {
        let (current, year) = current()
        switch current {
        case .winter: return (.fall, year - 1)
        case .spring: return (.winter, year)
        case .summer: return (.spring, year)
        case .fall: return (.summer, year)
        }
    }

    /// Returns the next season and its year.
    static func next() -> (AniListSeason, Int) {
        let (current, year) = current()
        switch current {
        case .winter: return (.spring, year)
        case .spring: return (.summer, year)
        case .summer: return (.fall, year)
        case .fall: return (.winter, year + 1)
        }
    }
}

struct AniListRelations: Codable {
    let edges: [AniListRelationEdge]
}

struct AniListRelationEdge: Codable, Identifiable {
    var id: Int { node.id }
    let relationType: String
    let node: AniListMedia

    var formattedRelation: String {
        relationType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Studios

struct AniListStudios: Codable {
    let edges: [AniListStudioEdge]
}

struct AniListStudioEdge: Codable {
    let node: AniListStudio
    let isMain: Bool
}

struct AniListStudio: Codable, Identifiable {
    let id: Int
    let name: String
}

// MARK: - Characters & Voice Actors

struct AniListCharacterConnection: Codable {
    let edges: [AniListCharacterEdge]
}

struct AniListCharacterEdge: Codable, Identifiable {
    var id: Int { node.id }
    let role: String?
    let node: AniListCharacter
    let voiceActors: [AniListVoiceActor]?
}

struct AniListCharacter: Codable, Identifiable {
    let id: Int
    let name: AniListCharacterName?
    let image: AniListCharacterImage?
    let description: String?
}

struct AniListCharacterName: Codable {
    let full: String?
    let native: String?
}

struct AniListCharacterImage: Codable {
    let large: String?
    let medium: String?
}

struct AniListVoiceActor: Codable, Identifiable {
    let id: Int
    let name: AniListCharacterName?
    let language: String?
    let image: AniListCharacterImage?
}

// MARK: - Recommendations

struct AniListRecommendationConnection: Codable {
    let nodes: [AniListRecommendation]
}

struct AniListRecommendation: Codable, Identifiable {
    var id: Int { rating }
    let rating: Int
    let mediaRecommendation: AniListMedia?
}

// MARK: - Trailer

struct AniListTrailer: Codable {
    let id: String?
    let site: String?   // "youtube", "dailymotion"
    let thumbnail: String?

    var youtubeURL: URL? {
        guard let id = id, let site = site?.lowercased(), site == "youtube" else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    var embedURL: URL? {
        guard let id = id, let site = site?.lowercased(), site == "youtube" else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(id)")
    }
}

// MARK: - Fuzzy Date (AniList's date format)

struct AniListFuzzyDate: Codable {
    let year: Int?
    let month: Int?
    let day: Int?

    /// Formatted as "Oct 2007" or "Oct 5, 2007" depending on available components.
    var formatted: String {
        var parts: [String] = []
        if let month = month, month >= 1 && month <= 12 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            parts.append(f.monthSymbols[month - 1])
        }
        if let day = day, day > 0 { parts.append("\(day),") }
        if let year = year, year > 0 { parts.append("\(year)") }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Airing Schedule Item

/// A single airing schedule entry: one episode of one anime, airing at a specific time.
struct AniListAiringScheduleItem: Identifiable {
    let id: Int
    let episode: Int
    let airingAt: Int          // Unix timestamp
    let media: AniListMedia

    /// Formatted countdown (e.g. "in 3h 20m" or "aired 2h ago").
    var countdownDisplay: String {
        let now = Int(Date().timeIntervalSince1970)
        let diff = airingAt - now
        if diff <= 0 {
            let ago = -diff
            let hours = ago / 3600
            if hours > 0 { return "aired \(hours)h ago" }
            return "aired just now"
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(mins)m"
    }

    var airDateDisplay: String {
        let date = Date(timeIntervalSince1970: TimeInterval(airingAt))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
