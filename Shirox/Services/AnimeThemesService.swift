import Foundation
import Combine

// MARK: - Models (file scope — actor-neutral so Codable synthesis is safe)

/// One anime from the AnimeThemes database, with its themes included.
/// Everything displayed in the Music section comes from these fields —
/// nothing is invented.
struct ATAnime: Identifiable, Equatable, Codable {
    let id: Int
    let slug: String
    let romajiTitle: String
    let englishTitle: String?
    let year: Int?
    let season: String?
    let format: String?
    let siteUrl: String?
    /// LARGE_COVER image URL (r2 CDN) — the artwork on music cards.
    let coverImage: String?
    /// The provider's own AniList resource mapping (site: ANILIST) — nil
    /// when this anime has no AniList link. Powers exact Music → anime
    /// navigation with no title matching.
    let anilistId: Int?
    /// The provider's MAL resource mapping — used as a backup for the
    /// offline id-mapping cache.
    let malId: Int?
    let themes: [ATTheme]

    var displayTitle: String {
        if let english = englishTitle, !english.isEmpty { return english }
        return romajiTitle
    }

    static func == (lhs: ATAnime, rhs: ATAnime) -> Bool { lhs.id == rhs.id }
}

/// Embedded anime info carried on shuffle results (the provider nests the
/// anime inside each theme there).
struct ATThemeAnimeRef: Equatable, Codable {
    let animeId: Int
    let slug: String
    let title: String
    let coverImage: String?
    let year: Int?
    /// The provider's AniList resource id for this anime, when linked.
    let anilistId: Int?
}

/// One performer of a theme's song, exactly as the provider lists them.
struct ATPerformer: Equatable, Codable {
    let artistId: Int
    let slug: String
    let name: String
    /// e.g. "LiSA as Yuu" — the `as` credit, when the provider gives one.
    let credit: String
}

/// One theme (OP / ED / insert) of an anime, with its song, performers,
/// entries (versions), and playable media.
struct ATTheme: Identifiable, Equatable, Codable {
    let id: Int
    /// "OP", "ED", or "IN" (insert song).
    let type: String
    let sequence: Int?
    /// "OP1", "ED3"…
    let slug: String
    let songTitle: String?
    /// Performer names — every artist the provider credits.
    let performers: [ATPerformer]
    let entries: [ATEntry]
    /// Present on shuffle results (theme → its anime).
    let animeRef: ATThemeAnimeRef?

    var kindLabel: String {
        switch type {
        case "OP": return "Opening"
        case "ED": return "Ending"
        default:   return "Insert"
        }
    }
    /// "OP1", "ED2", "IN" — used on badges.
    var badge: String {
        if let seq = sequence, seq > 0 { return "\(type)\(seq)" }
        return type
    }
    /// Performer display string ("YOASOBI" / "LiSA as Yuu, milet") — nil
    /// when the provider lists none.
    var artistLine: String? {
        guard !performers.isEmpty else { return nil }
        return performers.map { $0.credit }.joined(separator: ", ")
    }
    /// Best playable media across the theme's entries: prefers the
    /// highest-resolution video that has an audio track, always carrying
    /// the audio-only link (background-friendly playback).
    var playableMedia: ATMedia? {
        var best: ATMedia?
        for entry in entries {
            for media in entry.media where media.audioLink != nil || media.videoLink != nil {
                if best == nil || (media.resolution ?? 0) > (best?.resolution ?? 0) {
                    best = media
                }
            }
        }
        return best
    }
    /// e.g. "1-16, 17-27" — joined when multiple entries exist.
    var episodesSummary: String? {
        let ranges = entries.compactMap { $0.episodes }.filter { !$0.isEmpty }
        guard !ranges.isEmpty else { return nil }
        return ranges.joined(separator: ", ")
    }

