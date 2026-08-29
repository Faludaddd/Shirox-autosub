import Foundation
import Combine
import SwiftUI

/// Auto Pick Engine — v2.10 from-scratch rework.
///
/// Replaces the old `autoPickAndPlay()` in AniListDetailViewModel, which had
/// four structural problems: (1) zero UI feedback while it churned through
/// modules, (2) a duplicate-guard that permanently blocked new taps if a
/// module hung, (3) no per-module timeout, so one dead module stalled the
/// whole chain forever, and (4) it switched the app-wide active module
/// before every attempt, thrashing global state even when nothing worked.
///
/// This engine's contract:
///   * **One run at a time; new tap wins.** Starting a pick cancels any
///     in-flight run instead of refusing the tap.
///   * **Hard 25s budget per module.** A hung search/episode/stream fetch
///     counts as a failure and the chain moves on.
///   * **Global state is touched exactly once** — the active module is
///     switched only when a stream actually won, right before playback.
///   * **Visible progress, no overlays.** `activeMediaId`/`activeEpisode`/
///     `statusText` are published; the tapped episode row renders an inline
///     spinner + status line. Nothing floats above the UI.
///   * **Real stream scoring.** Resolution is parsed from the title
///     (2160/1440/1080/720/576/540/480/432/360/240), sub/dub is honoured,
///     HLS breaks ties. No more alphabetical "quality" sorting.
///   * **Honest failure.** If nothing worked, a toast explains why and the
///     manual stream picker opens — the user is never left with a dead tap.
@MainActor
final class AutoPickEngine: ObservableObject {
    static let shared = AutoPickEngine()

    // MARK: - Published state (observed by the episode row)

    /// Media currently being auto-picked. The episode row compares this
    /// (plus `activeEpisode`) against its own media/episode to decide
    /// whether to show the inline spinner.
    @Published private(set) var activeMediaId: Int? = nil
    /// Episode currently being auto-picked.
    @Published private(set) var activeEpisode: Int? = nil
    /// Short human-readable progress, e.g. "Trying HiAnime…".
    @Published private(set) var statusText: String = ""

    private var runTask: Task<Void, Never>? = nil
    /// Identifies the CURRENT run. A cancelled run's cleanup only clears
    /// the published state if it still owns it — a newer pick may have
    /// already taken over the same media/episode.
    private var currentRunId: UUID? = nil

    // MARK: - Settings keys (the only ones the engine actually reads)

    private let enabledKey = "autoPickModuleTesting"
    private let qualityKey = "autoPickPreferredQuality"    // Auto / Highest / Lowest / 1080p / 720p / 480p
    private let languageKey = "autoPickPreferredLanguage"  // Sub / Dub / Any
    private let priorityKey = "autoPickModulePriority"
    private let skipUnavailableKey = "autoPickSkipUnavailable"
    private let useFallbackKey = "autoPickUseFallback"

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    func isRunning(mediaId: Int, episode: Int) -> Bool {
        activeMediaId == mediaId && activeEpisode == episode
    }

    // MARK: - Entry point

    /// Starts an Auto Pick run for `episode`. Cancels any in-flight run —
    /// a new tap always wins over a stuck old one.
    func pick(media: Media, episode: Int, viewModel: AniListDetailViewModel) {
        runTask?.cancel()
        let runId = UUID()
        currentRunId = runId
        activeMediaId = media.id
        activeEpisode = episode
        statusText = "Starting…"
        let requestId = String(runId.uuidString.prefix(8))
        runTask = Task { [weak self] in
            await self?.run(media: media, episode: episode, viewModel: viewModel, requestId: requestId, runId: runId)
        }
    }

    /// Cancels the in-flight run (if any) and clears the row state.
    func cancel() {
        runTask?.cancel()
        clearActive()
    }

    private func clearActive() {
        activeMediaId = nil
        activeEpisode = nil
        statusText = ""
    }

    // MARK: - Errors

    private enum AutoPickError: LocalizedError, Equatable {
        case timedOut
        case noSearchResults
        case noEpisodes
        case episodeNotFound(Int)
        case noStreams
        case moduleError(String)

