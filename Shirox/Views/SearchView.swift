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
    @State private var maxDurationText: String = ""
    @State private var maxScoreText: String = ""
    @State private var minScoreText: String = ""
    @State private var minChaptersText: String = ""
    @State private var maxChaptersText: String = ""
    @State private var tagInputText: String = ""
    @State private var excludeTagInputText: String = ""
    @FocusState private var maxEpisodesFocused: Bool

    // #132 — Expanded genre list. AniList's full genre enum has 19 values;
    // we surface all of them so power users can build precise queries.
    private let availableGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy",
        "Horror", "Mahou Shoujo", "Mecha", "Music", "Mystery",
        "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports",
        "Supernatural", "Thriller"
    ]

    // #132 — Common AniList tags (a tiny subset of the ~2,000-tag taxonomy,
    // hand-picked for being widely-used and useful as filter seeds). The
    // user can also type arbitrary tag names via the tag input field.
    private let commonTags: [String] = [
        "Isekai", "School", "Shounen", "Shoujo", "Seinen", "Josei",
        "Harem", "Reverse Harem", "Time Travel", "Reincarnation",
        "Overpowered Protagonist", "Crossover", "Original Work",
        "Board Games", "Card Battle", "Virtual World", "Cyberpunk",
        "Post-Apocalyptic", "Zombie", "Vampire", "Demon", "Ghost",
        "Samurai", "Ninja", "Military", "Police", "Detective",
        "Cooking", "Medical", "Teacher", "Otaku Culture", "IDOL",
        "Band", "Music Band", "Female Protagonist", "Male Protagonist",
        "Ensemble Cast", "Tragedy", "Coming of Age", "Found Family",
        "Revenge", "Conspiracy", "Survival", "War", "Tournament",
        "Training", "Martial Arts", "Boxing", "Tennis", "Basketball",
        "Football", "Baseball", "Volleyball", "Swimming", "Track and Field"
    ]

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

                // MARK: Exclude Genres (#132)
                Section {
                    excludeGenresChips
                } header: {
                    sectionHeader("Exclude Genres", icon: "hand.thumbsdown")
                } footer: {
                    if !localFilters.excludeGenres.isEmpty {
                        Text("\(localFilters.excludeGenres.count) excluded")
                            .font(.caption)
                    }
                }

                // MARK: Tags (#132)
                Section {
                    tagsEditor(
                        title: "Tags",
                        inputText: $tagInputText,
                        tags: localFilters.tags,
                        onAdd: { tag in
                            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty, !localFilters.tags.contains(cleaned) else { return }
                            localFilters.tags.append(cleaned)
                        },
                        onRemove: { tag in
                            localFilters.tags.removeAll { $0 == tag }
                        }
                    )
                    commonTagsGrid
                } header: {
                    sectionHeader("Tags", icon: "number")
                } footer: {
                    Text("AniList tags are fine-grained themes (e.g. Isekai, School, Vampire). Tap a common tag to add it, or type your own.")
                        .font(.caption)
                }

                // MARK: Exclude Tags (#132)
                Section {
                    tagsEditor(
                        title: "Excluded Tags",
                        inputText: $excludeTagInputText,
                        tags: localFilters.excludeTags,
                        onAdd: { tag in
                            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty, !localFilters.excludeTags.contains(cleaned) else { return }
                            localFilters.excludeTags.append(cleaned)
                        },
                        onRemove: { tag in
                            localFilters.excludeTags.removeAll { $0 == tag }
                        }
                    )
                } header: {
                    sectionHeader("Exclude Tags", icon: "hand.thumbsdown.fill")
                } footer: {
                    Text("Hide results matching any of these tags.")
                        .font(.caption)
                }

                // MARK: Score Range (#132)
                Section {
                    HStack {
                        Text("Min Score")
                        Spacer()
                        TextField("0", text: $minScoreText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChangeOf(minScoreText) { newValue in
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { minScoreText = trimmed }
                                localFilters.minScore = Int(trimmed)
                            }
                        Text("/ 100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Max Score")
                        Spacer()
                        TextField("100", text: $maxScoreText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChangeOf(maxScoreText) { newValue in
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { maxScoreText = trimmed }
                                localFilters.maxScore = Int(trimmed)
                            }
                        Text("/ 100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    sectionHeader("Score Range", icon: "star.fill")
                } footer: {
                    Text("Filter by AniList's 0–100 average score. Leave blank for no limit.")
                        .font(.caption)
                }

                // MARK: Country (#132)
                Section {
                    Picker("Country", selection: Binding(
                        get: { localFilters.countryOfOrigin ?? "" },
                        set: { localFilters.countryOfOrigin = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(countries, id: \.1) { c in
                            Text(c.0).tag(c.1)
                        }
                    }
                    .tint(.appAccent)
                } header: {
                    sectionHeader("Country of Origin", icon: "globe")
                }

                // MARK: Duration (#132)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Min Duration")
                            Spacer()
                            Text(localFilters.minDuration.map { "\($0) min+" } ?? "Any")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                        Slider(value: Binding(
                            get: { Double(localFilters.minDuration ?? 0) },
                            set: { localFilters.minDuration = $0 == 0 ? nil : Int($0) }
                        ), in: 0...180, step: 5)
                        .tint(.appAccent)
                    }
                    HStack {
                        Text("Max Duration")
                        Spacer()
                        TextField("Any", text: $maxDurationText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChangeOf(maxDurationText) { newValue in
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { maxDurationText = trimmed }
                                localFilters.maxDuration = Int(trimmed)
                            }
                        Text("min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    sectionHeader("Episode Duration", icon: "clock")
                } footer: {
                    Text("Filter by episode length in minutes. Use 0 / blank for no limit.")
                        .font(.caption)
                }

                // MARK: Chapter Count Range (Requirement #4)
                Section {
                    HStack {
                        Text("Min Chapters")
                        Spacer()
                        TextField("0", text: $minChaptersText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChangeOf(minChaptersText) { newValue in
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { minChaptersText = trimmed }
                                localFilters.minChapters = Int(trimmed)
                            }
                    }
                    HStack {
                        Text("Max Chapters")
                        Spacer()
                        TextField("Any", text: $maxChaptersText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChangeOf(maxChaptersText) { newValue in
                                let trimmed = newValue.filter(\.isNumber)
                                if trimmed != newValue { maxChaptersText = trimmed }
                                localFilters.maxChapters = Int(trimmed)
                            }
                    }
                } header: {
                    sectionHeader("Chapter Count", icon: "book.closed")
                } footer: {
                    Text("Filter by total chapter count (primarily for manga search). Use 0 / blank for no limit.")
                        .font(.caption)
                }

                // MARK: Additional Toggles (#132)
                Section {
                    Toggle("Only Show Titles With Episodes", isOn: $localFilters.onlyHasEpisodes)
                        .tint(.appAccent)
                } header: {
                    sectionHeader("Other", icon: "slider.horizontal.3")
                } footer: {
                    Text("Hides announcement/TBA titles that don't have an episode count yet.")
                        .font(.caption)
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
    }

    // #132 — Exclude-genres chips. Same visual treatment as `genresChips` but
    // tinted red so the user can tell at a glance which set they're editing.
    private var excludeGenresChips: some View {
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
    }

    /// Reusable chip grid used by both include and exclude genre sections.
    /// `tint` controls the selected-state accent (default `.appAccent`, red for
    /// excludes) so the two sections are visually distinct.
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
                            .lineLimit(1)
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
        .padding(.vertical, 6)
    }

    // #132 — Tags editor. A text field to type a new tag (committed on
    // return), plus a horizontal wrap of the currently-selected tags with
    // tap-to-remove. Mirrors the input UX of email "To:" fields.
    @ViewBuilder
    private func tagsEditor(title: String, inputText: Binding<String>, tags: [String], onAdd: @escaping (String) -> Void, onRemove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Add \(title.lowercased())…", text: inputText)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    #endif
                    .onSubmit {
                        onAdd(inputText.wrappedValue)
                        inputText.wrappedValue = ""
                    }
                if !inputText.wrappedValue.isEmpty {
                    Button {
                        onAdd(inputText.wrappedValue)
                        inputText.wrappedValue = ""
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button { onRemove(tag) } label: {
                            HStack(spacing: 4) {
                                Text(tag)
                                    .lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption.weight(.medium))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(Color.appAccent.opacity(0.15)))
                            .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.5), lineWidth: 1))
                            .foregroundStyle(Color.appAccent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // #132 — Common tags quick-pick grid. Tapping a common tag adds it to
    // the selected tags (or removes it if already selected). Smaller chip
    // size than the genre grid since there are more of them.
    private var commonTagsGrid: some View {
        let selected = Set(localFilters.tags)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
            ForEach(commonTags, id: \.self) { tag in
                let isSelected = selected.contains(tag)
                Button {
                    if isSelected {
                        localFilters.tags.removeAll { $0 == tag }
                    } else {
                        localFilters.tags.append(tag)
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(tag)
                            .lineLimit(1)
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule().fill(isSelected ? Color.appAccent.opacity(0.15) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? Color.appAccent.opacity(0.5) : Color.secondary.opacity(0.15),
                            lineWidth: 1
                        )
                    )
                    .foregroundStyle(isSelected ? Color.appAccent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Bottom Bar (Reset All + Results preview)
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    localFilters = .empty
                    maxEpisodesText = ""
                    maxDurationText = ""
                    minScoreText = ""
                    maxScoreText = ""
                    minChaptersText = ""
                    maxChaptersText = ""
                    tagInputText = ""
                    excludeTagInputText = ""
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
//
// #132 — Scoped to AniList only. MAL and other providers are hidden from this
// picker until they're actually ready (the search/filter pipeline is AniList-
// only; surfacing MAL here would let the user pick a source the search VM can't
// query). The full provider list is still available in Settings → Sources.

struct SourcesPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var pushSettings = false

    private var activeProviderType: ProviderType? {
        providerManager.orderedProviders.first?.providerType
    }

    /// #132 — Only AniList is surfaced in the Search picker. When other
    /// providers are ready for search, add them to this list.
    private var searchableProviders: [ProviderType] { [.anilist] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    ForEach(searchableProviders, id: \.self) { type in
                        if let provider = providerManager.orderedProviders.first(where: { $0.providerType == type }) {
                            sourceCard(provider)
                        } else {
                            // Provider isn't registered in ProviderManager —
                            // render a stub card so the user still sees the
                            // option and can connect it.
                            stubCard(for: type)
                        }
                    }
                    comingSoonCard
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

    // MARK: - Stub Card (#132)
    // Rendered for providers that are searchable in principle but not
    // currently registered in ProviderManager. Visually identical to a
    // real source card so the user has a consistent connect affordance.
    @ViewBuilder
    private func stubCard(for type: ProviderType) -> some View {
        let isActive = activeProviderType == type
        Button {
            providerManager.selectProvider(type)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                sourceIcon(type: type, isConnected: false)
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
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 7, height: 7)
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
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

    // MARK: - Coming Soon Card (#132)
    // Explains why only AniList is shown. Keeps the user informed that
    // other providers exist but aren't ready for search yet.
    private var comingSoonCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("More sources coming soon")
                .font(.caption.weight(.semibold))
            Text("MyAnimeList and other providers will appear here once search and filters support them. For now, AniList powers all search, filters, and library sync.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
