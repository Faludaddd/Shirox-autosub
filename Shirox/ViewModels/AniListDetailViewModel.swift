import Foundation
import Combine

@MainActor
final class AniListDetailViewModel: ObservableObject {
    @Published var media: Media?
    @Published var isLoading = true
    @Published var error: String?

    /// Raw AniList characters + recommendations, fetched alongside `media`
    /// so `CharactersSection` / `RecommendationsSection` can render without
    /// a second network call. nil when not yet loaded or fetch failed.
    @Published var characters: [AniListCharacterEdge] = []
    @Published var recommendations: [AniListRecommendation] = []

    // Stream picker state
    @Published var showStreamPicker = false
    @Published var selectedEpisodeNumber: Int?

    // Stream results that bubble up from ModuleStreamPickerView
    @Published var pendingStreams: [StreamResult] = []
    @Published var showFinalStreamPicker = false
    @Published var selectedStream: StreamResult?
    @Published var showPlayer = false

    // Download stream picker state
    @Published var pendingDownloadStreams: [StreamResult] = []
    @Published var pendingDownloadEpisode: (EpisodeLink, Int)?
    @Published var pendingDownloadModule: ModuleDefinition?
    @Published var pendingDownloadMedia: Media?
    @Published var showDownloadStreamPicker = false

    /// Deferred streams waiting to be presented after a sheet fully dismisses.
    var pendingModuleStream: StreamResult?   // single-stream from ModuleStreamPickerView
    var pendingModuleStreamEpisodeHref: String?  // show/search-result href (used to re-fetch episodes)
    var pendingModuleStreamActualHref: String?   // the matched episode's own href (anchors Next Episode)
    var pendingModuleStreamAvailableCount: Int?  // episode count from module search result
    var pendingFinalStream: StreamResult?    // chosen stream from AniListStreamResultSheet
    var pendingFinalStreamEpisodeHref: String?  // show/search-result href (used to re-fetch episodes)
    var pendingFinalStreamActualHref: String?    // the matched episode's own href (anchors Next Episode)
    var pendingFinalStreamAvailableCount: Int?   // saved count for final picker

    /// Resume position if navigated from Continue Watching (only applies to the specific episode)
    var resumeWatchedSeconds: Double?
    var resumeEpisodeNumber: Int?

