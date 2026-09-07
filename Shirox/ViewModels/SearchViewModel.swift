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
                // Cache entries store the pre-patch results; re-apply the
                // airing-manga chapter counts (disk-cached, so normally this
                // costs zero network calls). No-ops for anime results.
                if !aniListResults.isEmpty {
                    await enrichAiringChapterCounts()
                }
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
                    // Provider path. v2.24 — plain text searches run through
                    // the UnifiedProviderSystem chains (anime: TVDB → MAL →
                    // AniList → Kitsu; manga: MangaBaka → MAL → AniList) —
                    // one shared, health-gated, deduplicated, cached chain.
                    // AniList's FILTER search (genre/format/year filters)
                    // only exists on AniList, so filtered queries keep their
                    // direct AniList call — the chain has no equivalent.
                    let res: [Media]
                    if isMangaMode {
                        // Manga mode: the manga chain keeps anime results
                        // out of Reading Mode.
                        res = try await UnifiedProviderSystem.shared.searchManga(q)
                    } else if !filters.isEmpty {
                        let aniListMedia = try await AniListService.shared.search(keyword: q, filters: filters)
                        res = aniListMedia.map { AniListProvider.shared.mapMedia($0) }
                    } else {
                        res = try await UnifiedProviderSystem.shared.searchAnime(q)
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
                    if isMangaMode && (AniListService.shared.isApiDisabled() || AniListService.shared.isRateLimited()) {
                        errorMessage = "Manga search is temporarily unavailable. AniList and Jikan are both down. Please try again shortly."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }

            // Round 9 — fill in live chapter counts for AIRING manga result
            // posters (same progressive patch as the manga home shelves:
            // AniList leaves `chapters` null while a manga is releasing, so
            // MangaUpdatesChapterService supplies the live count). No-ops
            // instantly for anime results / results that already have counts.
            if !Task.isCancelled && !aniListResults.isEmpty {
                await enrichAiringChapterCounts()
            }
        }
    }

    /// Patches airing manga search results from a bare "Airing" status line
    /// to "Airing, N" by filling `episodes` with the live chapter count from
    /// MangaUpdates. Runs inside the search task, so typing a new query
    /// cancels it automatically.
    private func enrichAiringChapterCounts() async {
        let queue = aniListResults.filter {
            $0.isManga && $0.statusDisplay == "Airing" && ($0.episodes ?? 0) == 0
        }
        guard !queue.isEmpty else { return }

        for m in queue {
            if Task.isCancelled { break }
            guard let count = await MangaUpdatesChapterService.shared.latestChapter(
                anilistId: m.id,
                title: m.title.displayTitle,
                altTitle: m.title.searchTitle,
                year: m.seasonYear
            ) else { continue }
            if let index = aniListResults.firstIndex(where: { $0.id == m.id }) {
                aniListResults[index].episodes = count
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
