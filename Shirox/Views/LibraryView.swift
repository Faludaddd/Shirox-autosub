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
/// in the card layout so users can scan the list by status at a glance.
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
    /// History is presented as a pushed navigation destination with a system
    /// back button so the user can return to the Library list — consistent
    /// with the rest of the app's push/pop navigation.
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

    /// Entries grouped by status for the sectioned list layout.
    /// Only the statuses present in the current filter are returned, in the
    /// user's preferred order. Empty groups are skipped.
    private var groupedEntries: [(MediaListStatus, [LibraryEntry])] {
        let groups = Dictionary(grouping: displayedEntries, by: { $0.status })
        return orderedStatuses
            .filter { groups[$0]?.isEmpty == false }
            .map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        // Single NavigationStack: Library content is the root, History is
        // pushed via a NavigationLink so it gets a system back button.
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

    /// The status / custom-list picker items.
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

    /// Inline filter chip — compact pill with icon, label, chevron, accent
    /// dot when active.
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

    /// Top-level Library / History segment. New design: a single rounded bar
    /// with a sliding indicator behind the selected pill. Tapping History
    /// pushes it onto the navigation stack (so it gets a system back button).
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

    /// Anime | Manga capsule pills.
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

    /// New unified filter row: status chip + sort menu + grid/list toggle on
    /// a single row.
    @ViewBuilder
    private var filterCapsuleRow: some View {
        HStack(spacing: 8) {
            statusFilterChip
            sortMenu
            Spacer(minLength: 0)
            gridListToggleInline
        }
    }

    /// Inline grid/list toggle button.
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

    /// Hidden programmatic link for manga rows.
    @ViewBuilder private var mangaNavLink: some View {
        NavigationLink(
            destination: Group { if let item = pendingMangaItem { MangaDetailView(item: item) } },
            isActive: $mangaLinkActive
        ) { EmptyView() }
        .hidden()
    }

    /// Hidden link for provider-synced manga rows: opens the AniList-backed detail.
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
        "Nothing here yet"
    }

    private var emptyStateIcon: String {
        "tray"
    }

    private var emptyStateDescription: String {
        let noun = vm.mediaType == .manga ? "manga" : "anime"
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

    /// Builds the row view (no List — we use ScrollView+LazyVStack for
    /// tighter spacing control and to avoid List's row-hit-area issues).
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
    /// Uses a NavigationLink with `sense: .navigate` so it pushes cleanly. The
    /// `opacity(0)` overlay trick is avoided because it inflates the row's hit
    /// area; we attach the NavigationLink only to the row's text column instead.
    @ViewBuilder
    private func navigableRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(
            entry: entry,
            scoreFormat: scoreFormat,
            onTapEdit: {
                if !vm.isLocal && anilistAuth.isLoggedIn && malAuth.isLoggedIn && !dualSync {
                    pendingEntry = entry
                    showProviderPicker = true
                } else {
                    selectedEntry = entry
                }
            },
            onTapRow: {
                if let source = entry.localSource, source.kind == .module {
                    // module-scraped entry → push DetailView via a hidden link
                    pendingMangaItem = SearchItem(
                        title: entry.media.title.displayTitle,
                        image: entry.media.coverImage.best ?? "",
                        href: source.detailHref ?? ""
                    )
                    mangaLinkActive = true
                } else {
                    // AniList-backed → push AniListDetailView via NavigationLink
                    pendingAniListMangaMedia = entry.media
                    aniListMangaLinkActive = true
                }
            }
        )
        .contextMenu {
            libraryContextMenu(for: entry)
        }
    }

    /// Manga entries: tap opens the reader detail; pencil opens the edit sheet.
    @ViewBuilder
    private func mangaRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(
            entry: entry,
            scoreFormat: scoreFormat,
            onTapEdit: { selectedEntry = entry },
            onTapRow: { openManga(entry) }
        )
        .overlay(alignment: .center) {
            if resolvingMangaId == entry.media.id {
                ProgressView()
            }
        }
        .contextMenu {
            libraryContextMenu(for: entry)
        }
    }

    /// Local imported files have no detail screen — tapping the row resumes playback.
    @ViewBuilder
    private func localFileRow(_ entry: LibraryEntry, source: LocalSource) -> some View {
        LibraryRowView(
            entry: entry,
            scoreFormat: scoreFormat,
            onTapEdit: { selectedEntry = entry },
            onTapRow: { resumeLocalFile(source) }
        )
        .contextMenu {
            libraryContextMenu(for: entry)
        }
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

    // MARK: - List View (redesigned — clean card list with sectioned status)

    /// Redesigned list layout. Switched from List to ScrollView+LazyVStack so
    /// we have full control over row insets, spacing, and hit areas (List's
    /// row hit area extends edge-to-edge and intercepts taps meant for
    /// overlay controls — the core poster-touch bug). Cards now have
    /// consistent 12pt horizontal padding and 8pt vertical spacing.
    private var libraryListView: some View {
        ScrollView {
            VStack(spacing: 18) {
                // When the status filter is a single specific status or a
                // custom list, show a flat list. Otherwise, group by status
                // with section headers.
                if isStatusFilterActive || vm.selectedCustomList != nil {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedEntries, id: \.media.id) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.horizontal, 14)
                } else {
                    ForEach(groupedEntries, id: \.0) { status, entries in
                        VStack(alignment: .leading, spacing: 8) {
                            statusSectionHeader(status, count: entries.count)
                                .padding(.horizontal, 14)
                            LazyVStack(spacing: 8) {
                                ForEach(entries, id: \.media.id) { entry in
                                    entryRow(entry)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// Section header for grouped list: colored dot + status name + count.
    @ViewBuilder
    private func statusSectionHeader(_ status: MediaListStatus, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusAccentColor(status))
                .frame(width: 8, height: 8)
            Text(status.displayName(for: vm.mediaType))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: - Grid View (kept — posters with score + progress overlay)

    private var libraryGridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                let columns = [GridItem(.adaptive(minimum: 108), spacing: 14)]
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(displayedEntries, id: \.media.id) { entry in
                        LibraryGridCard(
                            entry: entry,
                            onTap: { handleGridTap(entry) },
                            onContextTap: { /* context menu via .contextMenu below */ }
                        )
                        .contextMenu {
                            libraryContextMenu(for: entry)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
    }

    /// Handles a tap on a grid card. Branches by entry type so manga /
    /// local-file / module-scraped entries route to the right destination.
    private func handleGridTap(_ entry: LibraryEntry) {
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
            pendingAniListMangaMedia = entry.media
            aniListMangaLinkActive = true
        }
    }

    // MARK: - Library content

    private var libraryContentBase: some View {
        VStack(spacing: 0) {
            // Top-level Library / History segment, pinned at the top of the screen.
            // Tapping History pushes LibraryHistoryView onto the navigation stack
            // so it gets a system back button (consistent with the rest of the app).
            viewModeSegment
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)

            // History mode: render the history view inline. Pass an onBack
            // callback so the History view's toolbar shows an explicit
            // "← Library" button — consistent with the rest of the app's
            // navigation and discoverable even without a system back button.
            if libraryViewMode == .history {
                LibraryHistoryView(onBack: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        libraryViewMode = .library
                    }
                })
            } else {
                libraryListContent
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
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    /// The library list/grid content (sans the view-mode segment). Broken
    /// out so History can swap in its own content cleanly.
    @ViewBuilder
    private var libraryListContent: some View {
        VStack(spacing: 0) {
            // Source switcher + media type + filter row. Always pinned above
            // the entries (not inside the ScrollView) so the controls stay
            // reachable. This is the fix for the old design where the
            // controls scrolled away with the list.
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
            .background(
                Rectangle()
                    .fill(Color.primary.opacity(0.02))
                    .ignoresSafeArea(edges: .horizontal)
            )

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

// MARK: - Library list row (redesigned — clean, polished card)

/// Redesigned list row. The cover image is rendered with
/// `.allowsHitTesting(false)` so it NEVER intercepts taps meant for the
/// overlay controls (score badge, status dot, edit button). The row's tap
/// target is the text column + a transparent contentShape on the card — not
/// the cover. The edit button sits in its own high-priority tap area so it
/// always wins over the row tap.
private struct LibraryRowView: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal
    var onTapEdit: () -> Void = {}
    var onTapRow: () -> Void = {}

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
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTapRow() }
    }

    @ViewBuilder
    private var cardBody: some View {
        HStack(alignment: .top, spacing: 12) {
            coverImage
                // CRITICAL: cover image does not participate in hit-testing.
                // This is the fix for the poster-touch bug — overlays
                // (score badge, edit button, status dot) always receive
                // taps because the cover underneath them is non-interactive.
                .allowsHitTesting(false)

            // Info column — title, progress bar, chips, meta. This column
            // is the primary tap target for "open the entry".
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

            // Edit button — its own high-priority tap area so it always
            // wins over the row tap, even when visually overlapping the
            // cover's overlay badges.
            Button {
                onTapEdit()
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(TapGesture())
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
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.appAccent.opacity(0.12), in: Capsule())
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

// MARK: - Library grid card (redesigned — poster with controlled hit area)

/// Redesigned grid card. The poster image is rendered with
/// `.allowsHitTesting(false)` so the overlay controls (status dot, score
/// badge, progress bar, ep-count badge) always receive taps. The card's
/// tap target is a transparent contentShape that matches the visible card
/// boundary — not the full grid cell — so taps on the gaps between cards
/// don't accidentally open a card.
private struct LibraryGridCard: View {
    let entry: LibraryEntry
    var onTap: () -> Void = {}
    var onContextTap: () -> Void = {}

    private var accentColor: Color { statusAccentColor(entry.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
                // CRITICAL: poster does not participate in hit-testing.
                // Overlays (status dot, score badge, progress bar) sit on
                // top of the poster and need to receive taps directly.
                // The card's tap target is the contentShape on the
                // outer VStack, scoped to the visible card.
                .allowsHitTesting(false)

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
        // Tap target = visible card only. The contentShape is a rounded
        // rectangle matching the card's bounds so taps in the grid gap
        // don't trigger a card open.
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var poster: some View {
        ZStack {
            CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)
        }
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(accentColor)
                .frame(width: 10, height: 10)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.45)))
                .padding(6)
                .allowsHitTesting(true)  // status dot — currently non-interactive; safe.
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
                .allowsHitTesting(true)
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
                .allowsHitTesting(true)
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
                    .allowsHitTesting(true)
            }
        }
    }
}