    func load(id: Int, preloaded: Media? = nil) async {
        guard media == nil else { return }
        if let preloaded { media = preloaded }
        isLoading = true
        error = nil
        do {
            media = try await ProviderManager.shared.call { try await $0.detail(id: id) }
            // MAL/Jikan has no banner art; reuse the already-cached TVDB fanart.
            if media?.provider == .mal, media?.bannerImage == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: id, provider: .mal)
                if let fanart = artwork.fanart {
                    media?.bannerImage = fanart
                }
            }
            // Fetch raw AniList media for characters + recommendations.
            // Best-effort: don't fail the whole load if this secondary
            // fetch errors. Uses the anime endpoint (the VM is anime-only).
            if let raw = try? await AniListService.shared.detail(id: id) {
                characters = raw.characters?.edges ?? []
                recommendations = raw.recommendations?.nodes ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// True while autoResolveWithActiveModule is running. Prevents the user
    /// from spamming the Watch button and firing multiple resolve cycles
    /// (each of which hammers the module's server with search + episodes +
    /// streams requests). The Watch button should check this and disable.
    @Published var isResolving = false

    func watchEpisode(_ number: Int) {
        // Guard: don't start a new resolve if one is already in flight.
        // This prevents the duplicate episode/stream fetches that happen
        // when the user spams the Watch button.
        guard !isResolving else { return }
        selectedEpisodeNumber = number
        Task { await autoResolveWithActiveModule(episode: number) }
    }

    /// Auto-resolves streams for `episode` using the currently-active anime
    /// module. Normal flow: search → episodes → match → streams → auto-play
    /// the best stream. Fallback flow: if auto-play fails (403, empty, error),
    /// show the ModuleStreamPickerView so the user can manually pick a
    /// module/source/stream.
    private func autoResolveWithActiveModule(episode: Int) async {
        isResolving = true
        defer { isResolving = false }

        // Need a media title to search.
        guard let media else {
            ToastManager.shared.show(
                title: "Watch",
                message: "Media not loaded yet — try again in a moment.",
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange
            )
            return
        }

        // Find an anime module to use. Prefer the active module if it's an
        // anime module; otherwise the first installed anime module.
        let manager = ModuleManager.shared
        let activeAnimeModule: ModuleDefinition? = {
            if let active = manager.activeModule, !active.isManga { return active }
            return manager.modules.first { !$0.isManga }
        }()

        guard let module = activeAnimeModule else {
            // No anime module installed — show the picker so the user can
            // install one.
            showStreamPicker = true
            return
        }

        // Ensure the chosen module is the active one (loads its JS).
        // MODULE ISOLATION: the selected module must be the one that
        // performs ALL operations — search, episodes, streams. We never
        // mix modules.
        if manager.activeModule?.id != module.id {
            _ = await manager.selectAndAwaitReady(module)
        }

        // Use a dedicated ModuleJSRunner for this module. The runner
        // carries its own JSContext loaded with THIS module's script,
        // so all calls (search, fetchEpisodes, fetchStreams) go through
        // the same module — no cross-module contamination.
        let runner = ModuleJSRunner()
        let searchTitle = ModuleSearchAliasManager.shared.getAlias(
            mediaId: media.id, animeTitle: media.title.searchTitle, moduleId: module.id
        ) ?? media.title.searchTitle

        do {
            // Load the module's JS into the runner first.
            try await runner.load(module: module)

            // 1. Search + 2. Fetch episodes in parallel with 3. Season offset.
            // This cuts ~2s off the typical watch flow (search + episode fetch
            // were sequential before, now they overlap with the offset lookup).
            async let searchResults: [SearchItem] = {
                var r = try await runner.search(keyword: searchTitle)
                if r.isEmpty {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if Task.isCancelled { return [] }
                    r = try await runner.search(keyword: searchTitle)
                }
                return r
            }()
            async let offsetResult: Int = await SeasonChainMapper.shared.resolveOffset(
                anchorAniListID: media.id, anchorMALID: nil) ?? 0

            let results = try await searchResults
            let offset = await offsetResult

            guard !results.isEmpty else {
                showStreamPicker = true
                return
            }
            let ordered = SearchResultMatcher.ranked(
                query: media.title.searchTitle, items: results, title: { $0.title })
            let match = ordered.first!

            // 2. Fetch episodes for the matched result.
            var episodes = try await runner.fetchEpisodes(url: match.href)
            if episodes.isEmpty {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await runner.fetchEpisodes(url: match.href)
            }
            guard !episodes.isEmpty else {
                showStreamPicker = true
                return
            }

            // 3. Match the target episode.
            let targetDouble = Double(episode)
            let matched: EpisodeLink? = {
                if let exact = episodes.first(where: { $0.number == targetDouble }) { return exact }
                if let rounded = episodes.first(where: { round($0.number) == targetDouble }) { return rounded }
                if offset > 0 {
                    let offsetTarget = Double(episode + offset)
                    if let off = episodes.first(where: { $0.number == offsetTarget }) { return off }
                }
                return nil
            }()
            guard let matched else {
                showStreamPicker = true
                return
            }

            // 4. Fetch streams for the matched episode.
            let streams = try await runner.fetchStreams(episodeUrl: matched.href)
            guard !streams.isEmpty else {
                // No streams — fall back to manual picker.
                showStreamPicker = true
                return
            }

            // 5. Auto-select the best stream. Don't blindly pick the first
            // returned stream — prefer streams that look like HLS/m3u8 (most
            // reliable), then by title (quality indicators like "1080p" rank
            // higher). If "Auto-pick Last Stream" is enabled and we have a
            // saved preference, use that.
            let sorted = streams.sorted { $0.title < $1.title }
            let selectedStream: StreamResult?

            // Check for saved stream preference (autoPickLastStream).
            if UserDefaults.standard.bool(forKey: "autoPickLastStream"),
               let moduleId = manager.activeModule?.id,
               let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(moduleId: moduleId),
               let saved = sorted.first(where: { $0.title == savedTitle }) {
                selectedStream = saved
            } else if sorted.count == 1 {
                // Only one stream — use it directly.
                selectedStream = sorted[0]
            } else {
                // Multiple streams — try to auto-select the best one.
                // Prefer HLS streams (m3u8) as they're most reliable.
                // Then prefer higher quality (1080p > 720p > 480p).
                selectedStream = pickBestStream(sorted)
            }

            // Remember the alias + href for next time.
            ModuleSearchAliasManager.shared.setLastSearchResultHref(
                mediaId: media.id, animeTitle: media.title.searchTitle,
                moduleId: module.id, href: match.href)

            if let selectedStream {
                // Auto-play the selected stream.
                onStreamsLoaded(sorted, selectedStream: selectedStream,
                                episodeHref: match.href,
                                availableCount: episodes.count,
                                actualEpisodeHref: matched.href)
            } else {
                // Couldn't auto-select — show the manual stream picker
                // (the quality/server picker, NOT the module picker).
                onStreamsLoaded(sorted, selectedStream: nil,
                                episodeHref: match.href,
                                availableCount: episodes.count,
                                actualEpisodeHref: matched.href)
            }
        } catch {
            // Resolution failed (403, network, module error, etc.).
            // FALLBACK: show the ModuleStreamPickerView so the user can
            // manually try a different module or approach. Cancellation
            // is silent (expected when the user navigates away).
            if !ProviderManager.isCancellationError(error) {
                Logger.shared.log(
                    "[Watch] Auto-resolve failed for ep \(episode): \(error.localizedDescription) — falling back to manual picker",
                    type: "Error"
                )
                showStreamPicker = true
            }
        }
    }

    /// Picks the best stream from a list. Prefers HLS (m3u8) streams as
    /// they're most reliable, then ranks by quality indicators in the title
    /// (1080p > 720p > 480p > unknown). Returns nil if no stream looks
    /// playable.
    private func pickBestStream(_ streams: [StreamResult]) -> StreamResult? {
        guard !streams.isEmpty else { return nil }

        // Quality ranking: extract resolution from title.
        func qualityScore(_ title: String) -> Int {
            let lower = title.lowercased()
            if lower.contains("1080") { return 100 }
            if lower.contains("720") { return 80 }
            if lower.contains("480") { return 60 }
            if lower.contains("360") { return 40 }
            return 50  // unknown quality — middle priority
        }

        // Prefer HLS streams (m3u8) — they're more reliable than MP4 direct.
        let hlsStreams = streams.filter { $0.url.absoluteString.contains(".m3u8") }
        let pool = hlsStreams.isEmpty ? streams : hlsStreams

        // Sort by quality score (descending), then by title alphabetically.
        return pool.sorted { a, b in
            let qa = qualityScore(a.title)
            let qb = qualityScore(b.title)
            return qa != qb ? qa > qb : a.title < b.title
        }.first
    }

    func dismissModulePicker() {
        showStreamPicker = false
        selectedEpisodeNumber = nil
    }

    func dismissFinalPicker() {
        showFinalStreamPicker = false
        pendingStreams = []
        selectedEpisodeNumber = nil
    }

    func onStreamsLoaded(_ streams: [StreamResult], selectedStream: StreamResult? = nil, episodeHref: String? = nil, availableCount: Int? = nil, actualEpisodeHref: String? = nil) {
        let sorted = streams.sorted { $0.title < $1.title }
        if let selected = selectedStream {
            // User already picked from quality picker — auto-play, but keep all streams for in-player switching
            pendingStreams = sorted
            pendingModuleStream = selected
            pendingModuleStreamEpisodeHref = episodeHref
            pendingModuleStreamActualHref = actualEpisodeHref
            pendingModuleStreamAvailableCount = availableCount
        } else if sorted.count == 1 {
            // Store and let onDismiss present after the sheet fully clears.
            pendingStreams = sorted
            pendingModuleStream = sorted[0]
            pendingModuleStreamEpisodeHref = episodeHref
            pendingModuleStreamActualHref = actualEpisodeHref
            pendingModuleStreamAvailableCount = availableCount
        } else {
            pendingStreams = sorted
            pendingFinalStreamEpisodeHref = episodeHref
            pendingFinalStreamActualHref = actualEpisodeHref
            pendingFinalStreamAvailableCount = availableCount
            showFinalStreamPicker = true
        }
        showStreamPicker = false
    }

    func selectStream(_ stream: StreamResult, searchResultHref: String? = nil, episodeActualHref: String? = nil, availableEpisodes: Int? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil) {
        selectedStream = stream
        guard let media else { return }
        let currentEpNum = selectedEpisodeNumber ?? 1
        let mediaTitle = media.title.displayTitle
        // availableEpisodes = how many are currently aired (may be < series total for ongoing shows)
        // Order of precedence:
        // 1. AniList's nextAiringEpisode (fallback airing count)
        // 2. The count passed from the module (best for accurate "caught up" tracking on a specific provider)
        // 3. AniList's total episodes (general fallback)
        let anilistAiring = media.nextAiringEpisode != nil ? (media.nextAiringEpisode!.episode - 1) : nil
        let availEps: Int? = anilistAiring ?? availableEpisodes ?? media.episodes
        // totalEpisodes = full series count (nil if unknown)
        let totalEpisodes: Int? = media.episodes
        let episodeThumbnail = TVDBMappingService.shared.getCachedEpisode(for: media.id, episodeNumber: currentEpNum)?.thumbnail
        let context = PlayerContext(
            mediaTitle: mediaTitle,
            episodeNumber: currentEpNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            malID: media.idMal,
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: totalEpisodes,
            availableEpisodes: availEps,
            isAiring: media.status == "RELEASING",
            resumeFrom: resumeEpisodeNumber == currentEpNum
                ? resumeWatchedSeconds
                : ContinueWatchingManager.shared.items.first(where: { $0.aniListID == media.id && $0.episodeNumber == currentEpNum })?.watchedSeconds,
            detailHref: searchResultHref,
            episodeHref: episodeActualHref,
            streamTitle: stream.title,
            workingDetailHref: searchResultHref,
            thumbnailUrl: episodeThumbnail
        )

        // Build next-episode loader using ModuleJSRunner (same path as ModuleStreamPickerView)
        let onWatchNext: WatchNextLoader? = {
            guard let module = ModuleManager.shared.activeModule, let resultHref = searchResultHref else {
                Logger.shared.log("[AniListDetailVM] No module or working href available", type: "Error")
                return nil
            }
            let total = availEps ?? 0
            // If we are at the end of what's available, don't even create the loader
            if total > 0 && currentEpNum >= total {
                return nil
            }

            // Anchor on the matched episode's own href: the module may number a season's
            // episodes with an offset (S2 = 25…48) or restart from 1, so advance by list
            // position rather than `currentEpNum + 1` (which would jump to season 1).
            var currentHref = episodeActualHref
            var fallbackNumber = currentEpNum  // last resort if the href isn't in the list
            return { _ in
                do {
                    let runner = ModuleJSRunner()
                    try await runner.load(module: module)

                    // Use the stored working href - this is the search result that was proven to work
                    let episodes = try await runner.fetchEpisodes(url: resultHref)
                    Logger.shared.log("[AniListDetailVM] Got \(episodes.count) episodes from stored href", type: "Debug")

                    guard let step = EpisodeNavigator.next(afterHref: currentHref, in: episodes)
                        ?? EpisodeNavigator.next(currentNumber: fallbackNumber, anchor: 0, in: episodes) else {
                        Logger.shared.log("[AniListDetailVM] No next episode after current", type: "Error")
                        return nil
                    }

                    let streams = try await runner.fetchStreams(episodeUrl: step.episode.href)
                        .sorted { $0.title < $1.title }
                    Logger.shared.log("[AniListDetailVM] Got \(streams.count) streams for episode \(Int(step.episode.number))", type: "Debug")

                    guard !streams.isEmpty else { return nil }
                    currentHref = step.episode.href
                    fallbackNumber = Int(step.episode.number)
                    return (streams: streams, episodeNumber: Int(step.episode.number), episodeHref: step.episode.href)
                } catch {
                    Logger.shared.log("[AniListDetailVM] Error loading next episode: \(error)", type: "Error")
                    return nil
                }
            }
        }()

        let onSequelNeeded: SequelLoader? = {
            guard
                let sequelNode = media.relations?.edges.first(where: {
                    $0.relationType == "SEQUEL" && $0.node.type == "ANIME"
                })?.node,
                let module = ModuleManager.shared.activeModule
            else { return nil }
            let sequelTitle = sequelNode.title.displayTitle
            let sequelID = sequelNode.id
            return {
                let runner = ModuleJSRunner()
                try await runner.load(module: module)
                let items = try await SequelResolver.searchResults(title: sequelTitle, module: module, runner: runner)
                return (items: items, mediaID: sequelID)
            }
        }()

        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, streams: pendingStreams, context: context, onWatchNext: onWatchNext, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced)
        #elseif os(macOS)
        MacPlayerWindowManager.shared.open(stream: stream, streams: pendingStreams, context: context, onWatchNext: onWatchNext, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced)
        #endif
        selectedEpisodeNumber = nil
    }

    func downloadWithSelectedStream(_ stream: StreamResult) {
        #if os(iOS)
        guard let (episodeLink, epNum) = pendingDownloadEpisode,
              let module = pendingDownloadModule,
              let media = pendingDownloadMedia else { return }

        let ctx = DownloadContext(
            mediaTitle: media.title.displayTitle,
            episodeNumber: epNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: module.id,
            detailHref: "https://anilist.co/anime/\(media.id)",
            episodeHref: episodeLink.href,
            streamTitle: stream.title,
            totalEpisodes: media.episodes
        )
        DownloadManager.shared.download(stream: stream, episodeHref: episodeLink.href, context: ctx)

        // Clear pending state
        showDownloadStreamPicker = false
        pendingDownloadStreams = []
        pendingDownloadEpisode = nil
        pendingDownloadModule = nil
        pendingDownloadMedia = nil
        #endif
    }
}
