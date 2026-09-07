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
    }

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil

        let isMAL = ProviderManager.shared.primary?.providerType == .mal

        if isMAL {
            // MAL: sequential to avoid 429s. Recently Completed and Upcoming
            // are AniList-only, so they won't load — that's expected.
            do {
                trending = try await ProviderManager.shared.call { try await $0.trending() }
                try await Task.sleep(nanoseconds: 400_000_000)
                seasonal = try await ProviderManager.shared.call { try await $0.seasonal() }
                try await Task.sleep(nanoseconds: 400_000_000)
                popular = try await ProviderManager.shared.call { try await $0.popular() }
                try await Task.sleep(nanoseconds: 400_000_000)
                topRated = try await ProviderManager.shared.call { try await $0.topRated() }
            } catch {
                self.error = error.localizedDescription
            }
            if !trending.isEmpty {
                SnapshotStore.saveHomeShelves(trending: trending, seasonal: seasonal, popular: popular, topRated: topRated)
            }
        } else {
            // AniList: fetch each section independently so a slow response
            // from one doesn't block the others. Each result is assigned as
            // soon as it arrives, so the UI populates progressively.
            //
            // v2.23 — every shelf now goes through ProviderManager.call —
            // ONE fallback path shared by the whole app (AniList → MAL/Jikan
            // → snapshot). The old per-shelf hand-rolled fallback fired
            // SECOND, independent Jikan requests on top of the ones
            // ProviderManager already made — the duplicate-request flood
            // behind the Jikan 429s.
            async let t: Void = loadTrending()
            async let s: Void = loadSeasonal()
            async let p: Void = loadPopular()
            async let r: Void = loadTopRated()
            async let rc: Void = loadRecentlyCompleted()
            async let u: Void = loadUpcoming()
            _ = await (t, s, p, r, rc, u)
        }

        // v2.23 — persist the last-good shelves AFTER everything settles so
        // the snapshot captures the fully-populated page (the loaders run
        // concurrently — saving inside one of them would snapshot empty
        // shelves).
        if !trending.isEmpty {
            SnapshotStore.saveHomeShelves(trending: trending, seasonal: seasonal, popular: popular, topRated: topRated)
        }

        loaded = true
        isLoading = false
    }

    private func loadTrending() async {
        do {
            trending = try await ProviderManager.shared.call { try await $0.trending() }
        } catch {
            serveSnapshotIfAvailable(error: error)
        }
    }

    private func loadSeasonal() async {
        do {
            seasonal = try await ProviderManager.shared.call { try await $0.seasonal() }
        } catch {
            // Snapshot of last-good data fills the shelf silently; the
            // trending loader reports the honest error once.
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadPopular() async {
        do {
            popular = try await ProviderManager.shared.call { try await $0.popular() }
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadTopRated() async {
        do {
            topRated = try await ProviderManager.shared.call { try await $0.topRated() }
        } catch {
            serveSnapshotIfAvailable(error: error, quiet: true)
        }
    }

    private func loadRecentlyCompleted() async {
        do {
            let media = try await AniListService.shared.recentlyCompletedLastSeason()
            recentlyCompleted = media.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            // AniList-only feature — no Jikan equivalent for "recently
            // completed last season"
            recentlyCompleted = []
        }
    }

    private func loadUpcoming() async {
        do {
            let media = try await AniListService.shared.upcoming()
            upcoming = media.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            upcoming = []
        }
    }

    /// v2.23 — Requirement: primary trending source → fallback provider →
    /// cached trending results → offline snapshot. When both providers
    /// fail, the last-good shelves (6h TTL) keep the Home page — and its
    /// carousel — alive with real data instead of an error wall. Only
    /// surfaces an error when there is NO snapshot to serve.
    private func serveSnapshotIfAvailable(error: Error, quiet: Bool = false) {
        let sourceNotice = SnapshotStore.loadHomeShelves()
        let snapshot = sourceNotice?.shelves
        if trending.isEmpty, let snapshot, let snapTrending = snapshot.trending, !snapTrending.isEmpty {
            trending = snapTrending
        }
        if seasonal.isEmpty, let snapshot, let snapSeasonal = snapshot.seasonal, !snapSeasonal.isEmpty {
            seasonal = snapSeasonal
        }
        if popular.isEmpty, let snapshot, let snapPopular = snapshot.popular, !snapPopular.isEmpty {
            popular = snapPopular
        }
        if topRated.isEmpty, let snapshot, let snapTop = snapshot.topRated, !snapTop.isEmpty {
            topRated = snapTop
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
    }

    static func saveHomeShelves(trending: [Media], seasonal: [Media], popular: [Media], topRated: [Media]) {
        guard !trending.isEmpty else { return }
        let snapshot = ShelfSnapshot(savedAt: Date(),
                                     trending: trending,
                                     seasonal: seasonal.isEmpty ? nil : seasonal,
                                     popular: popular.isEmpty ? nil : popular,
                                     topRated: topRated.isEmpty ? nil : topRated)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Returns the snapshot (and when it was saved) when it's fresh enough.
    static func loadHomeShelves() -> (shelves: ShelfSnapshot)? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ShelfSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) < ttl else { return nil }
        return snapshot
    }
}
