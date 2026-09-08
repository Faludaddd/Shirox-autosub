import Foundation
import Combine

// MARK: - Provider kinds

/// Every metadata source the unified provider system knows about.
/// The anime / manga / schedule domains each get their own priority
/// ordering over this single enum.
enum MetaProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case tvdb
    case mal
    case anilist
    case kitsu
    case anidb
    case mangabaka
    case anichart
    case animeschedule

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tvdb:          return "TVDB"
        case .mal:           return "MyAnimeList"
        case .anilist:       return "AniList"
        case .kitsu:         return "Kitsu"
        case .anidb:         return "AniDB"
        case .mangabaka:     return "MangaBaka"
        case .anichart:      return "AniChart"
        case .animeschedule: return "AnimeSchedule"
        }
    }

    var shortName: String {
        switch self {
        case .mal: return "MAL"
        default: return displayName
        }
    }

    /// Real base URL, surfaced in the Data Sources settings card.
    var apiHost: String {
        switch self {
        case .tvdb:          return "api4.thetvdb.com"
        case .mal:           return "api.jikan.moe"
        case .anilist:       return "graphql.anilist.co"
        case .kitsu:         return "kitsu.io"
        case .anidb:         return "api.anidb.net"
        case .mangabaka:     return "api.mangabaka.org"
        case .anichart:      return "anichart.net"
        case .animeschedule: return "animeschedule.net"
        }
    }

    /// Which domains the provider can serve.
    var domains: [ProviderDomain] {
        switch self {
        case .tvdb, .anidb: return [.anime]
        case .mal, .anilist: return [.anime, .manga]
        // Batch 24 — Kitsu genuinely serves manga lists and search (its
        // /manga JSON:api mirrors /anime, verified live, with MAL/AniList
        // mappings for navigation). As the manga chain's final live
        // fallback it keeps the Manga tab + Reading-mode releases working
        // through MAL/Jikan + AniList outage windows.
        case .kitsu: return [.anime, .manga]
        case .mangabaka: return [.manga]
        case .anichart, .animeschedule: return [.schedule]
        }
    }
}

enum ProviderDomain: String, Codable, CaseIterable, Hashable {
    case anime, manga, schedule
}

// MARK: - Health

/// The health state machine for a single provider. States transition
/// from real request outcomes only — nothing is simulated.
enum ProviderHealthState: String, Codable {
    case healthy
    /// Answered, but some recent requests failed or latency is poor.
    case degraded
    /// Returned a rate-limit (429 / documented limiter).
    case rateLimited
    /// Repeated hard failures — cooling down.
    case unavailable
    /// The device/network itself is offline.
    case offline
    /// No real measurement this session yet.
    case unknown

    var label: String {
        switch self {
        case .healthy: return "Online"
        case .degraded: return "Degraded"
        case .rateLimited: return "Rate Limited"
        case .unavailable: return "Unavailable"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .rateLimited: return "hourglass"
        case .unavailable: return "xmark.circle.fill"
        case .offline: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Per-provider health snapshot, observable by the Data Sources UI.
struct ProviderStatus: Identifiable, Equatable {
    var id: String { kind.rawValue }
    let kind: MetaProviderKind
    var state: ProviderHealthState
    /// Timestamp of the last successful request (any endpoint).
    var lastSuccess: Date?
    /// Latency of the most recent successful request.
    var lastLatencyMs: Int?
    /// Time at which the current cooldown ends (nil = none).
    var cooldownUntil: Date?
    var failureStreak: Int
    /// The provider's own message for the current state (e.g. "429 Too Many Requests").
    var note: String?

    var isCoolingDown: Bool {
        guard let until = cooldownUntil else { return false }
        return until > Date()
    }
}

/// Result of an explicit "Test Provider" run — a real request with a
/// measured latency, or an honest failure with the real reason.
struct ProviderTestResult: Identifiable, Equatable {
    var id: String { kind.rawValue }
    let kind: MetaProviderKind
    let ok: Bool
    let latencyMs: Int
    let message: String
    let testedAt: Date
}

// MARK: - Chain errors

enum ProviderChainError: LocalizedError {
    /// Every provider in the chain failed (or is cooling down).
    case allProvidersFailed(lastReason: String?)
    /// No providers are enabled for the domain.
    case noProvidersEnabled

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let reason):
            return reason ?? "All providers are unavailable right now."
        case .noProvidersEnabled:
            return "All providers for this feature are disabled. Re-enable them in Settings → Data Sources."
        }
    }
}

// MARK: - Disk cache

