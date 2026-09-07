import Foundation

// MARK: - Detail fields

/// MangaBaka's contribution to a manga detail bundle — the PRIMARY manga
/// source per the provider priority. Fields the provider doesn't carry
/// stay nil and get filled from MAL → AniList (field-level fallback).
struct MangaBakaDetailFields: Codable, Equatable {
    var title: String?
    var coverURL: String?
    var description: String?
    var chapters: Int?
    var volumes: Int?
    var authors: [String]?
    var artists: [String]?
    var genres: [String]?
    var status: String?
    var type: String?
    var rating: Double?
    var published: String?
    var malId: Int?
    var anilistId: Int?
}

// MARK: - Provider

/// MangaBaka provider — the PRIMARY manga source.
///
/// Real public JSON API at api.mangabaka.org/v2 (search + full series
/// records). The host sits behind Cloudflare; requests from some networks
/// (datacenter IPs especially) are challenged — a challenge response is
/// an honest failure and the chain moves to MAL, so a MangaBaka block can
/// never blank the manga pages. Navigation ids are parsed from the
/// provider's own `links` (MAL / AniList URLs) — never guessed.
@MainActor
final class MangaBakaProvider {
    static let shared = MangaBakaProvider()

    private let base = "https://api.mangabaka.org/v2"

    /// Series-id cache keyed by MAL id (from the provider's own links) so
    /// detail lookups don't re-search every time.
    private var malIdToSeriesId: [Int: Int] = [:]
    private var searchInFlight: [String: Task<[Media]?, Never>] = [:]

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        // A real browser identity: MangaBaka's CDN rejects bare API agents
        // outright on some networks.
        cfg.httpAdditionalHeaders = [("User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")]
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Response models

    private struct Envelope: Decodable {
        let data: MBSeries?
        let pagination: MBPagination?
    }

    private struct ListEnvelope: Decodable {
        let data: [MBSeries]?
        let pagination: MBPagination?
    }

    private struct MBPagination: Decodable {
        let count: Int?
        let page: Int?
        let limit: Int?
        let next: String?
        let previous: String?
    }

    private struct MBSeries: Decodable {
        let id: Int?
        let state: String?
        let title: String?
        let cover: MBCover?
        let authors: [String]?
        let artists: [String]?
        let description: String?
        let status: String?
        let type: String?
        let rating: Double?
        let finalVolume: Int?
        let totalChapters: Int?
        let titles: [MBTitle]?
        let tags: [MBTag]?
        let links: [MBLink]?
        let published: MBPublished?

        enum CodingKeys: String, CodingKey {
            case id, state, title, cover, authors, artists, description, status, type, rating
            case finalVolume = "final_volume"
            case totalChapters = "total_chapters"
            case titles, tags, links, published
        }

        struct MBCover: Decodable {
            let raw: String?
            let x150: String?
            let x250: String?
            let x350: String?
        }
        struct MBTitle: Decodable {
            let title: String?
            let isPrimary: Bool?
            let language: String?
        }
        struct MBTag: Decodable {
            let name: String?
            let isGenre: Bool?
            let isSpoiler: Bool?
        }
        struct MBLink: Decodable {
            let url: String?
            let name: String?
            let type: String?
        }
        struct MBPublished: Decodable {
            // MangaBaka publishes the first publication year/month.
            let year: Int?
            let month: Int?
        }
    }

    private init() {}

    // MARK: - Health check

