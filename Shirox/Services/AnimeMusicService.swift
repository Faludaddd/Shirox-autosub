import Foundation
import Combine

// MARK: - Song model (file scope — actor-neutral, so Codable synthesis is safe)

/// One anime opening/ending theme, parsed from MyAnimeList's theme string.
struct AnimeSong: Identifiable, Equatable, Codable {

    enum Kind: String, CaseIterable, Codable {
        case opening = "OP"
        case ending = "ED"

        var label: String { self == .opening ? "Opening" : "Ending" }
    }

    /// Stable id: "op-16498-1" (kind-malId-number). Deterministic so
    /// disk-cached songs keep their identity across launches.
    let id: String
    let kind: Kind
    /// Theme number within the anime (1, 2, 3…). `nil` when MAL didn't number it.
    let number: Int?
    let title: String
    let artist: String?
    /// e.g. "eps 1-13" — shown only when the source provided it.
    let episodesRange: String?
    let animeMALId: Int
    let animeTitle: String
    let coverImage: String?
    let animeYear: Int?
    /// AniList cross-reference from the offline mapping cache
    /// (`nil` = unknown; the view resolves on tap, best-effort).
    var anilistMediaId: Int?

    static func == (lhs: AnimeSong, rhs: AnimeSong) -> Bool { lhs.id == rhs.id }
}

// MARK: - Service

/// Anime openings & endings — the data layer behind the Music tab.
///
/// MyAnimeList (through Jikan) is the one database the app can query for
/// real per-anime theme songs: every anime entry carries
/// `theme: { openings: [...], endings: [...] }` arrays of strings such as
///
///     1: "Guren no Yumiya" by Linked Horizon (eps 1-13)
///     2: "Kimi ni Todoke" by Tanizawa Tomofumi
///
/// This service parses those strings into structured songs (number, title,
/// artist, episode range), caches successful fetches on disk (30 minutes —
/// themes change rarely), rate-limits and de-duplicates outbound requests,
/// and resolves AniList cross-ids from the offline id-mapping cache so
/// songs navigate to the real detail pages.
///
/// Nothing is invented: unparsable entries are skipped, artist/episode
/// info appears only when the source provided it, and an honest error
/// surfaces when the source is unreachable.
@MainActor
final class AnimeMusicService: ObservableObject {

    static let shared = AnimeMusicService()

    private init() {}

    // MARK: - Networking

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private var lastRequestAt = Date.distantPast
    private let minRequestSpacing: TimeInterval = 0.45

    private var inFlight: [String: Task<Data, Error>] = [:]
    private let inFlightLock = NSLock()

    private let memoryCacheTTL: TimeInterval = 300
    private var memoryCache: [String: (songs: [AnimeSong], at: Date)] = [:]

