import SwiftUI

// MARK: - MangaHomeContent
//
// The manga experience rendered INSIDE HomeView's NavigationStack when the
// user taps the mode-toggle icon to enter Reading Mode. Mirrors the anime
// Home's structure (hero carousel → continue reading → browse sections) so
// the two modes feel like parallel surfaces, not two different apps.
//
// No NavigationStack of its own — the parent HomeView owns the nav stack
// and the toolbar. There is NO back button to "leave" Reading Mode; the
// only way back to Anime Mode is to tap the mode-toggle icon in the
// toolbar again.

struct MangaHomeContent: View {
    @ObservedObject var progressManager: MangaProgressManager
    @ObservedObject var anilistAuth: AniListAuthManager
    @StateObject private var vm = MangaHomeViewModel()
    @State private var readerContext: ReaderContext?
    @State private var crNavTarget: ContinueReadingNavTarget?
    @AppStorage("mangaBrowseCategoriesGridLayout") private var browseCategoriesGridLayout = false

    var body: some View {
        Group {
            if vm.isLoading && vm.trending.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error, vm.trending.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.load() } }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // 1. HERO — manga featured carousel (same component as
                        //    anime, but fed manga Media items). `isManga: true`
                        //    flips the action button to "Read" and routes taps
                        //    to the manga detail page.
                        if !vm.trending.isEmpty {
                            FeaturedCarousel(items: vm.trending, isManga: true)
                        }

                        // 2. CONTINUE READING — horizontal strip of in-progress
                        //    manga. Mirrors the anime home's Continue Watching
                        //    slot so the layout reads identically across modes.
                        #if os(iOS)
                        if !progressManager.items.isEmpty {
                            ContinueReadingSection(items: progressManager.items, readerContext: $readerContext, navTarget: $crNavTarget)
                        }
                        #endif

                        // 3. BROWSE — manga shelves or grid
                        if browseCategoriesGridLayout {
                            mangaBrowseGrid
                        } else {
                            MangaSection(title: "Trending Manga", items: vm.trending)
                            MangaSection(title: "All-Time Popular", items: vm.popular)
                        }

