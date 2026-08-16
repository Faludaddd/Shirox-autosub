import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case score      = "My Rating"
    case updated    = "Last Updated"
    case progress   = "Progress"
    case title      = "Title"

    var id: String { rawValue }
}

/// Top-level mode for the Library tab. "Library" shows the user's tracked
/// list (anime/manga). "History" shows the unified anime+manga activity feed.
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case library
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Library"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .library: return "books.vertical.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var showProfile = false
    @StateObject private var profileVM = ProfileViewModel()
    @State private var searchText = ""
    @AppStorage("libraryGridLayout") private var isGridLayout = false
    @AppStorage("librarySortOrder") private var sortOrderRaw: String = LibrarySortOrder.score.rawValue
    @AppStorage("librarySortAscending") private var sortAscending = false
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue

    #if os(iOS)
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.topBarLeading, ToolbarItemPlacement.topBarTrailing]
    #else
        // TDOO: fix toolbar placement
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.automatic, ToolbarItemPlacement.automatic]
    #endif

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRaw) ?? .score
    }
    @AppStorage("dualSync") private var dualSync = false
    @State private var selectedEntry: LibraryEntry? = nil
    @State private var pendingEntry: LibraryEntry? = nil
    @State private var showProviderPicker = false
    @State private var showManageCollections = false
    @State private var otherEntry: LibraryEntry? = nil
    @State private var otherMedia: Media? = nil
    @State private var showOtherSheet = false
    @State private var isLoadingOtherEntry = false
    // Manga navigation: provider-synced rows resolve to a module asynchronously,
    // so manga taps drive a programmatic NavigationLink rather than an eager one.
    @State private var pendingMangaItem: SearchItem? = nil
    @State private var mangaLinkActive = false
    @State private var resolvingMangaId: Int? = nil
    @State private var pendingAniListMangaMedia: Media? = nil
    @State private var aniListMangaLinkActive = false
    /// Drives the hidden anime-detail NavigationLink for "View Anime"
    /// context menu actions on anime entries.
    @State private var pendingAnimeMedia: Media? = nil
    @State private var animeLinkActive = false
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    /// The provider type that should drive the library UI right now.
    /// Normally the primary provider; falls back to secondary when primary is down.
    private var activeProviderType: ProviderType {
        let primary = providerManager.primary?.providerType ?? .anilist
        if providerManager.fallbackActive, let fallback = providerManager.fallback {
            return fallback.providerType
        }
        return primary
    }

    private var isActiveProviderAuthenticated: Bool {
        activeProviderType == .mal ? malAuth.isLoggedIn : anilistAuth.isLoggedIn
    }

    private var scoreFormat: ScoreFormat {
        if vm.isLocal { return ScoreFormat(rawValue: localScoreFormatRaw) ?? .point10Decimal }
        return activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private var displayUsername: String {
        let name = activeProviderType == .mal
            ? (malAuth.username ?? "Profile")
            : (anilistAuth.username ?? "Profile")
        return name.count > 15 ? String(name.prefix(15)) + "…" : name
    }

    private var activeAvatarURL: String? {
        activeProviderType == .mal ? malAuth.avatarURL : anilistAuth.avatarURL
    }

    private var orderedStatuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private var displayedEntries: [LibraryEntry] {
        var seen = Set<Int>()
        var entries = vm.entries.filter { seen.insert($0.media.id).inserted }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            entries = entries.filter {
                ($0.media.title.english?.lowercased().contains(q) ?? false) ||
                ($0.media.title.romaji?.lowercased().contains(q) ?? false)
            }
        }
        entries.sort {
            switch sortOrder {
            case .title:
                let a = $0.media.title.displayTitle.lowercased()
                let b = $1.media.title.displayTitle.lowercased()
                return sortAscending ? a < b : a > b
            case .progress:
                return sortAscending ? $0.progress < $1.progress : $0.progress > $1.progress
            case .score:
                let a = $0.displayScore(in: scoreFormat)
                let b = $1.displayScore(in: scoreFormat)
                return sortAscending ? a < b : a > b
            case .updated:
                let a = $0.updatedAt ?? 0
                let b = $1.updatedAt ?? 0
                return sortAscending ? a < b : a > b
            }
        }
        return entries
    }

    var body: some View {
        // `libraryContent` is the single, always-present NavigationStack child so the
        // `.searchable` bar stays attached to the navigation bar across push/pop (matching
        // the working SearchView pattern). Logged-out users default to the local source, so
        // there's always something to show; sign-in lives in the toolbar + Settings.
        NavigationStack {
            libraryContent
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(LibrarySortOrder.allCases) { order in
                    Button {
                        if sortOrder == order { sortAscending.toggle() }
                        else { sortOrderRaw = order.rawValue; sortAscending = false }
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if sortOrder == order {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
        }
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.primary)
            Text(activeProviderType == .mal
                 ? "Track your anime with MyAnimeList"
                 : "Track your anime with AniList")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                #if os(iOS)
                guard let window = presentationWindow else { return }
                if activeProviderType == .mal {
                    MALAuthManager.shared.login(presentationAnchor: window)
                } else {
                    AniListAuthManager.shared.login(presentationAnchor: window)
                }
                #endif
            } label: {
                Text(activeProviderType == .mal ? "Sign in with MyAnimeList" : "Sign in with AniList")
                    .font(.headline)
                    #if os(iOS)
                        .foregroundStyle(Color(.systemBackground))
                    #else
                        // TODO: fix missing color ( XCAssets )
                        .foregroundStyle(Color.secondary)
                    #endif
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.primary, in: Capsule())
                    .padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .navigationTitle("Library")
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    // MARK: - Filter menus

    /// Whether the status filter is off its default (default = `.current`, no custom list).
    private var isStatusFilterActive: Bool {
        vm.selectedCustomList != nil || vm.selectedStatus != .current
    }

    /// The status / custom-list picker items (shared by the macOS capsule and the iOS toolbar button).
    @ViewBuilder
    private var statusMenuContent: some View {
        Section("Lists") {
            ForEach(orderedStatuses) { status in
                Button {
                    vm.selectStatus(status)
                } label: {
                    HStack {
                        Text(status.displayName(for: vm.mediaType))
                        if vm.selectedCustomList == nil && vm.selectedStatus == status {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if !vm.customListNames.isEmpty {
            Section("Custom Lists") {
                ForEach(vm.customListNames, id: \.self) { name in
                    Button {
                        vm.selectCustomList(vm.selectedCustomList == name ? nil : name)
                    } label: {
                        HStack {
                            Label(name, systemImage: "list.star")
                            if vm.selectedCustomList == name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if vm.isLocal {
                    Button {
                        showManageCollections = true
                    } label: {
                        Label("Manage Collections…", systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusFilterMenu() -> some View {
        Menu { statusMenuContent } label: {
            LibraryFilterLabel(
                systemImage: "line.3.horizontal.decrease",
                text: vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType),
                isActive: isStatusFilterActive,
                collapsed: false
            )
        }
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var filterCapsuleRow: some View {
        HStack {
            statusFilterMenu()
            Spacer()
        }
    }

    /// Anime | Manga capsule pills, matching `LibrarySourceSwitcher`'s pill style.
    @ViewBuilder private var mediaTypeSegment: some View {
        HStack(spacing: 8) {
            mediaTypePill(title: "Anime", systemImage: "tv", kind: .anime)
            mediaTypePill(title: "Manga", systemImage: "book", kind: .manga)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func mediaTypePill(title: String, systemImage: String, kind: MediaKind) -> some View {
        let selected = vm.mediaType == kind
        Button { vm.selectMediaType(kind) } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    /// Hidden programmatic link for manga rows (module-source rows navigate directly;
    /// provider-synced rows resolve to a module first). Uses the classic isActive
    /// NavigationLink so it works with this file's NavigationStack.
    @ViewBuilder private var mangaNavLink: some View {
        NavigationLink(
            destination: Group { if let item = pendingMangaItem { MangaDetailView(item: item) } },
            isActive: $mangaLinkActive
        ) { EmptyView() }
        .hidden()
    }

    /// Hidden link for provider-synced manga rows: opens the AniList-backed detail
    /// (which resolves a module itself) so AniList metadata + relations are kept.
    @ViewBuilder private var aniListMangaNavLink: some View {
        NavigationLink(
            destination: Group {
                if let m = pendingAniListMangaMedia {
                    AniListMangaDetailView(mediaId: m.id, preloadedMedia: m)
                }
            },
            isActive: $aniListMangaLinkActive
        ) { EmptyView() }
        .hidden()
    }

    /// Hidden link for anime entries: opens AniListDetailView. Used by
    /// `openEntryDetail` when the user taps "View Anime" from a context
    /// menu — previously anime entries fell through to the manga link,
    /// which opened the wrong page.
    @ViewBuilder private var animeNavLink: some View {
        NavigationLink(
            destination: Group {
                if let m = pendingAnimeMedia {
                    AniListDetailView(mediaId: m.id, preloadedMedia: m)
                }
            },
            isActive: $animeLinkActive
        ) { EmptyView() }
        .hidden()
    }

    private func openManga(_ entry: LibraryEntry) {
        if let source = entry.localSource, source.kind == .module {
            pendingMangaItem = SearchItem(
                title: entry.media.title.displayTitle,
                image: entry.media.coverImage.best ?? "",
                href: source.detailHref ?? "")
            mangaLinkActive = true
        } else {
            pendingAniListMangaMedia = entry.media
            aniListMangaLinkActive = true
        }
    }

    /// Manga entries: tap opens the reader detail (resolving a module first for
    /// provider-synced rows); the pencil opens the edit sheet.
    @ViewBuilder
    private func mangaRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            selectedEntry = entry
        }
        .overlay(alignment: .center) {
            if resolvingMangaId == entry.media.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openManga(entry) }
    }

    #if os(iOS)
    /// True when the scrolling list (rather than a loading / empty / error state) is on screen.
    private var showsLibraryList: Bool {
        !vm.isLoading && vm.error == nil && !displayedEntries.isEmpty
    }
    #endif

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: toolbarItemPlacement[0]) {
            Button {
                isGridLayout.toggle()
            } label: {
                Image(systemName: isGridLayout ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
            }
        }
        #endif
        ToolbarItem(placement: toolbarItemPlacement[0]) {
            sortMenu
        }
        ToolbarItem(placement: toolbarItemPlacement[1]) {
            if isActiveProviderAuthenticated {
                HStack(spacing: 10) {
                    Button {
                        showProfile = true
                    } label: {
                        HStack(spacing: 6) {
                            if let url = activeAvatarURL {
                                CachedAsyncImage(urlString: url)
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                            }
                            Text(displayUsername)
                                .font(.subheadline.weight(.medium))
                                .layoutPriority(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            } else {
                Button("Sign In") {
                    #if os(iOS)
                    guard let window = presentationWindow else { return }
                    if activeProviderType == .mal {
                        MALAuthManager.shared.login(presentationAnchor: window)
                    } else {
                        AniListAuthManager.shared.login(presentationAnchor: window)
                    }
                    #endif
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateTitle: LocalizedStringKey {
        searchText.isEmpty ? "Nothing here yet" : "No Results"
    }

    private var emptyStateIcon: String {
        searchText.isEmpty ? "tray" : "magnifyingglass"
    }

    private var emptyStateDescription: String {
        let noun = vm.mediaType == .manga ? "manga" : "anime"
        if !searchText.isEmpty {
            return "No \(noun) matching \"\(searchText)\"."
        }
        let listName = vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType)
        if vm.isLocal {
            return "Add \(noun) to \(listName) from any title's detail screen."
        }
        return "Add \(noun) to \(listName) on \(activeProviderType == .mal ? "MyAnimeList" : "AniList")."
    }

    // MARK: - Entries list

    /// Refreshes the AniList unread-notification count when signed in to AniList; no-op otherwise.
    private func refreshUnreadCountIfNeeded() async {
        if activeProviderType == .anilist && anilistAuth.isLoggedIn {
            await anilistAuth.refreshUnreadCount()
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LibraryEntry) -> some View {
        Group {
            if entry.media.isManga {
                mangaRow(entry)
            } else if let source = entry.localSource, source.kind == .localFile {
                localFileRow(entry, source: source)
            } else {
                navigableRow(entry)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task {
                    await vm.update(
                        entry: entry,
                        status: entry.status,
                        progress: entry.progress + 1,
                        score: entry.displayScore(in: scoreFormat)
                    )
                }
            } label: {
                Label(entry.media.isManga ? "+1 CH" : "+1 EP", systemImage: "plus.circle.fill")
            }
            .tint(.green)
        }
        .contextMenu {
            libraryContextMenu(for: entry)
        }
        #endif
    }

    @ViewBuilder
    private func libraryContextMenu(for entry: LibraryEntry) -> some View {
        ForEach(MediaListStatus.allCases) { status in
            if status != entry.status {
                Button {
                    Task {
                        await vm.update(
                            entry: entry,
                            status: status,
                            progress: entry.progress,
                            score: entry.displayScore(in: scoreFormat)
                        )
                    }
                } label: {
                    Label("Move to \(status.displayName(for: vm.mediaType))", systemImage: statusIcon(status))
                }
            }
        }
        Divider()
        Button {
            Task { await vm.setPrivate(entry: entry, isPrivate: !entry.isPrivate) }
        } label: {
            Label(
                entry.isPrivate ? "Remove Private" : "Mark as Private",
                systemImage: entry.isPrivate ? "lock.open.fill" : "lock.fill"
            )
        }
        Divider()
        Button(role: .destructive) {
            Task { await vm.delete(entry: entry) }
        } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }

    /// Opens the detail page for an entry — shared by the context menu's
    /// "View Anime"/"View Manga" action. Branches by entry type so manga,
    /// local-file, and module-scraped entries all route correctly.
    private func openEntryDetail(_ entry: LibraryEntry) {
        if entry.media.isManga {
            openManga(entry)
        } else if let source = entry.localSource, source.kind == .localFile {
            resumeLocalFile(source)
        } else if entry.localSource?.kind == .module {
            pendingMangaItem = SearchItem(
                title: entry.media.title.displayTitle,
                image: entry.media.coverImage.best ?? "",
                href: entry.localSource?.detailHref ?? ""
            )
            mangaLinkActive = true
        } else {
            // Anime entry (AniList/MAL-backed) → open AniListDetailView.
            pendingAnimeMedia = entry.media
            animeLinkActive = true
        }
    }

    private func statusIcon(_ status: MediaListStatus) -> String {
        switch status {
        case .current:   return "play.circle"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }

    /// Module-scraped and AniList/MAL entries navigate to a detail screen (branched destination).
    @ViewBuilder
    private func navigableRow(_ entry: LibraryEntry) -> some View {
        ZStack {
            NavigationLink(destination: rowDestination(entry)) {
                EmptyView()
            }
            .opacity(0)

            LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
                if !vm.isLocal && anilistAuth.isLoggedIn && malAuth.isLoggedIn && !dualSync {
                    pendingEntry = entry
                    showProviderPicker = true
                } else {
                    selectedEntry = entry
                }
            }
        }
    }

    @ViewBuilder
    private func rowDestination(_ entry: LibraryEntry) -> some View {
        if let source = entry.localSource, source.kind == .module {
            DetailView(
                item: SearchItem(
                    title: entry.media.title.displayTitle,
                    image: entry.media.coverImage.best ?? "",
                    href: source.detailHref ?? ""
                ),
                moduleId: source.moduleId
            )
        } else {
            AniListDetailView(mediaId: entry.media.id, preloadedMedia: entry.media)
        }
    }

    /// Local imported files have no detail screen — tapping the row resumes playback.
    @ViewBuilder
    private func localFileRow(_ entry: LibraryEntry, source: LocalSource) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            selectedEntry = entry   // tap the row content → edit sheet
        }
        .contentShape(Rectangle())
        .onTapGesture { resumeLocalFile(source) }
    }

    private func resumeLocalFile(_ source: LocalSource) {
        #if os(iOS)
        guard let name = source.localImportName else { return }
        if let url = LocalPlaybackCoordinator.shared.resolveImport(name: name) {
            LocalPlaybackCoordinator.shared.launch(videoURL: url, subtitle: nil, resumeFrom: 0)
        } else {
            ToastManager.shared.show(
                title: "Playback",
                message: "File moved or unavailable — remove this item",
                icon: "exclamationmark.circle.fill",
                iconColor: .red
            )
        }
        #endif
    }

    private var entriesList: some View {
        Group {
            if isGridLayout {
                libraryGridView
            } else {
                libraryListView
            }
        }
        .refreshable {
            async let count: Void = refreshUnreadCountIfNeeded()
            await vm.refresh()
            await count
        }
    }

    private var libraryListView: some View {
        List {
            #if os(iOS)
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            mediaTypeSegment
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            filterCapsuleRow
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            #endif
            ForEach(displayedEntries, id: \.media.id) { entry in
                entryRow(entry)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grid View (item 6)
    private var libraryGridView: some View {
        ScrollView {
            // Pin the filter controls above the grid
            VStack(spacing: 0) {
                #if os(iOS)
                LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                mediaTypeSegment
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                filterCapsuleRow
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                #endif

                let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(displayedEntries, id: \.media.id) { entry in
                        NavigationLink {
                            rowDestination(entry)
                        } label: {
                            libraryGridCard(entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            libraryContextMenu(for: entry)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
    }

    private func libraryGridCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if let score = entry.media.averageScore {
                        Text("\(score)%")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(4)
                    }
                }
            Text(entry.media.title.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if entry.progress > 0 {
                Text("\(entry.progress) ep")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Library content

    private var libraryContentBase: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                .padding(.horizontal, 16)
            mediaTypeSegment
                .padding(.horizontal, 16)
                .padding(.top, 6)
            // Combined row: Status on left, Genres on right
            filterCapsuleRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            #else
            // The source switcher + filter row scroll away as the list's first rows; for the
            // non-list states (loading / empty / error) they're pinned here so the source and
            // filters stay usable.
            if !showsLibraryList {
                LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                mediaTypeSegment
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                filterCapsuleRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            #endif

            if vm.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.refresh() } }
                }
            } else if displayedEntries.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateIcon,
                    description: Text(emptyStateDescription)
                )
            } else {
                entriesList
            }
        }
        .background { mangaNavLink }
        .background { aniListMangaNavLink }
        .background { animeNavLink }
        .toolbar { libraryToolbar }
        .task { await vm.autoRefreshIfNeeded() }
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            Task { await refreshUnreadCountIfNeeded() }
        }
        #endif
        .onChangeOf(anilistAuth.isLoggedIn) { newValue in
            if newValue { vm.selectSource(.provider(.anilist)) }
            else if !malAuth.isLoggedIn { vm.selectSource(.local) }
        }
        .onChangeOf(malAuth.isLoggedIn) { newValue in
            if newValue { vm.selectSource(.provider(.mal)) }
            else if !anilistAuth.isLoggedIn { vm.selectSource(.local) }
        }
        .onChangeOf(providerManager.fallbackActive) {
            Task { await vm.refresh() }
        }
        #if os(iOS)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library")
        #else
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search library")
        #endif
    }

    private var libraryContent: some View {
        libraryContentBase
        .adaptiveSheet(item: $selectedEntry) { entry in
            LibraryEntryEditSheet(
                entry: entry,
                media: entry.media,
                scoreFormatOverride: vm.isLocal ? scoreFormat : nil,
                progressUnit: entry.media.isManga ? "chapter" : "episode",
                onSave: { status, progress, score in
                    if status == .completed {
                        ContinueWatchingManager.shared.resetProgress(
                            aniListID: entry.media.id, moduleId: nil, mediaTitle: entry.media.title.searchTitle
                        )
                    }
                    Task {
                        await vm.update(entry: entry, status: status, progress: progress, score: score)
                        if !vm.isLocal && vm.mediaType != .manga && dualSync && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
                            if activeProviderType == .anilist, let idMal = entry.media.idMal {
                                try? await MALProvider.shared.updateEntry(mediaId: idMal, status: status, progress: progress, score: score)
                            } else if activeProviderType == .mal {
                                if let aniListId = await IDMappingService.shared.anilistId(forMALId: entry.media.id) {
                                    try? await AniListProvider.shared.updateEntry(mediaId: aniListId, status: status, progress: progress, score: score)
                                }
                            }
                        }
                    }
                },
                onDelete: {
                    Task {
                        await vm.delete(entry: entry)
                        if !vm.isLocal && vm.mediaType != .manga && dualSync && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
                            if activeProviderType == .anilist, let idMal = entry.media.idMal {
                                try? await MALProvider.shared.deleteEntry(entryId: idMal)
                            } else if activeProviderType == .mal {
                                if let aniListId = await IDMappingService.shared.anilistId(forMALId: entry.media.id),
                                   let aniListEntry = try? await AniListProvider.shared.fetchEntry(mediaId: aniListId) {
                                    try? await AniListProvider.shared.deleteEntry(entryId: aniListEntry.id)
                                }
                            }
                        }
                    }
                },
                onTogglePrivate: { newValue in
                    Task { await vm.setPrivate(entry: entry, isPrivate: newValue) }
                }
            )
        }
        .confirmationDialog("Edit on which service?", isPresented: $showProviderPicker, titleVisibility: .visible) {
            Button("Edit on AniList") {
                guard let entry = pendingEntry else { return }
                if activeProviderType == .anilist {
                    selectedEntry = entry
                } else {
                    isLoadingOtherEntry = true
                    Task {
                        if let aniListId = await IDMappingService.shared.anilistId(forMALId: entry.media.id) {
                            let fetched = try? await AniListProvider.shared.fetchEntry(mediaId: aniListId)
                            let aniListMedia = Media(
                                id: aniListId, idMal: entry.media.id, provider: .anilist,
                                title: entry.media.title, coverImage: entry.media.coverImage,
                                bannerImage: nil, description: nil, episodes: entry.media.episodes,
                                status: nil, averageScore: nil, genres: nil,
                                season: nil, seasonYear: nil, nextAiringEpisode: nil,
                                relations: nil, type: nil, format: nil,
                                studioNames: nil, source: nil, duration: nil, airDateRange: nil
                            )
                            otherEntry = fetched
                            otherMedia = aniListMedia
                            showOtherSheet = true
                        }
                        isLoadingOtherEntry = false
                    }
                }
            }
            Button("Edit on MyAnimeList") {
                guard let entry = pendingEntry else { return }
                if activeProviderType == .mal {
                    selectedEntry = entry
                } else {
                    guard let idMal = entry.media.idMal else { return }
                    isLoadingOtherEntry = true
                    Task {
                        let fetched = try? await MALProvider.shared.fetchEntry(mediaId: idMal)
                        let malMedia = Media(
                            id: idMal, idMal: idMal, provider: .mal,
                            title: entry.media.title, coverImage: entry.media.coverImage,
                            bannerImage: nil, description: nil, episodes: entry.media.episodes,
                            status: nil, averageScore: nil, genres: nil,
                            season: nil, seasonYear: nil, nextAiringEpisode: nil,
                            relations: nil, type: nil, format: nil,
                            studioNames: nil, source: nil, duration: nil, airDateRange: nil
                        )
                        otherEntry = fetched
                        otherMedia = malMedia
                        showOtherSheet = true
                        isLoadingOtherEntry = false
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingEntry = nil }
        }
        .adaptiveSheet(isPresented: $showOtherSheet) {
            if let media = otherMedia {
                LibraryEntryEditSheet(
                    entry: otherEntry,
                    media: media,
                    onSave: { status, progress, score in
                        Task {
                            if media.provider == .mal {
                                try? await MALProvider.shared.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
                            } else {
                                try? await AniListProvider.shared.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
                            }
                        }
                    },
                    onDelete: otherEntry != nil ? {
                        Task {
                            if media.provider == .mal {
                                try? await MALProvider.shared.deleteEntry(entryId: media.id)
                            } else if let entry = otherEntry {
                                try? await AniListProvider.shared.deleteEntry(entryId: entry.id)
                            }
                        }
                        otherEntry = nil
                        showOtherSheet = false
                    } : nil
                )
            }
        }
        .adaptiveSheet(isPresented: $showProfile) {
            if activeProviderType == .mal, let uid = malAuth.userId {
                ProfileView(userId: uid, username: malAuth.username ?? "Profile", avatarURL: malAuth.avatarURL)
            } else if let uid = anilistAuth.userId, let username = anilistAuth.username {
                ProfileView(userId: uid, username: username, avatarURL: anilistAuth.avatarURL)
            }
        }
        .adaptiveSheet(isPresented: $showManageCollections) {
            ManageCollectionsView()
        }
    }
}

// MARK: - Library row

private struct LibraryRowView: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Cover image — AniListCardView style
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 70)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.75), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if entry.score > 0 {
                        HStack(spacing: 2) {
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill").font(.system(size: 7))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

            // Info
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.media.title.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let avg = entry.media.averageScore {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 9))
                            Text("\(avg)%")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.blue)
                    }
                    if entry.score > 0 {
                        HStack(spacing: 3) {
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.yellow)
                    }
                    if let ts = entry.updatedAt {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if let genres = entry.media.genres, !genres.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(genres.prefix(2), id: \.self) { g in
                            Text(g)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { onEdit() } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var progressLabel: String {
        if entry.media.isManga {
            if let total = entry.media.episodes {
                return "\(entry.progress) / \(total) ch"
            }
            return "\(entry.progress) ch read"
        }
        if let total = entry.media.episodes {
            return "\(entry.progress) / \(total) episodes"
        }
        return "\(entry.progress) episodes watched"
    }
}

