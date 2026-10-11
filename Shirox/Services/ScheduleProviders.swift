import Foundation

// MARK: - AniChart (primary schedule source)

/// AniChart provider — the PRIMARY schedule source.
///
/// AniChart (anichart.net) is AniList's seasonal airing chart: its web
/// worker queries `graphql.anilist.co` with a week-window
/// `airingSchedules` query. This provider runs that exact query shape
/// through `AniListService.runQuery`, so it shares the SAME circuit
/// breaker, pacing, and Cloudflare handling as every other AniList
/// transport call — when the GraphQL backend is 403-down, AniChart fails
/// instantly without burning a request, and the chain moves on.
@MainActor
final class AniChartProvider {
    static let shared = AniChartProvider()

    private init() {}

    /// AniChart's airing query (extracted from anichart.net's own worker
    /// bundle): a week window of airing schedules with the chart's field
    /// set. Entries map into the app's unified schedule model with REAL
    /// AniList ids, so every row navigates.
    func entries(from startTs: Int, to endTs: Int) async throws -> [UnifiedScheduleEntry]? {
        // AniChart's worker queries page by page; our windows are small
        // (a week), so a generous perPage covers them in one page.
        let query = """
        query ($weekStart: Int, $weekEnd: Int) {
          Page(page: 1, perPage: 100) {
            airingSchedules(airingAt_greater: $weekStart, airingAt_lesser: $weekEnd) {
              id
              episode
              airingAt
              media {
                id
                idMal
                title { romaji english native }
                coverImage { large extraLarge }
                format
                genres
                averageScore
                countryOfOrigin
                isAdult
              }
            }
          }
        }
        """
        let data = try await AniListService.shared.runQuery(
            query: query,
            variables: ["weekStart": startTs, "weekEnd": endTs])

        struct Envelope: Decodable {
            struct PageData: Decodable {
                struct Schedule: Decodable {
                    let id: Int
                    let episode: Int
                    let airingAt: Int
                    let media: Media?
                }
                struct Media: Decodable {
                    let id: Int
                    let idMal: Int?
                    struct Title: Decodable { let romaji: String?; let english: String?; let native: String? }
                    let title: Title?
                    struct Cover: Decodable { let large: String?; let extraLarge: String? }
                    let coverImage: Cover?
                    let format: String?
                    let genres: [String]?
                    let averageScore: Int?
                    let isAdult: Bool?
                }
                let airingSchedules: [Schedule]?
            }
            struct Data: Decodable { let Page: PageData? }
            let data: Data?
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let schedules = envelope.data?.Page?.airingSchedules ?? []
        return schedules.compactMap { schedule -> UnifiedScheduleEntry? in
            guard let media = schedule.media, !(media.isAdult ?? false) else { return nil }
            let title = media.title?.english ?? media.title?.romaji ?? media.title?.native ?? "Unknown"
            return UnifiedScheduleEntry(
                id: schedule.id,
                source: .anime,
                sourceMediaId: media.id,
                aniListMediaId: media.id,
                title: title,
                airingAt: schedule.airingAt,
                episode: schedule.episode,
                season: nil,
                coverImage: media.coverImage?.extraLarge ?? media.coverImage?.large,
                format: media.format,
                isStreamingRelease: false,
                genres: media.genres,
                popularity: media.averageScore ?? 0)
        }
    }
}

// MARK: - AnimeSchedule.net (schedule fallback #1)

/// AnimeSchedule.net provider — schedule fallback #1 after AniChart.
///
/// Their v3 API is fully documented (animeschedule.net/api/v3/documentation)
/// with a weekly `/timetables` endpoint. It requires a free Bearer token
/// issued from an AnimeSchedule account (per their API terms, application
/// tokens must not be embedded in public code — so the app NEVER ships
/// one). Users who create their own free application token can paste it
/// in Data Sources settings; with a token the provider genuinely serves
/// the real timetable. Without one it reports "API token required" —
/// honestly, and the chain moves on to MAL.
@MainActor
final class AnimeScheduleProvider {
    static let shared = AnimeScheduleProvider()

    private let base = "https://animeschedule.net/api/v3"
    private let imageBase = "https://img.animeschedule.net/production/assets/public/img/"
    private let tokenKey = "animeschedule.apiToken.v1"

