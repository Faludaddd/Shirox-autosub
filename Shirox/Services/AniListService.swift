import Foundation
import Combine

// MARK: - Response wrappers with error handling

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
    let status: Int?
}

// MARK: - Page response structures

private struct PageData: Decodable {
    let Page: PageContent
}

private struct PageContent: Decodable {
    let media: [AniListMedia]
}

// MARK: - Media Data Wrapper

private struct MediaData: Decodable {
    let Media: AniListMedia
}

// MARK: - Service

final class AniListService {
    nonisolated(unsafe) static let shared = AniListService()

    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let session: URLSession

    // #92 — In-memory schedule cache. Populated by the splash preload
    // (`AniListService.shared.airingToday()` from `ShiroxApp.task`) so that
    // when `HomeView` / `ScheduleView` load a few moments later they can
    // reuse the same data instead of re-fetching. Keyed loosely by range:
    // if the cached range fully contains the requested range AND the cache
    // is still fresh (within `scheduleCacheTTL`), we filter the cached
    // entries to the requested window and return them. Otherwise we fetch
    // fresh and overwrite the cache. Synchronized via `scheduleCacheLock`
    // because `AniListService` is not actor-isolated and may be called from
    // any Task (including the `Task.detached` preload in `ShiroxApp`).
    private var scheduleCacheEntries: [AniListAiringScheduleItem] = []
    private var scheduleCacheFrom: Int = 0
    private var scheduleCacheTo: Int = 0
    private var scheduleCacheAt: Date = .distantPast
    private let scheduleCacheTTL: TimeInterval = 60  // seconds
    private let scheduleCacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Search filters for the AniList anime search. All fields are optional — when nil/empty,
    /// the filter is not applied. Used by `SearchView`'s filter sheet.
    struct SearchFilters: Equatable {
        var year: Int? = nil
        var season: String? = nil          // "WINTER", "SPRING", "SUMMER", "FALL"
        var format: String? = nil          // "TV", "MOVIE", "OVA", "ONA", "SPECIAL", "MUSIC"
        var status: String? = nil          // "FINISHED", "RELEASING", "NOT_YET_RELEASED", "CANCELLED"
        var genres: [String] = []
        var sort: String = "SEARCH_MATCH"

        // #91 — extended filters. All optional / default-valued so existing
        // call sites (e.g. `SearchFilters()`) keep their old behavior.
        var studio: String? = nil              // Animation studio name; client-side filtered (AniList Media has no studio-name arg).
        var source: String? = nil              // MediaSource — "MANGA", "LIGHT_NOVEL", "ORIGINAL", "ANIME", …
        var minEpisodes: Int? = nil            // Inclusive lower bound on episode count (AniList's `episodes_greater` is strict >).
        var maxEpisodes: Int? = nil            // Inclusive upper bound on episode count (AniList's `episodes_lesser` is strict <).
        var sortDescending: Bool = true        // Toggles the _DESC suffix on sort. SEARCH_MATCH ignores it.

        // #132 — Additional rich filters. All optional so existing stored
        // filters (and `SearchFilters()`) keep working.
        var minScore: Int? = nil               // Average score lower bound (0–100). AniList `averageScore_greater`.
        var maxScore: Int? = nil               // Average score upper bound (0–100). AniList `averageScore_lesser`.
        var tags: [String] = []                // AniList tag names (e.g. "Isekai", "School"). Sent via `tags` arg.
        var excludeGenres: [String] = []       // Genres to exclude. AniList `genres_exclude`.
        var excludeTags: [String] = []         // Tags to exclude. AniList `tags_exclude`.
        var countryOfOrigin: String? = nil     // "JP", "KR", "CN" etc. AniList `countryOfOrigin`.
        var minDuration: Int? = nil            // Episode duration lower bound (minutes). AniList `duration_greater`.
        var maxDuration: Int? = nil            // Episode duration upper bound (minutes). AniList `duration_lesser`.
        // Requirement #4 — Chapter count range (for manga search). AniList's
        // `chapters_greater` / `chapters_lesser` are strict inequalities, same
        // as episodes — we apply the same ±1 correction in the query builder.
        var minChapters: Int? = nil
        var maxChapters: Int? = nil
        var startDateAfter: String? = nil      // "YYYYMMDD" — only titles that started on/after this date.
        var startDateBefore: String? = nil     // "YYYYMMDD" — only titles that started on/before this date.
        var endDateAfter: String? = nil        // "YYYYMMDD" — only titles that ended on/after this date.
        var endDateBefore: String? = nil       // "YYYYMMDD" — only titles that ended on/before this date.
        var onlyHasEpisodes: Bool = false       // When true, requires `episodes` > 0 (filters out TBA/announcement titles).
        var hideRestricted: Bool = true        // Hardcoded true in the query regardless, but exposed so the sheet can show the lock state.

        static let defaultSort = "SEARCH_MATCH"
        static let empty = SearchFilters()
        var isEmpty: Bool {
            year == nil && season == nil && format == nil && status == nil
                && genres.isEmpty && sort == Self.defaultSort
                && (studio?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                && (source?.isEmpty ?? true)
                && minEpisodes == nil && maxEpisodes == nil
                && sortDescending == true
                && minScore == nil && maxScore == nil
                && tags.isEmpty && excludeGenres.isEmpty && excludeTags.isEmpty
                && (countryOfOrigin?.isEmpty ?? true)
                && minDuration == nil && maxDuration == nil
                && minChapters == nil && maxChapters == nil
                && startDateAfter == nil && startDateBefore == nil
                && endDateAfter == nil && endDateBefore == nil
                && !onlyHasEpisodes
        }

        /// Effective `[MediaSort]` value to send to AniList, derived from `sort`
        /// + `sortDescending`. `SEARCH_MATCH` has no direction and is returned as-is;
        /// everything else has `_DESC` appended (or stripped) per the toggle.
        var effectiveSort: String {
            let base = sort.hasSuffix("_DESC") ? String(sort.dropLast(5)) : sort
            if base == "SEARCH_MATCH" || base.isEmpty { return "SEARCH_MATCH" }
            return sortDescending ? "\(base)_DESC" : base
        }
    }