        var errorDescription: String? {
            switch self {
            case .timedOut:            return "timed out"
            case .noSearchResults:     return "no search results"
            case .noEpisodes:          return "no episodes"
            case .episodeNotFound(let ep): return "episode \(ep) not found"
            case .noStreams:           return "no streams"
            case .moduleError(let msg): return msg
            }
        }
    }

    // MARK: - Run

    private func run(media: Media, episode: Int, viewModel: AniListDetailViewModel, requestId: String, runId: UUID) async {
        let startedAt = Date()
        defer {
            // Only clean up if this run still owns the published state —
            // a newer pick for the same media may have already started.
            if currentRunId == runId { clearActive() }
        }

        // Read settings once at run start.
        let quality = UserDefaults.standard.string(forKey: qualityKey) ?? "Auto"
        let language = UserDefaults.standard.string(forKey: languageKey) ?? "Sub"
        let priority = UserDefaults.standard.stringArray(forKey: priorityKey) ?? []
        let skipUnavailable = UserDefaults.standard.bool(forKey: skipUnavailableKey)
        let useFallback = UserDefaults.standard.bool(forKey: useFallbackKey)

        Logger.shared.log("[AutoPick:\(requestId)] Started — EP \(episode) — \(media.title.displayTitle) — quality \(quality), language \(language), fallback \(useFallback)", type: "Info")

        let manager = ModuleManager.shared
        let allAnimeModules = manager.modules.filter {
            !$0.isManga && !$0.isNovel && !$0.isLocalPlayback && !$0.isJellyfin
        }

        // Priority list first (only IDs that still exist), then any modules
        // not in the list, so a stale priority entry never hides a module.
        let orderedModules: [ModuleDefinition] = {
            if priority.isEmpty { return allAnimeModules }
            return priority.compactMap { id in allAnimeModules.first { $0.id == id } }
                + allAnimeModules.filter { !priority.contains($0.id) }
        }()

        guard !orderedModules.isEmpty else {
            ToastManager.shared.show(
                title: "Auto Pick",
                message: "No anime modules installed. Install one from the Module Store.",
                icon: "exclamationmark.triangle.fill",
                iconColor: .red)
            return
        }

        // Fallback disabled → only the top eligible module gets a chance.
        var candidates = orderedModules
        if !useFallback {
            candidates = Array(candidates.prefix(1))
        }
        if skipUnavailable {
            candidates = candidates.filter { module in
                guard let health = manager.health(for: module) else { return true }
                return health.status != .error && health.status != .blocked
            }
        }

        guard !candidates.isEmpty else {
            ToastManager.shared.show(
                title: "Auto Pick",
                message: "Every module in your priority list is currently marked unavailable. Open the module list to check their status.",
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange)
            return
        }

        var failureSummary: [String] = []

        for module in candidates {
            if Task.isCancelled { return }

            statusText = "Trying \(module.sourceName)…"
            Logger.shared.log("[AutoPick:\(requestId)] Trying \(module.sourceName)", type: "Info")
            let attemptStarted = Date()

            // Hard budget per module: search + episodes + streams combined.
            let outcome = await withTimeout(seconds: 25) {
                do {
                    let success = try await self.attempt(module: module, media: media, episode: episode)
                    return .success(success)
                } catch let error as AutoPickError {
                    return .failure(error)
                } catch {
                    return .failure(.moduleError(error.localizedDescription))
                }
            }

            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(attemptStarted)

            switch outcome {
            case .timedOut:
                Logger.shared.log("[AutoPick:\(requestId)] \(module.sourceName) timed out after \(Int(elapsed))s — moving on", type: "Warning")
                manager.reportFailure(for: module.id, error: "Auto Pick timeout")
                failureSummary.append("\(module.sourceName): timed out")

            case .failure(let error):
                Logger.shared.log("[AutoPick:\(requestId)] \(module.sourceName) failed (\(error.localizedDescription)) after \(Int(elapsed))s", type: "Info")
                manager.reportFailure(for: module.id, error: error.localizedDescription)
                failureSummary.append("\(module.sourceName): \(error.localizedDescription)")

            case .success(let success):
                // Remember the alias + href so the manual flow benefits too.
                ModuleSearchAliasManager.shared.setLastSearchResultHref(
                    mediaId: media.id, animeTitle: media.title.searchTitle,
                    moduleId: module.id, href: success.searchResultHref)

                manager.reportSuccess(for: module.id)

                // THE ONLY global module switch — once, for the winner.
                _ = await manager.selectAndAwaitReady(module)

                statusText = "Starting playback…"
                Logger.shared.log("[AutoPick:\(requestId)] Winner: \(module.sourceName) — \(success.stream.title) — starting playback (\(Int(Date().timeIntervalSince(startedAt)))s total)", type: "Info")

                // selectStream reads selectedEpisodeNumber and presents the
                // player with the full stream list so in-player switching
                // works exactly like the manual flow.
                viewModel.selectedEpisodeNumber = episode
                viewModel.pendingStreams = success.allStreams
                viewModel.selectStream(
                    success.stream,
                    searchResultHref: success.searchResultHref,
                    episodeActualHref: success.episodeHref,
                    availableEpisodes: success.episodeCount,
                    onSequelAdvanced: nil)

                ToastManager.shared.show(
                    title: "Auto Pick",
                    message: "Playing via \(module.sourceName) — \(success.stream.title)",
                    icon: "play.circle.fill",
                    iconColor: .green,
                    duration: 3)
                return
            }
        }

        // Every candidate failed — be honest about it and hand control back.
        Logger.shared.log("[AutoPick:\(requestId)] All \(candidates.count) eligible modules failed (\(failureSummary.joined(separator: "; ")))", type: "Error")
        ToastManager.shared.show(
            title: "Auto Pick",
            message: "No playable stream found — \(failureSummary.prefix(2).joined(separator: "; "))\(failureSummary.count > 2 ? "…" : ""). Opening the manual picker.",
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            duration: 5)
        viewModel.showStreamPicker = true
    }

