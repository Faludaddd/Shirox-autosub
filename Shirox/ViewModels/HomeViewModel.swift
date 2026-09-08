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
        // snapshot captures the fully-populated page.
        if !trending.isEmpty {
            SnapshotStore.saveHomeShelves(trending: trending, seasonal: seasonal, popular: popular, topRated: topRated,
                                          recentlyCompleted: recentlyCompleted, upcoming: upcoming)
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
        if let snapshot = SnapshotStore.loadHomeShelves() {
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
}

// MARK: - Home shelf snapshot (offline fallback of last resort)

/// Disk snapshot of the last-good Home shelves. Requirement: the carousel
/// (and shelves) keep rendering REAL data through provider outages —
/// AniList 403 → MAL/Jikan → this snapshot. Written on every successful
/// load, read when every source fails, 6-hour TTL (it's a bridge over
/// outages, not a permanent freeze — after 6h the honest error state
/// shows instead of stale content).
enum SnapshotStore {
    private static let ttl: TimeInterval = 6 * 3600

    private static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("home-shelves-snapshot.json")
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
    }

    static func saveHomeShelves(trending: [Media], seasonal: [Media], popular: [Media], topRated: [Media],
                                 recentlyCompleted: [Media] = [], upcoming: [Media] = []) {
        guard !trending.isEmpty else { return }
        let snapshot = ShelfSnapshot(savedAt: Date(),
                                     trending: trending,
                                     seasonal: seasonal.isEmpty ? nil : seasonal,
                                     popular: popular.isEmpty ? nil : popular,
                                     topRated: topRated.isEmpty ? nil : topRated,
                                     recentlyCompleted: recentlyCompleted.isEmpty ? nil : recentlyCompleted,
                                     upcoming: upcoming.isEmpty ? nil : upcoming)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Returns the snapshot when it's fresh enough (6h TTL — a bridge
    /// over outages, not a permanent freeze).
    static func loadHomeShelves() -> ShelfSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ShelfSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) < ttl else { return nil }
        return snapshot
    }
}
