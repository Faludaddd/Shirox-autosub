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
///
/// Batch 27 — AnimeSchedule was REMOVED from the app entirely (provider,
/// models, UI, settings entries, token row: zero active code remains).
/// The schedule chain is now AniChart → MAL → AniList → Jikan, with the
/// Kitsu+TVDB timetable synthesis as the final live source.
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