    func search(keyword: String, filters: SearchFilters = SearchFilters()) async throws -> [AniListMedia] {
        let effectiveKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var variables: [String: Any] = ["sort": [effectiveKeyword.isEmpty && filters.sort == "SEARCH_MATCH" ? "POPULARITY_DESC" : filters.effectiveSort]]
        if !effectiveKeyword.isEmpty { variables["search"] = effectiveKeyword }
        if let year = filters.year { variables["seasonYear"] = year }
        if let season = filters.season, !season.isEmpty { variables["season"] = season }
        if let format = filters.format, !format.isEmpty { variables["format"] = format }
        if let status = filters.status, !status.isEmpty { variables["status"] = status }
        if !filters.genres.isEmpty { variables["genres"] = filters.genres }
        if let source = filters.source, !source.isEmpty { variables["source"] = source }
        // AniList's `episodes_greater` / `episodes_lesser` are strict inequalities
        // (> / <), so subtract 1 from min and add 1 to max to make the filter
        // inclusive — the slider/field labels read "12+" / "24" and the results
        // match that intent (anime with episodes >= 12 / <= 24).
        if let minEp = filters.minEpisodes, minEp > 0 { variables["episodes_greater"] = minEp - 1 }
        if let maxEp = filters.maxEpisodes, maxEp > 0 { variables["episodes_lesser"] = maxEp + 1 }

        // #132 — New rich filters wired to AniList query args.
        if let minScore = filters.minScore, minScore > 0 { variables["averageScore_greater"] = minScore - 1 }
        if let maxScore = filters.maxScore, maxScore > 0 { variables["averageScore_lesser"] = maxScore + 1 }
        if !filters.tags.isEmpty { variables["tags"] = filters.tags }
        if !filters.excludeGenres.isEmpty { variables["genres_exclude"] = filters.excludeGenres }
        if !filters.excludeTags.isEmpty { variables["tags_exclude"] = filters.excludeTags }
        if let country = filters.countryOfOrigin, !country.isEmpty { variables["countryOfOrigin"] = country }
        if let minDur = filters.minDuration, minDur > 0 { variables["duration_greater"] = minDur - 1 }
        if let maxDur = filters.maxDuration, maxDur > 0 { variables["duration_lesser"] = maxDur + 1 }
        // Requirement #4 — Chapter count range (for manga search). AniList's
        // `chapters_greater` / `chapters_lesser` are strict inequalities, so
        // apply the same ±1 inclusive correction as episodes.
        if let minCh = filters.minChapters, minCh > 0 { variables["chapters_greater"] = minCh - 1 }
        if let maxCh = filters.maxChapters, maxCh > 0 { variables["chapters_lesser"] = maxCh + 1 }
        if let startDateAfter = filters.startDateAfter, !startDateAfter.isEmpty { variables["startDate_greater"] = startDateAfter }
        if let startDateBefore = filters.startDateBefore, !startDateBefore.isEmpty { variables["startDate_lesser"] = startDateBefore }
        if let endDateAfter = filters.endDateAfter, !endDateAfter.isEmpty { variables["endDate_greater"] = endDateAfter }
        if let endDateBefore = filters.endDateBefore, !endDateBefore.isEmpty { variables["endDate_lesser"] = endDateBefore }

        // `isAdult: false` is a contract of the AniList GraphQL API and is
        // required to exclude restricted titles from search results.
        var mediaArgs = ["type: ANIME", "sort: $sort", "isAdult: false"]
        if !effectiveKeyword.isEmpty { mediaArgs.append("search: $search") }
        if filters.year != nil { mediaArgs.append("seasonYear: $seasonYear") }
        if filters.season != nil { mediaArgs.append("season: $season") }
        if filters.format != nil { mediaArgs.append("format: $format") }
        if filters.status != nil { mediaArgs.append("status: $status") }
        if !filters.genres.isEmpty { mediaArgs.append("genres: $genres") }
        if filters.source != nil { mediaArgs.append("source: $source") }
        if filters.minEpisodes != nil { mediaArgs.append("episodes_greater: $episodes_greater") }
        if filters.maxEpisodes != nil { mediaArgs.append("episodes_lesser: $episodes_lesser") }
        // #132 — new arg wiring.
        if filters.minScore != nil { mediaArgs.append("averageScore_greater: $averageScore_greater") }
        if filters.maxScore != nil { mediaArgs.append("averageScore_lesser: $averageScore_lesser") }
        if !filters.tags.isEmpty { mediaArgs.append("tags: $tags") }
        if !filters.excludeGenres.isEmpty { mediaArgs.append("genres_exclude: $genres_exclude") }
        if !filters.excludeTags.isEmpty { mediaArgs.append("tags_exclude: $tags_exclude") }
        if filters.countryOfOrigin != nil { mediaArgs.append("countryOfOrigin: $countryOfOrigin") }
        if filters.minDuration != nil { mediaArgs.append("duration_greater: $duration_greater") }
        if filters.maxDuration != nil { mediaArgs.append("duration_lesser: $duration_lesser") }
        if filters.minChapters != nil { mediaArgs.append("chapters_greater: $chapters_greater") }
        if filters.maxChapters != nil { mediaArgs.append("chapters_lesser: $chapters_lesser") }
        if filters.startDateAfter != nil { mediaArgs.append("startDate_greater: $startDate_greater") }
        if filters.startDateBefore != nil { mediaArgs.append("startDate_lesser: $startDate_lesser") }
        if filters.endDateAfter != nil { mediaArgs.append("endDate_greater: $endDate_greater") }
        if filters.endDateBefore != nil { mediaArgs.append("endDate_lesser: $endDate_lesser") }

        let argList = mediaArgs.joined(separator: ", ")
        var varDecls = ["$sort: [MediaSort]"]
        if !effectiveKeyword.isEmpty { varDecls.append("$search: String") }
        if filters.year != nil { varDecls.append("$seasonYear: Int") }
        if filters.season != nil { varDecls.append("$season: MediaSeason") }
        if filters.format != nil { varDecls.append("$format: MediaFormat") }
        if filters.status != nil { varDecls.append("$status: MediaStatus") }
        if !filters.genres.isEmpty { varDecls.append("$genres: [String]") }
        if filters.source != nil { varDecls.append("$source: MediaSource") }
        if filters.minEpisodes != nil { varDecls.append("$episodes_greater: Int") }
        if filters.maxEpisodes != nil { varDecls.append("$episodes_lesser: Int") }
        // #132 — new var declarations.
        if filters.minScore != nil { varDecls.append("$averageScore_greater: Int") }
        if filters.maxScore != nil { varDecls.append("$averageScore_lesser: Int") }
        if !filters.tags.isEmpty { varDecls.append("$tags: [String]") }
        if !filters.excludeGenres.isEmpty { varDecls.append("$genres_exclude: [String]") }
        if !filters.excludeTags.isEmpty { varDecls.append("$tags_exclude: [String]") }
        if filters.countryOfOrigin != nil { varDecls.append("$countryOfOrigin: CountryCode") }
        if filters.minDuration != nil { varDecls.append("$duration_greater: Int") }
        if filters.maxDuration != nil { varDecls.append("$duration_lesser: Int") }
        if filters.minChapters != nil { varDecls.append("$chapters_greater: Int") }
        if filters.maxChapters != nil { varDecls.append("$chapters_lesser: Int") }
        if filters.startDateAfter != nil { varDecls.append("$startDate_greater: FuzzyDateInt") }
        if filters.startDateBefore != nil { varDecls.append("$startDate_lesser: FuzzyDateInt") }
        if filters.endDateAfter != nil { varDecls.append("$endDate_greater: FuzzyDateInt") }
        if filters.endDateBefore != nil { varDecls.append("$endDate_lesser: FuzzyDateInt") }
        let varDeclList = varDecls.joined(separator: ", ")

        let query = """
        query (\(varDeclList)) {
          Page(page: 1, perPage: 25) {
            media(\(argList)) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
              episodes
              status
              format
              season
              seasonYear
              source
              startDate { year month day }
              endDate { year month day }
              duration
              nextAiringEpisode { episode airingAt timeUntilAiring }
              studios { edges { isMain node { id name } } }
            }
          }
        }
        """
        var results = try await fetchPage(query: query, variables: variables)

        // #132 — `onlyHasEpisodes` is a client-side filter (AniList has no
        // "episodes is not null" arg). Drops titles with no episode count.
        if filters.onlyHasEpisodes {
            results = results.filter { ($0.episodes ?? 0) > 0 }
        }

        // AniList's Media query has no studio-name argument, so studio filtering
        // is done client-side against the studios already fetched above.
        let studioQuery = filters.studio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !studioQuery.isEmpty else { return results }
        return results.filter { media in
            guard let edges = media.studios?.edges, !edges.isEmpty else { return false }
            return edges.contains { $0.node.name.localizedCaseInsensitiveContains(studioQuery) }
        }
    }

    func search(keyword: String) async throws -> [AniListMedia] {
        return try await search(keyword: keyword, filters: SearchFilters())
    }