    func healthCheck() async throws -> Bool {
        let url = URL(string: "\(base)/series/search?q=one%20piece&limit=1")
        guard let url else { return false }
        let (data, response) = try await Self.session.data(for: URLRequest(url: url))
        let body = String(data: data, encoding: .utf8) ?? ""
        // Cloudflare challenge pages are HTML, not API JSON.
        if body.contains("<!DOCTYPE html>") || body.contains("Just a moment") {
            throw ProviderChainError.allProvidersFailed(lastReason: "Cloudflare challenge — MangaBaka is blocking this network")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "MangaBaka request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let doc = try? JSONDecoder().decode(ListEnvelope.self, from: data)
        return !(doc?.data ?? []).isEmpty
    }

    // MARK: - Helpers

    /// Detects a Cloudflare challenge / non-JSON response.
    private func isChallenge(_ data: Data, _ response: URLResponse?) -> Bool {
        if let http = response as? HTTPURLResponse, http.statusCode == 403 { return true }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("<!DOCTYPE html>") || body.contains("Just a moment")
    }

    /// Extracts MAL / AniList ids from the provider's own link URLs.
    private func extractIds(_ links: [MBSeries.MBLink]?) -> (mal: Int?, anilist: Int?) {
        var mal: Int?
        var anilist: Int?
        for link in links ?? [] {
            guard let url = link.url else { continue }
            let lowered = url.lowercased()
            if let id = extractTrailingId(url: url), lowered.contains("myanimelist.net") {
                mal = mal ?? id
            }
            if let id = extractTrailingId(url: url), lowered.contains("anilist.co") {
                anilist = anilist ?? id
            }
        }
        return (mal, anilist)
    }

    private func extractTrailingId(url: String) -> Int? {
        Int(url.split(separator: "/").last ?? "")
    }

    private func mapStatus(_ raw: String?) -> String? {
        switch raw {
        case "releasing": return "RELEASING"
        case "completed": return "FINISHED"
        case "hiatus": return "HIATUS"
        case "upcoming": return "NOT_YET_RELEASED"
        case "cancelled": return "CANCELLED"
        default: return raw
        }
    }

    private func mapFormat(_ raw: String?) -> String? {
        switch raw {
        case "manga": return "MANGA"
        case "novel": return "NOVEL"
        case "manhwa", "manhua": return "MANGA"
        default: return raw?.uppercased()
        }
    }

    private func buildMedia(from series: MBSeries) -> Media? {
        guard let seriesId = series.id else { return nil }
        let ids = extractIds(series.links)
        // Navigation needs a real MAL or AniList id from the provider's own
        // links; items without one would be dead ends, so they're skipped
        // in LIST results (detail fields still work by series id).
        guard let navId = ids.mal ?? ids.anilist else { return nil }
        let provider: ProviderType = ids.mal != nil ? .mal : .anilist
        let cover = series.cover?.x350 ?? series.cover?.raw
        let genres = (series.tags ?? []).compactMap { tag -> String? in
            guard tag.isGenre == true, let name = tag.name, !name.isEmpty, tag.isSpoiler != true else { return nil }
            return name
        }
        let englishTitle = series.titles?.first(where: { ($0.language ?? "").lowercased().hasPrefix("en") && ($0.isPrimary ?? false) })?.title
        let romajiTitle = series.titles?.first(where: { ($0.language ?? "").lowercased().hasPrefix("ja") })?.title
        // MangaBaka ratings are 0–10; the app's averageScore is 0–100.
        let score = series.rating.flatMap { $0 > 0 && $0 <= 10 ? Int(($0 * 10).rounded()) : nil }
        return Media(
            id: navId,
            idMal: ids.mal,
            provider: provider,
            title: MediaTitle(romaji: romajiTitle ?? series.title, english: englishTitle ?? series.title, native: nil),
            coverImage: MediaCoverImage(large: cover, extraLarge: series.cover?.raw),
            bannerImage: nil,
            description: series.description,
            episodes: series.totalChapters,
            status: mapStatus(series.status),
            averageScore: score,
            genres: genres.isEmpty ? nil : genres,
            season: nil,
            seasonYear: series.published?.year,
            nextAiringEpisode: nil,
            relations: nil,
            type: "MANGA",
            format: mapFormat(series.type),
            studioNames: nil,
            source: nil,
            duration: nil,
            airDateRange: nil,
            volumes: series.finalVolume,
            popularity: nil,
            countryOfOrigin: nil)
    }

    // MARK: - Search

    func searchMedia(query: String) async throws -> [Media] {
        if let running = searchInFlight[query] {
            return await running.value ?? []
        }
        let task = Task<[Media]?, Never> { [weak self] in
            await self?.performSearch(query: query)
        }
        searchInFlight[query] = task
        let result = await task.value
        searchInFlight[query] = nil
        guard let result else {
            // performSearch returned nil = transport/challenge failure —
            // a chain-eligible error (not an empty result).
            throw ProviderChainError.allProvidersFailed(lastReason: "MangaBaka unreachable (blocked or offline)")
        }
        return result
    }

    private func performSearch(query: String) async -> [Media]? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(base)/series/search?q=\(encoded)&limit=50&page=1") else { return [] }
        do {
            let (data, response) = try await Self.session.data(for: URLRequest(url: url))
            if isChallenge(data, response) { return nil }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let doc = try JSONDecoder().decode(ListEnvelope.self, from: data)
            let series = doc.data ?? []
            // Remember MAL-id → series-id mappings for detail lookups.
            for entry in series {
                if let sid = entry.id, let mal = extractIds(entry.links).mal {
                    malIdToSeriesId[mal] = sid
                }
            }
            return series.compactMap { buildMedia(from: $0) }
        } catch {
            return nil
        }
    }

