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
        } else {
            // AniList: fetch each section independently so a slow response
            // from one doesn't block the others. Each result is assigned as
            // soon as it arrives, so the UI populates progressively.
            async let t: Void = loadTrending()
            async let s: Void = loadSeasonal()
            async let p: Void = loadPopular()
            async let r: Void = loadTopRated()
            async let rc: Void = loadRecentlyCompleted()
            async let u: Void = loadUpcoming()
            _ = await (t, s, p, r, rc, u)
        }

        loaded = true
        isLoading = false
    }

    private func loadTrending() async {
<<<<<<< HEAD
        do { trending = try await ProviderManager.shared.call { try await $0.trending() } }
        catch {
            if trending.isEmpty { self.error = "AniList API is temporarily unavailable. Pull to retry." }
=======
        // Try AniList first; if it fails (e.g. API disabled), fall back to Jikan/MAL.
        do {
            trending = try await ProviderManager.shared.call { try await $0.trending() }
        } catch {
            // AniList failed — try Jikan/MAL as fallback for the data.
            if AniListService.shared.isApiDisabled() {
                Logger.shared.logStructured(type: "Provider", feature: "Home", operation: "Trending fallback to Jikan", error: "AniList API disabled")
                do {
                    let results = try await MALDiscoveryService.shared.trending()
                    trending = results.map { MALDiscoveryService.shared.mapToMedia($0) }
                } catch {
                    if trending.isEmpty { self.error = "AniList API is temporarily unavailable. Pull to retry." }
                }
            } else {
                if trending.isEmpty { self.error = "AniList API is temporarily unavailable. Pull to retry." }
            }
>>>>>>> 03769c9 (v1.78: Fall back to Jikan/MAL when AniList API is down)
        }
    }

    private func loadSeasonal() async {
        do {
            seasonal = try await ProviderManager.shared.call { try await $0.seasonal() }
        } catch {
            if AniListService.shared.isApiDisabled() {
                do {
                    let results = try await MALDiscoveryService.shared.seasonal()
                    seasonal = results.map { MALDiscoveryService.shared.mapToMedia($0) }
                } catch { }
            }
        }
    }

    private func loadPopular() async {
        do {
            popular = try await ProviderManager.shared.call { try await $0.popular() }
        } catch {
            if AniListService.shared.isApiDisabled() {
                do {
                    let results = try await MALDiscoveryService.shared.popular()
                    popular = results.map { MALDiscoveryService.shared.mapToMedia($0) }
                } catch { }
            }
        }
    }

    private func loadTopRated() async {
        do {
            topRated = try await ProviderManager.shared.call { try await $0.topRated() }
        } catch {
            if AniListService.shared.isApiDisabled() {
                do {
                    let results = try await MALDiscoveryService.shared.topRated()
                    topRated = results.map { MALDiscoveryService.shared.mapToMedia($0) }
                } catch { }
            }
        }
    }

    private func loadRecentlyCompleted() async {
        do {
            let media = try await AniListService.shared.recentlyCompletedLastSeason()
            recentlyCompleted = media.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            // AniList-only feature — no Jikan equivalent for "recently completed last season"
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

    func reload() async {
        loaded = false
        await load()
    }
}