    /// AniList MANGA search, used to auto-match a module-scraped manga to a
    /// tracking entry. Selects `idMal` (→ MAL tracking for free) and `chapters`
    /// (total, for Completed promotion; nil when ongoing).
    func searchManga(keyword: String) async throws -> [AniListMedia] {
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 25) {
            media(search: $search, type: MANGA, sort: SEARCH_MATCH, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              chapters
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["search": keyword])
    }

    /// Normalized set of restricted anime title variants + synonyms matching
    /// `keyword`. Used by `ContentSafetyFilter` to screen module results.
    /// The `isAdult: true` GraphQL parameter is a contract of the AniList
    /// API and is required to identify the titles this filter must remove.
    func searchRestrictedTitles(keyword: String) async throws -> Set<String> {
        struct RestrictedPage: Decodable { let Page: RestrictedContent }
        struct RestrictedContent: Decodable { let media: [RestrictedMedia] }
        struct RestrictedMedia: Decodable {
            let title: AniListTitle
            let synonyms: [String]?
        }
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 25) {
            media(search: $search, type: ANIME, isAdult: true) {
              title { romaji english native }
              synonyms
            }
          }
        }
        """
        let data = try await post(query: query, variables: ["search": keyword])
        let response = try JSONDecoder().decode(GraphQLResponse<RestrictedPage>.self, from: data)
        var result = Set<String>()
        for media in response.data?.Page.media ?? [] {
            let variants: [String?] = [media.title.romaji, media.title.english, media.title.native]
                + (media.synonyms ?? []).map(Optional.some)
            for raw in variants {
                guard let raw, !raw.isEmpty else { continue }
                let norm = ContentSafetyFilter.normalize(raw)
                if !norm.isEmpty { result.insert(norm) }
            }
        }
        return result
    }

    func trending() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: TRENDING_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func seasonal() async throws -> [AniListMedia] {
        let (season, year) = AniListSeason.current()
        let query = """
        query ($season: MediaSeason, $year: Int) {
          Page(page: 1, perPage: 20) {
            media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["season": season.rawValue, "year": year])
    }

    func popular() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func topRated() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: SCORE_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    // MARK: - Seasonal & Schedule