    /// Copy of the theme carrying the given anime reference (used when
    /// flattening anime lists so every card knows its real parent anime).
    func attaching(animeRef ref: ATThemeAnimeRef?) -> ATTheme {
        ATTheme(id: id,
                type: type,
                sequence: sequence,
                slug: slug,
                songTitle: songTitle,
                performers: performers,
                entries: entries,
                animeRef: ref)
    }

    static func == (lhs: ATTheme, rhs: ATTheme) -> Bool { lhs.id == rhs.id }
}

/// One entry (version) of a theme — v1, v2, … with episode ranges.
struct ATEntry: Equatable, Codable {
    let id: Int
    let version: Int?
    let episodes: String?
    let notes: String?
    let media: [ATMedia]

    /// "v2" badge label (nil for version 1 / unknown).
    var versionLabel: String? {
        guard let v = version, v > 1 else { return nil }
        return "v\(v)"
    }
}

/// Playable media: the AnimeThemes WebM video (v.animethemes.moe) and its
/// audio track (a.animethemes.moe, Opus-in-Ogg).
struct ATMedia: Equatable, Codable {
    let videoLink: String?
    let audioLink: String?
    let resolution: Int?
    let source: String?
    /// e.g. "NCBD1080" — quality tag from the video's tags.
    let tags: String?

    var qualityLabel: String? {
        if let r = resolution, r > 0 {
            let sourcePart: String
            if let s = source, !s.isEmpty { sourcePart = " \(s)" } else { sourcePart = "" }
            return "\(r)p\(sourcePart)"
        }
        return nil
    }
}

/// One artist from the AnimeThemes database.
struct ATArtist: Identifiable, Equatable, Codable {
    let id: Int
    let slug: String
    let name: String
    let siteUrl: String?

    static func == (lhs: ATArtist, rhs: ATArtist) -> Bool { lhs.id == rhs.id }
}

// MARK: - Service

/// Music provider — AnimeThemes.moe (the dedicated anime OP/ED database),
/// through its official GraphQL API at https://graphql.animethemes.moe/
/// (the JSON:API is deprecated in favor of GraphQL — see
/// https://api-docs.animethemes.moe).
///
/// Queries used (all documented):
///   animePagination(search/season/year, sort)   anime → themes/songs/artists
///   anime(slug:)                                every theme of one anime
///   findAnimeByExternalSite(site: ANILIST/MAL)  anime ↔ AniList/MAL mapping
///                                               (the provider's own resource
///                                               links — exact, no guessing)
///   animethemeShuffle(type:)                    random themes (Featured rail)
///   search(search:)                             global search (artists)
///
/// Architecture requirements this service implements:
///   • Independent from AniList — Music keeps working while AniList is
///     403-disabled (verified live during the current AniList outage).
///   • Request deduplication — identical in-flight queries share one Task.
///   • Response caching — memory (5 min) + disk (30 min, bounded to 30 keys).
///   • Failure caching — a query that failed is remembered 45s so screens
///     never hammer a dead source.
///   • Rate limiting — the API documents 90 req/min; 700ms pacing.
///   • Honest errors — nothing is invented; failures surface as errors.
@MainActor
final class AnimeThemesService: ObservableObject {

    static let shared = AnimeThemesService()

    private init() {}

    // MARK: - Errors

