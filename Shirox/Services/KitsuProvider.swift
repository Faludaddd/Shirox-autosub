import Foundation

/// Kitsu JSON:API provider — anime fallback #3. Keyless and public.
///
/// Cross-provider navigation works through Kitsu's `mappings` relationship
/// (included in list/search requests): each anime carries its MyAnimeList
/// and AniList ids, so results flow into the app's existing detail
/// navigation with REAL ids (never invented). Items without a usable
/// mapping are dropped instead of shown as dead ends.
@MainActor
final class KitsuProvider {
    static let shared = KitsuProvider()

    private let base = "https://kitsu.io/api/edge"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Response models

    private struct Document: Decodable {
        let data: [Resource]
        let included: [Included]?
    }

    private struct Resource: Decodable {
        let id: String
        let attributes: Attributes?
        let relationships: Relationships?
    }

    private struct Included: Decodable {
        let id: String
        let type: String
        let attributes: IncludedAttributes?
    }

    private struct IncludedAttributes: Decodable {
        let externalSite: String?
        let externalId: String?
    }

    private struct Attributes: Decodable {
        let canonicalTitle: String?
        let titles: [String: String]?
        let synopsis: String?
        let posterImage: Poster?
        let coverImage: Cover?
        let episodeCount: Int?
        // Manga attributes (absent on anime resources — decode as nil).
        let chapterCount: Int?
        let volumeCount: Int?
        let userCount: Int?
        let averageRating: String?
        let popularityRank: Int?
        let ratingRank: Int?
        let subtype: String?
        let status: String?
        let startDate: String?

        struct Poster: Decodable {
            let small: String?
            let medium: String?
            let large: String?
            let original: String?
        }
        struct Cover: Decodable {
            let tiny: String?
            let small: String?
            let original: String?
        }
    }

    private struct Relationships: Decodable {
        let mappings: MappingRef?
        struct MappingRef: Decodable {
            let data: [Link]?
            struct Link: Decodable {
                let id: String?
                let type: String?
            }
        }
    }

    // MARK: - Health check

    func healthCheck() async throws -> Bool {
        guard let url = URL(string: "\(base)/trending/anime?limit=1") else { return false }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let doc = try? JSONDecoder().decode(Document.self, from: data)
        return !(doc?.data ?? []).isEmpty
    }

    // MARK: - Mapping resolution

    /// Resolves the MAL/AniList ids for a list of anime resources from the
    /// document's `included` mappings. Only mappings referenced by each
    /// resource's relationships are considered.
    private func resolveIds(resources: [Resource], included: [Included]?) -> [String: (mal: Int?, anilist: Int?)] {
        let mappingById: [String: Included] = (included ?? []).filter { $0.type == "mappings" }
            .reduce(into: [:]) { $0[$1.id] = $1 }
        var result: [String: (Int?, Int?)] = [:]
        for resource in resources {
            let mappingLinks = resource.relationships?.mappings?.data ?? []
            var mal: Int?
            var anilist: Int?
            for link in mappingLinks {
                guard let mapping = mappingById[link.id ?? ""],
                      let site = mapping.attributes?.externalSite?.lowercased(),
                      let idString = mapping.attributes?.externalId,
                      let id = Int(idString), id > 0 else { continue }
                if site.contains("myanimelist") { mal = mal ?? id }
                if site.contains("anilist") { anilist = anilist ?? id }
            }
            result[resource.id] = (mal, anilist)
        }
        return result
    }

    // MARK: - Lists

    func trending() async throws -> [Media] {
        try await fetchList(path: "/trending/anime?limit=20&include=mappings")
    }

    /// Paged browse for the See All chain. Kitsu pages via offset
    /// (page[limit] x page[offset]).
    ///
    /// Batch 23: `.trending` used `sort=followersCount` — Kitsu answers
    /// that with HTTP 400 ("followers_count is not a valid sort criteria
    /// for anime", verified live). The valid sort field is `userCount`.
    ///
    /// Batch 24 — sort DIRECTION fix: JSON:API sorts are ASCENDING by
    /// default, so bare `userCount`/`averageRating` returned the LEAST
    /// popular, zero-user entries first (doujinshi, obscure shorts —
    /// verified live: sort=userCount led with 0-user doujinshi while
    /// sort=-userCount led with One Piece/BnHA). Every list sort now
    /// prefixes `-` (descending).
    func browse(category: BrowseCategory, page: Int) async throws -> [Media] {
        let offset = max(0, (page - 1)) * 20
        let path: String
        switch category {
        case .trending:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings&filter[status]=current,upcoming"
        case .seasonal:
            // Kitsu has no "current season" chart; sort by user count for
            // a stable popular-now list (the chain treats it as a fallback
            // after MAL/AniList anyway).
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings&filter[status]=current"
        case .popular:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings&filter[status]=current,finished"
        case .topRated:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-averageRating&include=mappings&filter[status]=finished"
        case .recentlyCompleted:
            // Kitsu exposes no finished-date sort — a completed list sorted
            // by user count is the closest honest equivalent (the chain
            // reaches Kitsu only after MAL/AniList failed).
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings&filter[status]=finished"
        case .upcoming:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings&filter[status]=upcoming,unreleased"
        }
        return try await fetchList(path: path)
    }

