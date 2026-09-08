import Foundation
import Combine

@MainActor
final class BrowseViewModel: ObservableObject {
    /// Batch 26 — the STABLE query this page pages through. It arrives
    /// from the Home row / grid tile that opened it (category OR genre —
    /// always the identifier the row itself used, so the page's list is
    /// the row's list continued, never another category's).
    let query: BrowseQuery

    @Published var items: [Media] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasMore = true

    private var currentPage = 0
    private var cancellables = Set<AnyCancellable>()

    init(query: BrowseQuery) {
        self.query = query
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reset() }
            }
            .store(in: &cancellables)
    }

    /// Backward-compatible category initializer.
    init(category: BrowseCategory) {
        self.init(query: .category(category))
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        let nextPage = currentPage + 1
        do {
            // v2.24 / Batch 26 — See All pages run through the unified
            // DISCOVERY chain — the SAME chain, cache, and dedup the Home
            // shelves use (the shelf IS page 1 of this browse), so opening
            // See All right after Home costs nothing, and PAGINATION
            // CONTINUES THE SAME QUERY (the genre/category the row named,
            // never another category's list).
            let newItems = try await query.load(page: nextPage)
            var seen = Set(items.map(\.uniqueId))
            let deduped = newItems.filter { seen.insert($0.uniqueId).inserted }
            items.append(contentsOf: deduped)
            currentPage = nextPage
            if newItems.count < 20 { hasMore = false }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Backs both the error-state Retry button and pull-to-refresh, so it must start over rather
    /// than continue paging: it previously left `currentPage` and `items` untouched, so pulling to
    /// refresh a populated grid just appended the *next* page to the bottom instead of reloading.
    func retry() async {
        await reset()
    }

    private func reset() async {
        items = []
        currentPage = 0
        hasMore = true
        error = nil
        await loadMore()
    }
}
