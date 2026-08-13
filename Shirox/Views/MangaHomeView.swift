import SwiftUI

// MARK: - MangaHomeView
//
// Reading Mode entry point — opened from the book icon in HomeView's toolbar.
// A first-class manga browsing surface, fully independent from the anime Home:
//   • Trending manga hero carousel
//   • Popular / Top-Rated / Latest shelves
//   • Continue Reading row (from MangaProgressManager)
//   • Manga-specific search bar
//   • Manga Library shortcut
//
// All manga settings live under their own AppStorage keys (`manga.*`) so
// changing the reading direction, page gap, or default sort here never
// affects anime settings. The shelf data is fetched via the manga-specific
// `AniListService.manga*` endpoints (MANGA media type) so anime and manga
// discovery never collide.

struct MangaHomeView: View {
    @StateObject private var vm = MangaHomeViewModel()
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchResults: [Media] = []
    @State private var isSearchingActive = false
    @State private var searchTask: Task<Void, Never>?
    @ObservedObject private var progressManager = MangaProgressManager.shared

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        Group {
            if isSearchingActive {
                mangaSearchView
            } else {
                mangaBrowseView
            }
        }
        .navigationTitle("Reading")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSearchingActive = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: MangaLibraryView()) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: MangaSettingsView()) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        #endif
        .task { await vm.load() }
    }

    // MARK: - Browse View

    @ViewBuilder
    private var mangaBrowseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = vm.error {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .padding(.top, 40)
                } else if vm.isLoading && vm.trending.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(.top, 60)
                } else {
                    if !progressManager.items.isEmpty {
                        continueReadingSection
                    }
                    trendingSection
                    popularSection
                    topRatedSection
                    latestSection
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await vm.load() }
    }

    // MARK: - Search View

    @ViewBuilder
    private var mangaSearchView: some View {
        VStack(spacing: 0) {
            searchBar
            if searchResults.isEmpty && !searchQuery.isEmpty && isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                ContentUnavailableView(
                    "No Manga Found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different title or keyword.")
                )
            } else if !searchResults.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(searchResults) { media in
                            NavigationLink {
                                AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                MangaPosterCard(media: media)
                                    .equatable()
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            } else {
                ContentUnavailableView(
                    "Search Manga",
                    systemImage: "book",
                    description: Text("Search across thousands of manga titles powered by AniList.")
                )
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isSearchingActive = false
                    searchQuery = ""
                    searchResults = []
                } label: {
                    Text("Cancel")
                }
            }
        }
        #endif
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search manga", text: $searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.search)
                .onChange(of: searchQuery) { newValue in
                    scheduleSearch(newValue)
                }
                .onSubmit { runSearch() }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { runSearch() }
        }
    }

    private func runSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        Task {
            do {
                let results = try await AniListService.shared.mangaSearch(keyword: trimmed)
                let mapped = results.map { AniListProvider.shared.mapMangaMedia($0) }
                await MainActor.run {
                    searchResults = mapped
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                }
            }
        }
    }

    // MARK: - Continue Reading

    @ViewBuilder
    private var continueReadingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Continue Reading")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(progressManager.items) { item in
                        ContinueReadingMangaCard(item: item)
                            .frame(width: 200)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private var trendingSection: some View {
        mangaShelf(title: "Trending Manga", items: vm.trending, icon: "flame.fill")
    }

    @ViewBuilder
    private var popularSection: some View {
        mangaShelf(title: "All-Time Popular", items: vm.popular, icon: "star.fill")
    }

    @ViewBuilder
    private var topRatedSection: some View {
        mangaShelf(title: "Top Rated", items: vm.topRated, icon: "trophy.fill")
    }

    @ViewBuilder
    private var latestSection: some View {
        mangaShelf(title: "Latest Releases", items: vm.latest, icon: "sparkles")
    }

    @ViewBuilder
    private func mangaShelf(title: String, items: [Media], icon: String) -> some View {
        if !items.isEmpty {
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
//
// Reusable button style that gives a subtle scale-down on press. Defined as
// file-private here so it doesn't collide with the identically-named style
// in SearchView.swift.

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - MangaLibraryView
//
// Lightweight manga library view. Pulls the user's manga list from AniList
// (type: MANGA) when signed in. Entries are rendered as poster cards with
// reading-progress badges. Tapping a card pushes the manga detail page;
// long-press offers a context menu with status moves and removal (same
// pattern as the anime LibraryView, but on manga's own library endpoint).

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
// Manga-specific settings. All keys are prefixed `manga.` so they live in
// their own namespace and never collide with the anime settings. The reader
// itself (`MangaReaderView`) reads these keys directly via @AppStorage.

struct MangaSettingsView: View {
    @AppStorage("manga.readingDirection") private var readingDirection: String = "auto"
    @AppStorage("manga.pageGap") private var pageGap: Bool = false
    @AppStorage("manga.defaultSort") private var defaultSort: String = "source"
    @AppStorage("manga.invertHorizontal") private var invertHorizontal: Bool = false

    var body: some View {
        Form {
            Section("Reading") {
                Picker("Direction", selection: $readingDirection) {
                    Text("Auto (follow source)").tag("auto")
                    Text("Left to Right").tag("ltr")
                    Text("Right to Left").tag("rtl")
                    Text("Vertical (Webtoon)").tag("vertical")
                }
                .pickerStyle(.menu)

                Toggle("Page Gap Between Pages", isOn: $pageGap)
                Toggle("Invert Horizontal Direction", isOn: $invertHorizontal)
            }

            Section("Library") {
                Picker("Default Sort", selection: $defaultSort) {
                    Text("Source Order").tag("source")
                    Text("By Title").tag("title")
                    Text("By Last Read").tag("recent")
                }
                .pickerStyle(.menu)
            }

            Section {
                Text("Manga settings are kept separate from anime settings. Changes here only affect the Reading tab and the manga reader.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Manga Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - ContinueReadingMangaCard
//
// Compact card for the "Continue Reading" row on the manga home page. Shows
// the cover, title, last-read chapter, and a progress bar. Tapping opens the
// manga detail page where the user can resume reading.

struct ContinueReadingMangaCard: View {
    let item: MangaReadingItem

    private var progressFraction: Double {
        MangaProgressManager.progressFraction(pageIndex: item.pageIndex, totalPages: item.totalPages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: item.coverImage)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            Text(item.mangaTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("Ch \(item.chapterNumber.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(item.chapterNumber)) : String(item.chapterNumber))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ProgressView(value: progressFraction)
                .tint(.red)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