    func popular() async throws -> [Media] {
        try await fetchList(path: "/anime?page[limit]=20&sort=-userCount&include=mappings&filter[status]=current,finished")
    }

    func topRated() async throws -> [Media] {
        try await fetchList(path: "/anime?page[limit]=20&sort=-averageRating&include=mappings&filter[status]=finished")
    }

    func search(query: String) async throws -> [Media] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await fetchList(path: "/anime?page[limit]=20&filter[text]=\(encoded)&include=mappings")
    }

    // MARK: - Manga (Batch 24: Kitsu joins the manga chain)

    /// Subtype filter for the manga lists. Kitsu indexes doujinshi under
    /// `subtype=doujin`; a bare popularity sort is self-selecting (doujin
    /// has ~0 followers), but `filter[subtype]` keeps the newest-started
    /// and rating-sorted lists clean too. NOTE: Kitsu 500s on a SINGLE
    /// subtype value (verified live) — the comma list works, so this
    /// always uses the multi-value form.
    private static let mangaSubtypes = "manga,manhwa,manhua,oneshot,oel"

    /// Manga shelves for the unified manga home chain — the live fallback
    /// that keeps the Manga tab working while MAL/Jikan and AniList are
    /// both in outage windows (the exact condition that made the manga
    /// tab a hard error wall in v2.25).
    func mangaShelf(_ shelf: MangaShelfKind) async throws -> [Media] {
        let path: String
        switch shelf {
        case .trending:
            // Most-followed ongoing/upcoming series (the anime browse's
            // trending uses the same status window).
            path = "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=current,upcoming&include=mappings"
        case .popular:
            // All-time most-followed, any status.
            path = "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&include=mappings"
        case .topRated:
            path = "/manga?page[limit]=20&sort=-averageRating&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=finished&include=mappings"
        case .latest:
            // Newest START dates (Kitsu 500s on -createdAt combined with a
            // subtype filter — verified live; -startDate works and is the
            // more honest "new series" signal anyway).
            path = "/manga?page[limit]=20&sort=-startDate&filter[subtype]=\(Self.mangaSubtypes)&include=mappings"
        }
        return try await mangaFetchList(path: path)
    }

    /// The Reading-mode release feed: Kitsu carries no per-chapter
    /// timetable, so the honest equivalent is the most-followed
    /// CURRENTLY-RELEASING manga (verified live: One Piece, One
    /// Punch-Man, Hunter x Hunter…).
    func mangaReleaseSchedule() async throws -> [Media] {
        try await mangaFetchList(path: "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=current&include=mappings")
    }

    /// Manga search for the unified manga search chain (after MangaBaka,
    /// MAL, AniList). Same text filter as the anime search.
    func searchManga(query: String) async throws -> [Media] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await mangaFetchList(path: "/manga?page[limit]=20&filter[text]=\(encoded)&include=mappings")
    }

    /// Fetch + decode a manga document. Same JSON:api envelope and mapping
    /// resolution as the anime `fetchList`; the Media mapping follows the
    /// app's manga conventions (type "MANGA", chapter count in `episodes`,
    /// volumes, user count as popularity — mirroring MALDiscoveryService
    /// .mapMangaToMedia). Kitsu's manga mappings include `anilist/manga`
    /// sites (verified live), so navigation flows into the existing manga
    /// detail pages with REAL AniList ids.
    private func mangaFetchList(path: String) async throws -> [Media] {
        guard let url = URL(string: base + path) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "Kitsu manga request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let doc = try JSONDecoder().decode(Document.self, from: data)
        let ids = resolveIds(resources: doc.data, included: doc.included)
        var media: [Media] = []
        for resource in doc.data {
            guard let attrs = resource.attributes else { continue }
            let mapping = ids[resource.id] ?? (nil, nil)
            guard let navId = mapping.anilist ?? mapping.mal else { continue }
            let provider: ProviderType = mapping.anilist != nil ? .anilist : .mal
            let titles = attrs.titles ?? [:]
            let poster = attrs.posterImage?.large ?? attrs.posterImage?.medium ?? attrs.posterImage?.original
            let score = Int(Double(attrs.averageRating ?? "") ?? 0)
            let year = attrs.startDate.flatMap { Int($0.prefix(4)) }
            media.append(Media(
                id: navId,
                idMal: mapping.mal,
                provider: provider,
                title: MediaTitle(
                    romaji: titles["en_jp"] ?? attrs.canonicalTitle,
                    english: titles["en"],
                    native: titles["ja_jp"]),
                coverImage: MediaCoverImage(large: poster, extraLarge: attrs.posterImage?.original),
                bannerImage: attrs.coverImage?.original,
                description: attrs.synopsis,
                episodes: attrs.chapterCount,
                status: mapStatus(attrs.status),
                averageScore: score > 0 ? score : nil,
                genres: nil,
                season: nil,
                seasonYear: year,
                nextAiringEpisode: nil,
                relations: nil,
                type: "MANGA",
                format: mapMangaFormat(attrs.subtype),
                studioNames: nil,
                source: nil,
                duration: nil,
                airDateRange: nil,
                volumes: attrs.volumeCount,
                popularity: attrs.userCount,
                countryOfOrigin: Self.inferredCountry(titles: attrs.titles)))
        }
        return media
    }

    /// Manga format from Kitsu's subtype (manga / manhwa / manhua /
    /// oneshot / oel / novel…), mirroring how MAL's type strings are used.
    private func mapMangaFormat(_ subtype: String?) -> String? {
        subtype?.uppercased()
    }

    private func fetchList(path: String) async throws -> [Media] {
        guard let url = URL(string: base + path) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "Kitsu request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let doc = try JSONDecoder().decode(Document.self, from: data)
        let ids = resolveIds(resources: doc.data, included: doc.included)
        var media: [Media] = []
        for resource in doc.data {
            guard let attrs = resource.attributes else { continue }
            let mapping = ids[resource.id] ?? (nil, nil)
            guard let navId = mapping.anilist ?? mapping.mal else { continue }
            let provider: ProviderType = mapping.anilist != nil ? .anilist : .mal
            let titles = attrs.titles ?? [:]
            let poster = attrs.posterImage?.large ?? attrs.posterImage?.medium ?? attrs.posterImage?.original
            // Kitsu's averageRating is a percent string ("86.75") — the
            // app's averageScore is 0–100, so parse and round.
            let score = Int(Double(attrs.averageRating ?? "") ?? 0)
            let year = attrs.startDate.flatMap { Int($0.prefix(4)) }
            media.append(Media(
                id: navId,
                idMal: mapping.mal,
                provider: provider,
                title: MediaTitle(
                    romaji: titles["en_jp"] ?? attrs.canonicalTitle,
                    english: titles["en"],
                    native: titles["ja_jp"]),
                coverImage: MediaCoverImage(large: poster, extraLarge: attrs.posterImage?.original),
                bannerImage: attrs.coverImage?.original,
                description: attrs.synopsis,
                episodes: attrs.episodeCount,
                status: mapStatus(attrs.status),
                averageScore: score > 0 ? score : nil,
                genres: nil,
                season: nil,
                seasonYear: year,
                nextAiringEpisode: nil,
                relations: nil,
                type: "ANIME",
                format: mapFormat(attrs.subtype),
                studioNames: nil,
                source: nil,
                duration: nil,
                airDateRange: nil,
                countryOfOrigin: Self.inferredCountry(titles: attrs.titles)))
        }
        return media
    }

    // MARK: - Country inference (feeds the JP catalog filter)

    /// Kitsu carries no country-of-origin field, and its `ja_jp` title
    /// slot is unreliable (Chinese donghua titles get stuffed into it —
    /// verified live: "斗罗大陆" sits in BOTH ja_jp and zh_cn). The honest
    /// signal is the WRITING SYSTEM, the same technique the Jikan path
    /// uses: a CJK title that contains NO kana is hanzi-only — Chinese
    /// production → "CN". A title with kana is Japanese; a title with no
    /// CJK at all is unknown (passes the catalog filter unchanged).
    private static func inferredCountry(titles: [String: String]?) -> String? {
        guard let titles,
              let cjkTitle = titles["zh_cn"] ?? titles["ja_jp"],
              !cjkTitle.isEmpty else { return nil }
        let hasCJK = cjkTitle.contains { char in
            char.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        guard hasCJK else { return nil }
        let hasKana = cjkTitle.contains { char in
            char.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }
        return hasKana ? nil : "CN"
    }

    private func mapStatus(_ raw: String?) -> String? {
        switch raw {
        case "current": return "RELEASING"
        case "finished": return "FINISHED"
        case "upcoming", "unreleased": return "NOT_YET_RELEASED"
        case "tba": return "NOT_YET_RELEASED"
        default: return raw
        }
    }

    private func mapFormat(_ subtype: String?) -> String? {
        switch subtype {
        case "TV": return "TV"
        case "movie": return "MOVIE"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "special": return "SPECIAL"
        case "music": return "MUSIC"
        default: return subtype?.uppercased()
        }
    }
}