                        Spacer().frame(height: 28)
                    }
                }
                .refreshable { await vm.load() }
                .coordinateSpace(name: "mangaHomeScroll")
                .ignoresSafeArea(edges: .top)
            }
        }
        .task { await vm.load() }
        #if os(iOS)
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        .continueReadingNavigation($crNavTarget)
        #endif
    }

    // MARK: - Grid layout (item 9)
    private var mangaBrowseGrid: some View {
        // Deduplicate by media id (trending + popular may overlap)
        var seen = Set<Int>()
        let allItems = (vm.trending + vm.popular).filter { seen.insert($0.id).inserted }
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(allItems) { media in
                NavigationLink {
                    AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                } label: {
                    MangaPosterCard(media: media)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - MangaHomeViewModel

@MainActor
final class MangaHomeViewModel: ObservableObject {
    @Published var trending: [Media] = []
    @Published var popular: [Media] = []
    @Published var topRated: [Media] = []
    @Published var latest: [Media] = []
    @Published var isLoading = false
    @Published var error: String?

    func load() async {
        guard trending.isEmpty else { return }
        isLoading = true
        error = nil
        async let trendingRes = try? AniListService.shared.mangaTrending()
        async let popularRes = try? AniListService.shared.mangaPopular()
        async let topRatedRes = try? AniListService.shared.mangaTopRated()
        async let latestRes = try? AniListService.shared.mangaLatest()
        let (t, p, r, l) = await (trendingRes, popularRes, topRatedRes, latestRes)
        trending = (t ?? []).map { AniListProvider.shared.mapMangaMedia($0) }
        popular = (p ?? []).map { AniListProvider.shared.mapMangaMedia($0) }
        topRated = (r ?? []).map { AniListProvider.shared.mapMangaMedia($0) }
        latest = (l ?? []).map { AniListProvider.shared.mapMangaMedia($0) }
        isLoading = false
    }
}

// MARK: - MangaSection
//
// Manga equivalent of `AnimeSection`. Same horizontal-strip layout: header
// row (icon + title) + horizontal scroll of poster cards. Tapping a card
// pushes `AniListMangaDetailView`.

struct MangaSection: View {
    let title: String
    let items: [Media]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            if items.isEmpty {
                Text("No titles available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { media in
                            NavigationLink {
                                AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                MangaPosterCard(media: media)
                                    .equatable()
                                    .frame(width: 130)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

// MARK: - MangaPosterCard

struct MangaPosterCard: View, Equatable {
    let media: Media

    static func == (lhs: MangaPosterCard, rhs: MangaPosterCard) -> Bool {
        lhs.media == rhs.media
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
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
                            .padding(6)
                    }
                }

            Text(media.title.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let chapters = media.episodes {
                Text("\(chapters) ch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let status = media.statusDisplay {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - CardPressStyle

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - MangaLibraryView

struct MangaLibraryView: View {
    @State private var entries: [LibraryEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedStatus: MediaListStatus? = nil
    @State private var selectedEntry: LibraryEntry?
    @ObservedObject private var auth = AniListAuthManager.shared

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var filteredEntries: [LibraryEntry] {
        guard let status = selectedStatus else { return entries }
        return entries.filter { $0.status == status }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !auth.isLoggedIn {
                    ContentUnavailableView(
                        "Sign in to AniList",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Connect AniList to sync your manga library.")
                    )
                    .padding(.top, 40)
                } else if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = error, entries.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .padding(.top, 40)
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No Manga in Library",
                        systemImage: "book.closed",
                        description: Text("Add manga from the Reading tab to see them here.")
                    )
                    .padding(.top, 40)
                } else {
                    statusFilter
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                mangaLibraryCard(entry)
                            }
                            .buttonStyle(CardPressStyle())
                            .contextMenu {
                                ForEach(MediaListStatus.allCases) { status in
                                    if status != entry.status {
                                        Button {
                                            Task { await move(entry: entry, to: status) }
                                        } label: {
                                            Label("Move to \(status.displayName(for: .manga))", systemImage: statusIcon(status))
                                        }
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    Task { await delete(entry: entry) }
                                } label: {
                                    Label("Remove from Library", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle("Manga Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .navigationDestinationCompat(item: $selectedEntry) { entry in
            AniListMangaDetailView(mediaId: entry.media.id, preloadedMedia: entry.media)
        }
    }

    private var statusFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", isSelected: selectedStatus == nil) {
                    selectedStatus = nil
                }
                ForEach(MediaListStatus.allCases) { status in
                    filterChip(title: status.displayName(for: .manga),
                               isSelected: selectedStatus == status) {
                        selectedStatus = status
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? Color.red.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.red : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.red : .primary)
        }
        .buttonStyle(.plain)
    }

    private func mangaLibraryCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(urlString: entry.media.coverImage.extraLarge ?? entry.media.coverImage.large ?? "")
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

                if entry.progress > 0 {
                    Text("Ch \(entry.progress)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(6)
                }
            }
            Text(entry.media.title.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.status.displayName(for: .manga))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusIcon(_ status: MediaListStatus) -> String {
        switch status {
        case .current:   return "book"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }

    private func load() async {
        guard auth.isLoggedIn else { return }
        isLoading = true
        error = nil
        do {
            if AniListAuthManager.shared.userId == nil {
                await AniListAuthManager.shared.fetchViewer()
            }
            guard let userId = AniListAuthManager.shared.userId else {
                throw ProviderError.unauthenticated
            }
            let raw = try await AniListLibraryService.shared.fetchAllLists(userId: userId, type: .manga)
            entries = raw.map { AniListProvider.shared.mapEntry($0) }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func move(entry: LibraryEntry, to status: MediaListStatus) async {
        do {
            try await AniListLibraryService.shared.updateEntry(
                mediaId: entry.media.id,
                status: status,
                progress: entry.progress,
                score: entry.score > 0 ? entry.score : nil,
                type: .manga
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(entry: LibraryEntry) async {
        do {
            try await AniListLibraryService.shared.deleteEntry(entryId: entry.id)
            entries.removeAll { $0.id == entry.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - MangaSettingsView
//
// Reading Mode's own settings system — fully independent from the anime
// SettingsView. Uses the SAME tab-based architecture as the anime settings
// (a category menu that pushes dedicated sub-pages) so the two settings
// systems feel structurally parallel. Each sub-page has its OWN unique
// layout (not a shared template), matching how every anime settings page
// already has a distinct design.
//
// All keys are prefixed `manga.` so they live in their own UserDefaults
// namespace and never collide with anime preferences.

struct MangaSettingsView: View {
    var body: some View {
        List {
            // Section 1: Reading Experience
            Section {
                NavigationLink {
                    MangaReaderSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "book.fill", title: "Reader", subtitle: "Direction, layout, zoom, tap zones")
                }
                NavigationLink {
                    MangaDisplaySettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "rectangle.on.rectangle", title: "Display", subtitle: "Background, image quality, page numbers")
                }
            }

            // Section 2: Library & Tracking
            Section {
                NavigationLink {
                    MangaTrackingSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "books.vertical.fill", title: "Library & Tracking", subtitle: "AniList sync, progress, ratings")
                }
                NavigationLink {
                    MangaNotificationsSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "bell.fill", title: "Notifications", subtitle: "Chapter release alerts")
                }
            }

            // Section 3: Sources & Modules (universal — same as anime)
            Section {
                NavigationLink {
                    SourcesSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "person.crop.circle.badge.checkmark", title: "Sources", subtitle: "AniList, MyAnimeList, accounts")
                }
                NavigationLink {
                    ModulesSettingsPage(mediaType: .manga)
                } label: {
                    MangaSettingsCategoryRow(icon: "puzzlepiece.extension.fill", title: "Modules", subtitle: "Manga sources, store, install")
                }
            }

            // Section 4: Appearance (universal)
            Section {
                NavigationLink {
                    AppearanceSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "paintbrush.fill", title: "Appearance", subtitle: "Theme, accent color, motion")
                }
            }

            // Section 5: Data & Downloads
            Section {
                NavigationLink {
                    MangaDataSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "externaldrive.fill", title: "Data & Downloads", subtitle: "Data saving, offline reading")
                }
            }

            // Section 6: Update (universal)
            Section {
                NavigationLink {
                    UpdateSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "arrow.down.circle.fill", title: "Update", subtitle: "Check for updates, download")
                }
            }

            // Section 7: Advanced & Logs (universal)
            Section {
                NavigationLink {
                    AdvancedSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "gearshape.2.fill", title: "Advanced", subtitle: "Cache, reset, storage")
                }
                NavigationLink {
                    LoggerSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "terminal", title: "Logger", subtitle: "App logs, debug info")
                }
            }

            // Section 8: About
            Section {
                NavigationLink {
                    AboutSettingsPage()
                } label: {
                    MangaSettingsCategoryRow(icon: "info.circle.fill", title: "About", subtitle: "Version, licenses")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Manga Settings Category Row

private struct MangaSettingsCategoryRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Manga Reader Settings Page
//
// Layout: Grid-based visual selector for reading direction (icon tiles),
// followed by stacked toggle cards for navigation, and a slider section
// for brightness. Distinct from all other manga settings pages.

private struct MangaReaderSettingsPage: View {
    @AppStorage("manga.readingDirection") private var readingDirection: String = "auto"
    @AppStorage("manga.pageGap") private var pageGap: Bool = false
    @AppStorage("manga.invertHorizontal") private var invertHorizontal: Bool = false
    @AppStorage("manga.tapZones") private var tapZones: String = "edges"
    @AppStorage("manga.swipeToNavigate") private var swipeToNavigate: Bool = true
    @AppStorage("manga.volumeButtons") private var volumeButtons: Bool = false
    @AppStorage("manga.hapticFeedback") private var hapticFeedback: Bool = true
    @AppStorage("manga.pageTransition") private var pageTransition: String = "slide"
    @AppStorage("manga.zoomMode") private var zoomMode: String = "fitWidth"
    @AppStorage("manga.rememberZoomPerSeries") private var rememberZoomPerSeries: Bool = false
    @AppStorage("manga.brightnessOverlay") private var brightnessOverlay: Double = 1.0
    @AppStorage("manga.cropMargins") private var cropMargins: Bool = false

    private let directions: [(label: String, icon: String, value: String)] = [
        ("Auto", "circle.dashed", "auto"),
        ("Left → Right", "arrow.right.square", "ltr"),
        ("Right → Left", "arrow.left.square", "rtl"),
        ("Vertical", "arrow.up.arrow.down.square", "vertical")
    ]

    private let layouts: [(label: String, icon: String, value: String)] = [
        ("Single", "rectangle.portrait", "single"),
        ("Double", "rectangle.split.2x1", "double"),
        ("Fit Width", "arrow.left.and.right", "fitWidth"),
        ("Fit Height", "arrow.up.and.down", "fitHeight"),
        ("Fit Screen", "rectangle.compress.vertical", "fitScreen")
    ]

    private let transitions: [(label: String, value: String)] = [
        ("Slide", "slide"), ("Fade", "fade"), ("Instant", "instant")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Direction — grid of icon tiles
                sectionLabel("Reading Direction")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(directions, id: \.value) { dir in
                        directionTile(dir)
                    }
                }
                toggleRow("Invert Horizontal Direction", isOn: $invertHorizontal)
                toggleRow("Page Gap Between Pages", isOn: $pageGap)

                Divider().padding(.vertical, 4)

                // Layout — horizontal scroll of tiles
                sectionLabel("Page Layout")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(layouts, id: \.value) { layout in
                            layoutTile(layout)
                        }
                    }
                }
                toggleRow("Crop Page Margins", isOn: $cropMargins)
                toggleRow("Remember Zoom Per Series", isOn: $rememberZoomPerSeries)

                Divider().padding(.vertical, 4)

                // Navigation — stacked toggles
                sectionLabel("Navigation")
                Picker("Tap Zones", selection: $tapZones) {
                    Text("Screen Edges").tag("edges")
                    Text("Left/Right Halves").tag("halves")
                    Text("Disabled").tag("disabled")
                }
                toggleRow("Swipe to Navigate", isOn: $swipeToNavigate)
                toggleRow("Volume Buttons Navigate", isOn: $volumeButtons)
                toggleRow("Haptic Feedback", isOn: $hapticFeedback)

                Divider().padding(.vertical, 4)

                // Transitions — segmented picker
                sectionLabel("Page Transitions")
                Picker("Transition Style", selection: $pageTransition) {
                    ForEach(transitions, id: \.value) { t in
                        Text(t.label).tag(t.value)
                    }
                }
                .pickerStyle(.segmented)

                Divider().padding(.vertical, 4)

                // Brightness — slider with live preview
                sectionLabel("Reader Brightness")
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "sun.min").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $brightnessOverlay, in: 0.3...1.0, step: 0.05)
                            .tint(Color.appAccent)
                        Image(systemName: "sun.max.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(Int(brightnessOverlay * 100))% — Dims the reader independently of system brightness.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Reader")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func directionTile(_ dir: (label: String, icon: String, value: String)) -> some View {
        let selected = readingDirection == dir.value
        return Button {
            Haptics.light()
            readingDirection = dir.value
        } label: {
            VStack(spacing: 8) {
                Image(systemName: dir.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(selected ? Color.appAccent : .secondary)
                Text(dir.label)
                    .font(.caption.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.appAccent : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.appAccent.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func layoutTile(_ layout: (label: String, icon: String, value: String)) -> some View {
        let selected = zoomMode == layout.value
        return Button {
            Haptics.light()
            zoomMode = layout.value
        } label: {
            VStack(spacing: 6) {
                Image(systemName: layout.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(selected ? Color.appAccent : .secondary)
                Text(layout.label)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.appAccent : .primary)
            }
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.appAccent.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(Color.appAccent)
                .glowEffect(isOn: isOn.wrappedValue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Manga Display Settings Page
//
// Layout: Color-swatch picker for background, quality dropdown card,
// and a toggle group card. Uses a visual color picker instead of a
// plain Picker, making it distinct from the Reader page.

private struct MangaDisplaySettingsPage: View {
    @AppStorage("manga.imageQuality") private var imageQuality: String = "high"
    @AppStorage("manga.backgroundColor") private var backgroundColor: String = "black"
    @AppStorage("manga.showPageNumbers") private var showPageNumbers: Bool = false
    @AppStorage("manga.downsampleImages") private var downsampleImages: Bool = false
    @AppStorage("manga.dataSavingCellular") private var dataSavingCellular: Bool = false
    @AppStorage("manga.keepScreenOn") private var keepScreenOn: Bool = true
    @AppStorage("mangaBrowseCategoriesGridLayout") private var browseCategoriesGridLayout: Bool = false

    private let bgColors: [(label: String, color: Color, value: String)] = [
        ("Black", .black, "black"),
        ("Dark Gray", Color(white: 0.2), "gray"),
        ("White", .white, "white")
    ]

    private let qualities: [(label: String, value: String)] = [
        ("High (Recommended)", "high"),
        ("Medium", "medium"),
        ("Low (Data Saver)", "low")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Background — visual color swatches
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reader Background")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(spacing: 24) {
                        ForEach(bgColors, id: \.value) { bg in
                            let isSelected = backgroundColor == bg.value
                            Button {
                                Haptics.light()
                                backgroundColor = bg.value
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(bg.color)
                                            .frame(width: 64, height: 64)
                                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                        if isSelected {
                                            Circle()
                                                .strokeBorder(Color.appAccent, lineWidth: 3)
                                                .frame(width: 72, height: 72)
                                        }
                                    }
                                    Text(bg.label)
                                        .font(.caption.weight(isSelected ? .bold : .regular))
                                        .foregroundStyle(isSelected ? Color.appAccent : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reader background \(bg.label)")
                            .accessibilityValue(isSelected ? "Selected" : "Not selected")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    Text("Independent of the app's overall theme. White is recommended for manga since pages are typically white.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                // Image Quality — menu picker card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Image Quality")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Picker("Quality", selection: $imageQuality) {
                        ForEach(qualities, id: \.value) { q in
                            Text(q.label).tag(q.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.appAccent)
                    Toggle("Downsample Large Images", isOn: $downsampleImages)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: downsampleImages)
                    Toggle("Data Saving on Cellular", isOn: $dataSavingCellular)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: dataSavingCellular)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                // Display options — compact toggle list
                VStack(alignment: .leading, spacing: 10) {
                    Text("Display Options")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Toggle("Browse as Grid", isOn: $browseCategoriesGridLayout)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: browseCategoriesGridLayout)
                    Toggle("Show Page Numbers", isOn: $showPageNumbers)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: showPageNumbers)
                    Toggle("Keep Screen Awake", isOn: $keepScreenOn)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: keepScreenOn)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Display")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Manga Tracking Settings Page
//
// Layout: Two-column status indicator (connected/disconnected) at top,
// followed by sync option toggles in a card, then progress options in
// a separate card. Uses a header summary block distinct from Form layout.

private struct MangaTrackingSettingsPage: View {
    @AppStorage("manga.trackOnAniList") private var trackOnAniList: Bool = true
    @AppStorage("manga.syncEdits") private var syncEdits: Bool = true
    @AppStorage("manga.neverReduceProgress") private var neverReduceProgress: Bool = false
    @AppStorage("manga.promptToRate") private var promptToRate: Bool = true
    @AppStorage("manga.autoMarkRead") private var autoMarkRead: Bool = true
    @AppStorage("manga.defaultSort") private var defaultSort: String = "source"
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // AniList connection card with icon + glow
                trackingServiceCard(
                    name: "AniList",
                    iconURL: ProviderType.anilist.iconURL,
                    isLoggedIn: anilistAuth.isLoggedIn,
                    username: anilistAuth.username,
                    onConnect: {
                        #if os(iOS)
                        if anilistAuth.isLoggedIn {
                            anilistAuth.logout()
                        } else if let window = presentationWindow {
                            anilistAuth.login(presentationAnchor: window)
                        }
                        #endif
                    }
                )

                // MAL connection card with icon + glow
                trackingServiceCard(
                    name: "MyAnimeList",
                    iconURL: ProviderType.mal.iconURL,
                    isLoggedIn: malAuth.isLoggedIn,
                    username: malAuth.username,
                    onConnect: {
                        #if os(iOS)
                        if malAuth.isLoggedIn {
                            malAuth.logout()
                        } else if let window = presentationWindow {
                            malAuth.login(presentationAnchor: window)
                        }
                        #endif
                    }
                )

                // Sync options
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sync Options")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Toggle("Track on AniList", isOn: $trackOnAniList).tint(Color.appAccent)
                        .glowEffect(isOn: trackOnAniList)
                    Toggle("Sync Edits", isOn: $syncEdits).tint(Color.appAccent)
                        .glowEffect(isOn: syncEdits)
                    Toggle("Never Reduce Progress", isOn: $neverReduceProgress).tint(Color.appAccent)
                        .glowEffect(isOn: neverReduceProgress)
                    Toggle("Prompt to Rate After Finishing", isOn: $promptToRate).tint(Color.appAccent)
                        .glowEffect(isOn: promptToRate)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                // Progress options
                VStack(alignment: .leading, spacing: 12) {
                    Text("Progress")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Toggle("Auto-Mark Chapters Read", isOn: $autoMarkRead).tint(Color.appAccent)
                        .glowEffect(isOn: autoMarkRead)
                    Picker("Default Library Sort", selection: $defaultSort) {
                        Text("Source Order").tag("source")
                        Text("By Title").tag("title")
                        Text("By Last Read").tag("recent")
                    }
                    .tint(Color.appAccent)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                Text("These settings only affect manga tracking. Anime tracking settings are completely separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Library & Tracking")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    private func trackingServiceCard(name: String, iconURL: String?, isLoggedIn: Bool, username: String?, onConnect: @escaping () -> Void) -> some View {
        let glowColor: Color = isLoggedIn ? .green : .red
        let glowOpacity: Double = Color.glowEnabled ? Color.glowIntensity * 1.0 : 0
        let glowRadius: CGFloat = Color.glowEnabled ? CGFloat(28 * Color.glowIntensity) : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CachedAsyncImage(urlString: iconURL ?? "")
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(glowColor.opacity(Color.glowEnabled ? 0.85 : 0.5), lineWidth: 1.5)
                    )
                    .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.body.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isLoggedIn ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 7, height: 7)
                        Text(isLoggedIn ? "Connected as \(username ?? "user")" : "Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button(isLoggedIn ? "Disconnect" : "Connect", action: onConnect)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(isLoggedIn ? .red : .appAccent)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Manga Notifications Settings Page
//
// Layout: Toggle cards grouped by notification type (Chapter / In-App / Phone)
// with a stepper in a separate card. Uses icon-accented header rows distinct
// from the Display and Tracking pages.

private struct MangaNotificationsSettingsPage: View {
    @AppStorage("manga.chapterNotificationsEnabled") private var chapterNotificationsEnabled: Bool = true
    @AppStorage("manga.inAppToastsEnabled") private var inAppToastsEnabled: Bool = true
    @AppStorage("manga.phoneNotificationsEnabled") private var phoneNotificationsEnabled: Bool = false
    @AppStorage("manga.notificationLeadTime") private var notificationLeadTime: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Chapter alerts card
                notifCard(
                    icon: "bell.badge",
                    title: "Chapter Release Alerts",
                    description: "Get notified when new chapters are released for tracked manga.",
                    toggle: $chapterNotificationsEnabled
                )

                // In-app toasts card
                notifCard(
                    icon: "rectangle.stack.badge.play.fill",
                    title: "In-App Toasts",
                    description: "Show a brief toast at the bottom of the screen when a new chapter is detected.",
                    toggle: $inAppToastsEnabled
                )

                // Phone notifications card
                notifCard(
                    icon: "iphone.radiowaves.left.and.right",
                    title: "Phone Notifications",
                    description: "Send system push notifications to your device. Requires notification permission.",
                    toggle: $phoneNotificationsEnabled
                )

                // Timing card
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                        Text("Timing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Stepper("Lead Time: \(notificationLeadTime == 0 ? "On Release" : "\(notificationLeadTime)m Before")",
                            value: $notificationLeadTime, in: 0...60, step: 5)
                        .tint(Color.appAccent)
                    Text("How early to fire the notification before the scheduled release time.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                Text("These settings only affect manga notifications. Anime notification settings are separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func notifCard(icon: String, title: String, description: String, toggle: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: toggle).labelsHidden().tint(Color.appAccent)
                    .glowEffect(isOn: toggle.wrappedValue)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Manga Data Settings Page
//
// Layout: Data saving toggle with a visual quality indicator bar,
// preloading stepper with a visual gauge. Distinct from all other pages.

private struct MangaDataSettingsPage: View {
    @AppStorage("manga.dataSavingCellular") private var dataSavingCellular: Bool = false
    @AppStorage("manga.preloadPages") private var preloadPages: Int = 3
    @AppStorage("manga.downsampleImages") private var downsampleImages: Bool = false
    @AppStorage("manga.imageQuality") private var imageQuality: String = "high"

    private let qualities: [(label: String, value: String, bars: Int)] = [
        ("Low", "low", 1),
        ("Medium", "medium", 2),
        ("High", "high", 3)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Data saving toggle
                VStack(alignment: .leading, spacing: 10) {
                    Text("Data Saving")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Toggle("Data Saving on Cellular", isOn: $dataSavingCellular)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: dataSavingCellular)
                    Text("Loads lower-resolution page images when on cellular connections to reduce data usage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                // Image quality — visual bar indicator
                VStack(alignment: .leading, spacing: 12) {
                    Text("Image Quality")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(spacing: 10) {
                        ForEach(qualities, id: \.value) { q in
                            let selected = imageQuality == q.value
                            Button {
                                Haptics.light()
                                imageQuality = q.value
                            } label: {
                                VStack(spacing: 6) {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3) { i in
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(i < q.bars ? (selected ? Color.appAccent : Color.secondary.opacity(0.5)) : Color.secondary.opacity(0.15))
                                                .frame(width: 8, height: CGFloat(10 + i * 8))
                                        }
                                    }
                                    Text(q.label)
                                        .font(.caption2.weight(selected ? .bold : .regular))
                                        .foregroundStyle(selected ? Color.appAccent : .primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selected ? Color.appAccent.opacity(0.1) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(selected ? Color.appAccent.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Toggle("Downsample Large Images", isOn: $downsampleImages)
                        .tint(Color.appAccent)
                        .glowEffect(isOn: downsampleImages)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                // Preloading — stepper with gauge
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preloading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack {
                        Stepper("Preload Pages: \(preloadPages)", value: $preloadPages, in: 1...6)
                            .tint(Color.appAccent)
                            .onChange(of: preloadPages) { _ in Haptics.light() }
                    }
                    // Visual gauge
                    HStack(spacing: 4) {
                        ForEach(1...6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i <= preloadPages ? Color.appAccent.opacity(0.6) : Color.secondary.opacity(0.15))
                                .frame(height: 6)
                        }
                    }
                    Text("Higher values mean smoother reading but more data usage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Data & Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
