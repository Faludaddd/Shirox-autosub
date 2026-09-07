import Foundation

// MARK: - TVDB detail fields

/// TVDB's contribution to a detail bundle. Field-level fallback means the
/// detail page keeps data from other providers wherever a field here is
/// nil — TVDB values only apply where TVDB actually has them.
struct TVDBDetailFields: Codable, Equatable {
    var synopsis: String?
    var posterURL: String?
    var bannerURL: String?
    var logoURL: String?
    var genres: [String]?
    var studios: [String]?
    var network: String?
    var episodeCount: Int?
    var runtimeMinutes: Int?
    var score: Double?           // TVDB scale 0–10
    var status: String?
    var firstAired: String?
    var episodes: [TVDBEpisodeInfo]?
    var characters: [TVDBCharacterInfo]?
    var anilistId: Int?
    var malId: Int?

    var isEmpty: Bool {
        synopsis == nil && posterURL == nil && bannerURL == nil && logoURL == nil
            && (genres ?? []).isEmpty && (studios ?? []).isEmpty && (episodes ?? []).isEmpty
            && (characters ?? []).isEmpty && episodeCount == nil
    }

    static let empty = TVDBDetailFields()
}

struct TVDBEpisodeInfo: Codable, Equatable, Identifiable {
    var id: Int { episodeId ?? number ?? 0 }
    var episodeId: Int?
    var season: Int?
    var number: Int?
    var absolute: Int?
    var title: String?
    var overview: String?
    var thumbnail: String?
    var aired: String?
    var runtime: Int?
}

struct TVDBCharacterInfo: Codable, Equatable, Identifiable {
    var id: String { "\(name)-\(person ?? "")" }
    var name: String?
    var person: String?
    var role: String?
    var image: String?
}

// MARK: - Provider

/// The TVDB v4 metadata provider — the PRIMARY source for anime detail
/// data (artwork, synopsis, episodes, characters, studios, genres).
///
/// Authentication uses the app's production TVDB API key (the same key
/// TVDBMappingService has used for artwork since v2.19). ID resolution is
/// EXACT — AniList/MAL ids map to TVDB ids through the anira mapping
/// snapshot (id-keyed, never title-guessed), so a TVDB record can only
/// ever be the same series as the AniList record it enriches.
@MainActor
final class TVDBProvider {
    static let shared = TVDBProvider()

    private let endpoint = "https://api4.thetvdb.com/v4"
    private let apiKey = "4cd66d53-3c21-45a7-9dd2-e4a9c2ed20a8"

    private var token: String?
    private var tokenExpiry: Date?

    /// Shared in-flight artwork/extended fetches (dedup per series id).
    private var extendedInFlight: [Int: Task<TVDBDetailFields?, Never>] = [:]

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Auth