    private var diskCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("music-theme-cache.json")
    }
    private let diskCacheTTL: TimeInterval = 1800 // 30 minutes

    // MARK: - Public API

    /// Featured songs — openings or endings of the most popular anime.
    func featured(kind: AnimeSong.Kind) async throws -> [AnimeSong] {
        let key = "featured-\(kind.rawValue)"
        if let songs = await cached(key) { return songs }
        let anime = try await fetchAnimeList(path: "top/anime",
                                             query: [URLQueryItem(name: "filter", value: "bypopularity"),
                                                     URLQueryItem(name: "limit", value: "25")])
        let songs = extract(kind: kind, from: anime)
        store(key: key, songs: songs)
        return songs
    }

    /// Search anime by name and return every theme song they carry.
    func search(_ rawQuery: String) async throws -> [AnimeSong] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let key = "search-\(query.lowercased())"
        if let songs = await cached(key) { return songs }
        let anime = try await fetchAnimeList(path: "anime",
                                             query: [URLQueryItem(name: "q", value: query),
                                                     URLQueryItem(name: "limit", value: "25"),
                                                     URLQueryItem(name: "sfw", value: "true")])
        var songs = extract(kind: .opening, from: anime)
        songs += extract(kind: .ending, from: anime)
        store(key: key, songs: songs)
        return songs
    }

    /// Resolves the AniList media id for a song's anime (offline cache
    /// first, one network mapping lookup on miss). `nil` = unresolved —
    /// callers keep the song usable and skip deep navigation.
    func anilistId(for song: AnimeSong) async -> Int? {
        if let known = song.anilistMediaId { return known }
        return await IDMappingService.shared.anilistId(forMALId: song.animeMALId)
    }

    /// Total bytes used by the Music theme cache (Storage → Other data).
    nonisolated static func diskCacheBytes() -> Int {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("music-theme-cache.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// Clears both Music caches (Storage → Other Cached Data).
    func clearCaches() {
        memoryCache.removeAll()
        try? FileManager.default.removeItem(at: diskCacheURL)
    }

    // MARK: - Caching

    private struct DiskCacheEntry: Codable {
        let at: Date
        let songs: [AnimeSong]
    }

    private func cached(_ key: String) async -> [AnimeSong]? {
        if let hit = memoryCache[key], Date().timeIntervalSince(hit.at) < memoryCacheTTL {
            return hit.songs
        }
        guard let disk = readDiskCache(),
              let hit = disk[key],
              Date().timeIntervalSince(hit.at) < diskCacheTTL else { return nil }
        memoryCache[key] = (hit.songs, Date())
        return hit.songs
    }

    private func store(key: String, songs: [AnimeSong]) {
        guard !songs.isEmpty else { return }
        memoryCache[key] = (songs, Date())
        var disk = readDiskCache() ?? [:]
        disk[key] = DiskCacheEntry(at: Date(), songs: songs)
        // Keep only the 40 freshest queries so the file stays bounded.
        let trimmed = disk.sorted { $0.value.at > $1.value.at }.prefix(40)
        let payload = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: diskCacheURL, options: .atomic)
        }
    }

    private func readDiskCache() -> [String: DiskCacheEntry]? {
        guard let data = try? Data(contentsOf: diskCacheURL) else { return nil }
        return try? JSONDecoder().decode([String: DiskCacheEntry].self, from: data)
    }

    // MARK: - Fetching

    private struct JikanThemeAnime: Decodable {
        let mal_id: Int?
        let title: String?
        let images: ImagesBox?
        let year: Int?
        let theme: ThemeBox?

        struct ImagesBox: Decodable { let jpg: JpgBox? }
        struct JpgBox: Decodable { let large_image_url: String?; let image_url: String? }
        struct ThemeBox: Decodable { let openings: [String]?; let endings: [String]? }
    }

    private func fetchAnimeList(path: String, query: [URLQueryItem]) async throws -> [JikanThemeAnime] {
        let urlKey = "\(path)?\(query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))"

        inFlightLock.lock()
        if let existing = inFlight[urlKey] {
            inFlightLock.unlock()
            let data = try await existing.value
            return try decode(data)
        }
        inFlightLock.unlock()

        let task = Task<Data, Error> { [self] in
            await pace()
            var components = URLComponents(url: URL(string: "https://api.jikan.moe/v4")!
                .appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 12
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            if http.statusCode == 429 || http.statusCode >= 500 {
                // One patient retry — Jikan/MAL blips are usually brief.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let (retryData, retryResp) = try await session.data(for: request)
                if let retryHttp = retryResp as? HTTPURLResponse, (400..<600).contains(retryHttp.statusCode) {
                    throw ProviderError.serverError(retryHttp.statusCode)
                }
                return retryData
            }
            if (400..<500).contains(http.statusCode) {
                throw ProviderError.serverError(http.statusCode)
            }
            return data
        }
        inFlightLock.lock()
        inFlight[urlKey] = task
        inFlightLock.unlock()
        defer {
            inFlightLock.lock()
            inFlight.removeValue(forKey: urlKey)
            inFlightLock.unlock()
        }

        let data = try await task.value
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> [JikanThemeAnime] {
        struct Root: Decodable { let data: [JikanThemeAnime]? }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return root.data ?? []
    }

    private func pace() async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minRequestSpacing {
            try? await Task.sleep(nanoseconds: UInt64((minRequestSpacing - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    // MARK: - Theme parsing

    /// Extracts every song of `kind` from a list of Jikan anime entries.
    private func extract(kind: AnimeSong.Kind, from anime: [JikanThemeAnime]) -> [AnimeSong] {
        var songs: [AnimeSong] = []
        var seen = Set<String>()
        for entry in anime {
            guard let malId = entry.mal_id,
                  let animeTitle = entry.title, !animeTitle.isEmpty else { continue }
            let cover = entry.images?.jpg?.large_image_url ?? entry.images?.jpg?.image_url
            let rawThemes = kind == .opening ? entry.theme?.openings : entry.theme?.endings
            guard let rawThemes else { continue }
            for raw in rawThemes {
                guard var song = Self.parse(raw, kind: kind, malId: malId,
                                            animeTitle: animeTitle, cover: cover,
                                            year: entry.year) else { continue }
                guard seen.insert(song.id).inserted else { continue }
                // Fill in the offline AniList cross-reference when known.
                song.anilistMediaId = IDMappingService.shared.cachedAnilistId(forMALId: malId)
                songs.append(song)
            }
        }
        return songs
    }

    /// Parses one MAL theme string into a song. Format examples:
    ///
    ///     1: "Guren no Yumiya" by Linked Horizon (eps 1-13)
    ///     2: "Kimi ni Todoke" by Tanizawa Tomofumi
    ///     1: "SHINKIRO" by UVERworld (v2) (eps 1-)
    ///     "unnumbered title" by artist
    ///     Bare title without artist
    ///
    /// Returns `nil` for empty/unparsable lines — never invents fields.
    static func parse(_ raw: String,
                      kind: AnimeSong.Kind,
                      malId: Int,
                      animeTitle: String,
                      cover: String?,
                      year: Int?) -> AnimeSong? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Leading "N:" theme number.
        var number: Int?
        if let colon = text.firstIndex(of: ":"),
           let prefix = Int(text[..<colon].trimmingCharacters(in: .whitespaces)) {
            if (1...99).contains(prefix) {
                number = prefix
                text = String(text[text.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard !text.isEmpty else { return nil }

        // Trailing parenthesized groups → episode range / version notes.
        var episodesRange: String?
        while text.hasSuffix(")"), let open = text.lastIndex(of: "("), open < text.index(before: text.endIndex) {
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let lower = inner.lowercased()
            if episodesRange == nil, lower.hasPrefix("eps") || lower.hasPrefix("ep ") {
                episodesRange = inner
            }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        // Quoted title ("Title" / “Title”) with optional " by Artist".
        var title: String
        var artist: String?
        if let openQuote = text.firstIndex(where: { $0 == "\"" || $0 == "\u{201C}" }),
           let closeQuote = text[text.index(after: openQuote)...].firstIndex(where: { $0 == "\"" || $0 == "\u{201D}" }) {
            title = String(text[text.index(after: openQuote)..<closeQuote])
                .trimmingCharacters(in: .whitespaces)
            let remainder = String(text[text.index(after: closeQuote)...])
            artist = Self.parseArtist(remainder)
        } else if let byRange = text.range(of: " by ", options: .caseInsensitive) {
            title = String(text[..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            artist = Self.parseArtist(String(text[byRange.upperBound...]))
        } else {
            title = text
        }

        // Reject degenerate leftovers (bare punctuation, empty title).
        let letters = title.filter { $0.isLetter || $0.isNumber }
        guard letters.count >= 2 else { return nil }

        let id = "\(kind.rawValue.lowercased())-\(malId)-\(number ?? 0)"
        return AnimeSong(
            id: id,
            kind: kind,
            number: number,
            title: title,
            artist: artist,
            episodesRange: episodesRange,
            animeMALId: malId,
            animeTitle: animeTitle,
            coverImage: cover,
            animeYear: year,
            anilistMediaId: nil
        )
    }

    /// Cleans up the remainder after a title into an artist string:
    /// strips a leading "by ", surrounding quotes, and stray whitespace.
    private static func parseArtist(_ raw: String) -> String? {
        var artist = raw.trimmingCharacters(in: .whitespaces)
        if let byRange = artist.range(of: "^by\\s+", options: [.regularExpression, .caseInsensitive]) {
            artist = String(artist[byRange.upperBound...])
        }
        artist = artist.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} "))
            .trimmingCharacters(in: .whitespaces)
        let letters = artist.filter { $0.isLetter || $0.isNumber }
        guard !artist.isEmpty, !letters.isEmpty else { return nil }
        return artist
    }
}
