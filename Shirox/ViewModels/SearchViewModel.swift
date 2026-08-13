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

    func search(usingModule: Bool, isMangaMode: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty && filters.isEmpty { clearResults(); return }
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
            let key = cacheKey(query: q, usingModule: usingModule, isMangaMode: isMangaMode)
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
                        let filtered = await ContentSafetyFilter.shared.filter(deduped, keyword: q)
                        moduleResults = filtered
                        aniListResults = []
                        resultCache[key] = CacheEntry(
                            moduleResults: filtered,
                            aniListResults: [],
                            storedAt: Date()
                        )
                    }
                } else {
                    // Provider path. AniList has a full filter API; MAL's
                    // public search endpoint only accepts a query string, so
                    // filters are applied client-side after fetching when the
                    // active provider is MAL. Manga mode forces the AniList
                    // manga endpoints regardless of the active provider.
                    let activeProvider = ProviderManager.shared.orderedProviders.first?.providerType ?? .anilist
                    let res: [Media]
                    if isMangaMode {
                        // Manga mode: always use AniList MANGA endpoints so
                        // anime results never appear in Reading Mode.
                        let mangaMedia = try await AniListService.shared.mangaSearch(keyword: q)
                        res = mangaMedia.map { AniListProvider.shared.mapMangaMedia($0) }
                    } else if activeProvider == .mal {
                        let raw = try await MALProvider.shared.search(q)
                        res = applyMALClientFilters(raw)
                    } else if filters.isEmpty {
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
    /// primary provider type for AniList/MAL searches) + mode. Provider/module
    /// switches and mode switches therefore never return a stale foreign
    /// cache entry.
    private func cacheKey(query: String, usingModule: Bool, isMangaMode: Bool) -> String {
        var source: String
        if usingModule {
            source = "module:" + (ModuleManager.shared.activeModule?.id ?? "?")
        } else {
            source = "provider:" + (ProviderManager.shared.orderedProviders.first?.providerType.rawValue ?? "?")
        }
        let mode = isMangaMode ? "manga" : "anime"
        return "\(source)|\(mode)|\(query.lowercased())|\(filters.effectiveSort)|\(filters.year ?? 0)|\(filters.season ?? "")|\(filters.format ?? "")|\(filters.status ?? "")|\(filters.genres.joined(separator: ","))|\(filters.studio ?? "")|\(filters.source ?? "")|\(filters.minEpisodes ?? 0)|\(filters.maxEpisodes ?? 0)"
    }

    /// Manga modules use the Luna contract (raw-object returns); everything
    /// else uses the Sora searchResults path. Both produce [SearchItem].
    private func moduleSearch(_ q: String) async throws -> [SearchItem] {
        if ModuleManager.shared.activeModule?.isManga == true {
            return try await JSEngine.shared.mangaSearch(keyword: q)
        }
        return try await JSEngine.shared.search(keyword: q)
    }

    /// MAL's public search endpoint only accepts a free-text `q` parameter —
    /// no genre/year/format/etc. filters. To preserve the user's filter
    /// selections when MAL is the active search source, we apply the filters
    /// client-side on the returned Media array. Filters that MAL's Media
    /// representation doesn't populate (studio, source, min/max episodes when
    /// `episodes` is nil) are silently skipped.
    private func applyMALClientFilters(_ items: [Media]) -> [Media] {
        guard !filters.isEmpty else { return items }
        return items.filter { media in
            if let year = filters.year, media.seasonYear != year { return false }
            if let season = filters.season, let s = media.season, s.uppercased() != season.uppercased() { return false }
            if let format = filters.format, let mf = media.format, mf.uppercased() != format.uppercased() { return false }
            if let status = filters.status, let ms = media.status, ms.uppercased() != status.uppercased() { return false }
            if !filters.genres.isEmpty {
                let mediaGenres = (media.genres ?? []).map { $0.lowercased() }
                let needed = filters.genres.map { $0.lowercased() }
                if !needed.allSatisfy({ mediaGenres.contains($0) }) { return false }
            }
            if let min = filters.minEpisodes, let ep = media.episodes, ep < min { return false }
            if let max = filters.maxEpisodes, let ep = media.episodes, ep > max { return false }
            return true
        }
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