    /// Anime from a specific season (e.g. Winter 2025), sorted by popularity.
    func seasonalBrowse(season: AniListSeason, year: Int, sort: String = "POPULARITY_DESC") async throws -> [AniListMedia] {
        let query = """
        query ($season: MediaSeason, $year: Int, $sort: [MediaSort]) {
          Page(page: 1, perPage: 30) {
            media(season: $season, seasonYear: $year, type: ANIME, sort: $sort, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              episodes
              duration
              status
              source
              format
              season
              seasonYear
              startDate { year month day }
              endDate { year month day }
              averageScore
              genres
              nextAiringEpisode { episode airingAt timeUntilAiring }
              studios { edges { isMain node { id name } } }
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["season": season.rawValue, "year": year, "sort": sort])
    }

    /// Recently completed anime from the previous season.
    /// Powers the "Recently Completed Last Season" home section.
    func recentlyCompletedLastSeason() async throws -> [AniListMedia] {
        let (season, year) = AniListSeason.previous()
        let query = """
        query ($season: MediaSeason, $year: Int) {
          Page(page: 1, perPage: 20) {
            media(season: $season, seasonYear: $year, type: ANIME, status: FINISHED, sort: POPULARITY_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              episodes
              duration
              status
              source
              format
              season
              seasonYear
              startDate { year month day }
              endDate { year month day }
              averageScore
              genres
              studios { edges { isMain node { id name } } }
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["season": season.rawValue, "year": year])
    }

    /// Upcoming anime (not yet released), sorted by popularity.
    func upcoming() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 30) {
            media(type: ANIME, status: NOT_YET_RELEASED, sort: POPULARITY_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              episodes
              status
              format
              season
              seasonYear
              startDate { year month day }
              averageScore
              genres
              studios { edges { isMain node { id name } } }
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    /// Anime airing today (next episode within the next 24 hours), sorted by airing time.
    /// Uses the AiringSchedule API for precise scheduling data.
    func airingToday() async throws -> [AniListAiringScheduleItem] {
        let now = Int(Date().timeIntervalSince1970)
        let tomorrow = now + 86400
        return try await airingSchedules(from: now, to: tomorrow)
    }

    /// Anime airing within the next 7 days, sorted by airing time.
    func airingThisWeek() async throws -> [AniListAiringScheduleItem] {
        let now = Int(Date().timeIntervalSince1970)
        let nextWeek = now + (86400 * 7)
        return try await airingSchedules(from: now, to: nextWeek)
    }

    /// Fetches airing schedules in a time range. Returns one entry per episode airing.
    ///
    /// AniList's `Page` only returns up to `perPage` results per request (here 50), so we
    /// paginate through all available pages up to a safety cap of 20 (1000 entries). A short
    /// delay is inserted between requests to stay within AniList's rate limits. This matters
    /// because long-running series (e.g. *Bleach: Thousand-Year Blood War*) frequently land
    /// beyond the first page and would otherwise be missing from "airing today/this week".
    ///
    /// #92 — Results are cached for `scheduleCacheTTL` seconds (60s). When a
    /// request arrives whose `[from, to]` window is fully contained in the
    /// cached window AND the cache is still fresh, the cached entries are
    /// filtered to the requested window and returned without a network call.
    /// This lets the splash preload (`airingToday()`) populate the cache so
    /// that `HomeView` / `ScheduleView` — which fetch slightly different
    /// windows — can reuse the data instead of re-fetching on first render.
    func airingSchedules(from: Int, to: Int) async throws -> [AniListAiringScheduleItem] {
        // 1. Try the cache first.
        if let cached = scheduleCacheLookup(from: from, to: to) {
            return cached
        }

        struct AiringPage: Decodable { let Page: AiringSchedulePage }
        struct AiringSchedulePage: Decodable {
            let airingSchedules: [AiringScheduleData]?
            let pageInfo: PageInfo?
        }
        struct PageInfo: Decodable {
            let currentPage: Int?
            let hasNextPage: Bool?
        }
        struct AiringScheduleData: Decodable {
            let id: Int
            let episode: Int
            let airingAt: Int
            let media: AniListMedia
        }

        let query = """
        query ($airingGreater: Int, $airingLess: Int, $page: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { currentPage hasNextPage }
            airingSchedules(airingAt_greater: $airingGreater, airingAt_lesser: $airingLess) {
              id
              episode
              airingAt
              media {
                id
                idMal
                title { romaji english native }
                coverImage { large extraLarge }
                bannerImage
                description(asHtml: false)
                episodes
                status
                format
                season
                seasonYear
                averageScore
                genres
                nextAiringEpisode { episode airingAt timeUntilAiring }
                studios { edges { isMain node { id name } } }
              }
            }
          }
        }
        """

        let maxPages = 20
        var all: [AniListAiringScheduleItem] = []

        for page in 1...maxPages {
            let data = try await post(query: query, variables: [
                "airingGreater": from,
                "airingLess": to,
                "page": page
            ])
            let response = try JSONDecoder().decode(GraphQLResponse<AiringPage>.self, from: data)
            let schedules = response.data?.Page.airingSchedules ?? []
            all.append(contentsOf: schedules.map {
                AniListAiringScheduleItem(id: $0.id, episode: $0.episode, airingAt: $0.airingAt, media: $0.media)
            })

            let hasNextPage = response.data?.Page.pageInfo?.hasNextPage ?? false
            if !hasNextPage { break }

            // Rate-limit safety: pause between pages (skip after the final request).
            if page < maxPages {
                try await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            }
        }

        // 2. Populate the cache with the freshly fetched window.
        scheduleCacheStore(entries: all, from: from, to: to)

        return all
    }

    // MARK: - Schedule cache (#92)

    /// #93 — Public, fetch-free cache probe. Returns the cached schedule
    /// entries filtered to the requested `[from, to]` window if the cache is
    /// fresh AND (with tolerance) fully contains the requested window. Returns
    /// `nil` otherwise. Used by `ScheduleView.load()` to skip a redundant
    /// network call when the splash preload already populated the cache with
    /// the same window.
    ///
    /// This is a thin public wrapper around `scheduleCacheLookup` so callers
    /// outside the service can decide whether to fetch without accidentally
    /// triggering one.
    func cachedAiringSchedules(from: Int, to: Int) -> [AniListAiringScheduleItem]? {
        scheduleCacheLookup(from: from, to: to)
    }

    /// Returns the cached schedule entries filtered to the requested
    /// `[from, to]` window if the cache is fresh AND (with a small tolerance)
    /// fully contains the requested window. Returns `nil` otherwise (caller
    /// must fetch fresh).
    ///
    /// The tolerance accounts for the fact that `airingToday()` computes
    /// `now` on every call, so two calls a few seconds apart request slightly
    /// different windows. Without tolerance, the second call would always
    /// miss the cache even though the underlying data is identical. We expand
    /// the cached window by `cacheAge + 5s` on both ends so subsequent calls
    /// within the TTL still hit.
    private func scheduleCacheLookup(from: Int, to: Int) -> [AniListAiringScheduleItem]? {
        scheduleCacheLock.lock()
        defer { scheduleCacheLock.unlock() }
        // Cache empty or never populated.
        guard scheduleCacheAt != .distantPast else { return nil }
        let age = Date().timeIntervalSince(scheduleCacheAt)
        // Cache stale?
        if age > scheduleCacheTTL { return nil }
        // Tolerance: how much the cached window can be expanded to absorb
        // small `now`-shifts between calls.
        let tolerance = Int(age.rounded(.up)) + 5  // +5s safety margin
        // Cached window (expanded by tolerance) must fully contain the
        // requested window.
        guard scheduleCacheFrom - tolerance <= from,
              scheduleCacheTo + tolerance >= to else { return nil }
        // Filter to the requested window.
        return scheduleCacheEntries.filter { $0.airingAt >= from && $0.airingAt <= to }
    }

    /// Stores the freshly fetched schedule entries in the cache, expanding
    /// the cached window if the new fetch extends beyond the previous one
    /// (so subsequent requests for an even larger window can still hit).
    private func scheduleCacheStore(entries: [AniListAiringScheduleItem], from: Int, to: Int) {
        scheduleCacheLock.lock()
        defer { scheduleCacheLock.unlock() }
        // If we already have a fresh cache that fully contains this new
        // window, merge the new entries in (deduped by `id`) so we keep the
        // broadest possible cached window without losing any data. Otherwise
        // overwrite the cache with this fresh fetch.
        let now = Date()
        let isFresh = scheduleCacheAt != .distantPast
            && now.timeIntervalSince(scheduleCacheAt) <= scheduleCacheTTL
        if isFresh, scheduleCacheFrom <= from, scheduleCacheTo >= to {
            // Merge — keep existing entries plus any new ones we hadn't seen.
            var seen = Set(scheduleCacheEntries.map { $0.id })
            var merged = scheduleCacheEntries
            for entry in entries where seen.insert(entry.id).inserted {
                merged.append(entry)
            }
            scheduleCacheEntries = merged
        } else {
            // Overwrite with the fresh fetch (broaden the cached window if
            // the new fetch extends beyond what was cached before).
            scheduleCacheEntries = entries
            scheduleCacheFrom = from
            scheduleCacheTo = to
        }
        scheduleCacheAt = now
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [AniListMedia] {
        // All four categories share the same field selection and perPage; only
        // the `sort` (and, for `.seasonal`, the season/seasonYear filters)
        // differ. Building the query from a single template avoids four
        // near-identical ~15-line GraphQL string literals drifting out of sync.
        let sort: String
        var mediaArgs = ["type: ANIME", "isAdult: false"]
        var varDecls = ["$page: Int"]
        var variables: [String: Any] = ["page": page]

        switch category {
        case .trending:
            sort = "TRENDING_DESC"
        case .seasonal:
            sort = "POPULARITY_DESC"
            let (season, year) = AniListSeason.current()
            mediaArgs.append(contentsOf: ["season: $season", "seasonYear: $year"])
            varDecls.append(contentsOf: ["$season: MediaSeason", "$year: Int"])
            variables["season"] = season.rawValue
            variables["year"] = year
        case .popular:
            sort = "POPULARITY_DESC"
        case .topRated:
            sort = "SCORE_DESC"
        }
        mediaArgs.append("sort: \(sort)")

        let argList = mediaArgs.joined(separator: ", ")
        let varDeclList = varDecls.joined(separator: ", ")
        let query = """
        query (\(varDeclList)) {
          Page(page: $page, perPage: 20) {
            media(\(argList)) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: variables)
    }

    func detail(id: Int) async throws -> AniListMedia {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME, isAdult: false) {
            id
            idMal
            title { romaji english native }
            coverImage { large extraLarge }
            bannerImage
            description(asHtml: false)
            episodes
            duration
            status
            source
            format
            season
            seasonYear
            startDate { year month day }
            endDate { year month day }
            nextAiringEpisode {
              episode
              airingAt
              timeUntilAiring
            }
            averageScore
            genres
            trailer { id site thumbnail }
            studios {
              edges {
                isMain
                node { id name }
              }
            }
            characters(sort: ROLE, perPage: 12) {
              edges {
                role
                node {
                  id
                  name { full native }
                  image { large medium }
                  description(asHtml: false)
                }
                voiceActors(language: JAPANESE, sort: ROLE) {
                  id
                  name { full native }
                  language
                  image { large medium }
                }
              }
            }
            recommendations(sort: RATING_DESC, perPage: 12) {
              nodes {
                rating
                mediaRecommendation {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  averageScore
                  episodes
                  status
                  format
                  season
                  seasonYear
                  genres
                }
              }
            }
            relations {
              edges {
                relationType
                node {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  status
                  type
                  format
                  episodes
                  season
                  seasonYear
                }
              }
            }
          }
        }
        """
        let data = try await post(query: query, variables: ["id": id])
        let response = try JSONDecoder().decode(GraphQLResponse<MediaData>.self, from: data)
        if let errors = response.errors {
            if errors.contains(where: { $0.status == 403 }) { throw AniListError.httpError(403) }
            throw AniListError.graphQL(errors.map(\.message).joined(separator: ", "))
        }
        guard let media = response.data?.Media else {
            throw AniListError.noData
        }
        return media
    }

    /// AniList detail for a MANGA id. Mirrors `detail(id:)` but queries the manga
    /// media type (chapters/volumes instead of episodes, no airing) and includes
    /// relations.
    ///
    /// #131 — Expanded field set so the manga detail page can render the same
    /// Statistics grid the anime page does: Type, Format, Status, Popularity,
    /// Chapters, Volumes, Score, Season, Start Date, Source, Studio/Publisher.
    func mangaDetail(id: Int) async throws -> AniListMedia {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: MANGA, isAdult: false) {
            id
            idMal
            title { romaji english native }
            coverImage { large extraLarge }
            bannerImage
            description(asHtml: false)
            chapters
            volumes
            status
            averageScore
            popularity
            genres
            format
            source
            countryOfOrigin
            season
            seasonYear
            startDate { year month day }
            endDate { year month day }
            studios { edges { isMain node { id name } } }
            relations {
              edges {
                relationType
                node {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  status
                  type
                  format
                }
              }
            }
          }
        }
        """
        let data = try await post(query: query, variables: ["id": id])
        let response = try JSONDecoder().decode(GraphQLResponse<MediaData>.self, from: data)
        if let errors = response.errors {
            if errors.contains(where: { $0.status == 403 }) { throw AniListError.httpError(403) }
            throw AniListError.graphQL(errors.map(\.message).joined(separator: ", "))
        }
        guard let media = response.data?.Media else { throw AniListError.noData }
        return media
    }

    // MARK: - Manga discovery
    //
    // Mirror of the anime discovery endpoints but with `type: MANGA`. Used by
    // `MangaHomeView` to populate its trending / popular / top-rated / latest
    // shelves. Each query selects the same field set as `mangaDetail` minus
    // the relations edges (the shelves don't render relations) so a shelf tap
    // can navigate to `AniListMangaDetailView` with enough metadata to render
    // the hero immediately while the full detail is fetched in the background.

    func mangaTrending() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: MANGA, sort: TRENDING_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              chapters
              volumes
              status
              averageScore
              popularity
              genres
              format
              source
              countryOfOrigin
              season
              seasonYear
              startDate { year month day }
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func mangaPopular() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: MANGA, sort: POPULARITY_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              chapters
              volumes
              status
              averageScore
              popularity
              genres
              format
              source
              countryOfOrigin
              season
              seasonYear
              startDate { year month day }
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func mangaTopRated() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: MANGA, sort: SCORE_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              chapters
              volumes
              status
              averageScore
              popularity
              genres
              format
              source
              countryOfOrigin
              season
              seasonYear
              startDate { year month day }
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    /// New releases — manga with the most recent `startDate` (newest first).
    /// Useful for a "Latest" shelf on the manga home page. AniList doesn't
    /// expose an `UPDATED_AT_DESC` for media directly, but `ID_DESC` gives
    /// roughly the newest entries (AniList IDs are monotonic by creation time).
    func mangaLatest() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: MANGA, sort: ID_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              chapters
              volumes
              status
              averageScore
              popularity
              genres
              format
              source
              countryOfOrigin
              season
              seasonYear
              startDate { year month day }
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    /// Free-text manga search used by the manga tab's search bar. Returns the
    /// same field set as `mangaTrending` so results can be tapped through to
    /// the manga detail page without an extra network call.
    func mangaSearch(keyword: String) async throws -> [AniListMedia] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = """
        query {
          Page(page: 1, perPage: 25) {
            media(type: MANGA, sort: POPULARITY_DESC, isAdult: false) {
              id
              idMal
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              description(asHtml: false)
              chapters
              volumes
              status
              averageScore
              popularity
              genres
              format
              source
              countryOfOrigin
              season
              seasonYear
              startDate { year month day }
            }
          }
        }
        """
        var variables: [String: Any] = [:]
        if !trimmed.isEmpty {
            query = """
            query ($search: String) {
              Page(page: 1, perPage: 25) {
                media(search: $search, type: MANGA, sort: SEARCH_MATCH, isAdult: false) {
                  id
                  idMal
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  description(asHtml: false)
                  chapters
                  volumes
                  status
                  averageScore
                  popularity
                  genres
                  format
                  source
                  countryOfOrigin
                  season
                  seasonYear
                  startDate { year month day }
                }
              }
            }
            """
            variables["search"] = trimmed
        }
        return try await fetchPage(query: query, variables: variables)
    }

    // MARK: - Private helpers

    private func fetchPage(query: String, variables: [String: Any] = [:]) async throws -> [AniListMedia] {
        let data = try await post(query: query, variables: variables)
        let response = try JSONDecoder().decode(GraphQLResponse<PageData>.self, from: data)
        if let errors = response.errors {
            if errors.contains(where: { $0.status == 403 }) { throw AniListError.httpError(403) }
            throw AniListError.graphQL(errors.map(\.message).joined(separator: ", "))
        }
        return response.data?.Page.media ?? []
    }

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

        Logger.shared.log("AniList Request: \(bodyDict)", type: "Network")

        let (data, response) = try await session.data(for: request)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Logger.shared.log("AniList Response: \(json)", type: "Network")
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                return data
            case 429:
                throw AniListError.rateLimited
            default:
                throw AniListError.httpError(http.statusCode)
            }
        }
        return data
    }
}

// MARK: - Errors

enum AniListError: LocalizedError {
    case rateLimited
    case httpError(Int)
    case graphQL(String)
    case noData
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "AniList rate limit reached. Please wait a moment."
        case .httpError(let code):
            return "HTTP error \(code). Please try again."
        case .graphQL(let message):
            return "AniList error: \(message)"
        case .noData:
            return "No data received from AniList."
        case .decodingError(let message):
            return "Failed to parse response: \(message)"
        }
    }
}

// MARK: - AniList Mapping Manager

/// Manages persistent mappings between standard module titles and AniList IDs.
final class AniListMappingManager {
    nonisolated(unsafe) static let shared = AniListMappingManager()
    
    private let userDefaults = UserDefaults.standard
    private let storageKey = "com.shirox.anilist_mappings"
    
    // Dictionary of moduleTitle -> aniListID
    private var mappings: [String: Int] = [:]
    
    private init() {
        loadMappings()
    }
    
    func saveMapping(title: String, aniListID: Int) {
        mappings[title.lowercased()] = aniListID
        persist()
    }
    
    func getMapping(title: String) -> Int? {
        return mappings[title.lowercased()]
    }
    
    func removeMapping(title: String) {
        mappings.removeValue(forKey: title.lowercased())
        persist()
    }
    
    private func loadMappings() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.mappings = decoded
        }
    }
    
    private func persist() {
        if let encoded = try? JSONEncoder().encode(mappings) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Browse Category

enum BrowseCategory: String, CaseIterable, Hashable {
    case trending
    case seasonal
    case popular
    case topRated

    var title: String {
        switch self {
        case .trending: return "Trending Now"
        case .seasonal: return "This Season"
        case .popular:  return "All-Time Popular"
        case .topRated: return "Top Rated"
        }
    }
}

// MARK: - TVDB Mapping Service

@MainActor final class TVDBMappingService: ObservableObject {
    static let shared = TVDBMappingService()
    private let mappingEndpoint = "https://api.anira.dev/mappings/"
    private let tvdbEndpoint = "https://api4.thetvdb.com/v4"
    private let apiKey = "4cd66d53-3c21-45a7-9dd2-e4a9c2ed20a8"
    private let cacheKey = "tvdb_mappings_cache_v4"
    private let malCacheKey = "tvdb_mal_mappings_cache_v1"
    private let bulkFetchedAtKey = "anira_all_mappings_fetchedAt_v1"
    /// How long a cached /mappings/all snapshot is considered fresh before re-fetching.
    private let bulkTTL: TimeInterval = 60 * 60 * 24  // 1 day

    @Published private var token: String?
    private var tokenExpiry: Date?

    // Cache: AniListID or MALID -> (TVDB_ID, SeasonNumber, PosterPath?, FanartPath?)
    struct CachedData: Codable {
        let tid: Int
        var season: Int?
        var epOffset: Int?
        var epOffsetFetched: Bool?  // nil = old entry (pre-epOffset), true = fetched fresh
        var posterPath: String?
        var fanartPath: String?
    }
    private var cache: [Int: CachedData] = [:]       // keyed by AniList ID
    private var malCache: [Int: CachedData] = [:]     // keyed by MAL ID
    private var episodeCache: [Int: [AniMapEpisode]] = [:]
    private var malEpisodeCache: [Int: [AniMapEpisode]] = [:]
    private var aniraEpisodeCache: [String: AniraEpisodeResponse] = [:]
    private var watchOrderCache: [Int: [AniraMediaEntry]] = [:]

    // Bulk ID-mapping snapshot from anira's /mappings/all — resolved locally instead of
    // hitting the per-id endpoint once per show. Seeded from disk on first use, refreshed
    // over the network when stale (see loadAllMappings).
    private var anilistMappingIndex: [Int: BulkMapping] = [:]
    private var malMappingIndex: [Int: BulkMapping] = [:]
    private var bulkLoaded = false
    private var bulkLoadTask: Task<Void, Never>?

    /// Subset of an anira /mappings/all entry we actually consume for TVDB resolution.
    struct BulkMapping: Codable, Sendable {
        let mal_id: Int?
        let anilist_id: Int?
        let tvdb_id: Int?
        let tvdb_season: Int?
        let tvdb_epoffset: Int?
    }

    struct AniraEpisodeResponse: Decodable {
        struct Skip: Decodable {
            let type: String
            let start: Double
            let end: Double
        }
        let episode: Int
        let title: String?
        let description: String?
        let thumbnail: String?
        let skips: [Skip]?
    }

    /// One entry from Anira's `/watch_order` (and identically-shaped `/similar`) response.
    /// `mappings.anilist_id` can be null for entries that only exist on other databases.
    struct AniraMediaEntry: Decodable, Identifiable {
        let title: String?
        let cover: String?
        let mappings: Mappings

        struct Mappings: Decodable {
            let anilist_id: Int?
            let mal_id: Int?
            let media_type: String?
        }

        /// Stable list identity — prefers AniList id, then MAL id, then title.
        var id: String { "\(mappings.anilist_id ?? mappings.mal_id ?? 0)-\(title ?? "")" }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([Int: CachedData].self, from: data) {
            self.cache = decoded
        }
        if let data = UserDefaults.standard.data(forKey: malCacheKey),
           let decoded = try? JSONDecoder().decode([Int: CachedData].self, from: data) {
            self.malCache = decoded
        }
    }

    private func authenticate() async throws -> String {
        if let t = token, let expiry = tokenExpiry, expiry > Date() {
            return t
        }

        struct LoginResponse: Decodable {
            struct Data: Decodable { let token: String }
            let data: Data
        }

        var request = URLRequest(url: URL(string: "\(tvdbEndpoint)/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apikey": apiKey])

        let (data, _) = try await Self.session.data(for: request)
        let res = try JSONDecoder().decode(LoginResponse.self, from: data)
        self.token = res.data.token
        self.tokenExpiry = Date().addingTimeInterval(3600 * 24 * 25) // Token usually lasts 1 month
        return res.data.token
    }

    private func mappingKey(for provider: ProviderType) -> String {
        provider == .mal ? "myanimelist" : "anilist"
    }

    private func tvdbCache(for provider: ProviderType) -> [Int: CachedData] {
        provider == .mal ? malCache : cache
    }

    private func setTVDBCache(_ data: CachedData, id: Int, provider: ProviderType) {
        if provider == .mal { malCache[id] = data } else { cache[id] = data }
    }

    func getTVDBId(for id: Int, provider: ProviderType = .anilist) async -> (id: Int, season: Int?)? {
        let cached = tvdbCache(for: provider)[id]
        // Only return from cache if we have a definitive result:
        // - tid < 0 means we already know there's no mapping
        // - epOffsetFetched == true means the entry was populated from a full fresh fetch
        if let cached, cached.tid < 0 { return nil }
        if let cached, cached.epOffsetFetched == true { return (cached.tid, cached.season) }

        // Primary: resolve from the bulk /mappings/all snapshot (one cached fetch, no per-id call).
        await loadAllMappings()
        let index = provider == .mal ? malMappingIndex : anilistMappingIndex
        if let m = index[id] {
            if let tid = m.tvdb_id {
                setTVDBCache(CachedData(tid: tid, season: m.tvdb_season, epOffset: m.tvdb_epoffset,
                                        epOffsetFetched: true,
                                        posterPath: cached?.posterPath, fanartPath: cached?.fanartPath),
                             id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
                return (tid, m.tvdb_season)
            }
            // Present in the snapshot but no TVDB id → definitively no TVDB mapping.
            setTVDBCache(CachedData(tid: -1, season: nil, epOffsetFetched: true), id: id, provider: provider)
            provider == .mal ? saveMALCache() : saveCache()
            return nil
        }

        // Fallback: id absent from the snapshot (e.g. added after the last refresh) — one per-id lookup.
        do {
            let key = mappingKey(for: provider)
            guard let url = URL(string: "\(mappingEndpoint)\(id)?mapping_key=\(key)") else { return nil }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            struct Mapping: Decodable { let tvdb_id: Int?; let tvdb_season: Int?; let tvdb_epoffset: Int? }
            let results = try JSONDecoder().decode([Mapping].self, from: data)
            if let first = results.first, let tid = first.tvdb_id {
                setTVDBCache(CachedData(tid: tid, season: first.tvdb_season, epOffset: first.tvdb_epoffset, epOffsetFetched: true), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
                return (tid, first.tvdb_season)
            } else {
                setTVDBCache(CachedData(tid: -1, season: nil, epOffsetFetched: true), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
            }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
        } catch {
            Logger.shared.log("TVDB mapping error (\(provider.rawValue)): \(error)", type: "Error")
        }
        return nil
    }

    // MARK: - Bulk /mappings/all

    /// Ensures the bulk mapping snapshot is loaded (deduping concurrent callers).
    private func loadAllMappings() async {
        if bulkLoaded { return }
        if let task = bulkLoadTask { await task.value; return }
        let task = Task { await performLoadAllMappings() }
        bulkLoadTask = task
        await task.value
        bulkLoadTask = nil
    }

    private func performLoadAllMappings() async {
        // 1. Seed from disk (any age) for instant availability.
        if anilistMappingIndex.isEmpty, let disk = await loadBulkFromDisk() {
            buildMappingIndices(from: disk)
        }
        // 2. Refresh from the network when we have nothing yet or the snapshot is stale.
        let fetchedAt = UserDefaults.standard.double(forKey: bulkFetchedAtKey)
        let isStale = Date().timeIntervalSince1970 - fetchedAt > bulkTTL
        if anilistMappingIndex.isEmpty || isStale {
            if let entries = await fetchAllMappings(), !entries.isEmpty {
                buildMappingIndices(from: entries)
                saveBulkToDisk(entries)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: bulkFetchedAtKey)
            }
        }
        // Only latch as "loaded" once we actually have data, so a failed cold start retries later.
        bulkLoaded = !anilistMappingIndex.isEmpty
    }

    private func fetchAllMappings() async -> [BulkMapping]? {
        guard let url = URL(string: "\(mappingEndpoint)all") else { return nil }
        do {
            let (data, resp) = try await Self.session.data(for: URLRequest(url: url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            // Decode the ~7MB payload off the main actor to avoid a UI hitch.
            return try await Task.detached(priority: .utility) {
                try JSONDecoder().decode([BulkMapping].self, from: data)
            }.value
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return nil
        } catch {
            Logger.shared.log("anira /mappings/all fetch failed: \(error)", type: "Error")
            return nil
        }
    }

    private func buildMappingIndices(from entries: [BulkMapping]) {
        var ani: [Int: BulkMapping] = [:]
        var mal: [Int: BulkMapping] = [:]
        ani.reserveCapacity(entries.count)
        mal.reserveCapacity(entries.count)
        for e in entries {
            if let a = e.anilist_id { ani[a] = e }
            if let m = e.mal_id { mal[m] = e }
        }
        anilistMappingIndex = ani
        malMappingIndex = mal
    }

    private var bulkFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("anira_all_mappings_v1.json")
    }

    private func saveBulkToDisk(_ entries: [BulkMapping]) {
        guard let url = bulkFileURL else { return }
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadBulkFromDisk() async -> [BulkMapping]? {
        guard let url = bulkFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([BulkMapping].self, from: data)
        }.value
    }

    /// Returns true if we've already checked TVDB for this ID (result may be positive or negative).
    func hasMappingResolved(for id: Int, provider: ProviderType = .anilist) -> Bool {
        tvdbCache(for: provider)[id] != nil
    }

    func cachedSeason(for id: Int, provider: ProviderType = .anilist) -> Int? {
        tvdbCache(for: provider)[id]?.season
    }

    func cachedEpOffset(for id: Int, provider: ProviderType = .anilist) -> Int? {
        tvdbCache(for: provider)[id]?.epOffset
    }

    func fetchAniraEpisode(id: Int, episodeNumber: Int, mappingKey: String = "anilist") async -> AniraEpisodeResponse? {
        let key = "\(id)-\(episodeNumber)-\(mappingKey)"
        if let cached = aniraEpisodeCache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/media/\(id)/episodes/\(episodeNumber)?mapping_key=\(mappingKey)"),
              let (data, _) = try? await Self.session.data(for: URLRequest(url: url)),
              let result = try? JSONDecoder().decode(AniraEpisodeResponse.self, from: data)
        else { return nil }
        aniraEpisodeCache[key] = result
        return result
    }

    /// Anira's recommended franchise watch order for a title. Returns [] when Anira has no
    /// data or returns a non-array error body for an unmapped id (mirrors the defensive
    /// decoding used for episodes). Cached in-memory per id.
    func fetchWatchOrder(id: Int, provider: ProviderType = .anilist) async -> [AniraMediaEntry] {
        if let cached = watchOrderCache[id] { return cached }
        let key = mappingKey(for: provider)
        guard let url = URL(string: "https://api.anira.dev/media/\(id)/watch_order?mapping_key=\(key)"),
              let (data, _) = try? await Self.session.data(for: URLRequest(url: url)),
              let results = try? JSONDecoder().decode([AniraMediaEntry].self, from: data)
        else { return [] }
        watchOrderCache[id] = results
        return results
    }

    func getCachedArtwork(for id: Int, provider: ProviderType = .anilist) -> (poster: String?, fanart: String?) {
        if let c = tvdbCache(for: provider)[id] {
            return (formatURL(c.posterPath), formatURL(c.fanartPath))
        }
        return (nil, nil)
    }

    func getArtwork(for id: Int, provider: ProviderType = .anilist) async -> (poster: String?, fanart: String?) {
        if let c = tvdbCache(for: provider)[id], c.posterPath != nil || c.fanartPath != nil {
            return (formatURL(c.posterPath), formatURL(c.fanartPath))
        }
        guard let mapping = await getTVDBId(for: id, provider: provider), mapping.id > 0 else {
            return (nil, nil)
        }
        let artwork = await fetchTVDBIdArtwork(tid: mapping.id, targetSeason: mapping.season)
        if provider == .mal {
            malCache[id]?.posterPath = artwork.poster
            malCache[id]?.fanartPath = artwork.fanart
            saveMALCache()
        } else {
            cache[id]?.posterPath = artwork.poster
            cache[id]?.fanartPath = artwork.fanart
            saveCache()
        }
        return (formatURL(artwork.poster), formatURL(artwork.fanart))
    }


    private func getEpisodesAniList(_ aniListId: Int) async -> [AniMapEpisode] {
        if let cached = episodeCache[aniListId] {
            return cached
        }
        
        // 1. Try the AniMap media episodes endpoint first (highly detailed)
        var aniMapResults: [AniMapEpisode] = []
        do {
            let urlString = "https://api.anira.dev/media/\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            aniMapResults = try JSONDecoder().decode([AniMapEpisode].self, from: data)
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch is DecodingError {
            // anira returns a non-array body ("Not Found"/error object) for titles it
            // has no mapping for. Expected — fall through to the TVDB/legacy fallbacks.
            Logger.shared.log("AniMap media episodes: no anira mapping for \(aniListId)", type: "Debug")
        } catch {
            Logger.shared.log("AniMap Media EP Error: \(error)", type: "Error")
        }

        if !aniMapResults.isEmpty {
            // If any episode is missing a thumbnail, merge in TVDB images
            let missingThumbnails = aniMapResults.contains { $0.thumbnail == nil }
            if missingThumbnails, let mapping = await getTVDBId(for: aniListId), mapping.id > 0 {
                let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
                if !tvdbEps.isEmpty {
                    let tvdbByNumber = Dictionary(uniqueKeysWithValues: tvdbEps.map { ($0.number, $0.image) })
                    let merged = aniMapResults.map { ep -> AniMapEpisode in
                        guard ep.thumbnail == nil, let img = tvdbByNumber[ep.episode] ?? tvdbByNumber[ep.absolute ?? -1] else { return ep }
                        return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                            episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                            season: ep.season, thumbnail: formatURL(img), title: ep.title)
                    }
                    episodeCache[aniListId] = merged
                    return merged
                }
            }
            episodeCache[aniListId] = aniMapResults
            return aniMapResults
        }
        
        // 2. Fallback to TVDB extended series data (direct API access)
        if let mapping = await getTVDBId(for: aniListId), mapping.id > 0 {
            let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
            if !tvdbEps.isEmpty {
                let mapped = tvdbEps.map { te in
                    AniMapEpisode(absolute: te.number, airdate: nil, description: te.overview,
                                  episode: te.number, filler_type: nil, mal_id: nil,
                                  season: te.seasonNumber, thumbnail: formatURL(te.image), title: te.name)
                }
                episodeCache[aniListId] = mapped
                return mapped
            }
        }
        
        // 3. Last resort fallback to legacy mapping episode endpoint
        do {
            let urlString = "\(mappingEndpoint)\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { return [] }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            let results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            episodeCache[aniListId] = results
            return results
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch is DecodingError {
            // Legacy mapping endpoint also returns a non-JSON body when it has no data
            // for this title. Expected — return the empty list below.
            Logger.shared.log("AniMap mapping episodes: no legacy mapping for \(aniListId)", type: "Debug")
        } catch {
            Logger.shared.log("AniMap Mapping EP Error: \(error)", type: "Error")
        }
        
        return []
    }

    private struct TVDBRawEpisode {
        let number: Int
        let seasonNumber: Int
        let image: String?
        let name: String?
        let overview: String?
    }

    private func fetchTVDBEpisodes(tid: Int, season: Int) async -> [TVDBRawEpisode] {
        struct TVDBEpisode: Decodable {
            let number: Int
            let seasonNumber: Int
            let image: String?
            let name: String?
            let overview: String?
        }
        struct TVDBExtendedResponse: Decodable {
            struct Data: Decodable { let episodes: [TVDBEpisode]? }
            let data: Data
        }
        do {
            let token = try await authenticate()
            let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await Self.session.data(for: req)
            let res = try JSONDecoder().decode(TVDBExtendedResponse.self, from: data)
            return (res.data.episodes ?? [])
                .filter { $0.seasonNumber == season }
                .map { TVDBRawEpisode(number: $0.number, seasonNumber: $0.seasonNumber,
                                     image: $0.image, name: $0.name, overview: $0.overview) }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch {
            Logger.shared.log("TVDB EP fetch error: \(error)", type: "Error")
            return []
        }
    }

    func getCachedEpisode(for id: Int, provider: ProviderType = .anilist, episodeNumber: Int) -> AniMapEpisode? {
        let eps = provider == .mal ? malEpisodeCache[id] : episodeCache[id]
        return eps?.first(where: { $0.episode == episodeNumber })
            ?? eps?.first(where: { $0.absolute == episodeNumber })
    }

    /// Resolves episode metadata for a given episode number, handling absolute/relative
    /// numbering mismatches via a four-step waterfall.
    func getEpisode(for id: Int, episodeNumber: Int, provider: ProviderType = .anilist) async -> AniMapEpisode? {
        // 1. In-memory cache (checks both .episode and .absolute fields)
        if let hit = getCachedEpisode(for: id, provider: provider, episodeNumber: episodeNumber) {
            return hit
        }

        // 2. Fresh network fetch + check both fields
        let eps = await getEpisodes(for: id, provider: provider)
        if let hit = eps.first(where: { $0.episode == episodeNumber })
                     ?? eps.first(where: { $0.absolute == episodeNumber }) {
            return hit
        }

        // 3. Offset fallback — ensures epOffset is cached, then tries ±offset variants
        _ = await getTVDBId(for: id, provider: provider)
        let offset = cachedEpOffset(for: id, provider: provider) ?? 0
        guard offset > 0 else { return nil }

        // Module absolute → AniList-relative (e.g. 25 − 24 = 1)
        let relative = episodeNumber - offset
        if relative > 0, let hit = eps.first(where: { $0.episode == relative }) {
            return hit
        }

        // AniList-relative → absolute (e.g. 1 + 24 = 25)
        let absolute = episodeNumber + offset
        if let hit = eps.first(where: { $0.episode == absolute }) {
            return hit
        }

        return nil
    }

    func getEpisodes(for id: Int, provider: ProviderType = .anilist) async -> [AniMapEpisode] {
        if provider != .mal { return await getEpisodesAniList(id) }
        if let cached = malEpisodeCache[id] { return cached }

        // 1. Try Anira MAL episodes endpoint first
        do {
            guard let url = URL(string: "https://api.anira.dev/media/\(id)/episodes?mapping_key=myanimelist") else { throw URLError(.badURL) }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            var results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            results = results.map { ep in
                guard let thumb = ep.thumbnail, !thumb.contains("mapping_key") else { return ep }
                return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                    episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                    season: ep.season, thumbnail: thumb + "?mapping_key=myanimelist", title: ep.title)
            }
            // If all titles are generic ("Episode N" or nil), fetch real titles from Jikan
            let allGeneric = results.allSatisfy { ep in
                guard let t = ep.title else { return true }
                return t.range(of: #"^Episode \d+$"#, options: .regularExpression) != nil
            }
            if allGeneric && !results.isEmpty {
                let jikanEps = (try? await MALDiscoveryService.shared.episodes(malId: id)) ?? []
                let titleByNumber = Dictionary(jikanEps.map { ($0.mal_id, $0.title) }, uniquingKeysWith: { $1 })
                results = results.map { ep in
                    let title = titleByNumber[ep.episode] ?? ep.title
                    guard title != ep.title else { return ep }
                    return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                        episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                        season: ep.season, thumbnail: ep.thumbnail, title: title)
                }
            }
            if !results.isEmpty {
                malEpisodeCache[id] = results
                return results
            }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch is DecodingError {
            // anira returns a non-array body for MAL ids it has no mapping for.
            // Expected — fall through to the TVDB fallback below.
            Logger.shared.log("Anira MAL episodes: no mapping for malId \(id)", type: "Debug")
        } catch {
            Logger.shared.log("Anira MAL episodes error: \(error)", type: "Error")
        }

        // 2. Fall back to TVDB
        if let mapping = await getTVDBId(for: id, provider: ProviderType.mal), mapping.id > 0 {
            let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
            if !tvdbEps.isEmpty {
                let mapped = tvdbEps.map { te in
                    AniMapEpisode(absolute: te.number, airdate: nil, description: te.overview,
                                  episode: te.number, filler_type: nil, mal_id: nil,
                                  season: te.seasonNumber, thumbnail: formatURL(te.image), title: te.name)
                }
                malEpisodeCache[id] = mapped
                return mapped
            }
        }

        return []
    }

    private func formatURL(_ path: String?) -> String? {
        guard let p = path else { return nil }
        if p.hasPrefix("http") { return p }
        return "https://artworks.thetvdb.com/banners/\(p)"
    }

    private func saveCache() {
        let snapshot = cache
        let key = cacheKey
        Task.detached(priority: .background) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private func saveMALCache() {
        let snapshot = malCache
        let key = malCacheKey
        Task.detached(priority: .background) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Shared TVDB artwork fetch used by both AniList and MAL paths.
    private func fetchTVDBIdArtwork(tid: Int, targetSeason: Int?) async -> (poster: String?, fanart: String?) {
        struct Artwork: Decodable {
            let image: String
            let type: Int
            let width: Int?
            let height: Int?
        }
        struct SeasonType: Decodable { let id: Int; let type: String? }
        struct Season: Decodable { let id: Int; let number: Int; let type: SeasonType? }
        struct SeriesExtended: Decodable {
            struct Data: Decodable { let artworks: [Artwork]?; let seasons: [Season]? }
            let data: Data
        }
        struct SeasonExtended: Decodable {
            struct Data: Decodable { let artwork: [Artwork]? }
            let data: Data
        }
        do {
            let token = try await authenticate()

            func fetchSeriesExtended() async -> SeriesExtended.Data? {
                let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await Self.session.data(for: req),
                      let res = try? JSONDecoder().decode(SeriesExtended.self, from: data) else { return nil }
                return res.data
            }
            func fetchSeasonArtwork(seasonId: Int) async -> [Artwork] {
                let url = URL(string: "\(tvdbEndpoint)/seasons/\(seasonId)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await Self.session.data(for: req),
                      let res = try? JSONDecoder().decode(SeasonExtended.self, from: data) else { return [] }
                return res.data.artwork ?? []
            }

            guard let seriesData = await fetchSeriesExtended() else { return (nil, nil) }
            let artworks = seriesData.artworks ?? []
            let bySize: (Artwork, Artwork) -> Bool = { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
            let fanart = artworks.filter { $0.type == 3 }.sorted(by: bySize).first?.image

            var poster: String?
            if let targetSeason {
                let officialSeasons = seriesData.seasons?.filter { $0.type?.type == "official" || $0.type?.id == 1 }
                if let seasonId = officialSeasons?.first(where: { $0.number == targetSeason })?.id {
                    let seasonArtworks = await fetchSeasonArtwork(seasonId: seasonId)
                    poster = seasonArtworks.filter { $0.type == 7 }.sorted(by: bySize).first?.image
                        ?? seasonArtworks.sorted(by: bySize).first?.image
                }
            }
            if poster == nil {
                poster = artworks.filter { $0.type == 2 }.sorted(by: bySize).first?.image
            }
            return (poster, fanart)
        } catch {
            Logger.shared.log("TVDB artwork fetch error: \(error)", type: "Error")
            return (nil, nil)
        }
    }
    }

    struct AniMapEpisode: Codable, Identifiable {
    var id: String { "\(episode)-\(season ?? 0)" }
    let absolute: Int?
    let airdate: String?
    let description: String?
    let episode: Int
    let filler_type: String?
    let mal_id: Int?
    let season: Int?
    let thumbnail: String?
    let title: String?
    }
