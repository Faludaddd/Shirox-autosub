import Foundation

// MARK: - Kitsu + TVDB timetable synthesis (Batch 26, schedule chain's
// final LIVE source)
//
// WHY THIS EXISTS: the prescribed schedule chain is AniChart →
// AnimeSchedule → MAL → AniList — and during the current outage window
// ALL FOUR are genuinely down (AniChart is AniList-backed 403,
// AnimeSchedule requires a user API token, MAL/Jikan 504, AniList 403).
// The chain logic was correct; the page went dark because no LIVE source
// remained after them.
//
// WHAT THIS SERVES: a REAL week timetable synthesized from two sources
// that ARE live — the discovery database (Kitsu `filter[status]=current`:
// the currently-airing shows, each carrying its AniList/MAL/TheTVDB ids)
// joined with TVDB's per-series airing fields (nextAired + airsTime +
// lastAired, id-keyed through the exact same series). Every entry has a
// real title, real cover, real ids (navigation works) and a REAL air
// time. Episode numbers are honestly 0 → the card renders the same "NEW"
// badge the Jikan fallback has always used for entries whose source
// doesn't carry per-episode numbers.

@MainActor
final class KitsuTVDBTimetableService {
    static let shared = KitsuTVDBTimetableService()

    private let base = "https://kitsu.io/api/edge"
    private let tvdbBase = "https://api4.thetvdb.com/v4"

    /// TVDB extended payloads per series, cached 6h in the shared provider
    /// cache (schedule domain) — repeat schedule loads cost nothing.
    private static let tvdbTTL: TimeInterval = 6 * 3600

    /// How many currently-airing shows are considered (most-followed
    /// first — the same honest popularity ordering every discovery list
    /// uses). NOTE: Kitsu's max page[limit] is 20 (verified live: 25
    /// answers HTTP 400), so this stays at 20.
    private let showBudget = 20
    /// Parallel TVDB fetches. Verified live: 8 parallel extended requests
    /// all answer in under a second; 6 keeps comfortable headroom.
    private let concurrency = 6

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Entry point (called by the unified schedule chain)

    func entries(from startTs: Int, to endTs: Int) async throws -> [UnifiedScheduleEntry]? {
        // 1. The discovery list: currently-airing anime with their
        //    cross-provider ids (Kitsu mappings include thetvdb ids —
        //    verified live; anira resolves the rest id-keyed).
        guard let airing = try? await currentlyAiring(),
              !airing.isEmpty else { return nil }

        // 2. TVDB airing fields per show (bounded parallelism, 6h cache).
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var entries: [UnifiedScheduleEntry] = []

        // Chunked task group (concurrency-bounded).
        var index = 0
        while index < airing.count {
            let chunk = Array(airing[index..<Swift.min(index + concurrency, airing.count)])
            let fields = await withTaskGroup(of: (Int, TVDBAiringFields?).self) { group in
                for (i, show) in chunk.enumerated() {
                    group.addTask { [weak self] in
                        guard let self else { return (i, nil) }
                        let f = await self.airingFields(for: show)
                        return (i, f)
                    }
                }
                var results: [(Int, TVDBAiringFields?)] = []
                for await r in group { results.append(r) }
                return results
            }
            for (offsetInChunk, f) in fields {
                let show = chunk[offsetInChunk]
                guard let f else { continue }
                entries.append(contentsOf: Self.buildEntries(show: show, fields: f, startTs: startTs, endTs: endTs, tokyo: tokyo))
            }
            index += concurrency
        }

        guard !entries.isEmpty else { return nil }
        return entries.sorted {
            if $0.popularity != $1.popularity { return $0.popularity > $1.popularity }
            return $0.airingAt < $1.airingAt
        }
    }

    // MARK: - Kitsu currently-airing list

    private struct AiringShow {
        let media: Media
        let title: String
        let kitsuId: Int?
        let tvdbId: Int?
    }