    private func authenticate() async throws -> String {
        if let t = token, let expiry = tokenExpiry, expiry > Date() { return t }
        struct LoginResponse: Decodable {
            struct Data: Decodable { let token: String }
            let data: Data
        }
        var request = URLRequest(url: URL(string: "\(endpoint)/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apikey": apiKey])
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            token = nil
            throw ProviderChainError.allProvidersFailed(lastReason: "TVDB login rejected (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        token = decoded.data.token
        tokenExpiry = Date().addingTimeInterval(3600 * 24 * 25) // documented ~1 month
        return decoded.data.token
    }

    // MARK: - Health check (used by Test Provider)

    /// A REAL minimal request: login + one search. Returns true only when
    /// usable data comes back.
    func healthCheck() async throws -> Bool {
        let token = try await authenticate()
        var req = URLRequest(url: URL(string: "\(endpoint)/search?query=one%20piece&type=series&limit=1")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let decoded = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return !(decoded.data ?? []).isEmpty
    }

    // MARK: - Search

    private struct SearchEnvelope: Decodable {
        let data: [SearchResult]?
    }

    private struct SearchResult: Decodable {
        let name: String?
        let title: String?
        let overview: String?
        let year: String?
        let poster: String?
        let image_url: String?
        let thumbnail: String?
        let tvdb_id: Int?
        let id: Int?
        let type: String?
        let genres: [String]?
        let remote_ids: [RemoteID]?
    }

    private struct RemoteID: Decodable {
        let id: String?
        let source: String?
    }

    /// TVDB search for the SEARCH page. Only results that carry a MAL or
    /// AniList remote id can navigate into the app's detail pages — the
    /// rest are dropped rather than shown as dead ends.
    func searchMedia(query: String) async throws -> [Media] {
        let token = try await authenticate()
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(endpoint)/search?query=\(encoded)&type=series&limit=20") else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "TVDB search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        let results = (envelope.data ?? []).filter { $0.type == nil || $0.type == "series" }
        var media: [Media] = []
        for result in results {
            let ids = extractIds(result.remote_ids)
            // Only results with a real MAL or AniList id can navigate into
            // the app's detail pages — drop the rest (no dead-end rows).
            guard let navId = ids.anilist ?? ids.mal else { continue }
            let provider: ProviderType = ids.anilist != nil ? .anilist : .mal
            let cover = result.poster ?? result.image_url ?? result.thumbnail
            media.append(Media(
                id: navId,
                idMal: ids.mal,
                provider: provider,
                title: MediaTitle(romaji: result.name, english: result.title, native: nil),
                coverImage: MediaCoverImage(large: cover, extraLarge: nil),
                bannerImage: nil,
                description: result.overview,
                episodes: nil,
                status: nil,
                averageScore: nil,
                genres: result.genres,
                season: nil,
                seasonYear: Int(result.year ?? ""),
                nextAiringEpisode: nil,
                relations: nil,
                type: "ANIME",
                format: "TV",
                studioNames: nil,
                source: nil,
                duration: nil,
                airDateRange: nil))
        }
        return media
    }

    private func extractIds(_ remotes: [RemoteID]?) -> (anilist: Int?, mal: Int?) {
        var anilist: Int?
        var mal: Int?
        for remote in remotes ?? [] {
            let source = (remote.source ?? "").lowercased()
            let value = Int(remote.id ?? "")
            guard let value, value > 0 else { continue }
            if source.contains("anilist") { anilist = anilist ?? value }
            if source.contains("mal") || source == "myanimelist" { mal = mal ?? value }
        }
        return (anilist, mal)
    }

    // MARK: - Detail fields (id-keyed)

    /// TVDB metadata for one title. The id resolution goes through the
    /// existing anira mapping snapshot — an EXACT series match (never
    /// title-guessed), so the TVDB record is the same series.
    func detailFields(anilistId: Int?, malId: Int?) async -> TVDBDetailFields? {
        guard anilistId != nil || malId != nil else { return nil }
        let provider: ProviderType = anilistId != nil ? .anilist : .mal
        let lookupId = anilistId ?? malId!
        guard let mapping = await TVDBMappingService.shared.getTVDBId(
            for: lookupId, provider: provider, malId: malId), mapping.id > 0 else {
            return nil
        }
        let tvdbId = mapping.id
        if let running = extendedInFlight[tvdbId] {
            return await running.value
        }
        let task = Task<TVDBDetailFields?, Never> { [weak self] in
            await self?.fetchExtended(tvdbId: tvdbId)
        }
        extendedInFlight[tvdbId] = task
        let result = await task.value
        extendedInFlight[tvdbId] = nil
        return result
    }

    private struct ExtendedEnvelope: Decodable {
        let data: ExtendedSeries?
    }

    private struct ExtendedSeries: Decodable {
        let id: Int?
        let name: String?
        let overview: String?
        let image: String?
        let score: Double?
        let status: Status?
        let firstAired: String?
        let year: String?
        let averageRuntime: Int?
        let episodes: [EpisodeRecord]?
        let characters: [CharacterRecord]?
        let artworks: [ArtworkRecord]?
        let genres: [GenreRecord]?
        let companies: [CompanyRecord]?
        let originalNetwork: CompanyRecord?
        let remoteIds: [RemoteID]?

        struct Status: Decodable { let name: String? }
        struct EpisodeRecord: Decodable {
            let id: Int?
            let seasonNumber: Int?
            let number: Int?
            let absoluteNumber: Int?
            let name: String?
            let overview: String?
            let image: String?
            let aired: String?
            let runtime: Int?
        }
        struct CharacterRecord: Decodable {
            let name: String?
            let image: String?
            let people: [PersonRecord]?
            struct PersonRecord: Decodable {
                let name: String?
                let role: String?
                let image: String?
            }
        }
        struct ArtworkRecord: Decodable {
            let image: String?
            let type: Int?
            let width: Int?
            let height: Int?
            let score: Int?
            let language: String?
        }
        struct GenreRecord: Decodable { let name: String? }
        struct CompanyRecord: Decodable {
            let name: String?
            let companyType: String?
        }
    }

    private func fetchExtended(tvdbId: Int) async -> TVDBDetailFields? {
        do {
            let token = try await authenticate()
            var req = URLRequest(url: URL(string: "\(endpoint)/series/\(tvdbId)/extended")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Logger.shared.log("[TVDB] series extended failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", type: "Provider")
                return nil
            }
            let envelope = try JSONDecoder().decode(ExtendedEnvelope.self, from: data)
            guard let series = envelope.data else { return nil }

            var fields = TVDBDetailFields()
            fields.synopsis = nonEmpty(series.overview)
            fields.episodeCount = series.episodes?.count
            fields.runtimeMinutes = series.averageRuntime
            fields.score = series.score
            fields.status = series.status?.name
            fields.firstAired = series.firstAired
            fields.genres = series.genres?.compactMap(\.name).filter { !$0.isEmpty }
            // Studios: production companies + the original network.
            var studios = (series.companies ?? []).compactMap { company -> String? in
                guard let name = company.name, !name.isEmpty else { return nil }
                let type = (company.companyType ?? "").lowercased()
                return type.contains("studio") || type.contains("production") || type.contains("animation") ? name : nil
            }
            if let network = series.originalNetwork?.name, !network.isEmpty, !studios.contains(network) {
                studios.append(network)
            }
            fields.studios = studios.isEmpty ? nil : studios
            fields.network = series.originalNetwork?.name

            // Artwork — verified TVDB type ids (same mapping the artwork
            // service uses): 2 poster, 3 background/fanart, 23 clearlogo.
            let artworks = series.artworks ?? []
            func best(_ typeId: Int) -> String? {
                artworks.filter { $0.type == typeId }
                    .sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
                    .first?.image
            }
            fields.posterURL = best(2) ?? nonEmpty(series.image)
            fields.bannerURL = best(3)
            fields.logoURL = best(23)

            fields.episodes = (series.episodes ?? []).map { ep in
                TVDBEpisodeInfo(
                    episodeId: ep.id,
                    season: ep.seasonNumber,
                    number: ep.number,
                    absolute: ep.absoluteNumber,
                    title: ep.name,
                    overview: ep.overview,
                    thumbnail: ep.image,
                    aired: ep.aired,
                    runtime: ep.runtime)
            }
            fields.characters = (series.characters ?? []).map { character in
                let person = character.people?.first
                return TVDBCharacterInfo(
                    name: character.name,
                    person: person?.name,
                    role: person?.role,
                    image: character.image)
            }
            let ids = extractIds(series.remoteIds)
            fields.anilistId = ids.anilist
            fields.malId = ids.mal
            return fields
        } catch {
            Logger.shared.log("[TVDB] extended fetch error: \(error.localizedDescription)", type: "Provider")
            return nil
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