    // MARK: - Per-module attempt

    private struct AttemptSuccess {
        let searchResultHref: String
        let episodeHref: String
        let episodeCount: Int
        let stream: StreamResult
        let allStreams: [StreamResult]
    }

    /// Search → match → episodes → episode → streams, using a LOCAL runner.
    /// The global active module is NOT touched here.
    private func attempt(module: ModuleDefinition, media: Media, episode: Int) async throws -> AttemptSuccess {
        let runner = ModuleJSRunner()
        try await runner.load(module: module)

        // Per-module search alias (the old code only consulted the alias of
        // the first module in the list — a subtle wrong-module bug).
        let searchTitle = ModuleSearchAliasManager.shared.getAlias(
            mediaId: media.id, animeTitle: media.title.searchTitle, moduleId: module.id
        ) ?? media.title.searchTitle

        var results = try await runner.search(keyword: searchTitle)
        if results.isEmpty {
            // One quick retry — sources frequently hiccup on first hit.
            try? await Task.sleep(nanoseconds: 800_000_000)
            results = try await runner.search(keyword: searchTitle)
        }
        guard !results.isEmpty else { throw AutoPickError.noSearchResults }

        let ordered = SearchResultMatcher.ranked(
            query: media.title.searchTitle, items: results, title: { $0.title })
        guard let match = ordered.first else { throw AutoPickError.noSearchResults }

        let episodes = try await runner.fetchEpisodes(url: match.href)
        guard !episodes.isEmpty else { throw AutoPickError.noEpisodes }

        let target = Double(episode)
        guard let epLink = episodes.first(where: { $0.number == target })
                ?? episodes.first(where: { round($0.number) == target }) else {
            throw AutoPickError.episodeNotFound(episode)
        }

        let streams = try await runner.fetchStreams(episodeUrl: epLink.href)
        guard !streams.isEmpty else { throw AutoPickError.noStreams }

        let chosen = selectBestStream(streams)
        return AttemptSuccess(
            searchResultHref: match.href,
            episodeHref: epLink.href,
            episodeCount: episodes.count,
            stream: chosen,
            allStreams: streams.sorted { $0.title < $1.title })
    }

    // MARK: - Timeout

    private enum TimeoutResult {
        case success(AttemptSuccess)
        case failure(AutoPickError)
        case timedOut
    }

