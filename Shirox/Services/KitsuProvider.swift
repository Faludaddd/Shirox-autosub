import Foundation

/// Kitsu JSON:API provider — the DEDICATED DISCOVERY DATABASE (Batch 26)
/// and anime metadata fallback. Keyless and public.
///
/// Discovery role (what appears in Trending / Popular / genre categories /
/// the Home carousel / Surprise Me): Kitsu's own trending chart, its real
/// season query, and its category taxonomy (`filter[categories]=<slug>`,
/// verified live) decide WHICH anime those surfaces show. Every list
/// request also includes `mappings`, so each result carries its AniList,
/// MAL and TheTVDB ids — the discovery layer returns real ids, and the
/// TVDB-first metadata system resolves artwork/characters for the SAME
/// series (never a title guess).
///
/// Metadata role: anime fallback #3 with field-level honesty.
///
/// Batch 26 — list requests now `include=categories` and map the genre
/// titles onto the canonical genre vocabulary (real metadata from the
/// discovery database — previously `genres` was nil on every Kitsu item,
/// which is why the carousel/category pills lost their genres).
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
        // Category metadata (type "categories" in the included array).
        let title: String?
        let nsfw: Bool?
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
        let categories: CategoryRef?
        struct MappingRef: Decodable {
            let data: [Link]?
            struct Link: Decodable {
                let id: String?
                let type: String?
            }
        }
        struct CategoryRef: Decodable {
            let data: [Link]?
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

    /// Everything resolvable about one anime/manga from its `mappings`:
    /// AniList id, MAL id and — new in Batch 26 — the TheTVDB series id
    /// (Kitsu maps `thetvdb/series` and `thetvdb` external sites, verified
    /// live: One Piece → 81797, Detective Conan → 72454/1). The resource's
    /// own id IS the Kitsu id.
    private struct ResolvedIds {
        var mal: Int?
        var anilist: Int?
        var tvdb: Int?
    }

    private func resolveIds(resources: [Resource], included: [Included]?) -> [String: ResolvedIds] {
        let mappingById: [String: Included] = (included ?? []).filter { $0.type == "mappings" }
            .reduce(into: [:]) { $0[$1.id] = $1 }
        var result: [String: ResolvedIds] = [:]
        for resource in resources {
            let mappingLinks = resource.relationships?.mappings?.data ?? []
            var ids = ResolvedIds(mal: nil, anilist: nil, tvdb: nil)
            for link in mappingLinks {
                guard let mapping = mappingById[link.id ?? ""],
                      let site = mapping.attributes?.externalSite?.lowercased(),
                      let idString = mapping.attributes?.externalId else { continue }
                // thetvdb/series mappings carry "72454/1" (id/season) —
                // split off any season suffix before parsing.
                let rawId = site.contains("thetvdb") ? idString.split("/").first.map(String.init) ?? idString : idString
                guard let id = Int(rawId), id > 0 else { continue }
                if site.contains("myanimelist") { ids.mal = ids.mal ?? id }
                if site.contains("anilist") { ids.anilist = ids.anilist ?? id }
                if site.contains("thetvdb") { ids.tvdb = ids.tvdb ?? id }
            }
            result[resource.id] = ids
        }
        return result
    }

    /// Genre names for one resource from the included `categories`. Kitsu
    /// mixes genres AND themes/demographics in one category list ("Action",
    /// "Fantasy" next to "Post Apocalypse", "Shounen") — only titles on the
    /// canonical genre vocabulary count, so pills show real GENRES.
    private static func genreNames(for resource: Resource, categoriesById: [String: Included]) -> [String]? {
        guard let links = resource.relationships?.categories?.data, !links.isEmpty else { return nil }
        var genres: [String] = []
        for link in links {
            guard let category = categoriesById[link.id ?? ""],
                  let title = category.attributes?.title,
                  !(category.attributes?.nsfw ?? false),
                  DiscoveryGenre.isGenreName(title) else { continue }
            if !genres.contains(title) { genres.append(title) }
        }
        return genres.isEmpty ? nil : genres
    }

    // MARK: - Lists (discovery)

    func trending() async throws -> [Media] {
        try await fetchList(path: "/trending/anime?limit=20&include=mappings,categories")
    }

    /// Paged browse for the See All chain. Kitsu pages via offset
    /// (page[limit] x page[offset]).
    ///
    /// Batch 26 — `.trending` page 1 is Kitsu's REAL trending chart (the
    /// same list kitsu.io's own homepage shows); deeper pages fall back to
    /// the most-followed current/upcoming list because the chart endpoint
    /// is not offset-paginated. `.seasonal` now uses the REAL season
    /// filter (verified live: filter[season]=summer&filter[seasonYear]).
    ///
    /// Batch 24 — sort DIRECTION fix: JSON:API sorts are ASCENDING by
    /// default, so every list sort prefixes `-` (descending).
    func browse(category: BrowseCategory, page: Int) async throws -> [Media] {
        let offset = max(0, (page - 1)) * 20
        let path: String
        switch category {
        case .trending:
            if page <= 1 {
                // The real chart — what "trending" promises.
                path = "/trending/anime?limit=20&include=mappings,categories"
            } else {
                path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[status]=current,upcoming"
            }
        case .seasonal:
            let (season, year) = AniListSeason.current()
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[status]=current&filter[season]=\(season.rawValue.lowercased())&filter[seasonYear]=\(year)"
        case .popular:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[status]=current,finished"
        case .topRated:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-averageRating&include=mappings,categories&filter[status]=finished"
        case .recentlyCompleted:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[status]=finished"
        case .upcoming:
            path = "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[status]=upcoming,unreleased"
        }
        return try await fetchList(path: path)
    }

    /// Batch 26 — GENRE browse: anime belonging to a genre, straight from
    /// the discovery database's category taxonomy (verified live:
    /// filter[categories]=fantasy returns genre members ordered by
    /// -userCount).
    func genreBrowse(genre: DiscoveryGenre, page: Int) async throws -> [Media] {
        let offset = max(0, (page - 1)) * 20
        return try await fetchList(path: "/anime?page[limit]=20&page[offset]=\(offset)&sort=-userCount&include=mappings,categories&filter[categories]=\(genre.slug)&filter[status]=current,finished")
    }

    /// Batch 26 — manga genre browse (same taxonomy; verified live:
    /// filter[categories]=romance on /manga returns Koe no Katachi, Horimiya…).
    func mangaGenreBrowse(genre: DiscoveryGenre, page: Int) async throws -> [Media] {
        let offset = max(0, (page - 1)) * 20
        return try await mangaFetchList(path: "/manga?page[limit]=20&page[offset]=\(offset)&sort=-userCount&filter[categories]=\(genre.slug)&include=mappings")
    }

    func popular() async throws -> [Media] {
        try await fetchList(path: "/anime?page[limit]=20&sort=-userCount&include=mappings,categories&filter[status]=current,finished")
    }

    func topRated() async throws -> [Media] {
        try await fetchList(path: "/anime?page[limit]=20&sort=-averageRating&include=mappings,categories&filter[status]=finished")
    }

    func search(query: String) async throws -> [Media] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await fetchList(path: "/anime?page[limit]=20&filter[text]=\(encoded)&include=mappings")
    }

    // MARK: - Characters (Batch 26 — the Kitsu leg of the character chain)

    /// One character document: data = media-characters (role + character +
    /// voices relationships); included = characters + characterVoices +
    /// people. Verified live: characters/people carry `name` +
    /// `image.original`; characterVoices carry `locale` ("ja_jp") and link
    /// to a person.
    private struct CharacterDocument: Decodable {
        let data: [MediaCharacter]
        let included: [IncludedRecord]?

        struct MediaCharacter: Decodable {
            let id: String
            let attributes: MCAttributes?
            let relationships: MCRelationships?
            struct MCAttributes: Decodable { let role: String? }
            struct MCRelationships: Decodable {
                let character: SingleRef?
                let voices: MultiRef?
                struct SingleRef: Decodable {
                    let data: Ref?
                    struct Ref: Decodable { let id: String? }
                }
                struct MultiRef: Decodable {
                    let data: [SingleRef.Ref]?
                }
            }
        }

        struct IncludedRecord: Decodable {
            let id: String
            let type: String
            let attributes: Attributes?
            let relationships: Relationships?
            struct Attributes: Decodable {
                // characters + people
                let name: String?
                let image: ImageBox?
                // characterVoices
                let locale: String?
                struct ImageBox: Decodable {
                    let original: String?
                    let large: String?
                    let medium: String?
                }
            }
            /// characterVoice → person link (decoded straight from the
            /// document — no side-channel state).
            struct Relationships: Decodable {
                let person: PersonRef?
                struct PersonRef: Decodable {
                    let data: Ref?
                    struct Ref: Decodable { let id: String? }
                }
            }
        }
    }

    /// Full characters for one anime: role (main/supporting), character
    /// image, and voice actors with language + person image. `kitsuId`
    /// comes from the canonical Media's `kitsuId` or the ID resolver —
    /// never a title guess.
    func characters(kitsuId: Int) async throws -> [AniListCharacterEdge] {
        guard let url = URL(string: "\(base)/anime/\(kitsuId)/characters?include=character,voices.person&page[limit]=20") else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "Kitsu characters request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let doc = try JSONDecoder().decode(CharacterDocument.self, from: data)

        // Index the included records by id (characters, voices, people).
        var characterById: [String: CharacterDocument.IncludedRecord] = [:]
        var voiceById: [String: CharacterDocument.IncludedRecord] = [:]
        var peopleById: [String: CharacterDocument.IncludedRecord] = [:]
        for inc in doc.included ?? [] {
            switch inc.type {
            case "characters": characterById[inc.id] = inc
            case "characterVoices": voiceById[inc.id] = inc
            case "people": peopleById[inc.id] = inc
            default: break
            }
        }

        func languageLabel(_ locale: String?) -> String? {
            switch locale {
            case "ja_jp": return "Japanese"
            case "en_us", "en": return "English"
            case "pt_br": return "Portuguese (Brazil)"
            case "es_es": return "Spanish"
            case "fr_fr": return "French"
            case "de_de": return "German"
            case "it_it": return "Italian"
            case "ko_kr": return "Korean"
            case "zh_cn": return "Chinese"
            default: return locale
            }
        }

        var edges: [AniListCharacterEdge] = []
        for mc in doc.data {
            guard let characterRef = mc.relationships?.character?.data?.id,
                  let character = characterById[characterRef],
                  let name = character.attributes?.name else { continue }
            let image = character.attributes?.image?.original
                ?? character.attributes?.image?.large
                ?? character.attributes?.image?.medium
            // Voice actors: each voice record links to one person.
            var voiceActors: [AniListVoiceActor] = []
            for voiceRef in mc.relationships?.voices?.data ?? [] {
                guard let vid = voiceRef.id,
                      let voice = voiceById[vid],
                      let personId = voice.relationships?.person?.data?.id,
                      let person = peopleById[personId],
                      let personName = person.attributes?.name else { continue }
                let personImage = person.attributes?.image?.original
                    ?? person.attributes?.image?.large
                    ?? person.attributes?.image?.medium
                voiceActors.append(AniListVoiceActor(
                    id: Int(vid) ?? 0,
                    name: AniListCharacterName(full: personName, native: nil, alternative: nil, alternativeSpoiler: nil),
                    language: languageLabel(voice.attributes?.locale),
                    image: AniListCharacterImage(large: personImage, medium: personImage)))
            }
            edges.append(AniListCharacterEdge(
                role: mc.attributes?.role,
                node: AniListCharacter(
                    id: Int(character.id) ?? Int(mc.id) ?? 0,
                    name: AniListCharacterName(full: name, native: nil, alternative: nil, alternativeSpoiler: nil),
                    image: AniListCharacterImage(large: image, medium: image),
                    description: nil,
                    gender: nil,
                    dateOfBirth: nil,
                    age: nil,
                    bloodType: nil,
                    favourites: nil,
                    siteUrl: nil),
                voiceActors: voiceActors.isEmpty ? nil : voiceActors))
        }
        // Main characters first, then supporting.
        return edges.sorted { ($0.role == "main" ? 0 : 1) < ($1.role == "main" ? 0 : 1) }
    }


    // MARK: - Manga (Batch 24: Kitsu joins the manga chain)

    /// Subtype filter for the manga lists. Kitsu indexes doujinshi under
    /// `subtype=doujin`; a bare popularity sort is self-selecting, but
    /// `filter[subtype]` keeps the newest-started and rating-sorted lists
    /// clean too. NOTE: Kitsu 500s on a SINGLE subtype value — the comma
    /// list always works.
    private static let mangaSubtypes = "manga,manhwa,manhua,oneshot,oel"

    func mangaShelf(_ shelf: MangaShelfKind) async throws -> [Media] {
        let path: String
        switch shelf {
        case .trending:
            path = "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=current,upcoming&include=mappings"
        case .popular:
            path = "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&include=mappings"
        case .topRated:
            path = "/manga?page[limit]=20&sort=-averageRating&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=finished&include=mappings"
        case .latest:
            path = "/manga?page[limit]=20&sort=-startDate&filter[subtype]=\(Self.mangaSubtypes)&include=mappings"
        }
        return try await mangaFetchList(path: path)
    }

    func mangaReleaseSchedule() async throws -> [Media] {
        try await mangaFetchList(path: "/manga?page[limit]=20&sort=-userCount&filter[subtype]=\(Self.mangaSubtypes)&filter[status]=current&include=mappings")
    }

    func searchManga(query: String) async throws -> [Media] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await mangaFetchList(path: "/manga?page[limit]=20&filter[text]=\(encoded)&include=mappings")
    }

    private func mangaFetchList(path: String) async throws -> [Media] {
        let media = try await fetchAnyList(path: path, isManga: true)
        return media
    }

    private func fetchList(path: String) async throws -> [Media] {
        try await fetchAnyList(path: path, isManga: false)
    }

    /// Fetch + decode an anime or manga list document (shared envelope;
    /// the manga mapping follows the app's conventions: type "MANGA",
    /// chapter count in `episodes`, volumes, user count as popularity).
    private func fetchAnyList(path: String, isManga: Bool) async throws -> [Media] {
        guard let url = URL(string: base + path) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "Kitsu request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return try decodeListData(data, isManga: isManga)
    }

    /// Decodes a Kitsu JSON:api list payload into Media (public so the
    /// Kitsu+TVDB timetable service can decode its own list request
    /// through the SAME pipeline — ids, genres, country inference and
    /// popularity all resolve identically).
    func decodeListData(_ data: Data, isManga: Bool = false) throws -> [Media] {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        let ids = resolveIds(resources: doc.data, included: doc.included)
        // Category index for genre extraction.
        let categoriesById: [String: Included] = (doc.included ?? []).filter { $0.type == "categories" }
            .reduce(into: [:]) { $0[$1.id] = $1 }
        var media: [Media] = []
        for resource in doc.data {
            guard let attrs = resource.attributes else { continue }
            let mapping = ids[resource.id] ?? ResolvedIds(mal: nil, anilist: nil, tvdb: nil)
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
                episodes: isManga ? attrs.chapterCount : attrs.episodeCount,
                status: mapStatus(attrs.status),
                averageScore: score > 0 ? score : nil,
                genres: Self.genreNames(for: resource, categoriesById: categoriesById),
                season: nil,
                seasonYear: year,
                nextAiringEpisode: nil,
                relations: nil,
                type: isManga ? "MANGA" : "ANIME",
                format: isManga ? mapMangaFormat(attrs.subtype) : mapFormat(attrs.subtype),
                studioNames: nil,
                source: nil,
                duration: nil,
                airDateRange: nil,
                volumes: isManga ? attrs.volumeCount : nil,
                countryOfOrigin: Self.inferredCountry(titles: attrs.titles),
                popularity: attrs.userCount,
                tvdbId: isManga ? nil : mapping.tvdb,
                kitsuId: Int(resource.id)))
        }
        return media
    }

    private func mapMangaFormat(_ subtype: String?) -> String? {
        subtype?.uppercased()
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

    // MARK: - Country inference (feeds the JP catalog filter)

    /// Kitsu carries no country-of-origin field, and its `ja_jp` title
    /// slot is unreliable (Chinese donghua titles get stuffed into it).
    /// The honest signal is the WRITING SYSTEM: a CJK title that contains
    /// NO kana is hanzi-only — Chinese production → "CN".
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
}
