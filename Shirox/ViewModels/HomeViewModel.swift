import Foundation
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var trending: [Media] = []
    @Published var seasonal: [Media] = []
    @Published var popular: [Media] = []
    @Published var topRated: [Media] = []
    @Published var recentlyCompleted: [Media] = []
    @Published var upcoming: [Media] = []
    /// Batch 26 — genre shelves (Action / Fantasy / Romance / Drama /
    /// Comedy / Sci-Fi), keyed by genre SLUG (the stable routing
    /// identifier — the shelf and its See All page share ONE query).
    @Published var genreShelves: [String: [Media]] = [:]
    @Published var isLoading = false
    @Published var error: String?
    /// v2.30 (original's home) — whose page Home is showing, driving the
    /// provider page-turn animation. The unified chain serves the feed; the
    /// primary tracker names the page, so switching providers in the menu
    /// turns the page exactly as the original does.
    @Published private(set) var feedProvider: ProviderType?

    private var loaded = false
    private var cancellables = Set<AnyCancellable>()
    private var currentPrimaryType: ProviderType?

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &cancellables)
        // v2.24 — reload when the unified provider chain's anime order
        // changes (Data Sources settings drag-reorder / reset).
        UnifiedProviderSystem.shared.$animeOrder
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil
        feedProvider = ProviderManager.shared.primary?.providerType

        // v2.31 (original's instant per-provider disk cache, adapted to our chain):
        // seed this provider page's last-good shelves from disk IMMEDIATELY — Home
        // renders real content on a cold start with no spinner, and the live chain
        // refreshes in the background (stale-while-refresh, exactly like the original's
        // HomeCacheStore). No TTL on the seed: the live load replaces it moments later;
        // the 6h-TTL snapshot remains the bridge when every source fails.
        seedFromDiskCache()

        // v2.24 — every shelf now goes through the UnifiedProviderSystem
        // chain (TVDB → MAL → AniList → Kitsu → AniDB, health-gated with
        // cooldowns + in-flight dedup + disk cache). One shared chain for
        // the whole app: multiple screens asking for the same shelf share
        // ONE request, a failing provider is skipped for its whole
        // cooldown window, and the Jikan layer paces outbound calls.
        // Batch 23 — recentlyCompleted/upcoming joined the chain too
        // (they were AniList-only direct calls, so the AniList outage
        // blanked them even while MAL/Kitsu were serving fine).
        async let t: Void = loadTrending()
        async let s: Void = loadSeasonal()
        async let p: Void = loadPopular()
        async let r: Void = loadTopRated()
        async let rc: Void = loadRecentlyCompleted()
        async let u: Void = loadUpcoming()
        async let g: Void = loadGenreShelves()
        _ = await (t, s, p, r, rc, u, g)

        // Persist the last-good shelves AFTER everything settles so the
        // snapshot captures the fully-populated page. Saved per provider page
        // so switching back to a provider restores ITS rows instantly.
        if !trending.isEmpty {
            SnapshotStore.saveHomeShelves(trending: trending, seasonal: seasonal, popular: popular, topRated: topRated,
                                          recentlyCompleted: recentlyCompleted, upcoming: upcoming,
                                          genreShelves: genreShelves,
                                          provider: feedProvider)
        }

        loaded = true
        isLoading = false
    }

    private func loadTrending() async {
        do {
            trending = try await UnifiedProviderSystem.shared.trending()
        } catch {
            serveSnapshotIfAvailable(error: error)
        }
    }

    private func loadSeasonal() async {
        do {
            seasonal = try await UnifiedProviderSystem.shared.seasonal()
        } catch {
            // Snapshot of last-good data fills the shelf silently; the
            // trending loader reports the honest error once.
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadPopular() async {
        do {
            popular = try await UnifiedProviderSystem.shared.popular()
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadTopRated() async {
        do {
            topRated = try await UnifiedProviderSystem.shared.topRated()
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadRecentlyCompleted() async {
        do {
            // Batch 23 — through the unified chain: Jikan's previous-season
            // list, AniList's FINISHED+previous-season query, and Kitsu's
            // completed list all serve this shelf now (not AniList alone).
            recentlyCompleted = try await UnifiedProviderSystem.shared.recentlyCompleted()
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadUpcoming() async {
        do {
            upcoming = try await UnifiedProviderSystem.shared.upcoming()
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    /// Batch 26 — genre shelves through the SAME discovery chain the See
    /// All genre pages use (the shelf IS page 1 of that query — one
    /// shared, cached, health-gated request per genre). A failing genre
    /// shelf stays empty (its row simply doesn't render) — the standard
    /// shelves carry the page.
    private func loadGenreShelves() async {
        await withTaskGroup(of: (String, [Media]?).self) { group in
            for genre in DiscoveryService.homeShelfGenres {
                group.addTask {
                    let list = try? await UnifiedProviderSystem.shared.browse(genre: genre, page: 1)
                    return (genre.slug, list ?? [])
                }
            }
            for await (slug, list) in group {
                if let list, !list.isEmpty {
                    genreShelves[slug] = list
                }
            }
        }
    }

    /// v2.23 — Requirement: primary trending source → fallback provider →
    /// cached trending results → offline snapshot. When both providers
    /// fail, the last-good shelves (6h TTL) keep the Home page — and its
    /// carousel — alive with real data instead of an error wall. Only
    /// surfaces an error when there is NO snapshot to serve.
    private func serveSnapshotIfAvailable(error: Error, quiet: Bool = false) {
        if let snapshot = SnapshotStore.loadHomeShelves(provider: feedProvider) {
            if trending.isEmpty, let snapTrending = snapshot.trending, !snapTrending.isEmpty {
                trending = snapTrending
            }
            if seasonal.isEmpty, let snapSeasonal = snapshot.seasonal, !snapSeasonal.isEmpty {
                seasonal = snapSeasonal
            }
            if popular.isEmpty, let snapPopular = snapshot.popular, !snapPopular.isEmpty {
                popular = snapPopular
            }
            if topRated.isEmpty, let snapTop = snapshot.topRated, !snapTop.isEmpty {
                topRated = snapTop
            }
            // Batch 23 — the two new shelves snapshot-serve too (6h TTL,
            // same bridge-over-outage contract as the other shelves).
            if recentlyCompleted.isEmpty, let snapRC = snapshot.recentlyCompleted, !snapRC.isEmpty {
                recentlyCompleted = snapRC
            }
            if upcoming.isEmpty, let snapUp = snapshot.upcoming, !snapUp.isEmpty {
                upcoming = snapUp
            }
        }
        if trending.isEmpty, !quiet {
            self.error = "Trending sources are all unreachable right now. Pull to retry — or check your connection."
        }
    }

    func reload() async {
        loaded = false
        await load()
    }

    /// Instant seed of this provider page's last-good shelves (the original's
    /// HomeCacheStore behavior): render the disk copy at once, no spinner, then
    /// let the live chain refresh over it.
    private func seedFromDiskCache() {
        guard let snapshot = SnapshotStore.loadHomeShelves(provider: feedProvider, ignoreTTL: true) else { return }
        if trending.isEmpty { trending = snapshot.trending ?? [] }
        if seasonal.isEmpty { seasonal = snapshot.seasonal ?? [] }
        if popular.isEmpty { popular = snapshot.popular ?? [] }
        if topRated.isEmpty { topRated = snapshot.topRated ?? [] }
        if recentlyCompleted.isEmpty { recentlyCompleted = snapshot.recentlyCompleted ?? [] }
        if upcoming.isEmpty { upcoming = snapshot.upcoming ?? [] }
        for (slug, list) in snapshot.genreShelves ?? [:] where genreShelves[slug] == nil {
            genreShelves[slug] = list
        }
    }
}

// MARK: - Home shelf snapshot (offline fallback of last resort)

/// Disk snapshot of the last-good Home shelves, keyed by provider page. Written on
/// every successful load, read two ways: INSTANTLY on cold start / provider switch
/// (the original's per-provider HomeCacheStore — stale-while-refresh, no TTL), and
/// with a 6-hour TTL as the bridge when every source fails (an outage bridge, not a
/// permanent freeze — after 6h the honest error state shows instead of stale content).
enum SnapshotStore {
    private static let ttl: TimeInterval = 6 * 3600

    private static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static func fileURL(provider: ProviderType?) -> URL {
        let key = provider?.rawValue ?? "chain"
        return cachesDirectory.appendingPathComponent("home-shelves-\(key).json")
    }

    struct ShelfSnapshot: Codable {
        let savedAt: Date
        let trending: [Media]?
        let seasonal: [Media]?
        let popular: [Media]?
        let topRated: [Media]?
        // Batch 23 — two more shelves in the snapshot. Optional + defaulted
        // so snapshots written before these fields existed still decode.
        var recentlyCompleted: [Media]? = nil
        var upcoming: [Media]? = nil
        // v2.31 — genre shelves cached per provider too (the heaviest reload:
        // six parallel genre queries).
        var genreShelves: [String: [Media]]? = nil
    }

    static func saveHomeShelves(trending: [Media], seasonal: [Media], popular: [Media], topRated: [Media],
                                 recentlyCompleted: [Media] = [], upcoming: [Media] = [],
                                 genreShelves: [String: [Media]] = [:], provider: ProviderType? = nil) {
        guard !trending.isEmpty else { return }
        let snapshot = ShelfSnapshot(savedAt: Date(),
                                     trending: trending,
                                     seasonal: seasonal.isEmpty ? nil : seasonal,
                                     popular: popular.isEmpty ? nil : popular,
                                     topRated: topRated.isEmpty ? nil : topRated,
                                     recentlyCompleted: recentlyCompleted.isEmpty ? nil : recentlyCompleted,
                                     upcoming: upcoming.isEmpty ? nil : upcoming,
                                     genreShelves: genreShelves.isEmpty ? nil : genreShelves)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL(provider: provider), options: .atomic)
    }

    /// The snapshot for a provider page. `ignoreTTL` is the instant-seed path
    /// (the original's HomeCacheStore: stale-while-refresh with no age limit);
    /// the TTL-gated read stays as the outage bridge.
    static func loadHomeShelves(provider: ProviderType? = nil, ignoreTTL: Bool = false) -> ShelfSnapshot? {
        // Per-provider file first; the pre-v2.31 single snapshot still serves as a
        // chain-keyed fallback so an upgrading user keeps their cached shelves.
        let candidates = [fileURL(provider: provider), fileURL(provider: nil)]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(ShelfSnapshot.self, from: data),
               ignoreTTL || Date().timeIntervalSince(snapshot.savedAt) < ttl {
                return snapshot
            }
        }
        return nil
    }
}
