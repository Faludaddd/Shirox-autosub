import Foundation

final class MALDiscoveryService {
    nonisolated(unsafe) static let shared = MALDiscoveryService()
    private let base = URL(string: "https://api.jikan.moe/v4")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private init() {}

    // MARK: - Shared request layer (in-flight dedup + cache + rate limit)
    //
    // Prevents the "request storm" where multiple screens (HomeView,
    // MangaHomeView, Schedule, Search) all call fetchList("top/manga")
    // at nearly the same moment. Without dedup, each fires its own
    // independent Jikan request — 3-4 concurrent calls to the same
    // endpoint within the same second, which trips Jikan's 3 req/sec
    // rate limit and causes 429/504 cascading failures.
    //
    // With this layer:
    //   1. In-flight dedup: if a request for the same URL is already
    //      running, the caller awaits the same Task instead of firing
    //      a new one.
    //   2. Short-lived cache: successful results are cached for 120s
    //      so screens loading shortly after each other reuse the cache.
    //   3. Rate limiting: a minimum 400ms gap between outbound Jikan
    //      requests, enforced app-wide via a serial gate.

    private var inFlightTasks: [String: Task<Data, Error>] = [:]
    private var inFlightLock = NSLock()

    private var listCache: [String: (data: [JikanAnime], timestamp: Date)] = [:]
    private var singleCache: [String: (data: JikanAnime, timestamp: Date)] = [:]
    private let cacheTTL: TimeInterval = 120  // 2 minutes

    private var lastRequestTime: Date = .distantPast
    private let minRequestSpacing: TimeInterval = 0.4  // 400ms between Jikan requests
    private let rateLimitLock = NSLock()

    /// v2.23 — Failure (negative) cache: key → when it failed. A key that
    /// failed within `failureCacheTTL` throws immediately without touching
    /// the network, so the many screens that independently fall back to
    /// Jikan during an AniList outage don't each re-request the same dead
    /// endpoint (the 429/504 flood the logs showed). One honest retry is
    /// allowed per key per cooldown window.
    private var failureCache: [String: Date] = [:]
    private let failureCacheTTL: TimeInterval = 45
    private let failureCacheLock = NSLock()

    /// Enforces minimum spacing between Jikan requests. Called before
    /// every outbound request. If the last request was less than
    /// `minRequestSpacing` ago, sleeps until the gap is met.
    private func enforceRateLimit() async {
        rateLimitLock.lock()
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let needed = minRequestSpacing - elapsed
        rateLimitLock.unlock()
        if needed > 0 {
            try? await Task.sleep(nanoseconds: UInt64(needed * 1_000_000_000))
        }
        rateLimitLock.lock()
        lastRequestTime = Date()
        rateLimitLock.unlock()
    }

    /// Builds a cache key from path + sorted query items.
    private func cacheKey(path: String, queryItems: [URLQueryItem]) -> String {
        let sorted = queryItems.sorted { $0.name < $1.name }
        let qs = sorted.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(path)?\(qs)"
    }

    /// Shared fetch for list endpoints — deduplicates in-flight requests,
    /// caches results for 120s, rate-limits outbound calls, and (v2.23)
    /// remembers failures for 45s so repeated fallback attempts don't
    /// re-request a dead endpoint.
    private func sharedFetchList(_ path: String, queryItems: [URLQueryItem]) async throws -> [JikanAnime] {
        let key = cacheKey(path: path, queryItems: queryItems)

        // Check cache
        if let cached = listCache[key], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            Logger.shared.log("[Jikan] Cache hit: \(key)", type: "Debug")
            return cached.data
        }

        // v2.23 — failure cache: this exact request just failed; fail fast
        // instead of feeding the outage with another round-trip.
        if let failedAt = failureValue(forKey: key), Date().timeIntervalSince(failedAt) < failureCacheTTL {
            throw ProviderError.serverError(503)
        }

        // Check in-flight
        inFlightLock.lock()
        if let existing = inFlightTasks[key] {
            inFlightLock.unlock()
            Logger.shared.log("[Jikan] Dedup: awaiting in-flight request for \(key)", type: "Debug")
            let data = try await existing.value
            return try decodeList(data)
        }

