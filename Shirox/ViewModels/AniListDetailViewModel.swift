import Foundation
import Combine

@MainActor
final class AniListDetailViewModel: ObservableObject {
    @Published var media: Media?
    @Published var isLoading = true
    @Published var error: String?
    /// True when the full-detail fetch failed. The preloaded media (from a
    /// list query) may still be set for the hero/metadata, but it lacks
    /// relations, characters, and recommendations. The UI uses this flag to
    /// show a "Tap to retry" prompt in the Relations section specifically,
    /// rather than hiding the whole page behind an error view.
    @Published var detailFetchFailed = false

    /// Raw AniList characters + recommendations + staff, fetched alongside
    /// `media` so `CharactersSection` / `RecommendationsSection` /
    /// `StaffSection` can render without a second network call.
    @Published var characters: [AniListCharacterEdge] = []
    @Published var recommendations: [AniListRecommendation] = []
    @Published var staff: [AniListStaffEdge] = []

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
        detailFetchFailed = false
        do {
            // AniList is the EXCLUSIVE source for Characters and Statistics.
            // MAL's detail endpoint returns fewer fields (no voice actors,
            // incomplete statistics), which previously caused an incomplete
            // Statistics section and a dead-end Characters section when the
            // MAL fallback fired. The MAL dual-source merge for these two
            // features has been removed — if AniList fails, the page shows
            // the error state instead of rendering partial MAL data.
            // (MAL fallback for other purposes — like the provider-level
            // rate-limit fallback for the Watch flow — is a separate system
            // and is NOT removed here.)
            let raw = try await AniListService.shared.detail(id: id)
            media = AniListProvider.shared.mapMedia(raw)
            // Pre-populate characters + recommendations + staff from the same fetch.
            characters = raw.characters?.edges ?? []
            recommendations = raw.recommendations?.nodes ?? []
            staff = raw.staff?.edges ?? []
            // AniList may not have banner art for every title; reuse the
            // already-cached TVDB fanart as a fallback.
            if media?.bannerImage == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: id, provider: .anilist)
                if let fanart = artwork.fanart {
                    media?.bannerImage = fanart
                }
            }
        } catch {
            // If we have a preloaded media (from a list query), DON'T set
            // self.error — that would hide the whole page behind an error
            // view, even though the hero/metadata are usable. Instead, set
            // detailFetchFailed so the Relations section can show a "Tap to
            // retry" prompt. The preloaded media lacks relations, characters,
            // and recommendations, but the hero/metadata/episodes are still
            // functional.
            // If we DON'T have a preloaded media, set self.error so the full
            // error view shows (there's nothing else to display).
            if preloaded != nil {
                detailFetchFailed = true
            } else {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Retries the detail fetch when the initial attempt failed (e.g. rate
    /// limit, network error). Called by the "Tap to retry" button in the
    /// Relations section when `detailFetchFailed` is true. Clears the flag,
    /// re-fetches, and updates `media` with the full data (including relations).
    func retryLoad(id: Int) async {
        detailFetchFailed = false
        isLoading = true
        do {
            let raw = try await AniListService.shared.detail(id: id)
            media = AniListProvider.shared.mapMedia(raw)
            characters = raw.characters?.edges ?? []
            recommendations = raw.recommendations?.nodes ?? []
            staff = raw.staff?.edges ?? []
            if media?.bannerImage == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: id, provider: .anilist)
                if let fanart = artwork.fanart {
                    media?.bannerImage = fanart
                }
            }
            error = nil
        } catch {
            // Retry also failed — set the flag again so the user can retry
            // once more.
            detailFetchFailed = true
        }
        isLoading = false
    }

    /// Opens the manual module-and-stream picker for the given episode.
    /// No automatic module selection, no automatic stream selection —
    /// the user picks the module, then picks the stream, then playback
    /// starts. This is the original manual workflow restored.
    func watchEpisode(_ number: Int) {
        selectedEpisodeNumber = number
        showStreamPicker = true
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
