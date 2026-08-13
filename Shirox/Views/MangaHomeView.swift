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
                            ContinueReadingSection(items: progressManager.items, readerContext: $readerContext)
                        }
                        #endif

                        // 3. BROWSE — manga shelves, same horizontal-strip
                        //    pattern as the anime home's AnimeSection.
                        MangaSection(title: "Trending Manga", items: vm.trending, icon: "flame.fill")
                        MangaSection(title: "All-Time Popular", items: vm.popular, icon: "star.fill")
                        MangaSection(title: "Top Rated", items: vm.topRated, icon: "trophy.fill")
                        MangaSection(title: "Latest Releases", items: vm.latest, icon: "sparkles")

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
        #endif
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
    var icon: String = "book.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
            }
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
// SettingsView. All keys are prefixed `manga.` so they live in their own
// UserDefaults namespace and never collide with anime preferences. The UI
// is a custom card-based layout (NOT a system Form) so it matches the
// app's visual language rather than reusing Apple's grouped-form style.

struct MangaSettingsView: View {
    @AppStorage("manga.readingDirection") private var readingDirection: String = "auto"
    @AppStorage("manga.pageGap") private var pageGap: Bool = false
    @AppStorage("manga.invertHorizontal") private var invertHorizontal: Bool = false
    @AppStorage("manga.imageQuality") private var imageQuality: String = "high"
    @AppStorage("manga.preloadPages") private var preloadPages: Int = 3
    @AppStorage("manga.tapZones") private var tapZones: String = "edges"
    @AppStorage("manga.keepScreenOn") private var keepScreenOn: Bool = true
    @AppStorage("manga.autoMarkRead") private var autoMarkRead: Bool = true
    @AppStorage("manga.showPageNumbers") private var showPageNumbers: Bool = false
    @AppStorage("manga.backgroundColor") private var backgroundColor: String = "black"
    @AppStorage("manga.defaultSort") private var defaultSort: String = "source"
    @AppStorage("manga.downsampleImages") private var downsampleImages: Bool = false
    @AppStorage("manga.swipeToNavigate") private var swipeToNavigate: Bool = true
    @AppStorage("manga.volumeButtons") private var volumeButtons: Bool = false
    @AppStorage("manga.cropMargins") private var cropMargins: Bool = false
    @AppStorage("manga.hapticFeedback") private var hapticFeedback: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                readerSection
                displaySection
                navigationSection
                progressSection
                infoCard
            }
            .padding(16)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("Manga Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Reader Section

    private var readerSection: some View {
        SettingsCard(title: "Reader", icon: "book.fill") {
            SettingsPickerRow(
                title: "Reading Direction",
                value: $readingDirection,
                options: [
                    ("Auto (follow source)", "auto"),
                    ("Left to Right", "ltr"),
                    ("Right to Left", "rtl"),
                    ("Vertical (Webtoon)", "vertical")
                ]
            )
            SettingsToggleRow(title: "Page Gap Between Pages", isOn: $pageGap)
            SettingsToggleRow(title: "Invert Horizontal Direction", isOn: $invertHorizontal)
            SettingsToggleRow(title: "Crop Page Margins", isOn: $cropMargins)
            SettingsStepperRow(title: "Preload Pages", value: $preloadPages, range: 1...6, suffix: " pages")
        }
    }

    // MARK: - Display Section

    private var displaySection: some View {
        SettingsCard(title: "Display", icon: "rectangle.on.rectangle") {
            SettingsPickerRow(
                title: "Image Quality",
                value: $imageQuality,
                options: [
                    ("High (Recommended)", "high"),
                    ("Medium", "medium"),
                    ("Low (Data Saver)", "low")
                ]
            )
            SettingsPickerRow(
                title: "Background",
                value: $backgroundColor,
                options: [
                    ("Black", "black"),
                    ("Dark Gray", "gray"),
                    ("White", "white")
                ]
            )
            SettingsToggleRow(title: "Show Page Numbers", isOn: $showPageNumbers)
            SettingsToggleRow(title: "Downsample Large Images", isOn: $downsampleImages)
        }
    }

    // MARK: - Navigation Section

    private var navigationSection: some View {
        SettingsCard(title: "Navigation", icon: "hand.tap.fill") {
            SettingsPickerRow(
                title: "Tap Zones",
                value: $tapZones,
                options: [
                    ("Screen Edges", "edges"),
                    ("Left/Right Halves", "halves"),
                    ("Disabled", "disabled")
                ]
            )
            SettingsToggleRow(title: "Swipe to Navigate", isOn: $swipeToNavigate)
            SettingsToggleRow(title: "Volume Buttons Navigate", isOn: $volumeButtons)
            SettingsToggleRow(title: "Haptic Feedback", isOn: $hapticFeedback)
            SettingsToggleRow(title: "Keep Screen Awake", isOn: $keepScreenOn)
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        SettingsCard(title: "Progress", icon: "checkmark.circle.fill") {
            SettingsToggleRow(title: "Auto-Mark Chapters Read", isOn: $autoMarkRead)
            SettingsPickerRow(
                title: "Default Library Sort",
                value: $defaultSort,
                options: [
                    ("Source Order", "source"),
                    ("By Title", "title"),
                    ("By Last Read", "recent")
                ]
            )
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Independent from Anime Settings")
                .font(.subheadline.weight(.semibold))
            Text("Manga settings are kept fully separate from anime settings. Changes here only affect Reading Mode and the manga reader — your anime playback, subtitles, and library preferences are never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Colors

    private var background: Color {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #else
        return Color.black.opacity(0.05)
        #endif
    }

    private var cardBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }
}

// MARK: - Manga Settings UI Components
//
// Custom card-based settings UI matching the app's visual language. Avoids
// the system Form style so Reading Mode settings feel distinct from the
// anime settings (which use the system Form).

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
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

private struct SettingsPickerRow: View {
    let title: String
    @Binding var value: String
    let options: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(options, id: \.1) { option in
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

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.appAccent)
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Stepper("\(value)\(suffix)", value: $value, in: range)
                .tint(Color.appAccent)
        }
    }
}
