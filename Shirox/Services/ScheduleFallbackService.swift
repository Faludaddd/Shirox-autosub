import Foundation

/// Multi-source fallback for the anime Schedule (#schedule-fallback).
///
/// The Schedule page used to be hard-wired to AniList's `airingSchedules`
/// GraphQL query — when AniList goes down (outage, 403 "API disabled", 429
/// rate limit, network error), the page went blank with an error.
///
/// This service owns the backup half of the chain:
///
///   1. AniList in-memory cache   (owned by AniListService, 60s TTL)
///   2. AniList network fetch     (owned by AniListService)
///   3. Jikan /schedules          (THIS service — per-weekday airing lists
///                                 from MyAnimeList, no auth, no AniList)
///   4. Disk snapshot             (THIS service — the last schedule that
///                                 ANY source successfully produced, kept
///                                 up to 48h so a temporary outage never
///                                 destroys the page)
///
/// Jikan's schedule entries carry broadcast slots ("Sundays at 17:00"
/// JST) rather than exact episode air times, and no episode numbers.
/// Entries built from it are honest about that: the badge shows "NEW"
/// instead of "EP N", and the AniList cross-reference is filled in from
/// the offline id-mapping cache whenever it is known (so library actions
/// and notifications still work for mapped titles).
///
/// Fail-soft by design: every function returns `nil`/empty on failure
/// instead of throwing to callers that render UI — the Schedule view
/// decides how much of the chain to show.
@MainActor
final class ScheduleFallbackService {

    static let shared = ScheduleFallbackService()

    private init() {}

    // MARK: - Networking

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    /// Minimum spacing between outbound Jikan requests (their public limit
    /// is 3 req/s; the weekday fetches loop sequentially so this keeps the
    /// whole fallback under the limit).
    private var lastRequestAt = Date.distantPast
    private let minRequestSpacing: TimeInterval = 0.45

    // MARK: - Public API

    /// Fetches the airing schedule from Jikan (`/schedules?filter=<weekday>`)
    /// for every weekday covered by the `[from, to]` window and maps the
    /// results into unified entries. Returns only entries that fall inside
    /// the window. Throws when every weekday request fails — the caller
    /// decides whether that means "empty" or "try the next source".
    ///
    /// Jikan only describes the *current* airing week: a window that reaches
    /// into next week still gets entries (a Monday show airs next Monday
    /// too), which is the best available approximation from this source.
    func jikanSchedule(from: Int, to: Int) async throws -> [UnifiedScheduleEntry] {

        // Distinct weekdays (local time) covered by the window, capped at 7.
        let cal = Calendar.current
        let fromDate = Date(timeIntervalSince1970: TimeInterval(from))
        let toDate = Date(timeIntervalSince1970: TimeInterval(to))
        var weekdayDates: [Date] = []
        var cursor = cal.startOfDay(for: fromDate)
        let endDay = cal.startOfDay(for: toDate)
        while weekdayDates.count < 7, cursor <= endDay {
            let weekday = cal.component(.weekday, from: cursor)
            if !weekdayDates.contains(where: { cal.component(.weekday, from: $0) == weekday }) {
                weekdayDates.append(cursor)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !weekdayDates.isEmpty else { return [] }

        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday",
                            "thursday", "friday", "saturday"]
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current

        var byMALId: [Int: UnifiedScheduleEntry] = [:]
        var lastError: Error?

        for day in weekdayDates {
            let weekdayIndex = cal.component(.weekday, from: day) // 1 = Sunday
            let name = weekdayNames[weekdayIndex - 1]

            // For a weekday visited once already (window > 7 days — can't
            // happen, capped above) we skip; otherwise fetch this weekday's
            // airing list once.
            do {
                let items = try await fetchWeekday(name)
                for item in items {
                    guard let malId = item.malId,
                          let title = item.title,
                          !title.isEmpty else { continue }

                    // Broadcast time ("17:00", JST) → timestamp on this
                    // window day. Missing/invalid broadcast → noon JST
                    // (entries sort into the right day, honest about the
                    // imprecise time).
                    let hour: Int
                    let minute: Int
                    if let time = item.broadcastTime,
                       let parsed = Self.parseClock(time) {
                        (hour, minute) = parsed
                    } else {
                        (hour, minute) = (12, 0)
                    }
                    var comps = cal.dateComponents([.year, .month, .day], from: day)
                    comps.hour = hour
                    comps.minute = minute
                    comps.timeZone = tokyo
                    guard let airDate = cal.date(from: comps) else { continue }
                    let airingAt = Int(airDate.timeIntervalSince1970)
                    guard airingAt >= from, airingAt <= to else { continue }

                    // Ids: 900_000_000 + malId * 1000 keeps Jikan entries
                    // far away from AniList's airing-schedule ids (and from
                    // every realistic MAL id), so notification keys never
                    // collide across sources.
                    let entryId = 900_000_000 + malId * 1000
                    let popularity = item.members ?? Int((item.score ?? 0) * 100)
                    let entry = UnifiedScheduleEntry(
                        id: entryId,
                        source: .anime,
                        sourceMediaId: malId,
                        aniListMediaId: IDMappingService.shared.cachedAnilistId(forMALId: malId),
                        title: title,
                        airingAt: airingAt,
                        episode: 0,
                        season: nil,
                        coverImage: item.coverImage,
                        format: item.type,
                        isStreamingRelease: false,
                        genres: item.genres,
                        popularity: popularity
                    )
                    // A title can appear on multiple weekdays in the source
                    // (Jikan lists the broadcast day, the window may cover
                    // it twice) — first (earliest) hit wins.
                    if byMALId[malId] == nil {
                        byMALId[malId] = entry
                    }
                }
            } catch {
                lastError = error
                Logger.shared.log("[ScheduleFallback] weekday \(name) failed: \(error.localizedDescription)", type: "Debug")
            }
        }

        // If literally every weekday request failed, this source is down.
        if byMALId.isEmpty, let lastError {
            throw lastError
        }
        return byMALId.values.sorted { $0.airingAt < $1.airingAt }
    }

    // MARK: - Disk snapshot (last-resort offline cache)

    private struct Snapshot: Codable {
        let storedAt: Date
        let windowFrom: Int
        let windowTo: Int
        let entries: [UnifiedScheduleEntry]
    }

    private var snapshotURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("schedule-fallback-snapshot.json")
    }

