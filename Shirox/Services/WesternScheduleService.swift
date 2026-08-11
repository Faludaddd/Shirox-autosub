import Foundation

// MARK: - WesternScheduleEntry

/// A single episode of a Western TV show, fetched from the TVMaze schedule API.
struct WesternScheduleEntry: Identifiable, Hashable, Sendable {
    /// TVMaze episode id (unique per episode).
    let id: Int
    /// TVMaze show id.
    let showId: Int
    /// Show name.
    let showName: String
    /// Season number (1-based; 0 for specials).
    let season: Int
    /// Episode number within the season.
    let episode: Int
    /// Unix timestamp (seconds) of the air time, or `nil` if TVMaze didn't provide one.
    let airTimestamp: Int?
    /// Best-available cover image URL (original > medium; show > episode).
    let coverImage: String?
    /// Show language (e.g. "English", "Japanese").
    let language: String?
    /// Show genres (e.g. ["Drama", "Science-Fiction"]).
    let genres: [String]
    /// `true` when the show is released on a streaming/web channel (Netflix, Hulu, …) rather
    /// than a traditional broadcast network.
    let isStreamingRelease: Bool

    /// Convenience: the air date, or `nil` when `airTimestamp` is missing.
    var airDate: Date? {
        guard let ts = airTimestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
}

// MARK: - WesternScheduleService

/// Fetches Western TV episode schedules from the TVMaze API (`/schedule` + `/schedule/web`),
/// filtering out anime (Japanese + animation genre) and daily shows (≥4 airings/week).
actor WesternScheduleService {

    static let shared = WesternScheduleService()

    private let session: URLSession
    private let baseHost = "api.tvmaze.com"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": URLSession.randomUserAgent
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Fetches Western schedule entries for the next `dayCount` days (clamped to 1…14, default 7).
    ///
    /// For each day both the broadcast schedule (`/schedule`) and the streaming/web schedule
    /// (`/schedule/web`) are requested. Anime (Japanese language + Anime/Animation genre) and
    /// daily shows (normalized to ≥4 airings per week) are filtered out.
    func fetchSchedule(dayCount: Int = 7) async throws -> [WesternScheduleEntry] {
        let clampedDays = max(1, min(dayCount, 14))
        let dateStrings = Self.generateDates(count: clampedDays)

        // Fetch both endpoints for every day concurrently.
        var raw: [TVMazeScheduleEpisode] = []
        try await withThrowingTaskGroup(of: [TVMazeScheduleEpisode].self) { group in
            for date in dateStrings {
                group.addTask { try await self.fetchDay(date: date, web: false) }
                group.addTask { try await self.fetchDay(date: date, web: true) }
            }
            for try await batch in group {
                raw.append(contentsOf: batch)
            }
        }

        // De-duplicate by episode id (broadcast + web endpoints can overlap for some shows).
        var seen = Set<Int>()
        let deduped = raw.filter { seen.insert($0.id).inserted }

        // Drop anime (Japanese + animation genre).
        let nonAnime = deduped.filter { !Self.isAnime($0.show) }

        // Drop daily shows — those that air ≥4 times per week (normalized to the fetched window).
        let showCounts = Self.countByShowId(nonAnime)
        let weeklyThreshold = 4
        let filtered = nonAnime.filter { ep in
            let count = showCounts[ep.show.id] ?? 0
            // Normalize the observed count to a 7-day week.
            let weeklyRate = (count * 7) / max(clampedDays, 1)
            return weeklyRate < weeklyThreshold
        }

        let entries = filtered.map { Self.makeEntry(from: $0) }
        // Sort by air time (entries without a timestamp sink to the end).
        return entries.sorted { lhs, rhs in
            (lhs.airTimestamp ?? Int.max) < (rhs.airTimestamp ?? Int.max)
        }
    }

    // MARK: - Fetching

    /// Fetches one day's episodes from either the broadcast or web schedule endpoint.
    private func fetchDay(date: String, web: Bool) async throws -> [TVMazeScheduleEpisode] {
        let path = web ? "/schedule/web" : "/schedule"
        var components = URLComponents()
        components.scheme = "https"
        components.host = baseHost
        components.path = path
        components.queryItems = [URLQueryItem(name: "date", value: date)]

        guard let url = components.url else { return [] }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            Logger.shared.log("[WesternSchedule] Network error fetching \(url.path)?date=\(date): \(error)", type: "Error")
            throw error
        }

        guard let http = response as? HTTPURLResponse else { return [] }
        // TVMaze returns 404 (with an empty body) for dates with no episodes — treat as empty.
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode != 404 {
                Logger.shared.log("[WesternSchedule] HTTP \(http.statusCode) for \(url.path)?date=\(date)", type: "Error")
            }
            return []
        }
        if data.isEmpty { return [] }

        do {
            return try JSONDecoder().decode([TVMazeScheduleEpisode].self, from: data)
        } catch {
            Logger.shared.log("[WesternSchedule] Decode error for \(url.path)?date=\(date): \(error)", type: "Error")
            return []
        }
    }

    // MARK: - Pure Helpers (nonisolated)

    /// Generates `count` date strings (`yyyy-MM-dd`) starting today.
    private static func generateDates(count: Int) -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: Date())
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return formatter.string(from: date)
        }
    }

    /// Returns `true` if the show is anime (Japanese language + an animation genre).
    /// Western animation (English + Animation) is kept; Japanese live-action is kept.
    private static func isAnime(_ show: TVMazeScheduleEpisode.Show) -> Bool {
        let language = (show.language ?? "").lowercased()
        guard language.contains("japanese") else { return false }
        let animationGenres: Set<String> = ["anime", "animation"]
        return show.genres.contains { animationGenres.contains($0.lowercased()) }
    }

    /// Counts episodes per show id across the supplied list.
    private static func countByShowId(_ episodes: [TVMazeScheduleEpisode]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for ep in episodes {
            counts[ep.show.id, default: 0] += 1
        }
        return counts
    }

    /// Parses a TVMaze ISO8601 `airstamp` into a Unix timestamp (seconds).
    private static func parseTimestamp(_ airstamp: String?) -> Int? {
        guard let raw = airstamp, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return Int(date.timeIntervalSince1970)
        }
        // Fallback without fractional seconds.
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        if let date = fallback.date(from: raw) {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    /// Converts a decoded TVMaze episode into a `WesternScheduleEntry`.
    private static func makeEntry(from ep: TVMazeScheduleEpisode) -> WesternScheduleEntry {
        let cover = ep.show.image?.original
            ?? ep.show.image?.medium
            ?? ep.image?.original
            ?? ep.image?.medium
        return WesternScheduleEntry(
            id: ep.id,
            showId: ep.show.id,
            showName: ep.show.name,
            season: ep.season,
            episode: ep.number,
            airTimestamp: parseTimestamp(ep.airstamp),
            coverImage: cover,
            language: ep.show.language,
            genres: ep.show.genres,
            isStreamingRelease: ep.show.webChannel != nil
        )
    }
}

// MARK: - TVMaze Decoding

private struct TVMazeScheduleEpisode: Decodable {
    let id: Int
    let name: String?
    let season: Int
    let number: Int
    let airstamp: String?
    let image: Image?
    let show: Show

    struct Show: Decodable {
        let id: Int
        let name: String
        let language: String?
        let genres: [String]
        let image: Image?
        let network: Network?
        let webChannel: Network?
    }

    struct Image: Decodable {
        let medium: String?
        let original: String?
    }

    struct Network: Decodable {
        let id: Int
        let name: String?
    }
}