/// JSON response cache shared by all providers. One directory per domain
/// (anime / manga / schedule) so cache controls can clear them
/// independently. Entries are TTL-stamped; expired entries are ignored
/// on read and overwritten on write.
enum ProviderCacheStore {
    private static var base: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("provider-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encode-side entry (write accepts any Encodable payload).
    private struct WriteEntry<T: Encodable>: Encodable {
        let savedAt: Date
        let payload: T
    }

    /// Decode-side entry (read accepts any Decodable payload). Same JSON
    /// shape as WriteEntry.
    private struct ReadEntry<T: Decodable>: Decodable {
        let savedAt: Date
        let payload: T
    }

    static func url(for key: String, domain: ProviderDomain) -> URL {
        let sanitized = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return base
            .appendingPathComponent(domain.rawValue, isDirectory: true)
            .appendingPathComponent("\(sanitized).json")
    }

    static func read<T: Decodable>(_ type: T.Type, key: String, domain: ProviderDomain, ttl: TimeInterval) -> T? {
        let fileURL = url(for: key, domain: domain)
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? JSONDecoder().decode(ReadEntry<T>.self, from: data),
              Date().timeIntervalSince(entry.savedAt) < ttl else { return nil }
        return entry.payload
    }

    static func write<T: Encodable>(_ payload: T, key: String, domain: ProviderDomain) {
        let entry = WriteEntry(savedAt: Date(), payload: payload)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let fileURL = url(for: key, domain: domain)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear(domain: ProviderDomain) {
        let dir = base.appendingPathComponent(domain.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    static func clearAll() {
        for domain in ProviderDomain.allCases { clear(domain: domain) }
    }

    /// Approximate on-disk size in bytes for a domain.
    static func directorySize(domain: ProviderDomain) -> Int64 {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let dir = caches?.appendingPathComponent("provider-cache/\(domain.rawValue)", isDirectory: true),
              let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Central system

/// The single owner of provider state and the single entry point for
/// anime / manga / schedule metadata.
///
/// Responsibilities (one place, used by every screen):
/// • Priority ordering per domain (user-reorderable, persisted)
/// • Enable/disable per provider (persisted)
/// • Automatic fallback down the chain, with HEALTH-GATED skipping
///   (a provider inside a cooldown window is never re-asked)
/// • Field-level fallback for detail bundles (merge, don't replace)
/// • Request deduplication (shared in-flight tasks per cache key)
/// • Response caching on disk with per-endpoint TTLs
/// • Failure caching (short negative cache so a dead provider isn't
///   re-hit by every screen)
/// • Exponential cooldowns + circuit-breaker health states
/// • Real "Test Provider" runs with measured latency
/// • Cache size accounting + per-domain cache clearing
@MainActor
final class UnifiedProviderSystem: ObservableObject {
    static let shared = UnifiedProviderSystem()

    // MARK: Published state

    @Published private(set) var statuses: [MetaProviderKind: ProviderStatus]
    @Published private(set) var animeOrder: [MetaProviderKind]
    @Published private(set) var mangaOrder: [MetaProviderKind]
    @Published private(set) var scheduleOrder: [MetaProviderKind]
    @Published private(set) var lastTestResults: [MetaProviderKind: ProviderTestResult] = [:]
    /// Announces which provider served the most recent chain result,
    /// e.g. "MAL" — used for honest source notices.
    @Published private(set) var lastServedBy: MetaProviderKind?

    // MARK: Persistence keys

    private let animeOrderKey = "providerOrder.anime.v1"
    private let mangaOrderKey = "providerOrder.manga.v1"
    private let scheduleOrderKey = "providerOrder.schedule.v1"
    private let enabledKey = "providerEnabled.v1"

    /// The recommended (default) order for each domain.
    static let recommendedAnimeOrder: [MetaProviderKind] = [.tvdb, .mal, .anilist, .kitsu, .anidb]
    /// Batch 24 — Kitsu appended as the manga chain's final fallback
    /// (MangaBaka → MAL → AniList → Kitsu).
    static let recommendedMangaOrder: [MetaProviderKind] = [.mangabaka, .mal, .anilist, .kitsu]
    static let recommendedScheduleOrder: [MetaProviderKind] = [.anichart, .animeschedule, .mal, .anilist]

    // MARK: Cooldown / backoff configuration

    /// Base cooldown for a hard provider failure. Grows exponentially with
    /// the failure streak: 60s → 120s → 240s → … capped at 10 minutes.
    private let failureCooldownBase: TimeInterval = 60
    private let failureCooldownCap: TimeInterval = 600
    /// Fixed cooldown when the provider answers with a rate limit.
    private let rateLimitCooldown: TimeInterval = 90
    /// Short negative cache: after a provider fails an operation, the SAME
    /// operation won't re-hit it within this window (other screens asking
    /// the same thing get the failure instantly instead of a request storm).
    private let failureCacheTTL: TimeInterval = 45

    /// In-flight deduplication: one shared task per logical cache key.
    private var inFlight: [String: Task<AnyMediaBox, Never>] = [:]
    /// Negative cache: (provider, operation) → when to stop skipping.
    private var failureCache: [String: Date] = [:]

    private init() {
        let defaults = UserDefaults.standard

        func loadOrder(_ key: String, recommended: [MetaProviderKind], all: [MetaProviderKind]) -> [MetaProviderKind] {
            guard let saved = defaults.stringArray(forKey: key), !saved.isEmpty else { return recommended }
            var ordered: [MetaProviderKind] = []
            for raw in saved {
                if let kind = MetaProviderKind(rawValue: raw), all.contains(kind), !ordered.contains(kind) {
                    ordered.append(kind)
                }
            }
            // Providers missing from the saved list (new in an update) append at the end.
            for kind in recommended where !ordered.contains(kind) {
                ordered.append(kind)
            }
            return ordered
        }

        animeOrder = loadOrder(animeOrderKey, recommended: Self.recommendedAnimeOrder, all: [.tvdb, .mal, .anilist, .kitsu, .anidb])
        // Users upgrading from v2.25 keep their saved order; `loadOrder`
        // appends Kitsu (new to this domain) at the end automatically.
        mangaOrder = loadOrder(mangaOrderKey, recommended: Self.recommendedMangaOrder, all: [.mangabaka, .mal, .anilist, .kitsu])
        scheduleOrder = loadOrder(scheduleOrderKey, recommended: Self.recommendedScheduleOrder, all: [.anichart, .animeschedule, .mal, .anilist])

        let savedEnabled = defaults.dictionary(forKey: enabledKey) as? [String: Bool] ?? [:]
        var initial: [MetaProviderKind: ProviderStatus] = [:]
        for kind in MetaProviderKind.allCases {
            let enabled = savedEnabled[kind.rawValue] ?? true
            initial[kind] = ProviderStatus(
                kind: kind,
                state: .unknown,
                lastSuccess: nil,
                lastLatencyMs: nil,
                cooldownUntil: nil,
                failureStreak: 0,
                note: enabled ? nil : "Disabled")
        }
        statuses = initial

        // TVDB needs its API key — the app ships one (the same production
        // key TVDBMappingService has used for artwork since v2.19), so TVDB
        // is genuinely reachable out of the box.
        // AniDB requires a REGISTERED client identity; without one the
        // provider reports the honest reason and the chain moves on.
        statuses[.anidb]?.note = AniDBProvider.shared.isConfigured
            ? nil : "Requires a registered AniDB client identity (name + version) — fill it in below."
        // AnimeSchedule requires the user's own free API token (their terms
        // forbid shipping an app token). Without one it is SKIPPED by the
        // chain (see activeChain) instead of being attempted and failing.
        statuses[.animeschedule]?.note = AnimeScheduleProvider.shared.isConfigured
            ? nil : "Optional — add a free API token from animeschedule.net below to activate this schedule source."
    }

    // MARK: - Ordering & enablement (Data Sources UI entry points)

    func order(for domain: ProviderDomain) -> [MetaProviderKind] {
        switch domain {
        case .anime: return animeOrder
        case .manga: return mangaOrder
        case .schedule: return scheduleOrder
        }
    }

    func setOrder(_ newOrder: [MetaProviderKind], for domain: ProviderDomain) {
        let key: String
        switch domain {
        case .anime:
            animeOrder = newOrder
            key = animeOrderKey
        case .manga:
            mangaOrder = newOrder
            key = mangaOrderKey
        case .schedule:
            scheduleOrder = newOrder
            key = scheduleOrderKey
        }
        UserDefaults.standard.set(newOrder.map(\.rawValue), forKey: key)
    }

    func resetOrder(for domain: ProviderDomain) {
        switch domain {
        case .anime: setOrder(Self.recommendedAnimeOrder, for: domain)
        case .manga: setOrder(Self.recommendedMangaOrder, for: domain)
        case .schedule: setOrder(Self.recommendedScheduleOrder, for: domain)
        }
    }

    func resetAllOrders() {
        resetOrder(for: .anime)
        resetOrder(for: .manga)
        resetOrder(for: .schedule)
    }

    func isEnabled(_ kind: MetaProviderKind) -> Bool {
        statuses[kind]?.note != "Disabled"
    }

    /// Returns false when the provider was already in the requested state.
    @discardableResult
    func setEnabled(_ kind: MetaProviderKind, _ enabled: Bool) -> Bool {
        guard isEnabled(kind) != enabled else { return false }
        var status = statuses[kind] ?? ProviderStatus(kind: kind, state: .unknown, lastSuccess: nil,
                                                      lastLatencyMs: nil, cooldownUntil: nil, failureStreak: 0, note: nil)
        status.note = enabled ? nil : "Disabled"
        if enabled {
            // Fresh start: clearing the cooldown lets the user immediately
            // verify a re-enabled provider via Test Provider.
            status.cooldownUntil = nil
            status.state = .unknown
        }
        statuses[kind] = status
        var saved = UserDefaults.standard.dictionary(forKey: enabledKey) as? [String: Bool] ?? [:]
        saved[kind.rawValue] = enabled
        UserDefaults.standard.set(saved, forKey: enabledKey)
        return true
    }

    /// The PRIMARY/fallback label a provider card shows.
    func priorityLabel(for kind: MetaProviderKind, domain: ProviderDomain) -> String {
        guard let index = order(for: domain).firstIndex(of: kind) else { return "Not in chain" }
        return index == 0 ? "PRIMARY" : "FALLBACK #\(index)"
    }

    /// Ordered, health-gated list of providers actually asked for a domain.
    func activeChain(for domain: ProviderDomain) -> [MetaProviderKind] {
        order(for: domain).filter { kind in
            guard isEnabled(kind) else { return false }
            // AniDB without a registered client is skipped (honest
            // unavailability — its HTTP API rejects unknown clients).
            if kind == .anidb && !AniDBProvider.shared.isConfigured { return false }
            // AnimeSchedule without the user's API token is skipped the
            // same way — their API answers 401 without a token, so there
            // is nothing to attempt until one is configured in settings.
            if kind == .animeschedule && !AnimeScheduleProvider.shared.isConfigured { return false }
            return true
        }
    }

    // MARK: - Health recording

    private func recordSuccess(_ kind: MetaProviderKind, latencyMs: Int) {
        var status = statuses[kind] ?? ProviderStatus(kind: kind, state: .unknown, lastSuccess: nil,
                                                      lastLatencyMs: nil, cooldownUntil: nil, failureStreak: 0, note: nil)
        status.lastSuccess = Date()
        status.lastLatencyMs = latencyMs
        status.failureStreak = 0
        status.cooldownUntil = nil
        // Latency-based degradation is honest: slow-but-working providers
        // show "Degraded" instead of pretending to be perfectly healthy.
        status.state = latencyMs > 4000 ? .degraded : .healthy
        status.note = nil
        statuses[kind] = status
    }

    private func recordFailure(_ kind: MetaProviderKind, error: Error) {
        var status = statuses[kind] ?? ProviderStatus(kind: kind, state: .unknown, lastSuccess: nil,
                                                      lastLatencyMs: nil, cooldownUntil: nil, failureStreak: 0, note: nil)
        status.failureStreak += 1
        status.note = ProviderErrorMapper.brief(error)

        if ProviderManager.isOfflineError(error) {
            status.state = .offline
        } else if ProviderErrorMapper.isRateLimit(error) {
            status.state = .rateLimited
            status.cooldownUntil = Date().addingTimeInterval(rateLimitCooldown)
        } else {
            // Exponential backoff, capped.
            let cooldown = min(failureCooldownBase * pow(2, Double(status.failureStreak - 1)), failureCooldownCap)
            status.cooldownUntil = Date().addingTimeInterval(cooldown)
            status.state = status.failureStreak >= 2 ? .unavailable : .degraded
        }
        statuses[kind] = status
    }

    /// True when the provider should be SKIPPED right now (cooldown window
    /// or disabled). This is what stops request storms: a provider that
    /// just failed is not re-asked by the next screen.
    private func shouldSkip(_ kind: MetaProviderKind) -> Bool {
        guard isEnabled(kind) else { return true }
        if kind == .anidb && !AniDBProvider.shared.isConfigured { return true }
        if kind == .animeschedule && !AnimeScheduleProvider.shared.isConfigured { return true }
        guard let status = statuses[kind] else { return false }
        return status.isCoolingDown
    }

    private func recordOperationFailure(_ kind: MetaProviderKind, operation: String) {
        failureCache["\(kind.rawValue)|\(operation)"] = Date().addingTimeInterval(failureCacheTTL)
    }

    private func isOperationFailureCached(_ kind: MetaProviderKind, operation: String) -> Bool {
        guard let until = failureCache["\(kind.rawValue)|\(operation)"] else { return false }
        if until > Date() { return true }
        failureCache["\(kind.rawValue)|\(operation)"] = nil
        return false
    }

    // MARK: - Chain execution

    /// Type-erased result box so ONE in-flight dictionary dedups every
    /// result type. `error` carries chain failures to shared awaiters.
    private struct AnyMediaBox {
        let wrapped: Any?
        let servedBy: MetaProviderKind?
        let error: Error?
    }

    /// Runs `operation` against the domain's chain, in order, skipping
    /// cooling-down providers, deduplicating concurrent identical requests
    /// (by `cacheKey`), and serving cached responses within the TTL.
    ///
    /// A provider returning `nil` means "this provider genuinely does not
    /// offer this data" (e.g. TVDB has no trending chart) — that SKIPS to
    /// the next provider without recording a failure. Only thrown errors
    /// affect health. Concurrent callers with the same cache key SHARE one
    /// chain execution (the awaited task IS the chain run).
    private func runChain<T>(
        domain: ProviderDomain,
        operation: String,
        cacheKey: String?,
        cacheTTL: TimeInterval,
        _ fetch: @escaping (MetaProviderKind) async throws -> T?
    ) async throws -> (value: T, servedBy: MetaProviderKind) where T: Encodable & Decodable {
        let fullKey = cacheKey.map { "\(domain.rawValue)|\(operation)|\($0)" }

        // 1. Disk cache (if the caller asked for one).
        if let fullKey, let cached = ProviderCacheStore.read(T.self, key: fullKey, domain: domain, ttl: cacheTTL) {
            return (cached, lastServedBy ?? order(for: domain).first ?? .mal)
        }

        // 2. In-flight dedup: if the identical request is already running,
        //    await the SAME chain execution instead of issuing another.
        if let fullKey, let running = inFlight[fullKey] {
            let box = await running.value
            if let error = box.error { throw error }
            if let value = box.wrapped as? T, let servedBy = box.servedBy {
                return (value, servedBy)
            }
            // Wrong type / empty box — run a fresh chain.
        }

        // 3. Execute the chain inside a task so concurrent callers share it.
        var storedOurs = false
        let task = Task<AnyMediaBox, Never> { [weak self] in
            guard let self else {
                return AnyMediaBox(wrapped: nil, servedBy: nil, error: CancellationError())
            }
            do {
                let (value, servedBy) = try await self.runChainOnce(
                    domain: domain, operation: operation, fullKey: fullKey,
                    cacheTTL: cacheTTL, fetch)
                return AnyMediaBox(wrapped: value, servedBy: servedBy, error: nil)
            } catch {
                return AnyMediaBox(wrapped: nil, servedBy: nil, error: error)
            }
        }
        if let fullKey {
            // If another caller created the same task in the meantime, the
            // first one wins and ours is dropped (its result is identical).
            if let existing = inFlight[fullKey] {
                let box = await existing.value
                if let error = box.error { throw error }
                if let value = box.wrapped as? T, let servedBy = box.servedBy {
                    return (value, servedBy)
                }
            } else {
                inFlight[fullKey] = task
                storedOurs = true
            }
        }
        let box = await task.value
        // Task is a struct (no identity comparison) — only the caller that
        // STORED the entry may remove it.
        if let fullKey, storedOurs { inFlight[fullKey] = nil }
        if let error = box.error { throw error }
        guard let value = box.wrapped as? T, let servedBy = box.servedBy else {
            throw ProviderChainError.allProvidersFailed(lastReason: nil)
        }
        return (value, servedBy)
    }

    private func runChainOnce<T>(
        domain: ProviderDomain,
        operation: String,
        fullKey: String?,
        cacheTTL: TimeInterval,
        _ fetch: (MetaProviderKind) async throws -> T?
    ) async throws -> (value: T, servedBy: MetaProviderKind) where T: Encodable & Decodable {
        let chain = activeChain(for: domain)
        guard !chain.isEmpty else { throw ProviderChainError.noProvidersEnabled }

        var lastReason: String?
        for kind in chain {
            if Task.isCancelled { throw CancellationError() }
            if shouldSkip(kind) {
                lastReason = statuses[kind]?.note ?? "cooling down"
                Logger.shared.log(
                    "[Providers] \(kind.displayName) skipped \(operation): \(lastReason ?? "")",
                    type: "Provider")
                continue
            }
            if isOperationFailureCached(kind, operation: operation) {
                lastReason = "recent failure"
                Logger.shared.log(
                    "[Providers] \(kind.displayName) skipped \(operation): recent failure (negative cache)",
                    type: "Provider")
                continue
            }
            do {
                let started = Date()
                guard let value = try await fetch(kind) else {
                    // Provider doesn't serve this data — skip WITHOUT a
                    // failure record (not an error). Logged so the chain's
                    // walk is fully visible in the debug log (e.g. TVDB
                    // genuinely IS asked first for browse — it just has no
                    // chart endpoints and hands over to the next provider).
                    Logger.shared.log(
                        "[Providers] \(kind.displayName) has no \(operation) data (doesn't serve this category) — trying next",
                        type: "Provider")
                    continue
                }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                recordSuccess(kind, latencyMs: latency)
                lastServedBy = kind
                if let fullKey {
                    ProviderCacheStore.write(value, key: fullKey, domain: domain)
                }
                Logger.shared.log(
                    "[Providers] \(operation) served by \(kind.displayName) in \(latency) ms",
                    type: "Provider")
                return (value, kind)
            } catch {
                if ProviderManager.isCancellationError(error) { throw error }
                lastReason = ProviderErrorMapper.brief(error)
                recordFailure(kind, error: error)
                recordOperationFailure(kind, operation: operation)
                Logger.shared.log(
                    "[Providers] \(kind.displayName) failed \(operation): \(lastReason ?? "") — trying next in chain",
                    type: "Provider")
            }
        }
        throw ProviderChainError.allProvidersFailed(lastReason: lastReason)
    }

    // MARK: - Anime discovery (Home shelves, Browse, See All)

    /// Home shelves and See All pages share ONE paged chain per category —
    /// the home shelf IS page 1 of the same browse the See All grid pages
    /// through, so both share cache + dedup for that page.
    func trending() async throws -> [Media] { try await browse(category: .trending, page: 1) }
    func seasonal() async throws -> [Media] { try await browse(category: .seasonal, page: 1) }
    func popular() async throws -> [Media] { try await browse(category: .popular, page: 1) }
    func topRated() async throws -> [Media] { try await browse(category: .topRated, page: 1) }
    func recentlyCompleted() async throws -> [Media] { try await browse(category: .recentlyCompleted, page: 1) }
    func upcoming() async throws -> [Media] { try await browse(category: .upcoming, page: 1) }

    /// Browse (See All) pagination through the same chain. Page-level cache
    /// keys keep the chain's dedup/cache benefits per page.
    ///
    /// Batch 23 — every browse result is filtered to the app's Japanese-
    /// anime catalog (same policy the carousel has had since v2.20): entries
    /// KNOWN to originate outside Japan are dropped; unknown-origin entries
    /// pass (the nil-passes rule). Each provider feeds that filter with its
    /// own real signal — AniList filters at the source AND carries the
    /// field, Jikan infers from production metadata (v2.23), Kitsu infers
    /// from the title script (hanzi-without-kana = Chinese production).
    func browse(category: BrowseCategory, page: Int) async throws -> [Media] {
        // NOTE: the closure's return type is annotated (`-> [Media]?`) and
        // `list` is explicitly typed — this generic + multi-statement trailing
        // closure shape exceeds the type checker's inference budget without
        // the anchors (CI: "generic parameter 'T' could not be inferred").
        let list: [Media] = try await runChain(
            domain: .anime,
            operation: "browse-\(category.rawValue)",
            cacheKey: "p\(page)",
            cacheTTL: 15 * 60) { kind -> [Media]? in
            switch kind {
            case .tvdb, .anidb:
                return nil // no chart endpoints
            case .mal:
                let list = try await MALDiscoveryService.shared.browse(category: category, page: page)
                return list.map { MALDiscoveryService.shared.mapToMedia($0) }
            case .anilist:
                let list = try await AniListService.shared.browse(category: category, page: page)
                return list.map { AniListProvider.shared.mapMedia($0) }
            case .kitsu:
                return try await KitsuProvider.shared.browse(category: category, page: page)
            default:
                return nil
            }
        }.value
        return Self.japaneseCatalogOnly(list)
    }

    /// The catalog filter shared by every anime browse/shelf surface:
    /// drops entries whose country of origin is known AND not Japan.
    /// Unknown origin passes (AniList entries from before the field, Kitsu
    /// entries without a CJK title to judge).
    static func japaneseCatalogOnly(_ list: [Media]) -> [Media] {
        list.filter { media in
            guard let country = media.countryOfOrigin else { return true }
            return country == "JP"
        }
    }

    // MARK: - Anime search

    func searchAnime(_ query: String) async throws -> [Media] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await runChain(
            domain: .anime,
            operation: "search",
            cacheKey: trimmed.lowercased(),
            cacheTTL: 30 * 60) { kind in
            switch kind {
            case .tvdb:
                return try await TVDBProvider.shared.searchMedia(query: trimmed)
            case .mal:
                return try await MALDiscoveryService.shared.search(trimmed).map { MALDiscoveryService.shared.mapToMedia($0) }
            case .anilist:
                return try await AniListService.shared.search(keyword: trimmed).map { AniListProvider.shared.mapMedia($0) }
            case .kitsu:
                return try await KitsuProvider.shared.search(query: trimmed)
            case .anidb:
                return nil // AniDB search is UDP-API-only; not available over HTTP
            default:
                return nil
            }
        }.value
    }

    // MARK: - TVDB-first detail enrichment (field-level fallback)

    /// Gathers TVDB's own metadata for one title (id-keyed via the existing
    /// AniList/MAL → TVDB mapping service — never title-guessed). This is
    /// the "construct from TVDB first" half of the detail flow; the caller
    /// keeps AniList/MAL records for the fields TVDB doesn't serve
    /// (relations, recommendations, tracking, airing countdowns).
    func tvdbDetailFields(anilistId: Int?, malId: Int?) async -> TVDBDetailFields? {
        let key = "detail-\(anilistId ?? 0)-\(malId ?? 0)"
        if let cached = ProviderCacheStore.read(TVDBDetailFields.self, key: key, domain: .anime, ttl: 6 * 3600) {
            return cached.isEmpty ? nil : cached
        }
        let started = Date()
        guard let fields = await TVDBProvider.shared.detailFields(anilistId: anilistId, malId: malId) else {
            // Negative-cache the miss so detail pages don't re-query a
            // TVDB miss on every open.
            ProviderCacheStore.write(TVDBDetailFields.empty, key: key, domain: .anime)
            return nil
        }
        recordSuccess(.tvdb, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
        ProviderCacheStore.write(fields, key: key, domain: .anime)
        return fields
    }

    // MARK: - Manga

    func searchManga(_ query: String) async throws -> [Media] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await runChain(
            domain: .manga,
            operation: "search",
            cacheKey: trimmed.lowercased(),
            cacheTTL: 30 * 60) { kind in
            switch kind {
            case .mangabaka:
                return try await MangaBakaProvider.shared.searchMedia(query: trimmed)
            case .mal:
                return try await MALDiscoveryService.shared.searchManga(trimmed)
            case .anilist:
                return try await AniListService.shared.searchManga(keyword: trimmed).map { AniListProvider.shared.mapMangaMedia($0) }
            case .kitsu:
                // Batch 24 — Kitsu serves manga search too, so the manga
                // search chain survives MAL + AniList outage windows.
                return try await KitsuProvider.shared.searchManga(query: trimmed)
            default:
                return nil
            }
        }.value
    }

    /// Manga home shelves. MangaBaka has no chart endpoints (its public API
    /// is search + series detail), so list shelves run MAL → AniList while
    /// MangaBaka remains the detail/search primary — every item's DETAIL
    /// fields still come from MangaBaka first via `mangaDetailFields`.
    func mangaShelf(_ shelf: MangaShelfKind) async throws -> [Media] {
        try await runChain(
            domain: .manga,
            operation: "shelf-\(shelf.rawValue)",
            cacheKey: shelf.rawValue,
            cacheTTL: 15 * 60) { kind in
            switch kind {
            case .mangabaka:
                return nil // no chart endpoint — honest skip
            case .mal:
                return try await MALDiscoveryService.shared.mangaShelf(shelf)
            case .anilist:
                let media: [AniListMedia]
                switch shelf {
                case .trending: media = try await AniListService.shared.mangaTrending()
                case .popular:   media = try await AniListService.shared.mangaPopular()
                case .topRated:  media = try await AniListService.shared.mangaTopRated()
                case .latest:    media = try await AniListService.shared.mangaLatest()
                }
                return media.map { AniListProvider.shared.mapMangaMedia($0) }
            case .kitsu:
                // Batch 24 — the live fallback that keeps the manga Home
                // shelves rendering while MAL and AniList are both down.
                return try await KitsuProvider.shared.mangaShelf(shelf)
            default:
                return nil
            }
        }.value
    }

    /// MangaBaka-first detail fields for a title (keyed by MAL id when
    /// known — MangaBaka's links carry MAL/AniList ids; the provider only
    /// returns data for titles it can resolve exactly).
    func mangaDetailFields(malId: Int?, titleHint: String?) async -> MangaBakaDetailFields? {
        await MangaBakaProvider.shared.detailFields(malId: malId, titleHint: titleHint)
    }

    /// Batch 23 — the manga release feed (Reading-mode Schedule) runs
    /// through the SAME unified chain as every other manga endpoint:
    /// MangaBaka has no chart endpoint (honest nil skip), MAL serves
    /// top/manga by popularity, AniList serves its releasing-manga feed.
    /// In-flight dedup + disk cache + provider cooldowns all apply — the
    /// old hand-rolled AniList→Jikan fallback fired one request per caller
    /// (three simultaneous duplicate fetches in the reported log).
    func mangaReleaseSchedule() async throws -> [Media] {
        try await runChain(
            domain: .manga,
            operation: "release-schedule",
            cacheKey: "current",
            cacheTTL: 15 * 60) { kind in
            switch kind {
            case .mangabaka:
                return nil // search + series detail only — no release feed
            case .mal:
                let list = try await MALDiscoveryService.shared.fetchList("top/manga", queryItems: [
                    URLQueryItem(name: "filter", value: "bypopularity"),
                    URLQueryItem(name: "limit", value: "25")
                ])
                return list.map { MALDiscoveryService.shared.mapMangaToMedia($0) }
            case .anilist:
                let media = try await AniListService.shared.mangaReleaseSchedule()
                return media.map { AniListProvider.shared.mapMangaMedia($0) }
            case .kitsu:
                // Batch 24 — most-followed currently-releasing manga; the
                // Reading-mode Releases tab keeps real data through MAL /
                // AniList outage windows.
                return try await KitsuProvider.shared.mangaReleaseSchedule()
            default:
                return nil
            }
        }.value
    }

    // MARK: - Schedule

    /// The full schedule chain: AniChart → AnimeSchedule → MAL → AniList.
    /// Returns entries plus which provider served them (for the honest
    /// source notice). Cached for 5 minutes; every screen asking within
    /// the window SHARES one request (dedup).
    func scheduleEntries(from startTs: Int, to endTs: Int) async throws -> (entries: [UnifiedScheduleEntry], source: MetaProviderKind?) {
        let value = try await runChain(
            domain: .schedule,
            operation: "timetable",
            cacheKey: "\(startTs)-\(endTs)",
            cacheTTL: 5 * 60) { kind in
            switch kind {
            case .anichart:
                return try await AniChartProvider.shared.entries(from: startTs, to: endTs)
            case .animeschedule:
                return try await AnimeScheduleProvider.shared.entries(from: startTs, to: endTs)
            case .mal:
                return try await ScheduleFallbackService.shared.jikanSchedule(from: startTs, to: endTs)
            case .anilist:
                let items = try await AniListService.shared.airingSchedules(from: startTs, to: endTs)
                return items.map { UnifiedScheduleEntry(item: $0) }
            default:
                return nil
            }
        }
        return (value.value, value.servedBy)
    }

    // MARK: - Test Provider (real requests, measured latency)

    @MainActor
    func testProvider(_ kind: MetaProviderKind) async -> ProviderTestResult {
        let started = Date()
        do {
            let ok: Bool
            switch kind {
            case .tvdb:
                ok = try await TVDBProvider.shared.healthCheck()
            case .mal:
                let results = try await MALDiscoveryService.shared.trending(page: 1)
                ok = !results.isEmpty
            case .anilist, .anichart:
                ok = try await AniListService.shared.healthCheck()
            case .kitsu:
                ok = try await KitsuProvider.shared.healthCheck()
            case .anidb:
                ok = try await AniDBProvider.shared.healthCheck()
            case .mangabaka:
                ok = try await MangaBakaProvider.shared.healthCheck()
            case .animeschedule:
                ok = try await AnimeScheduleProvider.shared.healthCheck()
            }
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let result = ProviderTestResult(
                kind: kind, ok: ok, latencyMs: latency,
                message: ok ? "Online" : "No usable data returned",
                testedAt: Date())
            lastTestResults[kind] = result
            if ok {
                recordSuccess(kind, latencyMs: latency)
                // A successful test clears any cooldown — the provider
                // just proved it works.
                statuses[kind]?.cooldownUntil = nil
            } else {
                recordFailure(kind, error: ProviderChainError.allProvidersFailed(lastReason: "no usable data"))
            }
            return result
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let result = ProviderTestResult(
                kind: kind, ok: false, latencyMs: latency,
                message: ProviderErrorMapper.brief(error),
                testedAt: Date())
            lastTestResults[kind] = result
            recordFailure(kind, error: error)
            return result
        }
    }

    // MARK: - Cache controls (Data Sources settings)

    func clearAnimeCache() { ProviderCacheStore.clear(domain: .anime) }
    func clearMangaCache() { ProviderCacheStore.clear(domain: .manga) }
    func clearScheduleCache() { ProviderCacheStore.clear(domain: .schedule) }
    func clearAllProviderCache() { ProviderCacheStore.clearAll() }

    func cacheSize(domain: ProviderDomain) -> Int64 {
        ProviderCacheStore.directorySize(domain: domain)
    }

    // MARK: - Maintenance

    /// Drops a provider's cooldown + failure cache (used when a provider is
    /// re-enabled so it gets an immediate fresh chance).
    func clearCooldown(_ kind: MetaProviderKind) {
        statuses[kind]?.cooldownUntil = nil
        failureCache = failureCache.filter { !$0.key.hasPrefix("\(kind.rawValue)|") }
    }
}

// MARK: - Error mapping helpers

enum ProviderErrorMapper {
    /// Short, human-readable reason for a provider failure.
    static func brief(_ error: Error) -> String {
        if let chainError = error as? ProviderChainError {
            return chainError.errorDescription ?? "provider failed"
        }
        if let aniError = error as? AniListError {
            switch aniError {
            case .httpError(let code): return "HTTP \(code)"
            case .rateLimited: return "rate limited"
            default: return "AniList error"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "offline"
            case .cancelled: return "cancelled"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    static func isRateLimit(_ error: Error) -> Bool {
        if let aniError = error as? AniListError {
            if case .rateLimited = aniError { return true }
            if case .httpError(429) = aniError { return true }
        }
        // (URLError.Code has no HTTP-status members — transport-level
        // errors carry no 429; service-level 429s arrive via the mapped
        // error types above.)
        return false
    }
}

// MARK: - Manga shelf kinds

enum MangaShelfKind: String, CaseIterable {
    case trending, popular, topRated, latest
}