    /// Persists the last schedule that any source produced successfully.
    /// Called by the Schedule view after a successful load (AniList OR
    /// Jikan) so the next outage can fall back to real recent data.
    func storeSnapshot(_ entries: [UnifiedScheduleEntry], from: Int, to: Int) {
        guard !entries.isEmpty else { return }
        let snap = Snapshot(storedAt: Date(), windowFrom: from, windowTo: to, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snap) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    /// Returns the cached snapshot when it is fresh enough (≤ 48h) and at
    /// least some of its entries overlap the requested window; `nil`
    /// otherwise. Entries are filtered to the window so past entries from
    /// an older snapshot don't pollute the page.
    func cachedSnapshot(from: Int, to: Int) -> (entries: [UnifiedScheduleEntry], storedAt: Date)? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return nil }
        guard Date().timeIntervalSince(snap.storedAt) < 48 * 3600 else { return nil }
        let entries = snap.entries.filter { $0.airingAt >= from && $0.airingAt <= to }
        guard !entries.isEmpty else { return nil }
        return (entries, snap.storedAt)
    }

    /// Nukes the disk snapshot (Storage → "Other Cached Data").
    func clearSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    // MARK: - Jikan request

    private struct JikanScheduleItem {
        let malId: Int?
        let title: String?
        let coverImage: String?
        let type: String?
        let genres: [String]?
        let broadcastTime: String?
        let score: Double?
        let members: Int?
    }

    private struct JikanScheduleRoot: Decodable {
        let data: [JikanScheduleEntry]?
    }

    private struct JikanScheduleEntry: Decodable {
        let mal_id: Int?
        let title: String?
        let images: JikanImagesBox?
        let type: String?
        let genres: [JikanGenreLite]?
        let broadcast: JikanBroadcastBox?
        let score: Double?
        let members: Int?

        struct JikanImagesBox: Decodable { let jpg: JikanJpgBox? }
        struct JikanJpgBox: Decodable { let large_image_url: String?; let image_url: String? }
        struct JikanGenreLite: Decodable { let name: String? }
        struct JikanBroadcastBox: Decodable { let time: String? }
    }

    private func fetchWeekday(_ weekday: String) async throws -> [JikanScheduleItem] {
        // Pacing: keep the sequential weekday fetches under Jikan's limit.
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minRequestSpacing {
            try? await Task.sleep(nanoseconds: UInt64((minRequestSpacing - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        var components = URLComponents(url: URL(string: "https://api.jikan.moe/v4/schedules")!,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter", value: weekday),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "sfw", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let root = try JSONDecoder().decode(JikanScheduleRoot.self, from: data)
        return (root.data ?? []).map {
            JikanScheduleItem(
                malId: $0.mal_id,
                title: $0.title,
                coverImage: $0.images?.jpg?.large_image_url ?? $0.images?.jpg?.image_url,
                type: $0.type,
                genres: $0.genres?.compactMap { $0.name }.filter { !$0.isEmpty }.isEmpty
                    ? nil : $0.genres?.compactMap { $0.name },
                broadcastTime: $0.broadcast?.time,
                score: $0.score,
                members: $0.members
            )
        }
    }

    /// Parses a "HH:mm" broadcast clock string ("17:00").
    private static func parseClock(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
