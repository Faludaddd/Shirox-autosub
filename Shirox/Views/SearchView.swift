import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryManager()
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared
    @ObservedObject private var appMode = AppModeManager.shared
    // #90 — Sources picker (custom card sheet) replaces the old Modules toolbar button.
    @State private var showSources = false
    @State private var showFilters = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isLandscape = false
    // A SINGLE file importer drives both phases. Two `.fileImporter` modifiers in one view
    // tree collide in SwiftUI (only one ever presents, regardless of separate background
    // views), so we switch `allowedContentTypes` by phase instead.
    @State private var showFileImporter = false
    @State private var importPhase: LocalImportPhase = .video
    @State private var pendingSubtitle: SubtitleTrack?
    @State private var addSubtitleUpFront = false
    // When a subtitle is wanted, the video is picked first and staged (copied) here; it only
    // plays once a subtitle is chosen or explicitly skipped.
    @State private var pendingVideoURL: URL?
    @State private var pendingVideoTitle: String?
    /// Debounce task for live search-as-you-type. Cancelled and restarted on each
    /// keystroke so we only search after the user stops typing for 500ms.
    @State private var liveSearchTask: Task<Void, Never>?

    private var isLocalModule: Bool { moduleManager.activeModule?.isLocalPlayback == true }
    private var isJellyfinModule: Bool { moduleManager.activeModule?.isJellyfin == true }

    /// True when the app is in Reading Mode. Search filters its content
    /// accordingly: manga-only results in Reading Mode, anime-only results
    /// in Anime Mode. The same SearchView instance is reused across both
    /// modes — no duplicate search system.
    private var isMangaMode: Bool { appMode.mode == .reading }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    private var columnCount: Int {
        #if os(iOS)
        guard sizeClass == .regular else { return 2 }
        return isLandscape ? 5 : 4
        #else
        return 4
        #endif
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    private var usingModule: Bool {
        // Issue #3 — Search always uses AniList directly. Even when a
        // streaming module is active, search queries AniList (not the
        // module). Modules are only used for streaming, not for search.
        false
    }
    private var primaryProvider: ProviderType { providerManager.orderedProviders.first?.providerType ?? .anilist }

    var body: some View {
        NavigationStack {
            mainContent
                .background(SearchActivationObserver { vm.clearResults() })
                .navigationTitle(isMangaMode ? "Search Manga" : "Search")
                .toolbar {
                    // Sources picker — only when not using a local/Jellyfin
                    // module (those don't use the provider system).
                    ToolbarItem(placement: .automatic) {
                        if !isLocalModule && !isJellyfinModule {
                            sourcesButton
                        }
                    }
                    // Issue #10 — Filter button is ALWAYS visible. Search is
                    // AniList-only (per prior requirement), so filters always
                    // apply. Even when a streaming module is active, the
                    // user can still filter the AniList metadata search.
                    ToolbarItem(placement: .automatic) {
                        if !isLocalModule && !isJellyfinModule {
                            filterButton
                        }
                    }
                }
                .modifier(ConditionalSearchable(enabled: !isLocalModule && !isJellyfinModule, text: $vm.query))
                .onSubmit(of: .search) {
                    history.add(vm.query)
                    vm.search(usingModule: usingModule, isMangaMode: isMangaMode)
                }
                .onChangeOf(vm.query) { new in
                    if new.isEmpty {
                        liveSearchTask?.cancel()
                        vm.clearResults()
                    } else {
                        // Live search: debounce 500ms, then search automatically.
                        // Cancels any pending search from the previous keystroke so
                        // fast typing doesn't queue up multiple requests.
                        liveSearchTask?.cancel()
                        liveSearchTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                vm.search(usingModule: usingModule, isMangaMode: isMangaMode)
                            }
                        }
                    }
                }
                .onChangeOf(moduleManager.moduleReadyId) { newId in
                    guard !vm.query.isEmpty, newId != nil else { return }
                    vm.search(usingModule: usingModule, isMangaMode: isMangaMode)
                }
                .onChangeOf(moduleManager.activeModule) { newModule in
                    guard !vm.query.isEmpty, newModule == nil else { return }
                    vm.search(usingModule: false, isMangaMode: isMangaMode)
                }
                .onChangeOf(providerManager.orderedProviders.first?.providerType) {
                    guard !vm.query.isEmpty, !usingModule else { return }
                    vm.search(usingModule: false, isMangaMode: isMangaMode)
                }
                // Mode switch: clear results and re-search if a query is
                // pending. The result set is mode-specific (anime vs manga)
                // so a stale cross-mode result set must never persist.
                .onChangeOf(appMode.mode) { _ in
                    vm.clearResults()
                    if !vm.query.isEmpty {
                        vm.search(usingModule: usingModule, isMangaMode: isMangaMode)
                    }
                }
                .navigationDestinationCompat(item: $surpriseDestination) { media in
                    if isMangaMode {
                        AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                    } else {
                        AniListDetailView(mediaId: media.id, preloadedMedia: media)
                    }
                }
        }
        .task { await loadRecommendations() }
        #if os(iOS)
        .adaptiveSheet(isPresented: $showSources) {
            SourcesPickerSheet()
                .background(.ultraThinMaterial)
        }
        #endif
        .adaptiveSheet(isPresented: $showFilters) {
            // #91 — pass the last-applied result count + hasSearched so the sheet
            // can show a live "N results" preview / "Apply to update" hint at the bottom.
            SearchFilterSheet(
                filters: $vm.filters,
                currentResultCount: vm.resultCount,
                hasSearched: vm.hasSearched,
                isMangaMode: isMangaMode
            ) {
                vm.search(usingModule: usingModule, isMangaMode: isMangaMode)
            }
            // #100 — Liquid-glass backdrop for the modal sheet.
            .background(.ultraThinMaterial)
        }
        #if os(iOS)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { isLandscape = geo.size.width > geo.size.height }
                    .onChangeOf(geo.size) { size in isLandscape = size.width > size.height }
            }
        )
        #endif
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            #endif
        }
    }

    // MARK: - Main Content
    @ViewBuilder
    private var mainContent: some View {
        if isJellyfinModule {
            JellyfinEntryView()
        } else if isLocalModule {
            localEntryView
        } else if vm.hasResults || vm.isLoading || vm.hasSearched || !vm.query.isEmpty {
            // Active search state — show results, loading, or error.
            // History is NOT shown underneath results.
            if vm.isLoading {
                loadingView
            } else if let err = vm.errorMessage {
                emptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Something went wrong",
                    subtitle: err
                )
            } else if !vm.hasResults && !vm.query.isEmpty {
                ContentUnavailableView.search(text: vm.query)
            } else if vm.hasResults {
                resultsView
            } else {
                // hasSearched but no results and empty query — show empty state
                searchEmptyState
            }
        } else if vm.query.isEmpty && !history.queries.isEmpty {
            // History section — its own state. Shows previous searches
            // with a small Surprise Me icon instead of the big button.
            historyView
        } else {
            // Fresh empty state — no history, no search yet.
            // Shows recommendations + big Surprise Me button.
            searchEmptyState
        }
    }

    // MARK: - Local Playback Entry

    /// The video is always chosen first. While "Add subtitle file" is on, the first pick stages
    /// the video and the second pick is the subtitle; otherwise the video plays immediately.
    /// Driving the button label off this makes each step explicit, so the user always knows
    /// which file the (otherwise identical-looking) Files picker is asking for.
    private var needsVideoStep: Bool { pendingVideoURL == nil }

    private var localStepDescription: String {
        if !needsVideoStep {
            return "Step 2 of 2 — choose a subtitle file for this video."
        }
        return addSubtitleUpFront
            ? "Step 1 of 2 — choose the video, then you'll add a subtitle."
            : "Pick a video from Files to play it in Shirox."
    }

    private var localEntryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Play a Local File")
                    .font(.headline)
                Text(localStepDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Toggle("Add subtitle file", isOn: $addSubtitleUpFront)
                .fixedSize()
                .disabled(!needsVideoStep)   // locked once a video is staged; clear it to change
                .onChangeOf(addSubtitleUpFront) { _ in clearStagedVideo() }

            // Feedback: show the staged video (and let the user drop it) before the subtitle step.
            if let title = pendingVideoTitle {
                HStack(spacing: 8) {
                    Image(systemName: "film.fill")
                        .foregroundStyle(.green)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        clearStagedVideo()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Button {
                importPhase = needsVideoStep ? .video : .subtitle
                showFileImporter = true
            } label: {
                Label(needsVideoStep ? "Choose video file" : "Choose subtitle file",
                      systemImage: needsVideoStep ? "play.rectangle.on.rectangle" : "captions.bubble")
                    .font(.headline)
                    .foregroundStyle(platformBackground)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            // On the subtitle step, allow playing the staged video without one.
            if !needsVideoStep {
                Button("Play without subtitle") { playStaged(subtitle: nil) }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: pendingVideoURL)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: importPhase == .subtitle ? subtitleContentTypes : videoContentTypes,
                      allowsMultipleSelection: false) { result in
            switch importPhase {
            case .video:
                guard case .success(let urls) = result, let url = urls.first else { return }
                if addSubtitleUpFront {
                    // Stage: copy now (the picker's scope is transient) and move to the subtitle step.
                    pendingVideoTitle = url.deletingPathExtension().lastPathComponent
                    pendingVideoURL = LocalPlaybackCoordinator.shared.importVideo(from: url) ?? url
                } else {
                    LocalPlaybackCoordinator.shared.playPickedVideo(url, subtitle: nil)
                }
            case .subtitle:
                // Cancelling leaves the user on the subtitle step (they can retry or skip).
                guard case .success(let urls) = result, let url = urls.first else { return }
                playStaged(subtitle: LocalPlaybackCoordinator.shared.importSubtitle(from: url))
            }
        }
    }

    /// Launches the staged video with an optional subtitle, then resets the staged state.
    private func playStaged(subtitle: SubtitleTrack?) {
        guard let video = pendingVideoURL else { return }
        LocalPlaybackCoordinator.shared.launch(videoURL: video, subtitle: subtitle, resumeFrom: nil)
        pendingVideoURL = nil
        pendingVideoTitle = nil
        pendingSubtitle = nil
    }

    /// Drops a staged (already-copied) video and reclaims its copy.
    private func clearStagedVideo() {
        if let url = pendingVideoURL, let name = LocalPlaybackCoordinator.shared.importName(for: url) {
            LocalPlaybackCoordinator.shared.removeImport(name: name)
        }
        pendingVideoURL = nil
        pendingVideoTitle = nil
        pendingSubtitle = nil
    }

    private var videoContentTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data]
    }

    private var subtitleContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .data]
        if let vtt = UTType(filenameExtension: "vtt") { types.insert(vtt, at: 0) }
        if let srt = UTType(filenameExtension: "srt") { types.insert(srt, at: 0) }
        return types
    }

    // MARK: - Results Grid
    private var resultsView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                if !vm.aniListResults.isEmpty {
                    ForEach(vm.aniListResults) { media in
                        NavigationLink {
                            // Mode-aware destination: manga detail in Reading
                            // Mode, anime detail in Anime Mode. Even if a
                            // title exists as both anime and manga, the
                            // destination follows the active mode so anime
                            // results never appear in Reading Mode.
                            if isMangaMode {
                                AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                            } else {
                                AniListDetailView(mediaId: media.id, preloadedMedia: media)
                            }
                        } label: {
                            AniListCardView(media: media)
                                .equatable()
                        }
                        .buttonStyle(CardPressStyle())
                    }
                } else {
                    ForEach(vm.moduleResults) { item in
                        NavigationLink {
                            if moduleManager.activeModule?.isManga == true || isMangaMode {
                                MangaDetailView(item: item)
                            } else {
                                DetailView(item: item)
                            }
                        } label: {
                            AnimeCardView(item: item)
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.25), value: vm.resultCount)
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Searching…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History View
    /// Search History section — its own state, shown when the query is
    /// empty and there are previous searches. Includes a small Surprise Me
    /// icon in the header instead of the big button.
    private var historyView: some View {
        List {
            Section {
                ForEach(history.queries, id: \.self) { query in
                    Button {
                        vm.query = query
                        history.add(query)
                        vm.search(usingModule: usingModule)
                    } label: {
                        Label(query, systemImage: "clock")
                            .foregroundStyle(.primary)
                    }
                    #if !os(tvOS)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            history.remove(query)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    #endif
                }
            } header: {
                HStack(spacing: 10) {
                    Text("Recent Searches")
                    Spacer()
                    // Small Surprise Me icon — fits naturally in the
                    // history header. Performs the same surpriseMe()
                    // function as the big button.
                    Button {
                        surpriseMe()
                    } label: {
                        Image(systemName: "shuffle.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSurpriseLoading)
                    .help("Surprise Me")
                    Button("Clear All") { history.clear() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #elseif !os(tvOS)
        .listStyle(.inset)
        #endif
    }

    // MARK: - Empty State

    /// Items 17+18: Search empty state with recommendations + Surprise Me.
    /// Surprise Me is a category-based discovery feature: the user picks
    /// one or more genres, and we fetch anime from AniList filtered by
    /// those genres. Previously shown IDs are tracked so pressing
    /// Surprise Me again never returns the same anime twice.
    private var searchEmptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: isMangaMode ? "book" : "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(isMangaMode ? "Search Manga" : "Search Anime")
                        .font(.headline)
                    Text(isMangaMode ? "Find any manga via AniList" : "Find any anime via AniList")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Surprise Me — category-based discovery
                surpriseMeSection

                // Item 17: Recommendations
                if !recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recommended for You")
                                .font(.title3.weight(.bold))
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(recommendations) { media in
                                    NavigationLink {
                                        if isMangaMode {
                                            AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                                        } else {
                                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                                                .aspectRatio(2/3, contentMode: .fill)
                                                .frame(width: 110, height: 165)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                            Text(media.title.displayTitle)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(2)
                                                .frame(width: 110, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }

    @State private var recommendations: [Media] = []

    private func loadRecommendations() async {
        let type = isMangaMode ? "MANGA" : "ANIME"
        // Get user's library genres for content-based matching
        guard let userId = AniListAuthManager.shared.userId else {
            // No login — fall back to trending
            await loadTrendingFallback(type: type)
            return
        }
        do {
            let library = try await AniListLibraryService.shared.fetchAllLists(
                userId: userId, type: isMangaMode ? .manga : .anime)
            // Collect genres from watching/reading + completed entries
            var genreSet: Set<String> = []
            for entry in library.prefix(20) {
                if let genres = entry.media.genres {
                    genreSet.formUnion(genres.prefix(3))
                }
            }
            guard !genreSet.isEmpty else {
                await loadTrendingFallback(type: type)
                return
            }
            // Search for titles matching top genres
            let topGenres = Array(genreSet.prefix(3))
            let query = topGenres.joined(separator: " ")
            let results = try await AniListService.shared.search(keyword: query)
            let mapped = results.prefix(12).map { AniListProvider.shared.mapMedia($0) }
            await MainActor.run {
                self.recommendations = Array(mapped)
            }
        } catch {
            await loadTrendingFallback(type: type)
        }
    }

    private func loadTrendingFallback(type: String) async {
        let results = (try? await AniListService.shared.trending()) ?? []
        let mapped = results.prefix(12).map { AniListProvider.shared.mapMedia($0) }
        await MainActor.run {
            self.recommendations = Array(mapped)
        }
    }

    // MARK: - Surprise Me (category-based discovery)

    /// Categories the user can pick from. These map to AniList genres.
    private let surpriseCategories: [(label: String, genre: String, icon: String)] = [
        ("Action", "Action", "bolt.fill"),
        ("Adventure", "Adventure", "mountain.2.fill"),
        ("Comedy", "Comedy", "face.smiling.fill"),
        ("Romance", "Romance", "heart.fill"),
        ("Fantasy", "Fantasy", "wand.and.stars"),
        ("Horror", "Horror", "ghost.fill"),
        ("Mystery", "Mystery", "questionmark.circle.fill"),
        ("Sci-Fi", "Sci-Fi", "rocket.fill"),
        ("Sports", "Sports", "figure.run"),
        ("Thriller", "Thriller", "exclamationmark.triangle.fill"),
        ("Drama", "Drama", "theatermasks.fill"),
        ("Slice of Life", "Slice of Life", "cup.and.saucer.fill"),
        ("Supernatural", "Supernatural", "sparkles"),
        ("Isekai", "Isekai", "arrow.triangle.swap"),
        ("Shounen", "Shounen", "flame.fill"),
        ("Seinen", "Seinen", "shield.fill"),
        ("School", "School", "graduationcap.fill"),
        ("Historical", "Historical", "clock.fill")
    ]

    /// Genres the user has selected for Surprise Me. Multi-select.
    /// IDs of anime already shown by Surprise Me in this session. Tracked
    /// so pressing Surprise Me again never returns the same anime twice.
    /// Reset when the user clears their selection or exhausts the pool.
    @State private var surpriseShownIds: Set<Int> = []
    @State private var surpriseDestination: Media?
    @State private var isSurpriseLoading = false

    @ViewBuilder
    private var surpriseMeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Simple one-button Surprise Me — no category chips, no filters.
            // Picks a random anime from trending/popular on AniList.
            // Tracks shown IDs so the same anime is never returned twice.
            Button {
                surpriseMe()
            } label: {
                HStack(spacing: 8) {
                    if isSurpriseLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "shuffle")
                            .font(.title3)
                    }
                    Text(isSurpriseLoading ? "Finding…" : "Surprise Me")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color.appAccent,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSurpriseLoading)
            .padding(.horizontal, 16)

            // Shown count — lets the user know how many they've explored.
            if !surpriseShownIds.isEmpty {
                Text("\(surpriseShownIds.count) explored this session")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Picks a random anime using a GENRE-BASED pool instead of category-based.
    /// Was previously fetching trending + popular + top rated (3 fixed
    /// categories, ~60 titles total — exhausted quickly). Now picks 3-4
    /// random genres from a curated list and fetches up to 50 titles per
    /// genre via `browseByGenre`, giving a pool of 150-200 titles.
    ///
    /// The pool is cached for 10 minutes so repeated taps don't re-fetch.
    /// If the pool is exhausted (user saw everything), we pick a new random
    /// set of genres and refresh automatically.
    private func surpriseMe() {
        isSurpriseLoading = true
        Task {
            let now = Date()
            let cacheKey = isMangaMode ? "manga" : "anime"

            // Use cache if it's fresh (< 10 min old) and has unused items.
            let useCache = SearchView.surpriseCache[cacheKey] != nil
                && now.timeIntervalSince(SearchView.surpriseCacheTimestamp[cacheKey] ?? .distantPast) < 600

            var results: [AniListMedia] = []
            if useCache, let cached = SearchView.surpriseCache[cacheKey] {
                results = cached
            } else {
                // Fresh fetch — pick 3-4 random genres and fetch a large pool.
                // This gives a MUCH larger result pool than the old category approach
                // (~150-200 titles vs ~60), so the user won't exhaust it quickly.
                let type = isMangaMode ? "MANGA" : "ANIME"
                let genres = isMangaMode ? SearchView.mangaGenres : SearchView.animeGenres
                let shuffledGenres = genres.shuffled()
                let selectedGenres = Array(shuffledGenres.prefix(4))

                // Fetch each genre's top 50 titles. We use multiple genres
                // (OR semantics) so the pool is diverse. If a genre fails,
                // we skip it and continue with the others.
                for genre in selectedGenres {
                    if let batch = try? await AniListService.shared.browseByGenre(
                        page: 1, type: type, genres: [genre], perPage: 50) {
                        results.append(contentsOf: batch)
                    }
                }

                // Deduplicate by ID (a title can match multiple genres).
                var seen = Set<Int>()
                results = results.filter { seen.insert($0.id).inserted }

                // Cache the result — even if it's empty (so we don't keep
                // retrying a failing API on every tap; the cache will
                // expire after 10 min and retry).
                SearchView.surpriseCache[cacheKey] = results
                SearchView.surpriseCacheTimestamp[cacheKey] = now
            }

            // Shuffle for true randomness
            results.shuffle()

            let pick: AniListMedia?
            if results.isEmpty {
                // API failure with no cache — reset exclusion list so next
                // attempt starts fresh on the next call (after cache expires).
                surpriseShownIds.removeAll()
                pick = nil
            } else {
                // Exclude already-shown
                let pool = results.filter { !surpriseShownIds.contains($0.id) }
                if let random = pool.randomElement() {
                    pick = random
                    surpriseShownIds.insert(random.id)
                } else {
                    // Pool exhausted — reset exclusion and pick from full set.
                    // Also clear the cache so the next tap fetches fresh genres.
                    surpriseShownIds = [results[0].id]
                    pick = results[0]
                    SearchView.surpriseCache[cacheKey] = nil
                    SearchView.surpriseCacheTimestamp[cacheKey] = .distantPast
                }
            }
            await MainActor.run {
                isSurpriseLoading = false
                if let pick {
                    surpriseDestination = AniListProvider.shared.mapMedia(pick)
                } else {
                    ToastManager.shared.show(
                        title: "Surprise Me",
                        message: "No anime found. Try again.",
                        icon: "shuffle.circle",
                        iconColor: .orange
                    )
                }
            }
        }
    }

    /// Static cache for Surprise Me results, keyed by media type ("anime" or
    /// "manga"). Survives view re-creation. Refreshed every 10 minutes (see
    /// `surpriseMe()`). Prevents repeated AniList API calls from triggering
    /// rate-limiting after a few uses.
    private static var surpriseCache: [String: [AniListMedia]] = [:]
    private static var surpriseCacheTimestamp: [String: Date] = [:]

    /// Curated genre lists for Surprise Me. Using a diverse set of genres
    /// ensures the random pool is large and varied.
    private static let animeGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Sci-Fi",
        "Mystery", "Romance", "Thriller", "Sports", "Supernatural",
        "Slice of Life", "Psychological", "Horror", "Mecha", "Music"
    ]

    private static let mangaGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Sci-Fi",
        "Mystery", "Romance", "Thriller", "Supernatural",
        "Slice of Life", "Psychological", "Horror", "Award Winning"
    ]

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sources Button (#90)
    /// Opens the custom Sources picker sheet. SF Symbol "rectangle.stack" mirrors
    /// the metaphor used on the Sources settings page. A tinted dot calls out when
    /// the active provider is anything other than the AniList default, so the user
    /// can see at a glance that MAL is currently powering search.
    private var sourcesButton: some View {
        Button {
            showSources = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                if providerManager.orderedProviders.first?.providerType != .anilist {
                    Circle()
                        .fill(Color.appAccent)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    // MARK: - Filter Button
    /// Filter icon with a tinted dot badge whenever any filter is active.
    // Issue #4 — Icon size increased by 30% (20 → 26pt) for better
    // visibility and tap target. Alignment and spacing maintained.
    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(.primary)
                if !vm.filters.isEmpty {
                    Circle()
                        .fill(Color.appAccent)
                        .frame(width: 10, height: 10)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }
}

// MARK: - Local Import Phase
/// Which file the shared local-file importer is currently picking.
private enum LocalImportPhase { case video, subtitle }

// MARK: - Search History Manager
private final class SearchHistoryManager: ObservableObject {
    @Published private(set) var queries: [String] = []
    private let key = "searchHistory"
    private let maxItems = 20

    init() {
        queries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var updated = queries.filter { $0.lowercased() != q.lowercased() }
        updated.insert(q, at: 0)
        queries = Array(updated.prefix(maxItems))
        UserDefaults.standard.set(queries, forKey: key)
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        UserDefaults.standard.set(queries, forKey: key)
    }

    func clear() {
        queries = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Search Filter Sheet (#91)
//
// Richer filter sheet: section headers with icons, chip-style multi-select for
// genres, new fields (Studio text, Source picker, Min/Max Episodes, Sort direction),
// a bottom bar with "Reset All" + a live results-count preview that updates once
// the user taps Apply (and the search re-runs against the new filter set).

struct SearchFilterSheet: View {
    @Binding var filters: AniListService.SearchFilters
    let currentResultCount: Int
    let hasSearched: Bool
    var isMangaMode: Bool = false
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localFilters: AniListService.SearchFilters = .empty
    @State private var maxEpisodesText: String = ""
    @State private var maxDurationText: String = ""
    @State private var maxScoreText: String = ""
    @State private var minScoreText: String = ""
    @State private var minChaptersText: String = ""
    @State private var maxChaptersText: String = ""

    // #132 — Expanded genre list. AniList's full genre enum has 19 values;
    // we surface all of them so power users can build precise queries.
    private let availableGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy",
        "Horror", "Mahou Shoujo", "Mecha", "Music", "Mystery",
        "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports",
        "Supernatural", "Thriller"
    ]

    // #132 — Common AniList tags (a tiny subset of the ~2,000-tag taxonomy,
    // Issue #6 — commonTags list removed (Tags filter completely removed).

    private let seasons: [(String, String)] = [
        ("Any", ""), ("Winter", "WINTER"), ("Spring", "SPRING"),
        ("Summer", "SUMMER"), ("Fall", "FALL")
    ]

    private let formats: [(String, String)] = [
        ("Any", ""), ("TV", "TV"), ("TV Short", "TV_SHORT"), ("Movie", "MOVIE"),
        ("OVA", "OVA"), ("ONA", "ONA"), ("Special", "SPECIAL"), ("Music", "MUSIC")
    ]

    private let statuses: [(String, String)] = [
        ("Any", ""), ("Finished", "FINISHED"), ("Releasing", "RELEASING"),
        ("Upcoming", "NOT_YET_RELEASED"), ("Cancelled", "CANCELLED"), ("Hiatus", "HIATUS")
    ]

    // AniList `MediaSource` enum values — what the anime was adapted from.
    private let sources: [(String, String)] = [
        ("Any", ""), ("Manga", "MANGA"), ("Light Novel", "LIGHT_NOVEL"),
        ("Original", "ORIGINAL"), ("Anime", "ANIME"), ("Visual Novel", "VISUAL_NOVEL"),
        ("Video Game", "VIDEO_GAME"), ("Novel", "NOVEL"), ("Other", "OTHER"),
        ("Doujinshi", "DOUJINSHI"), ("Comic", "COMIC"), ("Game", "GAME"),
        ("Live Action", "LIVE_ACTION"), ("Multimedia Project", "MULTIMEDIA_PROJECT"),
        ("Picture Book", "PICTURE_BOOK"), ("Web Novel", "WEB_NOVEL")
    ]

    // #132 — Country of origin (AniList CountryCode enum). The most common
    // anime-producing countries; "Any" omits the arg entirely.
    private let countries: [(String, String)] = [
        ("Any", ""), ("Japan", "JP"), ("South Korea", "KR"),
        ("China", "CN"), ("Taiwan", "TW"), ("United States", "US")
    ]

    // Sort option values are the BASE MediaSort enum (no _DESC suffix). The
    // direction is toggled separately via `localFilters.sortDescending`, so the
    // toggle visibly flips any of these between ascending and descending.
    private let sortOptions: [(String, String)] = [
        ("Best Match", "SEARCH_MATCH"),
        ("Popularity", "POPULARITY"),
        ("Top Rated", "SCORE"),
        ("Release Date", "START_DATE"),
        ("Most Favorites", "FAVOURITES"),
        ("Title", "TITLE_ROMAJI"),
        ("Recently Updated", "UPDATED_AT")
    ]

    private var yearOptions: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((1970...(currentYear + 1)).reversed())
    }

    /// True when the local (uncommitted) filters differ from the applied ones —
    /// drives the "Apply to update" hint in the bottom bar.
    private var hasUncommittedChanges: Bool { localFilters != filters }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    sortCard
                    releaseCard
                    typeCard
                    countCard
                    studioCard
                    genresCard
                    excludeGenresCard
                    scoreCard
                    countryCard
                    durationCard
                    otherCard
                }
                .padding(16)
            }
            .background(filterBackground.ignoresSafeArea())
            .navigationTitle(isMangaMode ? "Manga Filters" : "Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filters = localFilters
                        onApply()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        Haptics.light()
                        localFilters = .empty
                        maxEpisodesText = ""
                        maxDurationText = ""
                        minScoreText = ""
                        maxScoreText = ""
                        minChaptersText = ""
                        maxChaptersText = ""
                    }
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .disabled(localFilters.isEmpty)
                }
            }
            // Bottom Apply Filters bar removed — duplicate of the toolbar
            // Apply button (line ~931). Was creating two Apply buttons on
            // the filter sheet (toolbar + bottom bar). The toolbar button
            // remains as the single intended Apply button.
            #endif
        }
        .onAppear {
            localFilters = filters
            maxEpisodesText = localFilters.maxEpisodes.map { String($0) } ?? ""
            maxDurationText = localFilters.maxDuration.map { String($0) } ?? ""
            minScoreText = localFilters.minScore.map { String($0) } ?? ""
            maxScoreText = localFilters.maxScore.map { String($0) } ?? ""
            minChaptersText = localFilters.minChapters.map { String($0) } ?? ""
            maxChaptersText = localFilters.maxChapters.map { String($0) } ?? ""
        }
        #if os(iOS)
        .adaptivePresentationDetents([.large])
        #endif
    }

    // MARK: - Background
    private var filterBackground: Color {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #else
        return Color.black.opacity(0.05)
        #endif
    }

    private var filterCard: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    // MARK: - Sort Card
    private var sortCard: some View {
        FilterCard(title: "Sort", icon: "arrow.up.arrow.down.circle.fill") {
            FilterSegmentRow(
                title: "Sort by",
                value: $localFilters.sort,
                options: sortOptions
            )
            FilterToggleRow(
                title: localFilters.sortDescending ? "Descending" : "Ascending",
                icon: localFilters.sortDescending ? "arrow.down" : "arrow.up",
                isOn: $localFilters.sortDescending
            )
            .disabled(localFilters.sort == "SEARCH_MATCH")
            if localFilters.sort == "SEARCH_MATCH" {
                FilterFootnote("Direction only applies when sort isn't Best Match.")
            }
        }
    }

    // MARK: - Release Card
    private var releaseCard: some View {
        FilterCard(title: "Release", icon: "calendar") {
            FilterSegmentRow(
                title: "Year",
                value: Binding(
                    get: { localFilters.year.map(String.init) ?? "0" },
                    set: { localFilters.year = Int($0).flatMap { $0 == 0 ? nil : $0 } }
                ),
                options: [("Any", "0")] + yearOptions.map { (String($0), String($0)) }
            )
            FilterSegmentRow(
                title: "Season",
                value: Binding(
                    get: { localFilters.season ?? "" },
                    set: { localFilters.season = $0.isEmpty ? nil : $0 }
                ),
                options: seasons
            )
            .disabled(localFilters.year == nil)
        }
    }

    // MARK: - Type Card
    private var typeCard: some View {
        FilterCard(title: "Type", icon: "film.fill") {
            FilterSegmentRow(
                title: "Format",
                value: Binding(
                    get: { localFilters.format ?? "" },
                    set: { localFilters.format = $0.isEmpty ? nil : $0 }
                ),
                options: isMangaMode ? mangaFormats : formats
            )
            FilterSegmentRow(
                title: "Status",
                value: Binding(
                    get: { localFilters.status ?? "" },
                    set: { localFilters.status = $0.isEmpty ? nil : $0 }
                ),
                options: statuses
            )
            FilterSegmentRow(
                title: "Source",
                value: Binding(
                    get: { localFilters.source ?? "" },
                    set: { localFilters.source = $0.isEmpty ? nil : $0 }
                ),
                options: sources
            )
            FilterFootnote("Source = what the title was adapted from.")
        }
    }

    private var mangaFormats: [(String, String)] {
        [("Any", ""), ("Manga", "MANGA"), ("Novel", "NOVEL"),
         ("One Shot", "ONE_SHOT"), ("Doujinshi", "DOUJINSHI")]
    }

    // MARK: - Count Card (Episodes / Chapters)
    private var countCard: some View {
        FilterCard(title: isMangaMode ? "Chapter Count" : "Episode Count",
                   icon: isMangaMode ? "book.closed" : "number") {
            if isMangaMode {
                FilterTextRow(
                    title: "Min Chapters",
                    text: $minChaptersText,
                    placeholder: "0",
                    onChange: { v in localFilters.minChapters = Int(v.filter(\.isNumber)) }
                )
                FilterTextRow(
                    title: "Max Chapters",
                    text: $maxChaptersText,
                    placeholder: "Any",
                    onChange: { v in localFilters.maxChapters = Int(v.filter(\.isNumber)) }
                )
            } else {
                FilterSliderRow(
                    title: "Min Episodes",
                    value: Binding(
                        get: { Double(localFilters.minEpisodes ?? 0) },
                        set: { localFilters.minEpisodes = $0 == 0 ? nil : Int($0) }
                    ),
                    range: 0...200,
                    step: 1,
                    display: { v in v == 0 ? "Any" : "\(Int(v))+" }
                )
                FilterSliderRow(
                    title: "Max Episodes",
                    value: Binding(
                        get: { Double(localFilters.maxEpisodes ?? 0) },
                        set: { localFilters.maxEpisodes = $0 == 0 ? nil : Int($0) }
                    ),
                    range: 0...200,
                    step: 1,
                    display: { v in v == 0 ? "Any" : "\(Int(v))" }
                )
            }
            FilterFootnote(isMangaMode
                ? "Use 0 / blank for no limit."
                : "Use 0 / blank for no limit. Filters by total episode count.")
        }
    }

    // MARK: - Studio Card
    private var studioCard: some View {
        FilterCard(title: isMangaMode ? "Author / Studio" : "Studio", icon: "building.2.fill") {
            FilterTextRow(
                title: isMangaMode ? "Author / Studio" : "Studio",
                text: Binding(
                    get: { localFilters.studio ?? "" },
                    set: { localFilters.studio = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ),
                placeholder: isMangaMode ? "e.g. Gege Akutami" : "e.g. MAPPA, Ufotable, Bones",
                onChange: { _ in }
            )
            FilterFootnote("Case-insensitive match against any credited studio.")
        }
    }

    // MARK: - Genres Card
    private var genresCard: some View {
        FilterCard(title: "Genres", icon: "tag.fill") {
            chipGrid(
                items: availableGenres,
                selected: localFilters.genres,
                onTap: { genre in
                    if localFilters.genres.contains(genre) {
                        localFilters.genres.removeAll { $0 == genre }
                    } else {
                        localFilters.genres.append(genre)
                    }
                }
            )
            if !localFilters.genres.isEmpty {
                FilterFootnote("\(localFilters.genres.count) selected")
            }
        }
    }

    // MARK: - Exclude Genres Card
    private var excludeGenresCard: some View {
        FilterCard(title: "Exclude Genres", icon: "hand.thumbsdown") {
            chipGrid(
                items: availableGenres,
                selected: localFilters.excludeGenres,
                tint: .red,
                onTap: { genre in
                    if localFilters.excludeGenres.contains(genre) {
                        localFilters.excludeGenres.removeAll { $0 == genre }
                    } else {
                        localFilters.excludeGenres.append(genre)
                    }
                }
            )
            if !localFilters.excludeGenres.isEmpty {
                FilterFootnote("\(localFilters.excludeGenres.count) excluded")
            }
        }
    }

    // MARK: - Score Card
    private var scoreCard: some View {
        FilterCard(title: "Score Range", icon: "star.fill") {
            FilterSliderRow(
                title: "Min",
                value: Binding(
                    get: { Double(localFilters.minScore ?? 0) },
                    set: { newVal in
                        let clamped = min(Int(newVal), localFilters.maxScore ?? 100)
                        localFilters.minScore = clamped == 0 ? nil : clamped
                    }
                ),
                range: 0...100,
                step: 5,
                display: { v in String(Int(v)) }
            )
            FilterSliderRow(
                title: "Max",
                value: Binding(
                    get: { Double(localFilters.maxScore ?? 100) },
                    set: { newVal in
                        let clamped = max(Int(newVal), localFilters.minScore ?? 0)
                        localFilters.maxScore = clamped >= 100 ? nil : clamped
                    }
                ),
                range: 0...100,
                step: 5,
                display: { v in String(Int(v)) }
            )
            FilterFootnote("Filter by AniList's 0–100 average score.")
        }
    }

    // MARK: - Country Card
    private var countryCard: some View {
        FilterCard(title: "Country of Origin", icon: "globe") {
            FilterSegmentRow(
                title: "Country",
                value: Binding(
                    get: { localFilters.countryOfOrigin ?? "" },
                    set: { localFilters.countryOfOrigin = $0.isEmpty ? nil : $0 }
                ),
                options: countries
            )
        }
    }

    // MARK: - Duration Card (anime-only)
    @ViewBuilder
    private var durationCard: some View {
        if !isMangaMode {
            FilterCard(title: "Episode Duration", icon: "clock") {
                FilterSliderRow(
                    title: "Min Duration",
                    value: Binding(
                        get: { Double(localFilters.minDuration ?? 0) },
                        set: { localFilters.minDuration = $0 == 0 ? nil : Int($0) }
                    ),
                    range: 0...180,
                    step: 5,
                    display: { v in v == 0 ? "Any" : "\(Int(v)) min+" }
                )
                FilterSliderRow(
                    title: "Max Duration",
                    value: Binding(
                        get: { Double(localFilters.maxDuration ?? 0) },
                        set: { localFilters.maxDuration = $0 == 0 ? nil : Int($0) }
                    ),
                    range: 0...180,
                    step: 5,
                    display: { v in v == 0 ? "Any" : "\(Int(v)) min" }
                )
                FilterFootnote("Filter by episode length in minutes.")
            }
        }
    }

    // MARK: - Other Card
    private var otherCard: some View {
        FilterCard(title: "Other", icon: "slider.horizontal.3") {
            FilterToggleRow(
                title: isMangaMode ? "Only Show Titles With Chapters" : "Only Show Titles With Episodes",
                icon: "checkmark.circle",
                isOn: $localFilters.onlyHasEpisodes
            )
            FilterFootnote(isMangaMode
                ? "Hides announcement/TBA titles that don't have a chapter count yet."
                : "Hides announcement/TBA titles that don't have an episode count yet.")
        }
    }

    // MARK: - Chip Grid (used by Genres + Exclude Genres)
    private func chipGrid(items: [String], selected: [String], tint: Color = Color.appAccent, onTap: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.self) { item in
                let isSelected = selected.contains(item)
                Button { onTap(item) } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(item)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule().fill(isSelected ? tint.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? tint.opacity(0.6) : Color.secondary.opacity(0.2),
                            lineWidth: 1
                        )
                    )
                    .foregroundStyle(isSelected ? tint : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Bar (Apply + Results preview)
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                resultsPreview
                Spacer()
                Button {
                    filters = localFilters
                    onApply()
                    dismiss()
                } label: {
                    Text("Apply Filters")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.appAccent.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var resultsPreview: some View {
        if !hasSearched {
            EmptyView()
        } else if hasUncommittedChanges {
            Label("Apply to update", systemImage: "exclamationmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        } else {
            Label("\(currentResultCount) result\(currentResultCount == 1 ? "" : "s")",
                  systemImage: "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(currentResultCount > 0 ? .green : .secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Custom Filter UI Components
//
// Card-based filter UI matching the app's visual language. Each card is a
// rounded container with an icon+title header and stacked rows. Avoids the
// system Form style so the filter sheet feels native to the app.

private struct FilterCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var cardBg: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }
}

private struct FilterSegmentRow: View {
    let title: String
    @Binding var value: String
    let options: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            // Wrap segments into rows of up to 3 so long option lists (year,
            // source) lay out cleanly without horizontal scrolling.
            let chunks = stride(from: 0, to: options.count, by: 3).map {
                Array(options[$0..<min($0+3, options.count)])
            }
            VStack(spacing: 6) {
                ForEach(chunks.indices, id: \.self) { idx in
                    HStack(spacing: 6) {
                        ForEach(chunks[idx], id: \.1) { option in
                            let selected = value == option.1
                            Button {
                                Haptics.light()
                                value = option.1
                            } label: {
                                Text(option.0)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        Capsule().fill(selected ? Color.appAccent.opacity(0.18) : Color.secondary.opacity(0.1))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(selected ? Color.appAccent.opacity(0.55) : Color.clear, lineWidth: 1)
                                    )
                                    .foregroundStyle(selected ? Color.appAccent : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct FilterSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(display(value))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.appAccent)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.appAccent)
        }
    }
}

private struct FilterToggleRow: View {
    let title: String
    var icon: String = "checkmark.circle"
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.appAccent)
        }
    }
}

// Shared focus state for all FilterTextRow instances so the keyboard's
// "Done" button can dismiss any of them. Declared as a static on the
// FilterTextRow struct so any instance can read/write it.
private struct FilterTextRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var suffix: String? = nil
    let onChange: (String) -> Void
    @FocusState var isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            TextField(placeholder, text: $text)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                #endif
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .focused($isFocused)
                .onChange(of: text) { newValue in
                    onChange(newValue)
                }
            if let suffix {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FilterFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sources Picker Sheet
//
// Custom card-based source picker. Each provider is a card showing its
// connection status and account info. If a source requires an account and
// the user isn't signed in, a "Connect" button starts the OAuth flow
// directly from this sheet — NO navigation to a separate Settings page.
// If the account is already connected, the card shows the username and a
// "Disconnect" option. The entire account-connection experience stays
// inside the Sources sheet.

struct SourcesPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var providerManager = ProviderManager.shared
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    private var activeProviderType: ProviderType? {
        providerManager.orderedProviders.first?.providerType
    }

    /// Searchable providers — both AniList and MAL are surfaced. MAL is
    /// functional for keyword search and basic client-side filters; advanced
    /// filters that MAL's API doesn't support are silently skipped on the
    /// MAL path (see `SearchViewModel.applyMALClientFilters`).
    private var searchableProviders: [ProviderType] { [.anilist, .mal] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    ForEach(searchableProviders, id: \.self) { type in
                        sourceCard(for: type)
                    }
                    infoCard
                }
                .padding(20)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("Sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                presentationWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    // MARK: - Source Card (with inline connect/disconnect)

    @ViewBuilder
    private func sourceCard(for type: ProviderType) -> some View {
        let isActive = activeProviderType == type
        let isConnected: Bool = {
            switch type {
            case .anilist: return anilistAuth.isLoggedIn
            case .mal:     return malAuth.isLoggedIn
            default:       return false
            }
        }()
        let username: String? = {
            switch type {
            case .anilist: return anilistAuth.username
            case .mal:     return malAuth.username
            default:       return nil
            }
        }()

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                sourceIcon(type: type, isConnected: isConnected)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(type.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.appAccent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 7, height: 7)
                        Text(isConnected ? (username.map { "Connected as \($0)" } ?? "Connected") : "Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }

            // Inline account actions — connect or disconnect directly from
            // the card. NO navigation to a separate Sources settings page.
            HStack(spacing: 10) {
                if isConnected {
                    Button {
                        #if os(iOS)
                        disconnect(type)
                        #endif
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        #if os(iOS)
                        connect(type)
                        #endif
                    } label: {
                        Label("Connect", systemImage: "person.crop.circle.badge.plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.appAccent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if !isActive {
                    Button {
                        providerManager.selectProvider(type)
                    } label: {
                        Text("Use This Source")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive ? Color.appAccent.opacity(0.55) : Color.secondary.opacity(0.15),
                    lineWidth: isActive ? 2 : 1
                )
        )
    }

    // MARK: - Connect / Disconnect

    private func connect(_ type: ProviderType) {
        #if os(iOS)
        guard let window = presentationWindow else { return }
        switch type {
        case .anilist: anilistAuth.login(presentationAnchor: window)
        case .mal:     malAuth.login(presentationAnchor: window)
        default: break
        }
        #endif
    }

    private func disconnect(_ type: ProviderType) {
        switch type {
        case .anilist: anilistAuth.logout()
        case .mal:     malAuth.logout()
        default: break
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.appAccent)
            Text("Pick a Source")
                .font(.headline)
            Text("Choose which metadata provider powers your search and library sync. Connect or disconnect your account right here — no separate settings page needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Info Card

    private var infoCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("About Sources")
                .font(.caption.weight(.semibold))
            Text("AniList supports full search filters. MAL supports keyword search with client-side filtering for genres, year, season, format, and status. Anime and manga sources share the same accounts — no duplicate logins needed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Source Icon (with glow on connected)

    @ViewBuilder
    private func sourceIcon(type: ProviderType, isConnected: Bool) -> some View {
        let glowColor: Color = isConnected ? .green : .red
        let glowOpacity: Double = Color.glowEnabled ? Color.glowOpacity(1.0) : 0
        let glowRadius: CGFloat = Color.glowEnabled ? Color.glowRadiusLarge : 0

        CachedAsyncImage(urlString: type.iconURL)
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(glowColor.opacity(Color.glowEnabled ? 0.85 : 0.5), lineWidth: 1.5)
            )
            .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
    }

    // MARK: - Cross-platform colors

    private var pageBackground: Color {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color.black.opacity(0.05)
        #endif
    }

    private var cardBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #elseif os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }
}

// MARK: - Search Activation Observer
private struct SearchActivationObserver: View {
    @Environment(\.isSearching) private var isSearching
    let onActivate: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChangeOf(isSearching) { active in
                if active { onActivate() }
            }
    }
}

// MARK: - Conditional Searchable
/// Applies `.searchable` only when enabled, so the local-playback module can hide
/// the search bar entirely instead of showing an inert field.
private struct ConditionalSearchable: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "Search anime…")
        } else {
            content
        }
    }
}

// MARK: - Card Press Style
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - AniList Card
struct AniListCardView: View, Equatable {
    let media: Media

    static func == (lhs: AniListCardView, rhs: AniListCardView) -> Bool {
        // `Media.==` is keyed on `uniqueId` (provider + id), so two cards are
        // visually identical whenever they reference the same title. Used via
        // `.equatable()` in the search / browse grids to skip diffing the
        // poster + gradient + score badge tree on every grid re-evaluation
        // (e.g. while the live-search debounce or pagination spinner toggles).
        // `episodes` is compared separately: airing-manga chapter counts are
        // patched in AFTER the results render (MangaUpdatesChapterService)
        // and the status line ("Airing, N") must refresh when they land.
        lhs.media == rhs.media
            && lhs.media.episodes == rhs.media.episodes
    }

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
            .overlay(alignment: .bottomLeading) {
                // Matches MangaPosterCard's bottomLeading overlay — title
                // on top, then a small status line below: the unified
                // "[Status], [count]" string from `Media.posterStatusText`
                // (e.g. "Airing, 8" / "Finished, 12"). Same format, font,
                // size and position as the manga poster card, so anime and
                // manga posters render identical status text.
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title.displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let statusLine = media.posterStatusText {
                        Text(statusLine)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                if let score = media.averageScore {
                    Label(score.averageScoreOutOf10, systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
    }
}