    /// The user's own API token (from animeschedule.net account settings).
    var apiToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: tokenKey) }
    }

    var isConfigured: Bool { !apiToken.isEmpty }

    /// In-flight dedup: one timetable request per week at a time.
    private var inFlight: [String: Task<[UnifiedScheduleEntry]?, Never>] = [:]

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Health check

    func healthCheck() async throws -> Bool {
        guard isConfigured else {
            throw ProviderChainError.allProvidersFailed(
                lastReason: "AnimeSchedule v3 requires a free API token from animeschedule.net (Account → API). Without it, requests are rejected 401.")
        }
        let entries = try await fetchTimetable(reference: Date())
        return !(entries ?? []).isEmpty
    }

    // MARK: - Timetable

    /// The week's airing entries as unified schedule rows. Their timetable
    /// carries no AniList/MAL ids, so rows from this source render with
    /// real titles/images/times but don't deep-navigate (identical to how
    /// unmapped Jikan rows already behave).
    func entries(from startTs: Int, to endTs: Int) async throws -> [UnifiedScheduleEntry]? {
        let key = "\(startTs)-\(endTs)"
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task<[UnifiedScheduleEntry]?, Never> { [weak self] in
            try? await self?.fetchTimetable(reference: Date(timeIntervalSince1970: TimeInterval(startTs)))
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let result else {
            throw ProviderChainError.allProvidersFailed(
                lastReason: isConfigured
                    ? "AnimeSchedule request failed (unauthorized or unreachable)"
                    : "AnimeSchedule requires an API token (Settings → Data Sources)")
        }
        // Window-filter their week to the requested range.
        return result.filter { $0.airingAt >= startTs && $0.airingAt <= endTs }
    }

    private struct TimetableEnvelope: Decodable {
        struct TimetableAnime: Decodable {
            let title: String?
            let route: String?
            let romaji: String?
            let english: String?
            let episodeDate: String?
            let episodeNumber: Int?
            let episodes: Int?
            let lengthMin: Int?
            let imageVersionRoute: String?
            let airType: String?
        }
        typealias Payload = [TimetableAnime]
    }

    private func fetchTimetable(reference: Date) async throws -> [UnifiedScheduleEntry]? {
        guard isConfigured else { return nil }
        // ISO week + year for the reference date.
        let calendar = Calendar(identifier: .iso8601)
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
        let year = comps.yearForWeekOfYear ?? 2026
        let week = comps.weekOfYear ?? 1
        guard let url = URL(string: "\(base)/timetables?year=\(year)&week=\(week)&tz=Asia/Tokyo") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 {
            throw ProviderChainError.allProvidersFailed(lastReason: "AnimeSchedule rejected the API token (401)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "AnimeSchedule HTTP \(http.statusCode)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<!DOCTYPE html") {
            throw ProviderChainError.allProvidersFailed(lastReason: "AnimeSchedule returned HTML, not API data")
        }
        guard let timetable = try? JSONDecoder().decode([TimetableEnvelope.TimetableAnime].self, from: data) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        var entries: [UnifiedScheduleEntry] = []
        for anime in timetable {
            guard let date = formatter.date(from: anime.episodeDate ?? "") else { continue }
            let title = anime.english ?? anime.title ?? anime.romaji ?? "Unknown"
            let cover = anime.imageVersionRoute.map { imageBase + $0 }
            // Stable synthetic id space for this source (no AniList ids
            // available from the timetable). FNV-1a over the route slug —
            // deterministic across launches, far clear of both AniList
            // airing ids and the Jikan 900M range.
            let idSeed = anime.route ?? title
            let syntheticId = 950_000_000 + Int(Media.localId(forKey: "animeschedule-\(idSeed)") % 40_000_000)
            entries.append(UnifiedScheduleEntry(
                id: syntheticId,
                source: .anime,
                sourceMediaId: 0,
                aniListMediaId: nil,
                title: title,
                airingAt: Int(date.timeIntervalSince1970),
                episode: anime.episodeNumber ?? 0,
                season: nil,
                coverImage: cover,
                format: "TV",
                isStreamingRelease: false,
                genres: nil,
                popularity: 0))
        }
        return entries
    }
}
