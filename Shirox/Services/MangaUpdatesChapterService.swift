import Foundation

/// Live chapter counts for ONGOING manga (Round 9, poster status line).
///
/// Why this service exists: AniList, MAL/Jikan and Kitsu all leave the
/// chapter total `null` while a manga is still releasing — they only
/// backfill it once the series finishes — so the unified poster line
/// "Airing, [N]" (# posterStatusText) had no in-house source for N on
/// airing manga. MangaUpdates is the one database that tracks the latest
/// released chapter of ongoing series, so we cross-reference it BY TITLE
/// (no id mapping exists) to fill in the count.
///
/// Design constraints:
/// - **Strict matching.** An exact normalized-title hit, year-compatible
///   when both sides know a year; anything less is treated as "no data"
///   so the poster keeps an honest bare "Airing" instead of a WRONG
///   number. MangaUpdates' free-text search falls back to unrelated
///   popular series when nothing matches (verified live), so "first
///   result" matching is never safe.
/// - **Disk cache.** 24h for hits, 6h for "no match" negatives, keyed by
///   AniList media id — repeat loads cost zero network calls.
/// - **Pacing.** ~1 request/second through an app-wide serial gate
///   (MangaUpdates unauthenticated etiquette), mirroring the Jikan gate
///   in `MALDiscoveryService`.
/// - **Fail-soft.** Network errors are transient (never cached): the
///   poster just keeps the bare status word until the next load retries.
final class MangaUpdatesChapterService {
    nonisolated(unsafe) static let shared = MangaUpdatesChapterService()

    private let base = URL(string: "https://api.mangaupdates.com/v1")!
    private let userAgent = "Shirox (+https://github.com/Faludaddd/Shirox-autosub)"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Cache (memory + disk)

    private struct CachedCount: Codable {
        let chapters: Int?   // nil = "searched, no reliable match"
        let fetchedAt: Date
    }

    private var cache: [String: CachedCount] = [:]
    private let cacheLock = NSLock()
    private let hitTTL: TimeInterval = 24 * 3600   // counts change at most weekly
    private let missTTL: TimeInterval = 6 * 3600   // retry a miss sooner
    private var didLoadDiskCache = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("mangaupdates-chapter-counts.json")
    }

    // MARK: - In-flight dedup + rate limiting

    private var inFlightTasks: [String: Task<Int?, Never>] = [:]
    private let inFlightLock = NSLock()

    private var lastRequestTime = Date.distantPast
    private let minRequestSpacing: TimeInterval = 1.1   // ~1 req/s, app-wide
    private let rateLimitLock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Returns the latest released chapter count for the given AniList manga,
    /// or nil when no reliable value is available (no match / network error /
    /// still cached as a miss). `title` is the primary search key (English
    /// title first — MangaUpdates indexes English best), `altTitle` the
    /// romaji/native fallback, `year` the AniList start year used to
    /// disambiguate same-named series.
    func latestChapter(anilistId: Int, title: String, altTitle: String? = nil, year: Int? = nil) async -> Int? {
        let key = "al\(anilistId)"

        if let fresh = freshCachedValue(forKey: key) { return fresh }

        inFlightLock.lock()
        if let existing = inFlightTasks[key] {
            inFlightLock.unlock()
            return await existing.value
        }
        let task = Task<Int?, Never> { [self] in
            await fetchCount(key: key, title: title, altTitle: altTitle, year: year)
        }
        inFlightTasks[key] = task
        inFlightLock.unlock()

        let value = await task.value
        inFlightLock.lock()
        inFlightTasks.removeValue(forKey: key)
        inFlightLock.unlock()
        return value
    }

    // MARK: - Fetch pipeline

    private func fetchCount(key: String, title: String, altTitle: String?, year: Int?) async -> Int? {
        // Try each distinct title variant until one produces a strict match.
        var variants = [title]
        if let alt = altTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alt.isEmpty, alt != title {
            variants.append(alt)
        }

        for variant in variants {
            guard let seriesId = await searchSeriesId(title: variant, year: year) else { continue }
            if let chapters = await fetchLatestChapter(seriesId: seriesId), chapters > 0 {
                store(CachedCount(chapters: chapters, fetchedAt: Date()), forKey: key)
                Logger.shared.log("[MangaUpdates] \(variant): \(chapters) chapters", type: "Debug")
                return chapters
            }
        }

        // Searched every variant without a reliable hit — negative-cache so
        // the next load doesn't re-query the same dead end.
        store(CachedCount(chapters: nil, fetchedAt: Date()), forKey: key)
        return nil
    }

    /// POST /series/search — returns the series id only when a result's
    /// normalized title matches the query exactly AND the years are
    /// compatible (±1, when both are known).
    private func searchSeriesId(title: String, year: Int?) async -> Int? {
        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct Record: Decodable {
                    let series_id: Int?
                    let title: String?
                    let year: Int?
                }
                let record: Record?
            }
            let results: [Item]?
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["search": title, "perpage": 5]) else {
            return nil
        }

        var request = URLRequest(url: base.appendingPathComponent("series/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        guard let data = await send(request),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return nil   // transient — never cached
        }

        let needle = Self.normalize(title)
        for item in (decoded.results ?? []).prefix(5) {
            guard let record = item.record,
                  let recordTitle = record.title,
                  let seriesId = record.series_id else { continue }
            guard Self.normalize(recordTitle) == needle else { continue }
            if let year = year, let recordYear = record.year {
                guard abs(year - recordYear) <= 1 else { continue }
            }
            return seriesId
        }
        return nil
    }

    /// GET /series/{id} — the full record carries `latest_chapter`.
    private func fetchLatestChapter(seriesId: Int) async -> Int? {
        struct SeriesResponse: Decodable {
            let latest_chapter: Int?
        }

        var request = URLRequest(url: base.appendingPathComponent("series/\(seriesId)"))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let data = await send(request),
              let decoded = try? JSONDecoder().decode(SeriesResponse.self, from: data) else {
            return nil
        }
        return decoded.latest_chapter
    }

    // MARK: - Networking + pacing

    /// Performs the request after the app-wide pacing gate, returning nil on
    /// any transport/HTTP error (transient — callers do not cache these).
    private func send(_ request: URLRequest) async -> Data? {
        await enforceRateLimit()
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

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

    // MARK: - Cache plumbing

    private func freshCachedValue(forKey key: String) -> Int? {
        cacheLock.lock()
        loadDiskCacheIfNeeded()
        guard let entry = cache[key] else {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        let ttl = entry.chapters != nil ? hitTTL : missTTL
        guard Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.chapters
    }

    private func store(_ entry: CachedCount, forKey key: String) {
        cacheLock.lock()
        loadDiskCacheIfNeeded()
        cache[key] = entry
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        cacheLock.unlock()
    }

    private func loadDiskCacheIfNeeded() {
        guard !didLoadDiskCache else { return }
        didLoadDiskCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedCount].self, from: data) else {
            return
        }
        cache = decoded
    }

    // MARK: - Title normalization

    /// Collapses a title to its alphanumeric skeleton so punctuation,
    /// casing, spacing and "×" variants compare equal:
    /// "SPY×FAMILY" → "spyxfamily" == "Spy x Family" → "spyxfamily".
    private static func normalize(_ title: String) -> String {
        String(title.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .filter { $0.isLetter || $0.isNumber })
    }
}
