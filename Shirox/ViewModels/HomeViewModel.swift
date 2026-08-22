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
        do { trending = try await ProviderManager.shared.call { try await $0.trending() } }
        catch {
            if trending.isEmpty { self.error = "AniList API is temporarily unavailable. Pull to retry." }
        }
    }

    private func loadSeasonal() async {
        do { seasonal = try await ProviderManager.shared.call { try await $0.seasonal() } }
        catch { }
    }

    private func loadPopular() async {
        do { popular = try await ProviderManager.shared.call { try await $0.popular() } }
        catch { }
    }

    private func loadTopRated() async {
        do { topRated = try await ProviderManager.shared.call { try await $0.topRated() } }
        catch { }
    }

    private func loadRecentlyCompleted() async {
        do {
            let media = try await AniListService.shared.recentlyCompletedLastSeason()
            recentlyCompleted = media.map { AniListProvider.shared.mapMedia($0) }
        } catch { recentlyCompleted = [] }
    }

    private func loadUpcoming() async {
        do {
            let media = try await AniListService.shared.upcoming()
            upcoming = media.map { AniListProvider.shared.mapMedia($0) }
        } catch { upcoming = [] }
    }

    func reload() async {
        loaded = false
        await load()
    }
}
