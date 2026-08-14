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
    /// module, WITHOUT showing the ModuleStreamPickerView. This is the fix
    /// for "tapping Watch Anime opens another selection UI" — the user
    /// already picked a module via the toolbar module selector, so we
    /// should just use it. If resolution fails, show an error toast and
    /// NEVER fall back to the old module-selection picker.
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
            // No anime module installed — show a toast, NOT the picker.
            ToastManager.shared.show(
                title: "No Anime Module",
                message: "Install an anime module from Settings to watch episodes.",
                icon: "puzzlepiece.extension",
                iconColor: .orange
            )
            return
        }

        // Ensure the chosen module is the active one (loads its JS).
        if manager.activeModule?.id != module.id {
            _ = await manager.selectAndAwaitReady(module)
        }

        // Use the same ModuleJSRunner path as ModuleStreamRow, but drive
        // it directly instead of presenting a row UI.
        let runner = ModuleJSRunner()
        let searchTitle = ModuleSearchAliasManager.shared.getAlias(
            mediaId: media.id, animeTitle: media.title.searchTitle, moduleId: module.id
        ) ?? media.title.searchTitle

        do {
            // Load the module's JS into the runner first.
            try await runner.load(module: module)

            // 1. Search the module for the title.
            var results = try await runner.search(keyword: searchTitle)
            if results.isEmpty {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                results = try await runner.search(keyword: searchTitle)
            }
            guard !results.isEmpty else {
                ToastManager.shared.show(
                    title: "Not Found",
                    message: "\"\(media.title.searchTitle)\" wasn't found in \(module.sourceName). Try another module.",
                    icon: "magnifyingglass",
                    iconColor: .orange
                )
                return
            }
            // Pick the best-ranked result (same logic as ModuleStreamRow).
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
                ToastManager.shared.show(
                    title: "No Episodes",
                    message: "\(module.sourceName) returned no episodes for this title.",
                    icon: "tv.slash",
                    iconColor: .orange
                )
                return
            }

            // 3. Match the target episode (same logic as ModuleStreamRow).
            let offset = await SeasonChainMapper.shared.resolveOffset(
                anchorAniListID: media.id, anchorMALID: nil) ?? 0
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
                ToastManager.shared.show(
                    title: "Episode Not Found",
                    message: "Episode \(episode) isn't available in \(module.sourceName).",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
                return
            }

            // 4. Fetch streams for the matched episode.
            let streams = try await runner.fetchStreams(episodeUrl: matched.href)
            guard !streams.isEmpty else {
                ToastManager.shared.show(
                    title: "No Streams",
                    message: "No playable streams found for episode \(episode).",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
                return
            }

            // 5. Hand off to the existing onStreamsLoaded path — if there's
            // exactly one stream, it auto-plays; if multiple, the final
            // stream picker shows (quality picker, NOT module picker).
            let sorted = streams.sorted { $0.title < $1.title }
            // Remember the alias + href for next time.
            ModuleSearchAliasManager.shared.setLastSearchResultHref(
                mediaId: media.id, animeTitle: media.title.searchTitle,
                moduleId: module.id, href: match.href)
            onStreamsLoaded(sorted, selectedStream: nil, episodeHref: match.href,
                            availableCount: episodes.count, actualEpisodeHref: matched.href)
        } catch {
            // Resolution failed (network, module error, etc.) — show a
            // toast, NOT the picker. Cancellation is silent (expected when
            // the user navigates away mid-resolve).
            if !ProviderManager.isCancellationError(error) {
                ToastManager.shared.show(
                    title: "Playback Error",
                    message: error.localizedDescription,
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red
                )
            }
        }
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
