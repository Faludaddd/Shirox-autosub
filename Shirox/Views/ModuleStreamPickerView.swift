import SwiftUI
import Combine

// MARK: - VM Store

@MainActor
private final class ModuleStreamVMStore: ObservableObject {
    var viewModels: [String: ModuleStreamRowViewModel] = [:]

    func get(for module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int) -> ModuleStreamRowViewModel {
        if let vm = viewModels[module.id] { return vm }
        let vm = ModuleStreamRowViewModel(module: module, mediaId: mediaId, animeTitle: animeTitle, targetEpisodeNumber: episodeNumber)
        viewModels[module.id] = vm
        return vm
    }
}

// MARK: - Row ViewModel

@MainActor
private final class ModuleStreamRowViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case searchResults([SearchItem])
        case loadingEpisodes(SearchItem)
        case selectingEpisode([EpisodeLink])
        case loadingStreams
        case notFound
        case error(String)
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?
    @Published var selectedEpisodeHref: String?  // Show/search-result href (used to re-fetch the episode list)
    @Published var selectedEpisodeActualHref: String?  // The matched episode's own unique href (anchors Next Episode)
    @Published var availableCount: Int?        // Track total episodes in this module result
    @Published var cloudflareURL: URL?         // Set when *this* module's runner hit a Turnstile wall

    /// Captures whether this row's runner hit Cloudflare, then transitions to a settled state.
    private func settle(_ newState: State) {
        cloudflareURL = runner?.lastTurnstileURL
        state = newState
    }

    let module: ModuleDefinition
    let mediaId: Int?
    let originalAnimeTitle: String
    let targetEpisodeNumber: Int

    private var runner: ModuleJSRunner?
    private var currentTask: Task<Void, Never>?
    private var currentSearchResultHref: String?  // Track active search result for manual episode selection

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, targetEpisodeNumber: Int) {
        self.module = module
        self.mediaId = mediaId
        self.originalAnimeTitle = animeTitle
        self.targetEpisodeNumber = targetEpisodeNumber
        
        // Load custom alias if available, otherwise fallback to original title
        if let alias = ModuleSearchAliasManager.shared.getAlias(mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) {
            self.searchTitle = alias
        } else {
            self.searchTitle = animeTitle
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func cancelIfSearching() {
        switch state {
        case .loading, .loadingEpisodes, .loadingStreams:
            currentTask?.cancel()
            currentTask = nil
            state = .idle
        default:
            break
        }
    }

    func startFind() {
        guard case .idle = state else { return }
        persistSearchTitle()
        // Always run a fresh search — no fast-path skipping via the
        // saved search-result href. The user explicitly opened the
        // picker, so they want to see live results from the module.
        currentTask = Task { await find() }
    }

    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        persistSearchTitle()
        ModuleSearchAliasManager.shared.setLastSearchResultHref(
            mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, href: item.href)
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }

    private func persistSearchTitle() {
        ModuleSearchAliasManager.shared.setAlias(
            mediaId: mediaId,
            animeTitle: originalAnimeTitle,
            moduleId: module.id,
            alias: searchTitle
        )
    }

    func startSelectEpisode(_ episode: EpisodeLink) {
        currentTask = Task { await selectEpisode(episode) }
    }

    /// Franchise episodes preceding this AniList season, so a combined-season module list can be
    /// indexed to the right season. 0 for module-only flows (no AniList id) or single-season shows.
    private func seasonOffset() async -> Int {
        guard let mediaId else { return 0 }
        return await SeasonChainMapper.shared.resolveOffset(anchorAniListID: mediaId, anchorMALID: nil) ?? 0
    }

    func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            var results = try await r.search(keyword: keyword)

            if results.isEmpty {
                // Some modules (e.g. animepahe) need a warm session before search works;
                // retry once automatically before showing "Not Found".
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                results = try await r.search(keyword: keyword)
            }

            if results.isEmpty {
                settle(.notFound)
            } else {
                // Surface the entry that matches the AniList title's season first, so multi-season
                // shows (separate per-season entries) don't bury the right one behind look-alikes.
                let ordered = SearchResultMatcher.ranked(query: originalAnimeTitle, items: results, title: { $0.title })
                settle(.searchResults(ordered))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    func selectResult(_ item: SearchItem, targetEpisodeNumber: Int) async {
        guard let r = runner else { return }
        state = .loadingEpisodes(item)
        currentSearchResultHref = item.href

        do {
            var episodes = try await r.fetchEpisodes(url: item.href)
            if episodes.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await r.fetchEpisodes(url: item.href)
            }
            availableCount = episodes.count

            if let matched = matchEpisode(from: episodes, target: targetEpisodeNumber, seasonOffset: await seasonOffset()) {
                state = .loadingStreams
                selectedEpisodeHref = item.href
                selectedEpisodeActualHref = matched.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    settle(.error("No streams found for episode \(targetEpisodeNumber)"))
                } else {
                    readyStreams = streams
                }
            } else {
                settle(.selectingEpisode(episodes))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    /// Finds the episode matching `target`, handling modules that use absolute episode
    /// numbering (e.g., Season 2 numbered as episodes 25–48 instead of 1–24).
    ///
    /// `seasonOffset` is the number of franchise episodes preceding this AniList season. When
    /// the module concatenates every season into one list (e.g. AniWorld groups all seasons
    /// under one show, numbering restarts per season), a per-season number like "1" is
    /// ambiguous and the exact match would grab season 1. With a known offset we select by
    /// absolute position instead — but only when the list is actually long enough to contain
    /// that season, so single-season lists fall straight through to the existing logic.
    private func matchEpisode(from episodes: [EpisodeLink], target: Int, seasonOffset: Int = 0) -> EpisodeLink? {
        let targetDouble = Double(target)

        // 0. Combined multi-season list: pick by absolute position.
        if seasonOffset > 0 {
            let absoluteIndex = seasonOffset + target - 1 // 0-based
            if episodes.indices.contains(absoluteIndex) {
                return episodes[absoluteIndex]
            }
        }

        // 1. Exact match
        if let exact = episodes.first(where: { $0.number == targetDouble }) {
            return exact
        }

        // 2. Rounded match — catches modules that label ep 1 as 1.0 but ep 1.5 as a special
        if let rounded = episodes.first(where: { round($0.number) == targetDouble }) {
            return rounded
        }

        // 3. Offset match — module uses absolute numbering (e.g., S2 = eps 25–48).
        //    Only apply when every episode number exceeds the target, meaning the
        //    module doesn't start at 1 for this season.
        if let minEp = episodes.map(\.number).min(), minEp > targetDouble {
            let offsetTarget = minEp + targetDouble - 1
            if let offset = episodes.first(where: { $0.number == offsetTarget }) {
                return offset
            }
        }

        return nil
    }

    func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty {
                settle(.error("No streams found"))
            } else {
                // Use the current search result href if available (from manual episode selection)
                if let href = currentSearchResultHref {
                    selectedEpisodeHref = href
                }
                selectedEpisodeActualHref = episode.href
                readyStreams = streams
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        readyStreams = nil
        runner = nil
        currentSearchResultHref = nil
        cloudflareURL = nil
    }

    /// Runs the user-initiated Cloudflare challenge for this module, then re-runs the search.
    func verifyAndRetry() {
        guard let url = cloudflareURL else { return }
        Task {
            try? await CloudflareBypassManager.shared.triggerBypass(for: url)
            reset()
            startFind()
        }
    }
}



// MARK: - Sheet

/// Fully custom Change Stream UI.
///
/// Replaces the previous iOS-default List with a custom design that
/// matches the rest of the app: card-based module grid, custom stream
/// rows with quality badges, in-card loading/error/empty states, and a
/// persistent header showing what episode we're picking a stream for.
///
/// Module list is filtered at the data-source level — only anime modules
/// (modules where `isManga == false`) are returned by `visibleModules`.
/// Manga modules are never present in the array, so they cannot appear
/// in the UI regardless of which code path renders them.
struct ModuleStreamPickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], StreamResult?, String?, Int?, String?) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var vmStore = ModuleStreamVMStore()
    @State private var query: String = ""
    @State private var selectedModuleId: String? = nil

    /// Anime modules only — the underlying filter. Manga modules are
    /// excluded here at the data-source layer so they can never reach
    /// any rendering code path. We also filter out local-playback and
    /// Jellyfin pseudo-modules (they have their own entry points).
    private var animeModules: [ModuleDefinition] {
        moduleManager.modules.filter { !$0.isManga && !$0.isNovel && !$0.isLocalPlayback && !$0.isJellyfin }
    }

    private var visibleModules: [ModuleDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return animeModules }
        return animeModules.filter { $0.sourceName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    episodeHeader
                    moduleSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(platformBackground.ignoresSafeArea())
            .navigationTitle("Change Stream")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
        }
        #if os(iOS)
        .adaptivePresentationDetents([.large])
        #else
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color.black.opacity(0.05)
        #endif
    }

    // MARK: Episode header

    @ViewBuilder
    private var episodeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("Episode \(episodeNumber)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(animeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    // MARK: Module section

    @ViewBuilder
    private var moduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Modules")
                    .font(.headline)
                Spacer()
                Text("\(visibleModules.count) available")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                // Settings button — opens the existing Modules Settings page
                // (where the user can install / remove / reorder modules).
                // Uses the same custom design language as the rest of the
                // Change Stream UI: 36×36 ultraThinMaterial circle with a
                // 15%-opacity strokeBorder. Subtle scale-up on press.
                #if os(iOS)
                NavigationLink {
                    ModulesSettingsPage()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Haptics.light() })
                #endif
            }
            .padding(.horizontal, 4)

            // Search field — only shown when there are 4+ modules so it
            // doesn't clutter the UI for users with just 1–3 modules.
            if animeModules.count >= 4 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Filter modules", text: $query)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }

            if animeModules.isEmpty {
                EmptyStateView(
                    icon: "puzzlepiece.extension",
                    title: "No Anime Modules Installed",
                    message: "Install an anime module from Settings → Modules → Module Store to start watching."
                )
            } else if visibleModules.isEmpty && !query.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Matches",
                    message: "No modules match \"\(query)\". Try a different search."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visibleModules) { module in
                        ModuleCard(
                            module: module,
                            isSelected: selectedModuleId == module.id,
                            rowVm: vmStore.get(for: module, mediaId: mediaId, animeTitle: animeTitle, episodeNumber: episodeNumber),
                            episodeNumber: episodeNumber,
                            onSelect: {
                                Haptics.light()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    // TOGGLE — was previously a one-way "set"
                                    // (always assigned module.id, never
                                    // collapsed). Now: tapping a selected
                                    // module collapses it; tapping a different
                                    // module expands it. Multiple modules
                                    // stay independent because only one
                                    // selectedModuleId is set at a time.
                                    if selectedModuleId == module.id {
                                        selectedModuleId = nil
                                    } else {
                                        selectedModuleId = module.id
                                    }
                                }
                                // Kick off search on first expansion.
                                // If we're collapsing, no need to start a search.
                                if selectedModuleId == module.id {
                                    let vm = vmStore.get(for: module, mediaId: mediaId, animeTitle: animeTitle, episodeNumber: episodeNumber)
                                    if case .idle = vm.state {
                                        vm.startFind()
                                    }
                                }
                            },
                            onStreamSelected: { stream, allStreams, href, count, episodeHref in
                                moduleManager.selectModule(module)
                                onDismiss()
                                onStreamsLoaded(allStreams, stream, href, count, episodeHref)
                            },
                            onDismissPicker: onDismiss
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Module Card

/// Custom module card with built-in search-result + episode + stream
/// selection UI. Replaces the previous iOS-List row with a fully
/// custom card that:
///  - Shows the module icon + name + language + version
///  - Highlights when selected
///  - Shows loading skeleton / search results / episode picker /
///    stream picker / error state INSIDE the card
///  - Handles Cloudflare inline (no system alert)
private struct ModuleCard: View {
    let module: ModuleDefinition
    let isSelected: Bool
    @ObservedObject var rowVm: ModuleStreamRowViewModel
    let episodeNumber: Int
    let onSelect: () -> Void
    let onStreamSelected: (StreamResult, [StreamResult], String?, Int?, String?) -> Void
    let onDismissPicker: () -> Void

    @State private var showAllResults = false
    @State private var showStreamPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isSelected {
                stateContent
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.appAccent.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onSelect() }
        .onChangeOf(rowVm.readyStreams) { streams in
            guard let streams else { return }
            // Single stream → it's the only choice, auto-select it.
            // Multiple streams → ALWAYS show the manual picker. No
            // "auto-pick last stream" shortcut — the user must
            // explicitly choose which stream to play.
            if streams.count == 1 {
                fireStreamSelected(streams[0], allStreams: streams)
            } else {
                showStreamPicker = true
            }
        }
        .adaptiveSheet(isPresented: $showStreamPicker) {
            if let streams = rowVm.readyStreams {
                CustomStreamSelectionView(
                    streams: streams,
                    onSelect: { stream in
                        ModuleSearchAliasManager.shared.setLastStreamTitle(moduleId: module.id, title: stream.title)
                        showStreamPicker = false
                        let allStreams = rowVm.readyStreams ?? [stream]
                        fireStreamSelected(stream, allStreams: allStreams)
                    },
                    onDismiss: {
                        showStreamPicker = false
                        rowVm.reset()
                    }
                )
            }
        }
        .adaptiveSheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                SearchResultsPickerSheet(items: items, module: module) { item in
                    showAllResults = false
                    rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                }
            }
        }
    }

    private func fireStreamSelected(_ stream: StreamResult, allStreams: [StreamResult]) {
        UserDefaults.standard.set(module.id, forKey: "lastUsedModuleId")
        onStreamSelected(stream, allStreams, rowVm.selectedEpisodeHref, rowVm.availableCount, rowVm.selectedEpisodeActualHref)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(module.sourceName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let lang = module.language, !lang.isEmpty {
                        Text(lang)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    if let quality = module.quality, !quality.isEmpty {
                        Text(quality)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.appAccent.opacity(0.12)))
                    }
                }
            }
            Spacer()
            // Selection indicator
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? Color.appAccent : Color.secondary.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                if isSelected {
                    Circle()
                        .fill(Color.appAccent)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: State content

    @ViewBuilder
    private var stateContent: some View {
        switch rowVm.state {
        case .idle:
            EmptyView()

        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching for \"\(rowVm.searchTitle)\"…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Loading skeleton — 3 shimmer rows
                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 36)
                            .shimmer()
                    }
                }
            }

        case .loadingEpisodes(let item):
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Loading episodes for \"\(item.title)\"…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loadingStreams:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Fetching streams…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .searchResults(let items):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Search Results")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAllResults = true
                    } label: {
                        Label("Show All", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                Haptics.light()
                                rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                            } label: {
                                SearchResultCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 2)
                }
                if rowVm.cloudflareURL != nil {
                    CloudflareVerifyInlineButton(onVerify: { rowVm.verifyAndRetry() })
                }
            }

        case .selectingEpisode(let episodes):
            VStack(alignment: .leading, spacing: 8) {
                Text("Episode not auto-matched — pick manually:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            Button {
                                Haptics.light()
                                rowVm.startSelectEpisode(ep)
                            } label: {
                                Text("Ep \(ep.displayNumber)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 8) {
                if rowVm.cloudflareURL != nil {
                    Label("Blocked by Cloudflare", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    CloudflareVerifyInlineButton(onVerify: { rowVm.verifyAndRetry() })
                } else {
                    Label("No results found", systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Haptics.light()
                        rowVm.reset()
                        rowVm.startFind()
                    } label: {
                        Label("Retry Search", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button {
                    Haptics.light()
                    rowVm.reset()
                    rowVm.startFind()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}

// MARK: - Compact search result card

private struct SearchResultCard: View {
    let item: SearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 72)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: item.image)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.8), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)

            Text(item.title)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .frame(width: 72, height: 32, alignment: .topLeading)
                .foregroundStyle(.primary)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

// MARK: - Full results picker sheet

private struct SearchResultsPickerSheet: View {
    let items: [SearchItem]
    let module: ModuleDefinition
    let onSelect: (SearchItem) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Color.clear
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .overlay(
                                        ZStack {
                                            CachedAsyncImage(urlString: item.image)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .clipped()
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .clear, location: 0.5),
                                                    .init(color: .black.opacity(0.85), location: 1)
                                                ],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        }
                                    )
                                    .overlay(alignment: .bottomLeading) {
                                        Text(item.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 8)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(module.sourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])
        #else
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

// MARK: - Custom Stream Selection View

/// Fully custom stream picker — replaces the iOS-default List with
/// card-based rows that show quality badges, subtitle availability,
/// server name, and a clear selected indicator.
private struct CustomStreamSelectionView: View {
    let streams: [StreamResult]
    let onSelect: (StreamResult) -> Void
    let onDismiss: () -> Void

    @State private var selectedStreamURL: URL?

    private var sortedStreams: [StreamResult] {
        // Sort: HLS streams first, then by quality score, then alphabetically.
        streams.sorted { a, b in
            let aHLS = a.url.absoluteString.contains(".m3u8")
            let bHLS = b.url.absoluteString.contains(".m3u8")
            if aHLS != bHLS { return aHLS && !bHLS }
            let qa = qualityScore(a.title)
            let qb = qualityScore(b.title)
            return qa != qb ? qa > qb : a.title < b.title
        }
    }

    private func qualityScore(_ title: String) -> Int {
        let l = title.lowercased()
        if l.contains("1080") { return 100 }
        if l.contains("720")  { return 80 }
        if l.contains("480")  { return 60 }
        if l.contains("360")  { return 40 }
        return 50
    }

    private func qualityBadge(_ title: String) -> String? {
        let l = title.lowercased()
        if l.contains("1080") { return "1080p" }
        if l.contains("720")  { return "720p" }
        if l.contains("480")  { return "480p" }
        if l.contains("360")  { return "360p" }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // Stream count header
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(streams.count) stream\(streams.count == 1 ? "" : "s") available")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    ForEach(sortedStreams, id: \.url) { stream in
                        streamRow(stream)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Select Stream")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
            .tint(.primary)
        }
        #if os(iOS)
        .adaptivePresentationDetents([.large])
        #else
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    @ViewBuilder
    private func streamRow(_ stream: StreamResult) -> some View {
        let isSelected = selectedStreamURL == stream.url
        Button {
            Haptics.light()
            selectedStreamURL = stream.url
            // Slight delay so the user sees the selected state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                onSelect(stream)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.appAccent : Color.secondary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: isSelected ? "checkmark" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .primary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let badge = qualityBadge(stream.title) {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.appAccent.opacity(0.12)))
                        }
                        if stream.url.absoluteString.contains(".m3u8") {
                            Text("HLS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                        }
                        if stream.subtitle != nil {
                            Label("Soft subs", systemImage: "captions.bubble.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Label("No subs", systemImage: "captions.bubble")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.appAccent.opacity(0.6) : Color.primary.opacity(0.06),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
