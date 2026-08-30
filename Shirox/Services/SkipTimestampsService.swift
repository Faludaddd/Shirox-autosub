import Foundation

@MainActor
final class SkipTimestampsService {
    static let shared = SkipTimestampsService()

    private struct CacheKey: Hashable {
        let aniListID: Int
        let episodeNumber: Int
    }

    private var cache: [CacheKey: SkipSegments] = [:]

    private init() {}

    func fetchSegments(aniListID: Int, episodeNumber: Int) async -> SkipSegments? {
        let key = CacheKey(aniListID: aniListID, episodeNumber: episodeNumber)
        if let cached = cache[key] { return cached }

        let tvdbSeason: Int
        let epoffset: Int
        if let mapping = await TVDBMappingService.shared.getTVDBId(for: aniListID) {
            tvdbSeason = mapping.season.flatMap { $0 > 0 ? $0 : nil } ?? 1
            epoffset = TVDBMappingService.shared.cachedEpOffset(for: aniListID) ?? 0
        } else {
            tvdbSeason = 1
            epoffset = 0
        }
        // If episodeNumber > epoffset the module uses absolute/TVDB numbering —
        // convert to AniList-relative for Anira and use the value directly as tvdbEpisode.
        let isAbsolute = epoffset > 0 && episodeNumber > epoffset
        let aniListEpisode = isAbsolute ? episodeNumber - epoffset : episodeNumber
        let tvdbEpisode = isAbsolute ? episodeNumber : episodeNumber + epoffset

        // 1. Try Anira per-episode endpoint first (has intro/outro in seconds)
        let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: aniListEpisode)
        if let skips = aniraEp?.skips, !skips.isEmpty {
            var result = SkipSegments()
            for skip in skips {
                guard let seg = Self.sanitized(startSeconds: skip.start, endSeconds: skip.end) else { continue }
                switch skip.type {
                case "op", "mixed-op": if result.intro == nil { result.intro = seg }
                case "ed", "mixed-ed": if result.credits == nil { result.credits = seg }
                case "recap": if result.recap == nil { result.recap = seg }
                default: break
                }
            }
            cache[key] = result
            return result
        }

        // 2. Fall back to introdb / theIntroDB
        let imdbID = await IDMappingService.shared.imdbId(forAnilistId: aniListID)
        let tmdb = await IDMappingService.shared.tmdbId(forAnilistId: aniListID)
        let isMovie = tmdb?.isMovie ?? false

        async let introDBResult = fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)
        async let theIntroDBResult = fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)

        var (introDB, theIntroDB) = await (introDBResult, theIntroDBResult)

        // If tvdbEpisode returned nothing and differs from the raw episode number, retry with the raw number
        if introDB?.hasSegments != true && tvdbEpisode != episodeNumber {
            introDB = await fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
        if theIntroDB == nil && tvdbEpisode != episodeNumber {
            theIntroDB = await fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
        let segments = merge(introdb: introDB, theintrodb: theIntroDB)
        cache[key] = segments
        return segments
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private fetches

    private func fetchIntroDB(imdbID: String?, season: Int, episode: Int, isMovie: Bool) async -> IntroDBResponse? {
        guard let imdbID else { return nil }
        var urlString = "https://api.introdb.app/segments?imdb_id=\(imdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(IntroDBResponse.self, from: data)
    }

    private func fetchTheIntroDB(tmdbID: Int?, season: Int, episode: Int, isMovie: Bool) async -> TheIntroDBResponse? {
        guard let tmdbID else { return nil }
        var urlString = "https://api.theintrodb.org/v2/media?tmdb_id=\(tmdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TheIntroDBResponse.self, from: data)
    }

    // MARK: - Merge

    /// Drops implausible segments so a Skip button never surfaces for an
    /// episode that has no (usable) intro data — v2.15 accuracy fix.
    /// Rules:
    ///   • end must be positive and at least 1s past the start
    ///   • a segment with no start ("from the beginning") may not claim to end
    ///     after 5 minutes — that shape only comes from wrong-show/wrong-episode
    ///     ID mappings, and was exactly what made the button appear on episodes
    ///     with nothing to skip.
    private static func sanitized(startMs: Double?, endMs: Double) -> SkipSegments.Segment? {
        guard endMs > 0 else { return nil }
        if let startMs {
            guard endMs > startMs + 1000 else { return nil }
        } else {
            guard endMs <= 300_000 else { return nil }
        }
        return SkipSegments.Segment(startMs: startMs, endMs: endMs)
    }

    /// Seconds-based convenience for Anira (which reports skip windows in seconds).
    private static func sanitized(startSeconds: Double, endSeconds: Double) -> SkipSegments.Segment? {
        sanitized(startMs: startSeconds * 1000, endMs: endSeconds * 1000)
    }

    private func merge(introdb: IntroDBResponse?, theintrodb: TheIntroDBResponse?) -> SkipSegments {
        var result = SkipSegments()

        if let seg = introdb?.intro.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms) }) {
            result.intro = seg
        } else if let seg = theintrodb?.intro?.first.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms ?? 0) }) {
            result.intro = seg
        }

        if let seg = introdb?.recap.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms) }) {
            result.recap = seg
        } else if let seg = theintrodb?.recap?.first.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms ?? 0) }) {
            result.recap = seg
        }

        if let seg = introdb?.outro.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms) }) {
            result.credits = seg
        } else if let seg = theintrodb?.credits?.first.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms ?? 0) }) {
            result.credits = seg
        }

        if let seg = theintrodb?.preview?.first.flatMap({ Self.sanitized(startMs: $0.start_ms, endMs: $0.end_ms ?? 0) }) {
            result.preview = seg
        }

        return result
    }
}

// MARK: - Response decodables (private to this file)

private struct IntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double
    }
    let intro: Segment?
    let recap: Segment?
    let outro: Segment?
    var hasSegments: Bool { intro != nil || recap != nil || outro != nil }
}

private struct TheIntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double?
    }
    let intro: [Segment]?
    let recap: [Segment]?
    let credits: [Segment]?
    let preview: [Segment]?
}
