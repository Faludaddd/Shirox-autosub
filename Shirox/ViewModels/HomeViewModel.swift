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
            .dropFirst() // skip initial value — load() is called by the view's .task
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

        do {
            // Jikan (MAL) enforces ~3 req/s; load sequentially to avoid 429s.
            // AniList supports concurrent requests, so detect provider type first.
            let isMAL = ProviderManager.shared.primary?.providerType == .mal
            if isMAL {
                trending = try await ProviderManager.shared.call { try await $0.trending() }
                try await Task.sleep(nanoseconds: 400_000_000)
                seasonal = try await ProviderManager.shared.call { try await $0.seasonal() }
                try await Task.sleep(nanoseconds: 400_000_000)
                popular = try await ProviderManager.shared.call { try await $0.popular() }
                try await Task.sleep(nanoseconds: 400_000_000)
                topRated = try await ProviderManager.shared.call { try await $0.topRated() }
            } else {
                // AniList: fetch all sections concurrently, including new ones.
                async let t = ProviderManager.shared.call { try await $0.trending() }
                async let s = ProviderManager.shared.call { try await $0.seasonal() }
                async let p = ProviderManager.shared.call { try await $0.popular() }
                async let r = ProviderManager.shared.call { try await $0.topRated() }
                async let rc = fetchRecentlyCompleted()
                async let u = fetchUpcoming()
                let (tResult, sResult, pResult, rResult, rcResult, uResult) = try await (t, s, p, r, rc, u)
                trending = tResult
                seasonal = sResult
                popular = pResult
                topRated = rResult
                recentlyCompleted = rcResult
                upcoming = uResult
            }
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Fetches recently completed anime from last season (AniList only).
    private func fetchRecentlyCompleted() async throws -> [Media] {
        do {
            let media = try await AniListService.shared.recentlyCompletedLastSeason()
            return media.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            return []
        }
    }

    /// Fetches upcoming anime (AniList only).
    private func fetchUpcoming() async throws -> [Media] {
        do {
            let media = try await AniListService.shared.upcoming()
            return media.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            return []
        }
    }

    func reload() async {
        loaded = false
        await load()
    }
}