        // Create new task
        let task = Task<Data, Error> { [self] in
            await enforceRateLimit()
            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "sfw", value: "true")] + queryItems
            Logger.shared.log("[Jikan] Fetching: \(key)", type: "Info")
            let (data, response) = try await session.data(from: components.url!)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    // Single retry, no recursive call to avoid storms
                    Logger.shared.log("[Jikan] 429 on \(key) — retrying after 2s", type: "Warning")
                    let (retryData, retryResp) = try await session.data(from: components.url!)
                    if let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode >= 400 {
                        throw ProviderError.serverError(retryHttp.statusCode)
                    }
                    return retryData
                }
                if http.statusCode >= 500 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    Logger.shared.log("[Jikan] \(http.statusCode) on \(key) — retrying after 3s", type: "Warning")
                    let (retryData, retryResp) = try await session.data(from: components.url!)
                    if let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode >= 400 {
                        throw ProviderError.serverError(retryHttp.statusCode)
                    }
                    return retryData
                }
            }
            return data
        }

        inFlightTasks[key] = task
        inFlightLock.unlock()

        do {
            let data = try await task.value
            let decoded = try decodeList(data)
            // Cache the result
            listCache[key] = (data: decoded, timestamp: Date())
            // Remove from in-flight
            inFlightLock.lock()
            inFlightTasks.removeValue(forKey: key)
            inFlightLock.unlock()
            return decoded
        } catch {
            inFlightLock.lock()
            inFlightTasks.removeValue(forKey: key)
            inFlightLock.unlock()
            // v2.23 — remember the failure so other screens (and this one)
            // fail fast for the next 45s instead of re-requesting; also
            // record a MAL outage window in the ProviderManager so the
            // central state knows the fallback is cooling down.
            recordFailure(forKey: key)
            broadcastOutage(error)
            throw error
        }
    }

    /// Shared fetch for single-item endpoints — same dedup + cache + rate limit.
    private func sharedFetchSingle(_ path: String) async throws -> JikanAnime {
        let key = path

        // Check cache
        if let cached = singleCache[key], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.data
        }

        // Check in-flight
        inFlightLock.lock()
        if let existing = inFlightTasks[key] {
            inFlightLock.unlock()
            let data = try await existing.value
            return try decodeSingle(data)
        }

        let task = Task<Data, Error> { [self] in
            await enforceRateLimit()
            let url = base.appendingPathComponent(path)
            Logger.shared.log("[Jikan] Fetching single: \(key)", type: "Info")
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let (retryData, _) = try await session.data(from: url)
                    return retryData
                }
                if http.statusCode >= 500 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let (retryData, _) = try await session.data(from: url)
                    return retryData
                }
            }
            return data
        }

        inFlightTasks[key] = task
        inFlightLock.unlock()

        do {
            let data = try await task.value
            let decoded = try decodeSingle(data)
            singleCache[key] = (data: decoded, timestamp: Date())
            inFlightLock.lock()
            inFlightTasks.removeValue(forKey: key)
            inFlightLock.unlock()
            return decoded
        } catch {
            inFlightLock.lock()
            inFlightTasks.removeValue(forKey: key)
            inFlightLock.unlock()
            // v2.23 — same failure caching as the list layer.
            recordFailure(forKey: key)
            broadcastOutage(error)
            throw error
        }
    }

    // MARK: - v2.23 failure cache helpers

    private func failureValue(forKey key: String) -> Date? {
        failureCacheLock.lock()
        defer { failureCacheLock.unlock() }
        return failureCache[key]
    }

    private func recordFailure(forKey key: String) {
        failureCacheLock.lock()
        failureCache[key] = Date()
        // Bound the map — purge entries older than the TTL.
        let now = Date()
        failureCache = failureCache.filter { now.timeIntervalSince($0.value) < failureCacheTTL * 4 }
        failureCacheLock.unlock()
    }

    /// Tells the central ProviderManager the Jikan fallback is failing —
    /// it records a short provider cooldown so every screen sees the same
    /// state (no duplicate switching) and skips straight to caches/
    /// snapshots. Rate-limited to one broadcast per window (the failure
    /// cache already throttles the requests).
    private var lastOutageBroadcast: Date = .distantPast
    private func broadcastOutage(_ error: Error) {
        let now = Date()
        guard now.timeIntervalSince(lastOutageBroadcast) > 30 else { return }
        lastOutageBroadcast = now
        let code = (error as? ProviderError).flatMap { pe -> Int? in
            if case .serverError(let c) = pe { return c } else { return nil }
        } ?? 0
        Logger.shared.log("[Jikan] request failed (\(code)) — recording MAL outage cooldown", type: "Warning")
        Task { @MainActor in
            ProviderManager.shared.recordJikanOutage()
        }
    }

    // MARK: - Decoders

    private func decodeList(_ data: Data) throws -> [JikanAnime] {
        var seen = Set<Int>()
        return try JSONDecoder().decode(JikanPage<JikanAnime>.self, from: data).data.filter {
            guard $0.mal_id > 0 else { return false }
            guard let imgUrl = $0.images?.jpg?.image_url, !imgUrl.isEmpty, !imgUrl.contains("qm_50") else { return false }
            return seen.insert($0.mal_id).inserted
        }
    }

    private func decodeSingle(_ data: Data) throws -> JikanAnime {
        try JSONDecoder().decode(JikanSingle<JikanAnime>.self, from: data).data
    }

    // MARK: - Jikan models

    struct JikanAnime: Decodable {
        let mal_id: Int
        let title: String?
        let title_english: String?
        let title_japanese: String?
        let images: JikanImages?
        let synopsis: String?
        let episodes: Int?
        let status: String?
        let score: Double?
        let genres: [JikanGenre]?
        let season: String?
        let year: Int?
        let type: String?
        let source: String?
        let relations: [JikanRelation]?
        // v2.23 — country-of-origin inference signals (provider metadata):
        // Japanese TV broadcast timezone + Chinese production companies.
        let broadcast: JikanBroadcast?
        let producers: [JikanNamedRef]?
        let studios: [JikanNamedRef]?
        // Manga-only fields (nil on anime entries) — present on /top/manga
        // and /manga responses; used by mapMangaToMedia.
        let chapters: Int?
        let volumes: Int?
        let members: Int?
        let published: JikanPublished?

        struct JikanBroadcast: Decodable {
            let day: String?
            let time: String?
            let timezone: String?
            let string: String?
        }
        struct JikanNamedRef: Decodable {
            let mal_id: Int?
            let name: String?
        }

        struct JikanPublished: Decodable {
            // ISO-8601-ish string ("1997-07-22T00:00:00+00:00") or null.
            let from: String?
            var startYear: Int? {
                guard let from, from.count >= 4 else { return nil }
                return Int(from.prefix(4))
            }
        }
    }

    struct JikanImages: Decodable {
        let jpg: JikanImageSet?
        let webp: JikanImageSet?
    }

    struct JikanImageSet: Decodable {
        let image_url: String?
        let large_image_url: String?
    }

    struct JikanGenre: Decodable {
        let name: String
    }

    struct JikanRelation: Decodable {
        let relation: String
        let entry: [JikanRelationEntry]
    }

    struct JikanRelationEntry: Decodable {
        let mal_id: Int
        let name: String
        let type: String
    }

    private struct JikanPage<T: Decodable>: Decodable {
        let data: [T]
    }

    private struct JikanSingle<T: Decodable>: Decodable {
        let data: T
    }

    // MARK: - Fetch helpers (now route through the shared dedup+cache+rate-limit layer)

    func fetchList(_ path: String, queryItems: [URLQueryItem] = [], retrying: Bool = false) async throws -> [JikanAnime] {
        // The `retrying` parameter is kept for backward compatibility but
        // is no longer used — the shared layer handles retries internally.
        try await sharedFetchList(path, queryItems: queryItems)
    }

    private func fetchSingle(_ path: String, retrying: Bool = false) async throws -> JikanAnime {
        try await sharedFetchSingle(path)
    }

    // MARK: - Public API

    func trending(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "airing"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func seasonal(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("seasons/now", queryItems: [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func popular(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "bypopularity"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func topRated(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "favorite"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [JikanAnime] {
        switch category {
        case .trending: return try await trending(page: page)
        case .seasonal: return try await seasonal(page: page)
        case .popular:  return try await popular(page: page)
        case .topRated: return try await topRated(page: page)
        }
    }

    func search(_ query: String) async throws -> [JikanAnime] {
        try await fetchList("anime", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "25")
        ])
    }

    func detail(malId: Int) async throws -> JikanAnime {
        try await fetchSingle("anime/\(malId)/full")
    }

    /// Lightweight poster lookup by MAL id. The Jikan history feed carries no cover
    /// art, so the activity list fetches posters per row on demand.
    func posterURL(malId: Int) async throws -> String? {
        let anime = try await fetchSingle("anime/\(malId)")
        return anime.images?.jpg?.large_image_url ?? anime.images?.jpg?.image_url
    }

    struct JikanEpisode: Decodable {
        let mal_id: Int
        let title: String?
    }

    // MARK: - Jikan character models

    struct JikanCharacter: Decodable {
        let mal_id: Int
        let name: String?
        let name_kanji: String?
        let images: JikanCharacterImages?
        let about: String?
    }

    struct JikanCharacterImages: Decodable {
        let jpg: JikanCharacterImageSet?
        let webp: JikanCharacterImageSet?
    }

    struct JikanCharacterImageSet: Decodable {
        let image_url: String?
    }

    struct JikanCharacterVoiceActor: Decodable {
        let person: JikanVoiceActorPerson?
        let language: String?
    }

    struct JikanVoiceActorPerson: Decodable {
        let mal_id: Int
        let name: String?
        let images: JikanCharacterImages?
    }

    struct JikanCharacterEdge: Decodable {
        let character: JikanCharacter?
        let role: String?
        let voice_actors: [JikanCharacterVoiceActor]?
    }

    struct JikanCharacterData: Decodable {
        let data: [JikanCharacterEdge]
    }

    /// Fetches anime characters from MAL/Jikan. Returns character edges
    /// with name, image, about, role, and voice actors. This is used
    /// instead of AniList for anime characters because MAL shows anime
    /// characters (not manga characters) which looks cleaner.
    func characters(malId: Int) async throws -> [JikanCharacterEdge] {
        let url = base.appendingPathComponent("anime/\(malId)/characters")
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(JikanCharacterData.self, from: data).data
    }

    // MARK: - Jikan Staff models

    struct JikanStaffPerson: Decodable {
        let mal_id: Int
        let name: String?
        let given_name: String?
        let family_name: String?
        let images: JikanCharacterImages?
        let about: String?
        let website: String?
        let birthday: String?
    }

    struct JikanStaffEdge: Decodable {
        let person: JikanStaffPerson?
        let positions: [String]?
    }

    struct JikanStaffData: Decodable {
        let data: [JikanStaffEdge]
    }

    /// Fetches anime staff (directors, producers, animators, composers)
    /// from MAL/Jikan.
    func staff(malId: Int) async throws -> [JikanStaffEdge] {
        let url = base.appendingPathComponent("anime/\(malId)/staff")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(JikanStaffData.self, from: data).data
    }

    // MARK: - Jikan Video models

    struct JikanVideo: Decodable, Identifiable {
        let mal_id: Int
        let title: String?
        let url: String?
        let thumbnail: String?
        let type: String? // "OP", "ED", "PV", "CM", "Other"
        let images: JikanVideoImages?
        var id: Int { mal_id }
    }

    struct JikanVideoImages: Decodable {
        let jpg: JikanVideoImageSet?
        }

    struct JikanVideoImageSet: Decodable {
        let image_url: String?
    }

    struct JikanVideoData: Decodable {
        let data: [JikanVideo]
    }

    /// Fetches anime videos (PVs, trailers, openings, endings) from
    /// MAL/Jikan. Returns video entries with title, URL, thumbnail,
    /// and type.
    func videos(malId: Int) async throws -> [JikanVideo] {
        let url = base.appendingPathComponent("anime/\(malId)/videos")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(JikanVideoData.self, from: data).data
    }

    // MARK: - Jikan Person (Voice Actor) models

    struct JikanPerson: Decodable {
        let mal_id: Int
        let name: String?
        let given_name: String?
        let family_name: String?
        let images: JikanCharacterImages?
        let about: String?
        let website: String?
        let birthday: String?
    }

    struct JikanPersonAnimeEntry: Decodable {
        let anime: JikanAnime?
        let character: JikanPersonAnimeCharacter?
        let role: String?
    }

    struct JikanPersonAnimeCharacter: Decodable {
        let mal_id: Int
        let name: String?
        let images: JikanCharacterImages?
    }

    struct JikanPersonData: Decodable {
        let data: [JikanPersonAnimeEntry]
    }

    /// Fetches a person's (voice actor's) anime roles — all anime they
    /// voiced characters in, with character name and role.
    func personAnime(personId: Int) async throws -> [JikanPersonAnimeEntry] {
        let url = base.appendingPathComponent("people/\(personId)/anime")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(JikanPersonData.self, from: data).data
    }

    /// Fetches a person's (voice actor's) full profile from Jikan.
    func person(personId: Int) async throws -> JikanPerson {
        let url = base.appendingPathComponent("people/\(personId)/full")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        struct Wrapper: Decodable { let data: JikanPerson }
        return try JSONDecoder().decode(Wrapper.self, from: data).data
    }

    // MARK: - Jikan Character Animeography models

    struct JikanCharacterAnimeEntry: Decodable {
        let anime: JikanAnime?
        let role: String?
    }

    struct JikanCharacterAnimeData: Decodable {
        let data: [JikanCharacterAnimeEntry]
    }

    /// Fetches all anime a character appears in (animeography).
    func characterAnime(characterId: Int) async throws -> [JikanCharacterAnimeEntry] {
        let url = base.appendingPathComponent("characters/\(characterId)/anime")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(JikanCharacterAnimeData.self, from: data).data
    }

    /// Fetches a character's full profile from Jikan.
    func character(characterId: Int) async throws -> JikanCharacter {
        let url = base.appendingPathComponent("characters/\(characterId)/full")
        let (data, _) = try await session.data(for: URLRequest(url: url))
        struct Wrapper: Decodable { let data: JikanCharacter }
        return try JSONDecoder().decode(Wrapper.self, from: data).data
    }

    /// Fetches episode titles from Jikan (up to 100 per page).
    func episodes(malId: Int, page: Int = 1) async throws -> [JikanEpisode] {
        var components = URLComponents(url: base.appendingPathComponent("anime/\(malId)/episodes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 { throw ProviderError.serverError(429) }
        return try JSONDecoder().decode(JikanPage<JikanEpisode>.self, from: data).data
    }

    // MARK: - Mapping to shared Media

    /// Maps a Jikan MANGA entry to the shared `Media` model with correct
    /// manga semantics (v2.22): `type` is "MANGA" so `isManga` is true,
    /// `episodes` carries the chapter count, `volumes` and `popularity`
    /// (member count) are filled, and the start year falls back to
    /// `published.from` (the top-level `year` field only exists on anime
    /// entries). Using this instead of `mapToMedia` for manga keeps shelf
    /// posters, chapter-count enrichment, and detail navigation working
    /// consistently for Jikan-sourced manga.
    func mapMangaToMedia(_ m: JikanAnime) -> Media {
        Media(
            id: m.mal_id,
            idMal: m.mal_id,
            provider: .mal,
            title: MediaTitle(romaji: m.title, english: m.title_english, native: m.title_japanese),
            coverImage: MediaCoverImage(
                large: m.images?.jpg?.image_url,
                extraLarge: m.images?.jpg?.large_image_url
            ),
            bannerImage: nil,
            description: m.synopsis,
            episodes: m.chapters,
            status: m.status,
            averageScore: m.score.map { Int($0 * 10) },
            genres: m.genres?.map { $0.name },
            season: nil,
            seasonYear: m.year ?? m.published?.startYear,
            nextAiringEpisode: nil,
            relations: nil,
            type: "MANGA",
            format: m.type,
            studioNames: nil, source: m.source, duration: nil, airDateRange: nil,
            volumes: m.volumes,
            popularity: m.members,
            countryOfOrigin: nil
        )
    }

    func mapToMedia(_ a: JikanAnime) -> Media {
        Media(
            id: a.mal_id,
            idMal: a.mal_id,
            provider: .mal,
            title: MediaTitle(romaji: a.title, english: a.title_english, native: a.title_japanese),
            coverImage: MediaCoverImage(
                large: a.images?.jpg?.image_url,
                extraLarge: a.images?.jpg?.large_image_url
            ),
            bannerImage: nil,
            description: a.synopsis,
            episodes: a.episodes,
            status: a.status,
            averageScore: a.score.map { Int($0 * 10) },
            genres: a.genres?.map { $0.name },
            season: a.season?.uppercased(),
            seasonYear: a.year,
            nextAiringEpisode: nil,
            relations: {
                guard let jikanRelations = a.relations else { return nil }
                // Map the meaningful Jikan relation labels to the app's relationType
                // strings. Sequel handling is preserved so next-episode chaining works.
                func relationType(for label: String) -> String? {
                    switch label {
                    case "Sequel":              return "SEQUEL"
                    case "Prequel":             return "PREQUEL"
                    case "Side story":          return "SIDE_STORY"
                    case "Parent story":        return "PARENT"
                    case "Alternative version",
                         "Alternative setting": return "ALTERNATIVE"
                    default:                    return nil
                    }
                }
                let edges: [MediaRelationEdge] = jikanRelations
                    .compactMap { rel -> [MediaRelationEdge]? in
                        guard let type = relationType(for: rel.relation) else { return nil }
                        return rel.entry
                            .filter { $0.type == "anime" }
                            .map { entry in
                                MediaRelationEdge(
                                    relationType: type,
                                    node: Media(
                                        id: entry.mal_id,
                                        idMal: entry.mal_id,
                                        provider: .mal,
                                        title: MediaTitle(romaji: entry.name, english: nil, native: nil),
                                        coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                                        bannerImage: nil,
                                        description: nil,
                                        episodes: nil,
                                        status: nil,
                                        averageScore: nil,
                                        genres: nil,
                                        season: nil,
                                        seasonYear: nil,
                                        nextAiringEpisode: nil,
                                        relations: nil,
                                        type: "TV",
                                        format: nil,
                                        studioNames: nil, source: nil, duration: nil, airDateRange: nil
                                    )
                                )
                            }
                    }
                    .flatMap { $0 }
                return edges.isEmpty ? nil : MediaRelations(edges: edges)
            }(),
            type: a.type,
            format: a.source,
            studioNames: nil, source: nil, duration: nil, airDateRange: nil,
            // v2.23 — the Jikan fallback path now carries the same metadata
            // the AniList path does, so the carousel's popularity floor and
            // country filter actually apply to fallback data (they were
            // inert before: donghua sailed through with nil/nil).
            popularity: a.members,
            countryOfOrigin: Self.inferCountry(from: a)
        )
    }

    // MARK: - v2.23 country-of-origin inference (Jikan path)

    /// Jikan has no country field, so this reads the provider's own
    /// production metadata — NOT title blacklisting:
    ///   • A Chinese production company among producers/studios → "CN".
    ///     (The major Chinese media companies behind virtually all donghua;
    ///     company metadata from the provider, not title matching.)
    ///   • A live Japanese TV broadcast (timezone Asia/Tokyo) → "JP".
    ///   • Japanese kana in `title_japanese` → "JP" (Chinese titles are
    ///     hanzi-only; Japanese titles almost always contain kana).
    ///   • Otherwise nil — unknown, same as AniList entries without the
    ///     field (those pass the carousel filter unchanged).
    private static func inferCountry(from a: JikanAnime) -> String? {
        let companyNames = ((a.producers ?? []) + (a.studios ?? []))
            .compactMap { $0.name?.lowercased() }
            .filter { !$0.isEmpty }
        if companyNames.contains(where: { name in
            chineseProductionCompanies.contains(where: { name.contains($0) })
        }) {
            return "CN"
        }
        if let tz = a.broadcast?.timezone, tz == "Asia/Tokyo" {
            return "JP"
        }
        if let jp = a.title_japanese, !jp.isEmpty, jp.contains(where: isKana) {
            return "JP"
        }
        return nil
    }

    /// Major Chinese production companies (bilibili, Tencent Penguin
    /// Pictures, Youku, iQIYI, Haoliners, Big Firebird, Sparkly Key…).
    /// Matched as substrings of the provider's company names.
    private static let chineseProductionCompanies: [String] = [
        "bilibili",
        "tencent",
        "penguin pictures",
        "youku",
        "iqiyi",
        "haoliners",
        "big firebird",
        "sparkly key",
        "b.cmay",
        "colored pencil animation",
        "netease",
        "chinese ",
        "shanghai ",
        "beijing "
    ]

    /// Hiragana (U+3040–309F) or Katakana (U+30A0–30FF) — script used by
    /// Japanese titles and never by Chinese ones.
    private static func isKana(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }
}
