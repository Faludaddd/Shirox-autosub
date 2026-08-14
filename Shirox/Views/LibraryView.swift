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

/// Accent color per list status. Used as the left-edge stripe + chip background
/// in the new card layout so users can scan the list by status at a glance.
private func statusAccentColor(_ status: MediaListStatus) -> Color {
    switch status {
    case .current:   return .blue
    case .planning:  return .purple
    case .completed: return .green
    case .dropped:   return .red
    case .paused:    return .orange
    case .repeating: return .teal
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
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    /// Top-level Library tab mode: "Library" (the user's tracked list) or
    /// "History" (the unified anime+manga activity feed). Defaults to Library.
    @State private var libraryViewMode: LibraryViewMode = .library

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

    /// Entries grouped by status for the new sectioned list layout.
    /// Only the statuses present in the current filter are returned, in the
    /// user's preferred order. Empty groups are skipped.
    private var groupedEntries: [(MediaListStatus, [LibraryEntry])] {
        let groups = Dictionary(grouping: displayedEntries, by: { $0.status })
        return orderedStatuses
            .filter { groups[$0]?.isEmpty == false }
            .map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        // `libraryContent` is the single, always-present NavigationStack child so the
        // `.searchable` bar stays attached to the navigation bar across push/pop (matching
        // the working SearchView pattern). Logged-out users default to the local source, so
        // there's always something to show; sign-in lives in the toolbar + Settings.
        NavigationStack {
            Group {
                if libraryViewMode == .history {
                    LibraryHistoryView()
                } else {
                    libraryContent
                }
            }
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
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(sortOrder.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .menuIndicator(.hidden)
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

    /// Inline filter chip — new design: compact pill with icon, label, chevron,
    /// accent dot when active. Replaces the old `LibraryFilterLabel` capsule.
    @ViewBuilder
    private var statusFilterChip: some View {
        Menu { statusMenuContent } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                Text(vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isStatusFilterActive ? Color.appAccent : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isStatusFilterActive
                    ? Color.appAccent.opacity(0.15)
                    : Color.secondary.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(
                    isStatusFilterActive ? Color.appAccent.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
            )
        }
        .menuIndicator(.hidden)
    }

    // MARK: - Header segments (redesigned)

    /// Top-level Library / History segment. New design: a single rounded bar with
    /// a sliding indicator behind the selected pill, both pills share one material
    /// background for a cleaner "tab bar" look.
    @ViewBuilder private var viewModeSegment: some View {
        HStack(spacing: 4) {
            ForEach(LibraryViewMode.allCases) { mode in
                let selected = libraryViewMode == mode
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        libraryViewMode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 13, weight: .bold))
                        Text(mode.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.13) : Color.clear)
                    )
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    /// Anime | Manga capsule pills, matching `LibrarySourceSwitcher`'s pill style.
    @ViewBuilder private var mediaTypeSegment: some View {
        HStack(spacing: 6) {
            mediaTypePill(title: "Anime", systemImage: "tv", kind: .anime)
            mediaTypePill(title: "Manga", systemImage: "book", kind: .manga)
            Spacer()
        }
    }

    @ViewBuilder
    private func mediaTypePill(title: String, systemImage: String, kind: MediaKind) -> some View {
        let selected = vm.mediaType == kind
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.18)) { vm.selectMediaType(kind) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color.appAccent.opacity(0.18) : Color.secondary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(selected ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.appAccent : .primary)
        }
        .buttonStyle(.plain)
    }

    /// New unified filter row: status chip + sort menu on a single row.
    /// Replaces the old `filterCapsuleRow` (which only had status) by also surfacing
    /// the sort menu inline so users don't have to dig into the toolbar.
    @ViewBuilder
    private var filterCapsuleRow: some View {
        HStack(spacing: 8) {
            statusFilterChip
            sortMenu
            Spacer(minLength: 0)
            if isGridLayout {
                gridListToggleInline
            } else {
                gridListToggleInline
            }
        }
    }

    /// Inline grid/list toggle button — same icon as the toolbar item but presented
    /// inline so the toolbar slot can be reused (still kept on toolbar too for parity).
    @ViewBuilder
    private var gridListToggleInline: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.2)) { isGridLayout.toggle() }
        } label: {
            Image(systemName: isGridLayout ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .foregroundStyle(.primary)
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
        ToolbarItem(placement: toolbarItemPlacement[1]) {
            if isActiveProviderAuthenticated {
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
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    // MARK: - List View (sectioned by status, redesigned cards)

    private var libraryListView: some View {
        List {
            #if os(iOS)
            // Pinned header controls — sit above the entries as the first row.
            headerControlsRow
            #endif
            // When the status filter is a single specific status, show a flat list.
            // Otherwise, group by status with section headers.
            if isStatusFilterActive && vm.selectedCustomList == nil && vm.selectedStatus != .current {
                ForEach(displayedEntries, id: \.media.id) { entry in
                    entryRow(entry)
                }
            } else if vm.selectedCustomList != nil {
                ForEach(displayedEntries, id: \.media.id) { entry in
                    entryRow(entry)
                }
            } else {
                ForEach(groupedEntries, id: \.0) { status, entries in
                    Section {
                        ForEach(entries, id: \.media.id) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        statusSectionHeader(status, count: entries.count)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Inline header controls for the iOS list. Pinned at the top of the list so
    /// source switching, media type, and filters stay reachable. New design: stacked
    /// vertically with breathing room instead of cramped into one row.
    @ViewBuilder
    private var headerControlsRow: some View {
        VStack(spacing: 8) {
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
            HStack(spacing: 8) {
                mediaTypeSegment
                Spacer(minLength: 0)
            }
            filterCapsuleRow
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 8, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Section header for grouped list: colored dot + status name + count.
    @ViewBuilder
    private func statusSectionHeader(_ status: MediaListStatus, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusAccentColor(status))
                .frame(width: 8, height: 8)
            Text(status.displayName(for: vm.mediaType))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }

    // MARK: - Grid View (bigger posters, score + progress overlay)

    private var libraryGridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                #if os(iOS)
                VStack(spacing: 8) {
                    LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    HStack(spacing: 8) {
                        mediaTypeSegment
                        Spacer(minLength: 0)
                    }
                    filterCapsuleRow
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
                #endif

                let columns = [GridItem(.adaptive(minimum: 108), spacing: 14)]
                LazyVGrid(columns: columns, spacing: 18) {
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
                .padding(.horizontal, 14)
                .padding(.bottom, 30)
            }
        }
    }

    /// New grid card: bigger poster (2:3), score badge top-right, status dot top-left,
    /// progress bar overlay at the bottom of the poster, title + episode count below.
    @ViewBuilder
    private func libraryGridCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)
                    .interpolation(.high)
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(statusAccentColor(entry.status))
                    .frame(width: 10, height: 10)
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if let score = entry.media.averageScore {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(score)%")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let total = entry.media.episodes, total > 0, entry.progress > 0 {
                    GeometryReader { proxy in
                        let ratio = min(1.0, Double(entry.progress) / Double(total))
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.white.opacity(0.2))
                                .frame(height: 3)
                            Rectangle()
                                .fill(Color.appAccent)
                                .frame(width: proxy.size.width * ratio, height: 3)
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 0)
                    .padding(.bottom, 0)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if entry.progress > 0 {
                    let label = entry.media.isManga ? "Ch \(entry.progress)" : "Ep \(entry.progress)"
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }

            Text(entry.media.title.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)

            if let total = entry.media.episodes, total > 0 {
                Text("\(entry.progress) / \(total) \(entry.media.isManga ? "ch" : "ep")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if entry.progress > 0 {
                Text("\(entry.progress) \(entry.media.isManga ? "ch" : "ep")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Library content

    private var libraryContentBase: some View {
        VStack(spacing: 0) {
            // Top-level Library / History segment, pinned at the top of the screen.
            viewModeSegment
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)

            #if !os(iOS)
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                .padding(.horizontal, 16)
            mediaTypeSegment
                .padding(.horizontal, 16)
                .padding(.top, 6)
            filterCapsuleRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            #else
            // The source switcher + filter row scroll away as the list's first rows on iOS.
            // For the non-list states (loading / empty / error) they're pinned here so the
            // source and filters stay usable.
            if !showsLibraryList {
                VStack(spacing: 8) {
                    LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    HStack(spacing: 8) {
                        mediaTypeSegment
                        Spacer(minLength: 0)
                    }
                    filterCapsuleRow
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)
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

// MARK: - Library row (redesigned card)

private struct LibraryRowView: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal
    var onEdit: () -> Void = {}

    private var accentColor: Color { statusAccentColor(entry.status) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Status accent stripe — color-coded by list status.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 4)

            cardBody
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var cardBody: some View {
        HStack(alignment: .top, spacing: 12) {
            coverImage

            // Info column — title, progress bar, chips, meta
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.media.title.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                if let total = entry.media.episodes, total > 0 {
                    progressBar(total: total)
                } else {
                    Text(progressLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                metaRow

                if let genres = entry.media.genres, !genres.isEmpty {
                    genreChips(genres)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)

            // Edit button — column on the right
            VStack(spacing: 8) {
                Button { onEdit() } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var coverImage: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .frame(width: 64, height: 96)
            .overlay(
                CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .interpolation(.high)
            )
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .overlay(alignment: .bottomTrailing) {
                if entry.score > 0 {
                    HStack(spacing: 2) {
                        if scoreFormat != .point3 {
                            Image(systemName: "star.fill").font(.system(size: 7))
                        }
                        scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
    }

    @ViewBuilder
    private func progressBar(total: Int) -> some View {
        let ratio = min(1.0, Double(entry.progress) / Double(total))
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(accentColor)
                        .frame(width: max(4, proxy.size.width * ratio), height: 4)
                }
            }
            .frame(height: 4)

            HStack(spacing: 4) {
                Text("\(entry.progress)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                Text("/")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(total)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.media.isManga ? "chapters" : "episodes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if ratio >= 1.0 {
                    Text("Done")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else if ratio > 0 {
                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 8) {
            if let avg = entry.media.averageScore {
                HStack(spacing: 3) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(avg)%")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())
            }
            if entry.isPrivate {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("Private")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            if let ts = entry.updatedAt {
                Text(Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func genreChips(_ genres: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(genres.prefix(3), id: \.self) { g in
                Text(g)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }

    private var progressLabel: String {
        if entry.media.isManga {
            return "\(entry.progress) ch read"
        }
        return "\(entry.progress) episodes watched"
    }
}