    // MARK: - Detail fields

    /// MangaBaka detail for a title. Resolution order: exact series id via
    /// a remembered mapping (from search), then a targeted search by
    /// MAL-id-known title. Title matches must be EXACT (skeleton compare)
    /// so a detail bundle can never belong to a different series.
    func detailFields(malId: Int?, titleHint: String?) async -> MangaBakaDetailFields? {
        // 1. Known series id (from a previous search).
        if let malId, let seriesId = malIdToSeriesId[malId] {
            return await fetchSeries(seriesId: seriesId)
        }
        // 2. Search by title hint, then exact-match against the MAL id.
        if let titleHint, !titleHint.isEmpty {
            let encoded = titleHint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? titleHint
            if let url = URL(string: "\(base)/series/search?q=\(encoded)&limit=20&page=1"),
               let (data, response) = try? await Self.session.data(for: URLRequest(url: url)),
               !isChallenge(data, response),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
               let doc = try? JSONDecoder().decode(ListEnvelope.self, from: data) {
                let skeleton = titleHint.lowercased().filter { $0.isLetter || $0.isNumber }
                for entry in doc.data ?? [] {
                    guard let sid = entry.id else { continue }
                    let ids = extractIds(entry.links)
                    if let malId, ids.mal == malId {
                        if ids.mal != nil { malIdToSeriesId[malId] = sid }
                        return await fetchSeries(seriesId: sid)
                    }
                    // Title-skeleton equality is a strict secondary match.
                    if malId == nil,
                       let primary = primaryTitle(entry),
                       primary.lowercased().filter({ $0.isLetter || $0.isNumber }) == skeleton,
                       (ids.mal != nil || ids.anilist != nil) {
                        return await fetchSeries(seriesId: sid)
                    }
                }
            }
        }
        return nil
    }

    private func primaryTitle(_ series: MBSeries) -> String? {
        series.titles?.first(where: { $0.isPrimary ?? false })?.title ?? series.title
    }

    private func fetchSeries(seriesId: Int) async -> MangaBakaDetailFields? {
        guard let url = URL(string: "\(base)/series/\(seriesId)?schema=full"),
              let (data, response) = try? await Self.session.data(for: URLRequest(url: url)),
              !isChallenge(data, response),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let doc = try? JSONDecoder().decode(Envelope.self, from: data),
              let series = doc.data else {
            return nil
        }
        let ids = extractIds(series.links)
        let genres = (series.tags ?? []).compactMap { tag -> String? in
            guard tag.isGenre == true, tag.isSpoiler != true, let name = tag.name, !name.isEmpty else { return nil }
            return name
        }
        var published: String?
        if let year = series.published?.year {
            published = series.published?.month.map { "\($0)/\(year)" } ?? "\(year)"
        }
        return MangaBakaDetailFields(
            title: primaryTitle(series),
            coverURL: series.cover?.x350 ?? series.cover?.raw,
            description: series.description,
            chapters: series.totalChapters,
            volumes: series.finalVolume,
            authors: series.authors,
            artists: series.artists,
            genres: genres.isEmpty ? nil : genres,
            status: mapStatus(series.status),
            type: series.type,
            rating: series.rating,
            published: published,
            malId: ids.mal,
            anilistId: ids.anilist)
    }
}