    /// Runs `operation` with a hard wall-clock budget. Returns `.timedOut`
    /// if the budget expires first (the underlying work is cancelled).
    private func withTimeout(seconds: Double, operation: @escaping () async -> TimeoutResult) async -> TimeoutResult {
        await withTaskGroup(of: TimeoutResult.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    // MARK: - Stream scoring

    /// Traits parsed out of a stream's title + URL.
    private struct StreamTraits {
        let resolution: Int      // 2160…240; 0 = unknown
        let isDub: Bool
        let isSub: Bool
        let isHLS: Bool
    }

    /// Resolutions we recognize, highest first.
    private static let knownResolutions: [Int] = [2160, 1440, 1080, 720, 576, 540, 480, 432, 360, 240]

    private func traits(for stream: StreamResult) -> StreamTraits {
        let title = stream.title.lowercased()
        let url = stream.url.absoluteString.lowercased()

        // Resolution: prefer explicit "1080p"-style markers, then bare numbers.
        var resolution = 0
        for n in Self.knownResolutions where title.contains("\(n)p") {
            resolution = n
            break
        }
        if resolution == 0 {
            for n in Self.knownResolutions where title.contains(String(n)) {
                resolution = n
                break
            }
        }

        // Language: explicit markers only. "SUB" wins over "DUB" when both
        // appear ("English Sub" is sub, not dub).
        let isDub = title.contains("dub")
        let isSub = title.contains("sub")

        return StreamTraits(
            resolution: resolution,
            isDub: isDub,
            isSub: isSub,
            isHLS: url.contains(".m3u8"))
    }

    /// Picks the best stream using the user's quality + language prefs.
    private func selectBestStream(_ streams: [StreamResult]) -> StreamResult {
        let preferredQuality = UserDefaults.standard.string(forKey: qualityKey) ?? "Auto"
        let preferredLanguage = UserDefaults.standard.string(forKey: languageKey) ?? "Sub"

        var pool = streams.map { (stream: $0, traits: traits(for: $0)) }

        // 1. Language: if any stream matches the preference, restrict to those.
        if preferredLanguage != "Any" {
            let wantDub = preferredLanguage == "Dub"
            let matching = pool.filter { wantDub ? $0.traits.isDub : $0.traits.isSub }
            if !matching.isEmpty { pool = matching }
        }

        // 2. Quality.
        func best(_ candidates: [(stream: StreamResult, traits: StreamTraits)],
                  _ better: (StreamTraits, StreamTraits) -> Bool) -> StreamResult {
            var bestPair = candidates[0]
            for pair in candidates.dropFirst() where better(pair.traits, bestPair.traits) {
                bestPair = pair
            }
            return bestPair.stream
        }

        /// Total ordering for "prefer this stream" decisions: higher
        /// resolution first, then HLS over progressive.
        func outranks(_ a: StreamTraits, _ b: StreamTraits) -> Bool {
            if a.resolution != b.resolution { return a.resolution > b.resolution }
            if a.isHLS != b.isHLS { return a.isHLS }
            return false
        }

        switch preferredQuality {
        case "Lowest":
            // Lowest known resolution; unknown (0) counts as lowest.
            return best(pool) { a, b in
                if a.resolution != b.resolution { return a.resolution < b.resolution }
                if a.isHLS != b.isHLS { return !a.isHLS }
                return false
            }
        case "Auto", "Highest", "":
            return best(pool, outranks)
        default:
            // A concrete target like "1080p" / "720p" / "480p".
            let targetDigits = preferredQuality.filter { $0.isNumber }
            let targetRes = Int(targetDigits) ?? 0

            if targetRes > 0 {
                // Exact resolution match (HLS breaks ties among equals).
                let exact = pool.filter { $0.traits.resolution == targetRes }
                if !exact.isEmpty { return best(exact, outranks) }

                // Nearest resolution ABOVE the target, else nearest below.
                let above = pool.filter { $0.traits.resolution > targetRes }
                if !above.isEmpty {
                    return best(above) { a, b in a.resolution < b.resolution }
                }
                let below = pool.filter { $0.traits.resolution > 0 && $0.traits.resolution < targetRes }
                if !below.isEmpty {
                    return best(below, outranks)
                }
            }
            // Targeted quality unknown to this source — take the best.
            return best(pool, outranks)
        }
    }
}
