import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryManager()
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared
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

    private var usingModule: Bool { moduleManager.activeModule != nil }
    private var primaryProvider: ProviderType { providerManager.orderedProviders.first?.providerType ?? .anilist }

    var body: some View {
        NavigationStack {
            mainContent
                .background(SearchActivationObserver { vm.clearResults() })
                .navigationTitle("Search")
                .toolbar {
                    // Sources picker — #90. Same visibility rule as the filter button:
                    // only shown when a module isn't active (filters/providers are AniList-side).
                    ToolbarItem(placement: .automatic) {
                        if !usingModule && !isLocalModule && !isJellyfinModule {
                            sourcesButton
                        }
                    }
                    // Filter button — only when NOT using a module (filters are AniList-only)
                    ToolbarItem(placement: .automatic) {
                        if !usingModule && !isLocalModule && !isJellyfinModule {
                            filterButton
                        }
                    }
                }
                .modifier(ConditionalSearchable(enabled: !isLocalModule && !isJellyfinModule, text: $vm.query))
                .onSubmit(of: .search) {
                    history.add(vm.query)
                    vm.search(usingModule: usingModule)
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
                                vm.search(usingModule: usingModule)
                            }
                        }
                    }
                }
                .onChangeOf(moduleManager.moduleReadyId) { newId in
                    guard !vm.query.isEmpty, newId != nil else { return }
                    vm.search(usingModule: true)
                }
                .onChangeOf(moduleManager.activeModule) { newModule in
                    guard !vm.query.isEmpty, newModule == nil else { return }
                    vm.search(usingModule: false)
                }
                .onChangeOf(providerManager.orderedProviders.first?.providerType) {
                    guard !vm.query.isEmpty, !usingModule else { return }
                    vm.search(usingModule: false)
                }
        }
        .adaptiveSheet(isPresented: $showSources) {
            SourcesPickerSheet()
                // #100 — Liquid-glass backdrop for the modal sheet.
                .background(.ultraThinMaterial)
        }
        .adaptiveSheet(isPresented: $showFilters) {
            // #91 — pass the last-applied result count + hasSearched so the sheet
            // can show a live "N results" preview / "Apply to update" hint at the bottom.
            SearchFilterSheet(
                filters: $vm.filters,
                currentResultCount: vm.resultCount,
                hasSearched: vm.hasSearched
            ) {
                if !vm.query.isEmpty { vm.search(usingModule: usingModule) }
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
        } else if !vm.hasResults && !vm.isLoading && !vm.hasSearched {
            if vm.query.isEmpty && !history.queries.isEmpty {
                historyView
            } else {
                emptyStateView(
                    icon: usingModule ? "puzzlepiece.extension" : "magnifyingglass",
                    title: usingModule ? "Search via Module" : "Search Anime",
                    subtitle: usingModule
                        ? "Searching \(moduleManager.activeModule?.sourceName ?? "")…"
                        : "Find any anime via \(primaryProvider.displayName)"
                )
            }
        } else if vm.isLoading {
            loadingView
        } else if let err = vm.errorMessage {
            emptyStateView(
                icon: "exclamationmark.triangle",
                title: "Something went wrong",
                subtitle: err
            )
        } else if !vm.hasResults && !vm.query.isEmpty {
            ContentUnavailableView.search(text: vm.query)
        } else {
            resultsView
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
                .toggleStyle(.switch)
                .tint(Color.gray)
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
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                        } label: {
                            AniListCardView(media: media)
                                .equatable()
                        }
                        .buttonStyle(CardPressStyle())
                    }
                } else {
                    ForEach(vm.moduleResults) { item in
                        NavigationLink {
                            if moduleManager.activeModule?.isManga == true {
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
                HStack {
                    Text("Recent Searches")
                    Spacer()
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
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    // MARK: - Filter Button
    /// Filter icon with a tinted dot badge whenever any filter is active.
    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                if !vm.filters.isEmpty {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
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
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localFilters: AniListService.SearchFilters = .empty
    @State private var maxEpisodesText: String = ""
    @FocusState private var maxEpisodesFocused: Bool

    private let availableGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror",
        "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life",
        "Sports", "Supernatural", "Thriller", "Mecha", "Music"
    ]

    private let seasons: [(String, String)] = [
        ("Any", ""), ("Winter", "WINTER"), ("Spring", "SPRING"),
        ("Summer", "SUMMER"), ("Fall", "FALL")
    ]

    private let formats: [(String, String)] = [
        ("Any", ""), ("TV", "TV"), ("Movie", "MOVIE"), ("OVA", "OVA"),
        ("ONA", "ONA"), ("Special", "SPECIAL"), ("Music", "MUSIC")
    ]

    private let statuses: [(String, String)] = [
        ("Any", ""), ("Finished", "FINISHED"), ("Releasing", "RELEASING"),
        ("Upcoming", "NOT_YET_RELEASED"), ("Cancelled", "CANCELLED")
    ]

    // AniList `MediaSource` enum values — what the anime was adapted from.
    private let sources: [(String, String)] = [
        ("Any", ""), ("Manga", "MANGA"), ("Light Novel", "LIGHT_NOVEL"),
        ("Original", "ORIGINAL"), ("Anime", "ANIME"), ("Visual Novel", "VISUAL_NOVEL"),
        ("Video Game", "VIDEO_GAME"), ("Novel", "NOVEL"), ("Other", "OTHER")
    ]

    // Sort option values are the BASE MediaSort enum (no _DESC suffix). The
    // direction is toggled separately via `localFilters.sortDescending`, so the
    // toggle visibly flips any of these between ascending and descending.
    private let sortOptions: [(String, String)] = [
        ("Best Match", "SEARCH_MATCH"),
        ("Popularity", "POPULARITY"),
        ("Top Rated", "SCORE"),
        ("Newest", "START_DATE"),
        ("Most Favorites", "FAVOURITES")
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
            Form {
                // MARK: Sort
                Section {
                    Picker("Sort by", selection: $localFilters.sort) {
                        ForEach(sortOptions, id: \.1) { opt in
                            Text(opt.0).tag(opt.1)
                        }
                    }
                    .tint(.appAccent)

                    Toggle(isOn: $localFilters.sortDescending) {
                        Label(localFilters.sortDescending ? "Descending" : "Ascending",
                              systemImage: localFilters.sortDescending ? "arrow.down" : "arrow.up")
                    }
                    .tint(.appAccent)
                    .disabled(localFilters.sort == "SEARCH_MATCH")
                } header: {
                    sectionHeader("Sort", icon: "arrow.up.arrow.down.circle.fill")
                } footer: {
                    if localFilters.sort == "SEARCH_MATCH" {
                        Text("Sort direction only applies when sort isn't Best Match.")
                            .font(.caption)
                    }
                }

                // MARK: Release
                Section {
                    Picker("Year", selection: Binding(
                        get: { localFilters.year ?? 0 },
                        set: { localFilters.year = $0 == 0 ? nil : $0 }
                    )) {
                        Text("Any").tag(0)
                        ForEach(yearOptions, id: \.self) { year in
                            Text("\(year)").tag(year)
                        }
                    }
                    .tint(.appAccent)

                    Picker("Season", selection: Binding(
                        get: { localFilters.season ?? "" },
                        set: { localFilters.season = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(seasons, id: \.1) { s in
                            Text(s.0).tag(s.1)
                        }
                    }
                    .tint(.appAccent)
                    .disabled(localFilters.year == nil)
                } header: {
                    sectionHeader("Release", icon: "calendar")
                }

                // MARK: Type
                Section {
                    Picker("Format", selection: Binding(
                        get: { localFilters.format ?? "" },
                        set: { localFilters.format = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(formats, id: \.1) { f in
                            Text(f.0).tag(f.1)
                        }
                    }
                    .tint(.appAccent)

                    Picker("Status", selection: Binding(
                        get: { localFilters.status ?? "" },
                        set: { localFilters.status = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(statuses, id: \.1) { s in
                            Text(s.0).tag(s.1)
                        }
                    }
                    .tint(.appAccent)

                    Picker("Source", selection: Binding(
                        get: { localFilters.source ?? "" },
                        set: { localFilters.source = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(sources, id: \.1) { s in
                            Text(s.0).tag(s.1)
                        }
                    }
                    .tint(.appAccent)
                } header: {
                    sectionHeader("Type", icon: "film.fill")
                } footer: {
                    Text("Source = what the anime was adapted from (manga, light novel, original…).")
                        .font(.caption)
                }

                // MARK: Episodes
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Min Episodes")
                            Spacer()
                            Text(localFilters.minEpisodes.map { "\($0)+" } ?? "Any")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                        Slider(value: Binding(
                            get: { Double(localFilters.minEpisodes ?? 0) },
                            set: { localFilters.minEpisodes = $0 == 0 ? nil : Int($0) }
                        ), in: 0...200, step: 1)
                        .tint(.appAccent)
                    }

                    HStack {
                        Text("Max Episodes")
                        Spacer()
                        TextField("Any", text: $maxEpisodesText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($maxEpisodesFocused)
                            .onChangeOf(maxEpisodesText) { newValue in
                                // Strip anything that isn't a digit so the field can't
                                // ever hold invalid input (and Int() can't fail).
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { maxEpisodesText = trimmed }
                                localFilters.maxEpisodes = Int(trimmed)
                            }
                    }
                } header: {
                    sectionHeader("Episodes", icon: "number")
                } footer: {
                    Text("Use 0 / blank for no limit. Filters by total episode count.")
                        .font(.caption)
                }

                // MARK: Studio
                Section {
                    TextField("e.g. MAPPA, Ufotable, Bones", text: Binding(
                        get: { localFilters.studio ?? "" },
                        set: { localFilters.studio = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    #endif
                } header: {
                    sectionHeader("Studio", icon: "building.2.fill")
                } footer: {
                    Text("Case-insensitive match against any credited studio.")
                        .font(.caption)
                }

                // MARK: Genres (chip-style multi-select)
                Section {
                    genresChips
                } header: {
                    sectionHeader("Genres", icon: "tag.fill")
                } footer: {
                    if !localFilters.genres.isEmpty {
                        Text("\(localFilters.genres.count) selected")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filters = localFilters
                        onApply()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { maxEpisodesFocused = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .onAppear {
            localFilters = filters
            maxEpisodesText = localFilters.maxEpisodes.map { String($0) } ?? ""
        }
        #if os(iOS)
        .adaptivePresentationDetents([.large])
        #endif
    }

    // MARK: - Section Header (icon + title)
    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appAccent)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Genres Chips (#91)
    // Chip-style multi-select: filled accent capsule when selected, plain outline
    // otherwise. Uses an adaptive LazyVGrid so chips wrap naturally on any width.
    private var genresChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(availableGenres, id: \.self) { genre in
                let isSelected = localFilters.genres.contains(genre)
                Button {
                    if isSelected {
                        localFilters.genres.removeAll { $0 == genre }
                    } else {
                        localFilters.genres.append(genre)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(genre)
                            .lineLimit(1)
                    }
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule().fill(isSelected ? Color.appAccent.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? Color.appAccent.opacity(0.6) : Color.secondary.opacity(0.2),
                            lineWidth: 1
                        )
                    )
                    .foregroundStyle(isSelected ? Color.appAccent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Bottom Bar (Reset All + Results preview)
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    localFilters = .empty
                    maxEpisodesText = ""
                } label: {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(localFilters.isEmpty ? Color.secondary : Color.red)
                }
                .buttonStyle(.plain)
                .disabled(localFilters.isEmpty)

                Spacer()

                resultsPreview
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var resultsPreview: some View {
        // Three states — keep the layout stable so the bar doesn't jump as the
        // user edits filters:
        //   1. No search yet            → silent (EmptyView)
        //   2. Uncommitted filter edits → orange "Apply to update" hint
        //   3. Committed                → green checkmark + result count
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

// MARK: - Sources Picker Sheet (#90)
//
// Custom card-based source picker (NOT a Form/Menu). Presented from the search
// toolbar's Sources button. Each provider is a tappable card; tapping selects it
// via `ProviderManager.shared.selectProvider`. Connected sources get the same
// green glow used on the Sources settings page; unconnected sources expose a
// "Connect" button that pushes `SourcesSettingsPage`.

struct SourcesPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var pushSettings = false

    private var activeProviderType: ProviderType? {
        providerManager.orderedProviders.first?.providerType
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    ForEach(Array(providerManager.orderedProviders.enumerated()),
                            id: \.offset) { _, provider in
                        sourceCard(provider)
                    }
                    footerCard
                }
                .padding(20)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("Sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Push the Sources settings page when the user taps Connect. Uses a
            // hidden NavigationLink(isActive:) because the app's NavigationStack
            // is shimmed over NavigationView on iOS (see Shared/NavigationStack.swift),
            // which silently ignores `navigationDestination(...)`.
            .background(
                NavigationLink(
                    destination: SourcesSettingsPage(),
                    isActive: Binding(
                        get: { pushSettings },
                        set: { pushSettings = $0 }
                    )
                ) { EmptyView() }
            )
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
            Text("Choose which metadata provider powers your search and library sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Source Card
    @ViewBuilder
    private func sourceCard(_ provider: any MediaProvider) -> some View {
        let type = provider.providerType
        let isConnected = provider.isAuthenticated
        let isActive = activeProviderType == type

        // The whole card is a Button that selects the provider. The "Connect"
        // pill is a nested Button with `.plain` style — SwiftUI routes taps on
        // the inner Button to it (and does NOT fire the outer Button's action),
        // so unconnected sources give the user two distinct affordances: tap the
        // card body to switch the active provider anyway, or tap Connect to go
        // sign in. (Search auto-re-runs via SearchView's onChangeOf(providerType)
        // observer when the active provider changes.)
        Button {
            providerManager.selectProvider(type)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                sourceIcon(type: type, isConnected: isConnected)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
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
                        Text(isConnected ? "Connected" : "Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isConnected {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? Color.appAccent : Color.secondary.opacity(0.35))
                } else {
                    Button {
                        pushSettings = true
                    } label: {
                        Text("Connect")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.appAccent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Source Icon (with glow on connected)
    // Mirrors SourcesSettingsPage.iconView exactly: green halo when connected,
    // red border when not, driven by the global Color.glowIntensity / glowEnabled
    // settings so the picker matches the Sources settings page.
    @ViewBuilder
    private func sourceIcon(type: ProviderType, isConnected: Bool) -> some View {
        let glowColor: Color = isConnected ? .green : .red
        let glowOpacity: Double = Color.glowEnabled ? Color.glowIntensity * 1.0 : 0
        let glowRadius: CGFloat = Color.glowEnabled ? CGFloat(28 * Color.glowIntensity) : 0

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

    // MARK: - Footer
    private var footerCard: some View {
        VStack(spacing: 6) {
            Text("Want to connect a new account?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                pushSettings = true
            } label: {
                Label("Open Sources Settings", systemImage: "gearshape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Cross-platform colors
    // Form-style backgrounds so the card layout matches the rest of the app on
    // iOS (systemGroupedBackground) and degrades gracefully on macOS / tvOS.
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
        lhs.media == rhs.media
    }

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    TVDBPosterImage(media: media)
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
                Text(media.title.displayTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
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