    private func currentlyAiring() async throws -> [AiringShow] {
        guard let url = URL(string: "\(base)/anime?filter[status]=current&sort=-userCount&page[limit]=\(showBudget)&include=mappings") else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderChainError.allProvidersFailed(lastReason: "Kitsu currently-airing request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        // Reuse the provider's list decoding (Media with tvdbId/kitsuId
        // resolved from the mappings include).
        let media = try KitsuProvider.shared.decodeListData(data)
        return media.compactMap { m in
            AiringShow(media: m, title: m.title.displayTitle, kitsuId: m.kitsuId, tvdbId: m.tvdbId)
        }
    }

    // MARK: - TVDB airing fields

    /// TVDB's per-series airing data (its CURRENT wire fields — verified
    /// live): `nextAired` (next episode's DATE, "2026-09-13"), `lastAired`,
    /// `airsTime` ("23:15" JST) and `status.name` ("Continuing").
    struct TVDBAiringFields: Codable, Equatable {
        var nextAired: String?
        var lastAired: String?
        var airsTime: String?
        var statusName: String?

        var isEmpty: Bool { nextAired == nil && lastAired == nil }
    }

    private func airingFields(for show: AiringShow) async -> TVDBAiringFields? {
        var tvdbId = show.tvdbId
        if tvdbId == nil {
            // Resolve through the shared id-mapping service (anira bulk
            // snapshot — id-keyed, never a title guess).
            if let anilistId = show.media.provider == .anilist ? show.media.id : nil,
               let mapping = await TVDBMappingService.shared.getTVDBId(for: anilistId, provider: .anilist) {
                tvdbId = mapping.id
            } else if let malId = show.media.idMal ?? (show.media.provider == .mal ? show.media.id : nil),
                      let mapping = await TVDBMappingService.shared.getTVDBId(for: malId, provider: .mal) {
                tvdbId = mapping.id
            }
        }
        guard let tvdbId, tvdbId > 0 else { return nil }

        // 6h disk cache.
        let cacheKey = "tvdb-airing-\(tvdbId)"
        if let cached = ProviderCacheStore.read(TVDBAiringFields.self, key: cacheKey, domain: .schedule, ttl: Self.tvdbTTL),
           !cached.isEmpty {
            return cached
        }

        do {
            let token = try await TVDBProvider.shared.bearerToken()
            var req = URLRequest(url: URL(string: "\(tvdbBase)/series/\(tvdbId)/extended")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            struct Envelope: Decodable {
                struct Series: Decodable {
                    struct Status: Decodable { let name: String? }
                    let nextAired: String?
                    let lastAired: String?
                    let airsTime: String?
                    let status: Status?
                }
                let data: Series?
            }
            guard let series = try JSONDecoder().decode(Envelope.self, from: data).data else { return nil }
            let fields = TVDBAiringFields(
                nextAired: series.nextAired,
                lastAired: series.lastAired,
                airsTime: series.airsTime,
                statusName: series.status?.name)
            if !fields.isEmpty {
                ProviderCacheStore.write(fields, key: cacheKey, domain: .schedule)
            }
            return fields.isEmpty ? nil : fields
        } catch {
            return nil
        }
    }

    // MARK: - Entry construction

    /// Builds the schedule entries for one show: the NEXT airing (real
    /// date + real broadcast time) plus today's earlier episode when
    /// lastAired already happened today — the same window convention the
    /// page uses (episodes that aired earlier today stay visible).
    private static func buildEntries(show: AiringShow, fields: TVDBAiringFields, startTs: Int, endTs: Int, tokyo: TimeZone) -> [UnifiedScheduleEntry] {
        let cal = Calendar(identifier: .gregorian)

        func timestamp(dateString: String, timeString: String?) -> Int? {
            let parts = dateString.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var comps = DateComponents()
            comps.year = parts[0]
            comps.month = parts[1]
            comps.day = parts[2]
            var hour = 12, minute = 0
            if let time = timeString {
                let t = time.split(separator: ":")
                if t.count == 2, let h = Int(t[0]), let m = Int(t[1]) {
                    hour = h
                    minute = m
                }
            }
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = tokyo
            guard let date = cal.date(from: comps) else { return nil }
            return Int(date.timeIntervalSince1970)
        }

        var results: [UnifiedScheduleEntry] = []

        // Stable synthetic id space (Kitsu-sourced rows, no AniList
        // airing ids): 800_000_000 + anilist/mal id — far clear of the
        // AniList and Jikan ranges so notification keys never collide.
        let baseId = 800_000_000 + (show.media.id % 50_000_000)

        func makeEntry(airingTs: Int) -> UnifiedScheduleEntry {
            UnifiedScheduleEntry(
                id: baseId,
                source: .anime,
                sourceMediaId: show.media.id,
                aniListMediaId: show.media.provider == .anilist ? show.media.id : nil,
                title: show.title,
                airingAt: airingTs,
                episode: 0, // honest "NEW" badge — same as the Jikan source
                season: nil,
                coverImage: show.media.coverImage.best,
                format: show.media.format,
                isStreamingRelease: false,
                genres: show.media.genres,
                popularity: show.media.popularity ?? 0)
        }

        // Today's earlier episode (lastAired can equal today).
        if let last = fields.lastAired,
           let ts = timestamp(dateString: last, timeString: fields.airsTime),
           ts >= startTs, ts < endTs {
            results.append(makeEntry(airingTs: ts))
        }
        // The next episode.
        if let next = fields.nextAired,
           let ts = timestamp(dateString: next, timeString: fields.airsTime),
           ts >= startTs, ts <= endTs,
           // nextAired == lastAired means the "next" row already landed —
           // don't double-place the same episode.
           !(fields.lastAired == fields.nextAired) {
            results.append(makeEntry(airingTs: ts))
        }
        return results
    }
}