    enum ATError: LocalizedError {
        case network
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .network:
                return "AnimeThemes is unreachable right now. Check your connection and try again."
            case .rateLimited:
                return "AnimeThemes is rate-limiting requests — wait a few seconds and try again."
            }
        }
    }

    // MARK: - Networking

    private let endpoint = URL(string: "https://graphql.animethemes.moe/")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    /// 700ms between outbound requests (90/min documented limit → ~85/min
    /// with headroom for the occasional retry).
    private let minRequestSpacing: TimeInterval = 0.7
    private var lastRequestAt = Date.distantPast

    /// In-flight dedup keyed by the canonical request body.
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Failure cache — key → time of failure. A key that failed within
    /// `failureCacheTTL` fails immediately without touching the network.
    private var failureCache: [String: Date] = [:]
    private let failureCacheTTL: TimeInterval = 45

    /// Memory cache (5 min) in front of the disk cache.
    private var memoryCache: [String: (data: Data, at: Date)] = [:]
    private let memoryCacheTTL: TimeInterval = 300

    private let diskCacheTTL: TimeInterval = 1800 // 30 minutes

    private static let diskCacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("animethemes-cache.json")
    }()

    // MARK: - Public API

    /// Featured rail — random themes from the provider's own shuffle
    /// endpoint. Cached 10 minutes so the rail doesn't re-roll while
    /// scrolling, but stays genuinely dynamic across sessions.
    func featuredThemes(kind: String? = nil, limit: Int = 12) async throws -> [ATTheme] {
        var body = "query { animethemeShuffle(first: \(limit)"
        if let kind { body += ", type: [\(kind)]" }
        body += ") { \(Self.themeSelection) anime { \(Self.animeSelection) } } }"
        let data = try await fetch(body: body, cacheKey: "shuffle-\(kind ?? "all")-\(limit)", ttl: 600)
        return try Self.decodeShuffle(from: data)
    }

    /// This season's themes (real, current data — updates when the
    /// provider's database changes).
    func currentSeasonThemes(kind: String, limit: Int = 30) async throws -> [ATTheme] {
        let (year, season) = Self.currentSeason()
        let body = "query { animePagination(first: 30, sort: YEAR_DESC, season: \(season), year: \(year)) { data { \(Self.animeSelection) animethemes { \(Self.themeSelection) } } } }"
        let data = try await fetch(body: body, cacheKey: "season-\(year)-\(season)", ttl: 600)
        let anime = try Self.decodeAnimeList(from: data)
        return Self.extractThemes(kind: kind, from: anime, limit: limit)
    }

    /// Artist rail derived from this season's themes — real performer data
    /// from the provider (no invented popularity).
    func currentSeasonArtists(limit: Int = 12) async throws -> [ATArtist] {
        let (year, season) = Self.currentSeason()
        let body = "query { animePagination(first: 25, sort: YEAR_DESC, season: \(season), year: \(year)) { data { \(Self.animeSelection) animethemes { \(Self.themeSelection) } } } }"
        let data = try await fetch(body: body, cacheKey: "season-artists-\(year)-\(season)", ttl: 600)
        let anime = try Self.decodeAnimeList(from: data)
        var seen = Set<Int>()
        var artists: [ATArtist] = []
        for a in anime {
            for theme in a.themes {
                for performer in theme.performers where !performer.name.isEmpty {
                    guard !seen.contains(performer.artistId) else { continue }
                    seen.insert(performer.artistId)
                    artists.append(ATArtist(id: performer.artistId,
                                            slug: performer.slug,
                                            name: performer.name,
                                            siteUrl: nil))
                    if artists.count >= limit { return artists }
                }
            }
        }
        return artists
    }

    /// Search anime by name and return every theme they carry (optionally
    /// filtered to OP / ED).
    func searchAnime(_ rawQuery: String, kind: String? = nil) async throws -> [ATTheme] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let body = "query { animePagination(first: 25, search: \"\(Self.escape(query))\", sort: YEAR_DESC) { data { \(Self.animeSelection) animethemes { \(Self.themeSelection) } } } }"
        let data = try await fetch(body: body, cacheKey: nil, ttl: 300)
        let anime = try Self.decodeAnimeList(from: data)
        return Self.extractThemes(kind: kind, from: anime, limit: 200)
    }

    /// Global search for artists (the Music page's artist results).
    func searchArtists(_ rawQuery: String, limit: Int = 15) async throws -> [ATArtist] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let body = "query { search(search: \"\(Self.escape(query))\", first: \(limit)) { artists { id slug name { main } siteUrl } } }"
        let data = try await fetch(body: body, cacheKey: nil, ttl: 300)
        return try Self.decodeArtists(from: data)
    }

    /// Full anime + theme list for one anime (by its AnimeThemes slug).
    func animeForSlug(_ slug: String) async throws -> ATAnime {
        let body = "query { anime(slug: \"\(Self.escape(slug))\") { \(Self.animeSelection) animethemes { \(Self.themeSelection) } } }"
        let data = try await fetch(body: body, cacheKey: "anime-\(slug)", ttl: 3600)
        let anime = try Self.decodeAnimeList(from: data)
        guard let first = anime.first else { throw ATError.network }
        return first
    }

    /// Full theme list for one anime (by its AnimeThemes slug).
    func themes(forAnimeSlug slug: String) async throws -> [ATTheme] {
        try await animeForSlug(slug).themes
    }

    /// One artist + every theme they perform (artist → performances →
    /// songs → their anime themes). The artist page's data source.
    func artistDetail(slug: String) async throws -> (artist: ATArtist, themes: [ATTheme]) {
        let themeSel = "id type sequence slug song { title { romaji } performances { artist { id slug name { main } } as } } anime { \(Self.animeSelection) } animethemeentries { id version episodes notes videos { nodes { id link resolution source tags audio { link } } } }"
        let body = "query { artist(slug: \"\(Self.escape(slug))\") { id slug name { main } siteUrl performances { as song { title { romaji } animethemes { \(themeSel) } } } } }"
        let data = try await fetch(body: body, cacheKey: "artist-\(slug)", ttl: 3600)
        return try Self.decodeArtistDetail(from: data)
    }

    /// The provider's own external mappings: anime by AniList or MAL id.
    /// Powers Music ↔ anime navigation without any title matching.
    func animeForExternalId(site: String, id: Int) async throws -> ATAnime? {
        let body = "query { findAnimeByExternalSite(site: \(site), id: [\(id)]) { \(Self.animeSelection) animethemes { \(Self.themeSelection) } } }"
        let data = try await fetch(body: body, cacheKey: "ext-\(site)-\(id)", ttl: 3600)
        let anime = try Self.decodeAnimeList(from: data, externalList: true)
        return anime.first
    }

    /// Themes for an AniList media id — the provider's exact AniList
    /// resource mapping (used by the anime detail page's music entry).
    func themes(forAniListId id: Int) async throws -> [ATTheme] {
        guard let anime = try await animeForExternalId(site: "ANILIST", id: id) else { return [] }
        return anime.themes
    }

    // MARK: - Storage integration

    /// Total bytes used by the Music disk cache (Storage → Other data).
    nonisolated static func diskCacheBytes() -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: diskCacheURL.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// Clears both Music caches (Storage → Other data).
    func clearCaches() {
        memoryCache.removeAll()
        failureCache.removeAll()
        try? FileManager.default.removeItem(at: Self.diskCacheURL)
    }

    // MARK: - Query building

    /// Field selection for anime — everything the Music UI needs (the
    /// provider's own AniList/MAL resource ids ride along for exact
    /// navigation).
    private static let animeSelection = "id slug title { romaji english } year season format siteUrl images { nodes { facet link } } resources { nodes { site externalId } }"

    /// Field selection for a theme — song, performers, entries, media.
    private static let themeSelection = "id type sequence slug song { title { romaji } performances { artist { id slug name { main } } as } } animethemeentries { id version episodes notes videos { nodes { id link resolution source tags audio { link } } } }"

    /// Maps a month → the provider's season enum.
    private static func currentSeason() -> (year: Int, season: String) {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let season: String
        switch month {
        case 1...3:  season = "WINTER"
        case 4...6:  season = "SPRING"
        case 7...9:  season = "SUMMER"
        default:     season = "FALL"
        }
        return (year, season)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Fetch layer (dedup + cache + pacing + failure cache)

    /// `ttl` overrides the default disk lifetime for this key (shorter for
    /// dynamic rails, longer for per-anime data). `cacheKey == nil` skips
    /// caching entirely (unbounded search terms would bloat the file).
    private func fetch(body: String, cacheKey: String?, ttl: TimeInterval) async throws -> Data {
        let canonical = body.split(separator: " ").joined(separator: " ")

        // Failure cache — never re-touch a query that just failed.
        if let failedAt = failureCache[canonical], Date().timeIntervalSince(failedAt) < failureCacheTTL {
            throw ATError.network
        }

        // Memory cache.
        if let cacheKey, let hit = memoryCache[cacheKey], Date().timeIntervalSince(hit.at) < memoryCacheTTL {
            return hit.data
        }
        // Disk cache.
        if let cacheKey, let (data, at) = Self.readDisk(cacheKey), Date().timeIntervalSince(at) < ttl {
            memoryCache[cacheKey] = (data, Date())
            return data
        }

        // In-flight dedup — identical queries share one request.
        if let existing = inFlight[canonical] {
            return try await existing.value
        }

        let task = Task<Data, Error> { [self] in
            await pace()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["query": body])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ATError.network }
            if http.statusCode == 429 { throw ATError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw ATError.network }
            return data
        }
        inFlight[canonical] = task
        defer { inFlight.removeValue(forKey: canonical) }

        do {
            let data = try await task.value
            // GraphQL errors come back with HTTP 200 — surface them
            // honestly instead of decoding empty results.
            if Self.hasGraphQLError(in: data) {
                throw ATError.network
            }
            if let cacheKey {
                memoryCache[cacheKey] = (data, Date())
                Self.writeDisk(cacheKey, data: data)
            }
            return data
        } catch {
            failureCache[canonical] = Date()
            throw error
        }
    }

    private func pace() async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minRequestSpacing {
            try? await Task.sleep(nanoseconds: UInt64((minRequestSpacing - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    // MARK: - Disk cache

    private struct DiskEntry: Codable {
        let data: Data
        let at: Date
    }

    private static func readDisk(_ key: String) -> (data: Data, at: Date)? {
        guard let raw = try? Data(contentsOf: diskCacheURL),
              let store = try? JSONDecoder().decode([String: DiskEntry].self, from: raw),
              let hit = store[key] else { return nil }
        return (hit.data, hit.at)
    }

    private static func writeDisk(_ key: String, data: Data) {
        guard let raw = try? Data(contentsOf: diskCacheURL),
              var store = try? JSONDecoder().decode([String: DiskEntry].self, from: raw) else {
            let payload = [key: DiskEntry(data: data, at: Date())]
            if let encoded = try? JSONEncoder().encode(payload) {
                try? encoded.write(to: diskCacheURL, options: .atomic)
            }
            return
        }
        store[key] = DiskEntry(data: data, at: Date())
        // Keep only the 30 freshest entries so the file stays bounded.
        let trimmed = store.sorted { $0.value.at > $1.value.at }.prefix(30)
        let payload = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        if let encoded = try? JSONEncoder().encode(payload) {
            try? encoded.write(to: diskCacheURL, options: .atomic)
        }
    }

    // MARK: - Decoding

    /// Raw GraphQL response shapes (snake_case as served by the API).
    private struct RawGraphQLData: Decodable {
        let animePagination: RawPagination?
        let anime: RawAnime?
        let findAnimeByExternalSite: [RawAnime]?
        let animethemeShuffle: [RawTheme]?
        struct RawPagination: Decodable { let data: [RawAnime]? }
    }
    private struct RootEnvelope: Decodable { let data: RawGraphQLData? }
    private struct RawAnime: Decodable {
        let id: Int
        let slug: String?
        let title: Title?
        let year: Int?
        let season: String?
        let format: String?
        let siteUrl: String?
        let images: Images?
        let resources: Resources?
        let animethemes: [RawTheme]?
        struct Title: Decodable { let romaji: String?; let english: String? }
        struct Images: Decodable { let nodes: [Node]? }
        struct Node: Decodable { let facet: String?; let link: String? }
        struct Resources: Decodable { let nodes: [ResourceNode]? }
        struct ResourceNode: Decodable { let site: String?; let externalId: Int? }
    }
    private struct RawTheme: Decodable {
        let id: Int
        let type: String?
        let sequence: Int?
        let slug: String?
        let song: Song?
        let anime: RawAnime?
        let animethemeentries: [RawEntry]?
        struct Song: Decodable {
            let title: SongTitle?
            let performances: [Performance]?
        }
        struct SongTitle: Decodable { let romaji: String? }
        struct Performance: Decodable {
            let artist: RawArtist?
            let `as`: String?
        }
    }
    private struct RawArtist: Decodable {
        let id: Int
        let slug: String?
        let name: Name?
        let siteUrl: String?
        struct Name: Decodable { let main: String? }
    }
    private struct RawEntry: Decodable {
        let id: Int
        let version: Int?
        let episodes: String?
        let notes: String?
        let videos: Videos?
        struct Videos: Decodable { let nodes: [RawVideo]? }
    }
    private struct RawVideo: Decodable {
        let id: Int?
        let link: String?
        let resolution: Int?
        let source: String?
        let tags: String?
        let audio: RawAudio?
    }
    private struct RawAudio: Decodable { let link: String? }

    private static func hasGraphQLError(in data: Data) -> Bool {
        struct ErrorEnvelope: Decodable {
            struct Message: Decodable { let message: String? }
            let errors: [Message]?
        }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let errors = envelope.errors, !errors.isEmpty else { return false }
        Logger.shared.log("[AnimeThemes] GraphQL error: \(errors.compactMap { $0.message }.joined(separator: "; "))", type: "Error")
        return true
    }

    /// Decodes anime lists from animePagination / anime / findAnimeByExternalSite.
    private static func decodeAnimeList(from data: Data, externalList: Bool = false) throws -> [ATAnime] {
        let root = try JSONDecoder().decode(RootEnvelope.self, from: data)
        var raws: [RawAnime] = []
        if let single = root.data?.anime {
            raws = [single]
        } else if let list = root.data?.animePagination?.data {
            raws = list
        } else if externalList, let list = root.data?.findAnimeByExternalSite {
            raws = list
        }
        return raws.map { mapAnime($0) }
    }

    private static func decodeShuffle(from data: Data) throws -> [ATTheme] {
        let root = try JSONDecoder().decode(RootEnvelope.self, from: data)
        return (root.data?.animethemeShuffle ?? []).map { mapTheme($0) }
    }

    private static func decodeArtists(from data: Data) throws -> [ATArtist] {
        struct ArtistResponse: Decodable {
            struct Search: Decodable { let artists: [RawArtist]? }
            let data: Search?
        }
        let root = try JSONDecoder().decode(ArtistResponse.self, from: data)
        return (root.data?.artists ?? []).compactMap { raw in
            guard let name = raw.name?.main, !name.isEmpty else { return nil }
            return ATArtist(id: raw.id, slug: raw.slug ?? "", name: name, siteUrl: raw.siteUrl)
        }
    }

    /// Artist detail: artist + every theme across their performances
    /// (deduped by theme id — a song can back multiple themes).
    private static func decodeArtistDetail(from data: Data) throws -> (artist: ATArtist, themes: [ATTheme]) {
        struct ArtistDetailResponse: Decodable {
            struct Detail: Decodable {
                let artist: RawArtist?
                let performances: [Performance]?
            }
            struct Performance: Decodable {
                let song: Song?
            }
            struct Song: Decodable {
                let animethemes: [RawTheme]?
            }
            let data: Detail?
        }
        let root = try JSONDecoder().decode(ArtistDetailResponse.self, from: data)
        guard let rawArtist = root.data?.artist,
              let name = rawArtist.name?.main, !name.isEmpty else {
            throw ATError.network
        }
        let artist = ATArtist(id: rawArtist.id, slug: rawArtist.slug ?? "", name: name, siteUrl: rawArtist.siteUrl)
        var seen = Set<Int>()
        var themes: [ATTheme] = []
        for performance in root.data?.performances ?? [] {
            for rawTheme in performance.song?.animethemes ?? [] {
                guard !seen.contains(rawTheme.id), playableMedia(of: rawTheme) != nil else { continue }
                seen.insert(rawTheme.id)
                themes.append(mapTheme(rawTheme))
            }
        }
        return (artist, themes)
    }

    /// Quick playable check for raw themes (artist pages only include
    /// themes that can actually play).
    private static func playableMedia(of raw: RawTheme) -> ATMedia? {
        for entry in raw.animethemeentries ?? [] {
            for video in entry.videos?.nodes ?? [] {
                if video.link != nil || video.audio?.link != nil {
                    return ATMedia(videoLink: video.link,
                                   audioLink: video.audio?.link,
                                   resolution: video.resolution,
                                   source: video.source,
                                   tags: video.tags)
                }
            }
        }
        return nil
    }

    // MARK: - Mapping

    /// Prefer the LARGE_COVER facet (facets: SMALL_COVER, LARGE_COVER,
    /// GRILL, BANNER); fall back to any image the provider gives.
    private static func cover(from images: RawAnime.Images?) -> String? {
        let nodes = images?.nodes ?? []
        return nodes.first(where: { $0.facet == "LARGE_COVER" })?.link
            ?? nodes.first(where: { $0.facet == "SMALL_COVER" })?.link
            ?? nodes.first?.link
    }

    private static func mapAnime(_ raw: RawAnime) -> ATAnime {
        // The provider's own external mappings — exact ids, no guessing.
        var anilistId: Int?
        var malId: Int?
        for resource in raw.resources?.nodes ?? [] {
            guard let externalId = resource.externalId else { continue }
            if resource.site == "ANILIST" { anilistId = externalId }
            if resource.site == "MAL" { malId = externalId }
        }
        return ATAnime(
            id: raw.id,
            slug: raw.slug ?? "",
            romajiTitle: raw.title?.romaji ?? "",
            englishTitle: raw.title?.english,
            year: raw.year,
            season: raw.season,
            format: raw.format,
            siteUrl: raw.siteUrl,
            coverImage: cover(from: raw.images),
            anilistId: anilistId,
            malId: malId,
            themes: (raw.animethemes ?? []).map { mapTheme($0) }
        )
    }

    private static func mapTheme(_ raw: RawTheme) -> ATTheme {
        // Performers: every credited artist, with their `as` credit.
        var performers: [ATPerformer] = []
        for performance in raw.song?.performances ?? [] {
            guard let artist = performance.artist,
                  let name = artist.name?.main, !name.isEmpty else { continue }
            let asCredit = performance.`as`.flatMap { value -> String? in
                value.isEmpty ? nil : value
            }
            performers.append(ATPerformer(
                artistId: artist.id,
                slug: artist.slug ?? "",
                name: name,
                credit: asCredit.map { "\(name) as \($0)" } ?? name
            ))
        }
        // Entries → playable media.
        let entries = (raw.animethemeentries ?? []).map { entry in
            ATEntry(
                id: entry.id,
                version: entry.version,
                episodes: entry.episodes,
                notes: entry.notes,
                media: (entry.videos?.nodes ?? []).compactMap { video in
                    guard video.link != nil || video.audio?.link != nil else { return nil }
                    return ATMedia(
                        videoLink: video.link,
                        audioLink: video.audio?.link,
                        resolution: video.resolution,
                        source: video.source,
                        tags: video.tags
                    )
                }
            )
        }
        // Shuffle results nest their anime directly.
        let animeRef: ATThemeAnimeRef?
        if let rawAnime = raw.anime {
            var refAnilistId: Int?
            for resource in rawAnime.resources?.nodes ?? [] {
                if resource.site == "ANILIST", let externalId = resource.externalId {
                    refAnilistId = externalId
                }
            }
            animeRef = ATThemeAnimeRef(
                animeId: rawAnime.id,
                slug: rawAnime.slug ?? "",
                title: rawAnime.title?.english ?? rawAnime.title?.romaji ?? "",
                coverImage: cover(from: rawAnime.images),
                year: rawAnime.year,
                anilistId: refAnilistId
            )
        } else {
            animeRef = nil
        }
        return ATTheme(
            id: raw.id,
            type: raw.type ?? "OP",
            sequence: raw.sequence,
            slug: raw.slug ?? "",
            songTitle: raw.song?.title?.romaji,
            performers: performers,
            entries: entries,
            animeRef: animeRef
        )
    }

    /// Flattens themes out of anime lists, optionally filtered by kind
    /// ("OP" / "ED"), capped at `limit`. Each theme carries its parent
    /// anime as `animeRef` — the provider nests anime per-theme only on
    /// shuffle results, so list flattening re-attaches it here (real
    /// parent data, never mixed between different anime).
    private static func extractThemes(kind: String?, from anime: [ATAnime], limit: Int) -> [ATTheme] {
        var out: [ATTheme] = []
        for a in anime {
            for theme in a.themes {
                if let kind, theme.type != kind { continue }
                guard theme.playableMedia != nil else { continue }
                let ref = theme.animeRef ?? ATThemeAnimeRef(
                    animeId: a.id,
                    slug: a.slug,
                    title: a.displayTitle,
                    coverImage: a.coverImage,
                    year: a.year,
                    anilistId: a.anilistId
                )
                out.append(theme.attaching(animeRef: ref))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

// MARK: - MusicTrack (playback model)

/// A track prepared for playback — built ONLY from an ATTheme's real data.
struct MusicTrack: Identifiable, Equatable {
    let id: Int
    let themeSlug: String         // "OP1" / "ED3"
    let type: String              // OP / ED / IN
    let title: String
    let artist: String?
    let animeTitle: String
    let animeSlug: String
    let coverImage: String?
    let animeYear: Int?
    let episodesRange: String?
    let qualityLabel: String?
    let videoLink: String?
    let audioLink: String?
    /// Exact AniList id from the provider's resource mapping (nil → the
    /// anime button hides honestly).
    var anilistAnimeId: Int?

    var episodesBadge: String? { episodesRange }

    static func == (lhs: MusicTrack, rhs: MusicTrack) -> Bool { lhs.id == rhs.id }

    /// Built from a theme that belongs to a known anime (list/detail pages).
    init(theme: ATTheme, anime: ATAnime) {
        self.init(theme: theme,
                  animeTitle: anime.displayTitle,
                  animeSlug: anime.slug,
                  coverImage: anime.coverImage,
                  animeYear: anime.year,
                  anilistAnimeId: anime.anilistId)
    }

    /// Built from a shuffle theme (anime nested on the theme itself).
    init(theme: ATTheme) {
        let ref = theme.animeRef
        self.init(theme: theme,
                  animeTitle: ref?.title ?? "",
                  animeSlug: ref?.slug ?? "",
                  coverImage: ref?.coverImage,
                  animeYear: ref?.year,
                  anilistAnimeId: ref?.anilistId)
    }

    init(theme: ATTheme, animeTitle: String, animeSlug: String, coverImage: String?, animeYear: Int?, anilistAnimeId: Int? = nil) {
        self.id = theme.id
        self.themeSlug = theme.badge
        self.type = theme.type
        self.title = theme.songTitle ?? theme.kindLabel
        self.artist = theme.artistLine
        self.animeTitle = animeTitle
        self.animeSlug = animeSlug
        self.coverImage = coverImage
        self.animeYear = animeYear
        self.episodesRange = theme.episodesSummary
        let media = theme.playableMedia
        self.qualityLabel = media?.qualityLabel
        self.videoLink = media?.videoLink
        self.audioLink = media?.audioLink
        self.anilistAnimeId = anilistAnimeId
    }
}
