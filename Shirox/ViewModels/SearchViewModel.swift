import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var moduleResults: [SearchItem] = []
    @Published var aniListResults: [Media] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var hasSearched = false
    @Published var filters: AniListService.SearchFilters = .empty

    private(set) var isUsingModule = false
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - In-memory result cache
    //
    // Avoids re-hitting the network when the user re-issues a recent query
    // (e.g. tapping a history entry, toggling a filter back, or switching
    // providers and returning). Keyed by query + filters + active source so a
    // module search never collides with an AniList/MAL search. Entries expire
    // after `cacheTTL` (2 min) so stale data doesn't linger.
    private struct CacheEntry {
        let moduleResults: [SearchItem]
        let aniListResults: [Media]
        let storedAt: Date
    }
    private var resultCache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 120  // seconds

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in self?.clearResults() }
            .store(in: &cancellables)
    }

    func search(usingModule: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearResults(); return }
        searchTask?.cancel()
        isUsingModule = usingModule
        hasSearched = true
        isLoading = true
        errorMessage = nil
        moduleResults = []
        aniListResults = []
        searchTask = Task {
            // Cache hit short-circuits the network entirely. A fresh hit also
            // suppresses the loading spinner so re-issued searches feel instant.
            let key = cacheKey(query: q, usingModule: usingModule)
            if let hit = resultCache[key],
               Date().timeIntervalSince(hit.storedAt) <= cacheTTL,
               !Task.isCancelled {
                moduleResults = hit.moduleResults
                aniListResults = hit.aniListResults
                isLoading = false
                return
            }

            do {
                if usingModule {
                    CloudflareBypassManager.shared.pendingVerificationURL = nil
                    var res: [SearchItem]
                    do {
                        res = try await moduleSearch(q)
                    } catch {
                        // Modules often swallow a CF wall as a JSON parse error and rethrow.
                        // If a Turnstile host was flagged, fall through to verify; else surface it.
                        guard CloudflareBypassManager.shared.pendingVerificationURL != nil else { throw error }
                        res = []
                    }
                    // The user explicitly searched, so a Cloudflare wall here is solved inline
                    // (auto-verify + retry once) rather than deferred to a button. Verify whenever
                    // a wall was flagged — modules often swallow the CF page and return a bogus
                    // result, so we can't rely on the result being empty.
                    if !Task.isCancelled,
                       let cfURL = CloudflareBypassManager.shared.pendingVerificationURL {
                        try? await CloudflareBypassManager.shared.triggerBypass(for: cfURL)
                        if !Task.isCancelled {
                            CloudflareBypassManager.shared.pendingVerificationURL = nil
                            res = try await moduleSearch(q)
                        }
                    }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        let deduped = res.filter { seen.insert($0.href).inserted }
                        let filtered = await NSFWContentFilter.shared.filter(deduped, keyword: q)
                        moduleResults = filtered
                        aniListResults = []
                        resultCache[key] = CacheEntry(
                            moduleResults: filtered,
                            aniListResults: [],
                            storedAt: Date()
                        )
                    }
                } else {
                    // AniList path: use AniListService directly so we can pass filters.
                    let res: [Media]
                    if filters.isEmpty {
                        res = try await ProviderManager.shared.call { try await $0.search(q) }
                    } else {
                        let aniListMedia = try await AniListService.shared.search(keyword: q, filters: filters)
                        res = aniListMedia.map { AniListProvider.shared.mapMedia($0) }
                    }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        let deduped = res.filter { seen.insert($0.uniqueId).inserted }
                        aniListResults = deduped
                        moduleResults = []
                        resultCache[key] = CacheEntry(
                            moduleResults: [],
                            aniListResults: deduped,
                            storedAt: Date()
                        )
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    /// Builds a cache key that uniquely identifies a search result set:
    /// query + filters + active source (module id for module searches,
    /// primary provider type for AniList/MAL searches). Provider/module
    /// switches therefore never return a stale foreign-source cache entry.
    private func cacheKey(query: String, usingModule: Bool) -> String {
        var source: String
        if usingModule {
            source = "module:" + (ModuleManager.shared.activeModule?.id ?? "?")
        } else {
            source = "provider:" + (ProviderManager.shared.orderedProviders.first?.providerType.rawValue ?? "?")
        }
        return "\(source)|\(query.lowercased())|\(filters.effectiveSort)|\(filters.year ?? 0)|\(filters.season ?? "")|\(filters.format ?? "")|\(filters.status ?? "")|\(filters.genres.joined(separator: ","))|\(filters.studio ?? "")|\(filters.source ?? "")|\(filters.minEpisodes ?? 0)|\(filters.maxEpisodes ?? 0)"
    }

    /// Manga modules use the Luna contract (raw-object returns); everything
    /// else uses the Sora searchResults path. Both produce [SearchItem].
    private func moduleSearch(_ q: String) async throws -> [SearchItem] {
        if ModuleManager.shared.activeModule?.isManga == true {
            return try await JSEngine.shared.mangaSearch(keyword: q)
        }
        return try await JSEngine.shared.search(keyword: q)
    }

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        moduleResults = []
        aniListResults = []
        isLoading = false
        errorMessage = nil
        hasSearched = false
    }

    var hasResults: Bool { !moduleResults.isEmpty || !aniListResults.isEmpty }
    var resultCount: Int { moduleResults.count + aniListResults.count }
}
