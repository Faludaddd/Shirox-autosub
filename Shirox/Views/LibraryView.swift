import SwiftUI
import AuthenticationServices

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case score      = "My Rating"
    case updated    = "Last Updated"
    case progress   = "Progress"
    case title      = "Title"

    var id: String { rawValue }
}

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var showProfile = false
    /// What sheets grow out of: an entry's row for its edit sheet, the account chip for the
    /// profile and notifications, the sort menu for collections.
    @Namespace private var sheetZoom
    @State private var showNotifications = false
    @StateObject private var profileVM = ProfileViewModel()
    @State private var searchText = ""
    @AppStorage("librarySortOrder") private var sortOrderRaw: String = LibrarySortOrder.score.rawValue
    @AppStorage("librarySortAscending") private var sortAscending = false
    @ObservedObject private var newEpisodes = NewEpisodeTracker.shared
    @AppStorage(NewEpisodeTracker.firstKey) private var newEpisodesFirst = false
    /// Posters in a grid instead of rows.
    @AppStorage("libraryGridLayout") private var gridLayout = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue

    #if os(iOS)
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.topBarLeading, ToolbarItemPlacement.topBarTrailing]
    #else
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.automatic, ToolbarItemPlacement.automatic]
    #endif

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRaw) ?? .score
    }
    /// AniList ↔ MyAnimeList mirroring — one pair within `SyncTargets`.
    @AppStorage(SyncTargets.key) private var syncTargetsRaw = ""
    private var dualSync: Bool { SyncTargets.mirrors(.anilist, .mal, in: SyncTargets.decode(syncTargetsRaw)) }
    @State private var selectedGenres: Set<String> = []
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
    /// Drives the hidden DetailView NavigationLink for anime entries
    /// tapped in the Library list/grid. When the user taps an anime
    /// that has no linked module source, we asynchronously resolve the
    /// title through an installed anime module (see `openAnime`) and
    /// push DetailView directly — so the user lands on a page WITH
    /// episodes, instead of the episode-less AniListDetailView.
    @State private var pendingAnimeDetailItem: SearchItem? = nil
    @State private var pendingAnimeDetailModuleId: String? = nil
    @State private var animeDetailLinkActive = false
    /// Drives the hidden AniListDetailView NavigationLink for anime
    /// entries tapped in the Library list/grid (when no linked module).
    @State private var pendingAnimeMedia: Media? = nil
    @State private var animeLinkActive = false
    /// Media ID of the anime currently being resolved through a module
    /// (drives the row spinner overlay during async resolution).
    @State private var resolvingAnimeId: Int? = nil
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    /// The account the library UI should present right now: the provider whose list is on
    /// screen, or — when that one isn't signed in — whichever one is.
    private var activeProviderType: ProviderType {
        // Follows the library actually on screen, which is `vm.source` — deliberately fetched
        // provider-direct, so it never falls back to the other service the way content
        // elsewhere does.
        //
        // It used to switch to `fallback` whenever `ProviderManager.fallbackActive` was set,
        // which is a global flag any *other* call can raise — Home falling back during an
        // AniList outage, for instance. The Library's list stayed on the provider you picked
        // while its toolbar flipped to the other account, so selecting AniList showed the
        // AniList library under a MyAnimeList avatar and username.
        let nominal: ProviderType = {
            if case .provider(let source) = vm.source { return source }
            return providerManager.primary?.providerType ?? .anilist
        }()

        // A provider you aren't signed into can't drive the account UI — the username, the
        // avatar, the notifications bell, the Sign In button. Being signed into AniList while
        // MyAnimeList was the active provider made the toolbar offer a sign-in for an account
        // that *was* already connected, just not the one this happened to be pointed at.
        if !isSignedIn(nominal),
           let signedIn = ProviderType.userProviders.first(where: { isSignedIn($0) }) {
            return signedIn
        }
        return nominal
    }

    private var isActiveProviderAuthenticated: Bool {
        isSignedIn(activeProviderType)
    }

    private var scoreFormat: ScoreFormat {
        if vm.isLocal { return ScoreFormat(rawValue: localScoreFormatRaw) ?? .point10Decimal }
        return activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private var displayUsername: String {
        let name: String = activeProviderType == .mal
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
        return vm.source.statuses(in: saved + missing, for: vm.mediaType)
    }

    private var availableGenres: [String] {
        var seen = Set<Int>()
        let entries = vm.entries.filter { seen.insert($0.media.id).inserted }
        var genres = Set<String>()
        for entry in entries {
            for genre in (entry.media.genres ?? []) { genres.insert(genre) }
        }
        return genres.sorted()
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
        if !selectedGenres.isEmpty {
            entries = entries.filter { entry in
                let genres = Set(entry.media.genres ?? [])
                return !selectedGenres.isDisjoint(with: genres)
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
        if newEpisodesFirst {
            // Shows with episodes to catch up on lead, each half in the order chosen above.
            let behind = entries.filter { newEpisodes.unwatched($0) > 0 }
            if !behind.isEmpty {
                entries = behind + entries.filter { newEpisodes.unwatched($0) == 0 }
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
            Section {
                Toggle(isOn: $newEpisodesFirst) {
                    Label("New Episodes First", systemImage: "sparkles.tv")
                }
            }
            Section("Layout") {
                Picker("Layout", selection: $gridLayout) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.3x2").tag(true)
                }
                .pickerStyle(.inline)
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

    // MARK: - Profile unavailable

    /// Shown when an account is signed in but its profile never arrived.
    ///
    /// The name, avatar and user id come only from `fetchViewer`, which needs the API — so
    /// signing in while AniList has its API switched off leaves a session with no identity
    /// attached to it. The toolbar then reads "Profile" with no picture, and this sheet used to
    /// have no branch for the case at all, so it opened completely empty and looked broken.
    private var profileUnavailable: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Profile unavailable")
                .font(.headline)
            Text("You're signed in, but \(activeProviderType.displayName) hasn't sent your profile yet. This usually means its API is down — your account is fine, and it'll fill in once the service is reachable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await AniListAuthManager.shared.fetchViewer() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding()
    }

    // MARK: - Sign in

    /// Both trackers, offered explicitly.
    ///
    /// Signing in used to go to whichever provider the library happened to be pointed at, with
    /// no way to say you meant the other one — so someone who wanted MyAnimeList while AniList
    /// was active had nowhere to say so. Signing in already re-points the library at that
    /// provider (see the `isLoggedIn` handlers below), so picking one here is the whole action.
    @ViewBuilder
    private var signInMenuItems: some View {
        ForEach(ProviderType.userProviders, id: \.self) { type in
            Button {
                signIn(to: type)
            } label: {
                // An account that's already connected stays listed, so the menu always shows
                // both — but says so, rather than offering a sign-in that would do nothing.
                if isSignedIn(type) {
                    Label("\(type.displayName) — signed in", systemImage: "checkmark")
                } else {
                    Text(type.displayName)
                }
            }
            .disabled(isSignedIn(type))
        }
    }

    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return anilistAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        case .local:   return false
        }
    }

    /// Where the Library goes when the list on screen signs out.
    private var sourceAfterSignOut: LibrarySource {
        var signedIn: Set<ProviderType> = []
        if anilistAuth.isLoggedIn { signedIn.insert(.anilist) }
        if malAuth.isLoggedIn { signedIn.insert(.mal) }
        return .afterSignOut(primary: providerManager.primary?.providerType, signedIn: signedIn)
    }

    private func signIn(to type: ProviderType) {
        #if os(iOS)
        guard let window = presentationWindow else { return }
        if type == .mal {
            MALAuthManager.shared.login(presentationAnchor: window)
        } else {
            AniListAuthManager.shared.login(presentationAnchor: window)
        }
        #endif
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.primary)
            // Neutral wording now that the button below offers both: naming one service here
            // while the menu lists two read as though the choice had already been made.
            Text("Track your anime")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Menu {
                signInMenuItems
            } label: {
                HStack(spacing: 6) {
                    Text("Sign In")
                    Image(systemName: "chevron.down").font(.subheadline)
                }
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

    /// The status / custom-list picker items (shared by the capsule and the toolbar button).
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

    /// The genre picker items (shared by the capsule and the toolbar button).
    @ViewBuilder
    private var genreMenuContent: some View {
        Section("Genres") {
            if !selectedGenres.isEmpty {
                Button(role: .destructive) {
                    selectedGenres.removeAll()
                } label: {
                    Label("Clear All Filters", systemImage: "xmark.circle")
                }
            }
            ForEach(availableGenres, id: \.self) { genre in
                Button {
                    if selectedGenres.contains(genre) {
                        selectedGenres.remove(genre)
                    } else {
                        selectedGenres.insert(genre)
                    }
                } label: {
                    HStack {
                        Text(genre)
                        if selectedGenres.contains(genre) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    /// These wrap the shared menu content.
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
    private func genreFilterMenu() -> some View {
        Menu { genreMenuContent } label: {
            LibraryFilterLabel(
                systemImage: "tag",
                text: selectedGenres.isEmpty ? "All Genres" : "\(selectedGenres.count) selected",
                isActive: !selectedGenres.isEmpty,
                collapsed: false
            )
        }
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    /// The capsule filter row (List on the left, Genre on the right).
    @ViewBuilder
    private var filterCapsuleRow: some View {
        HStack {
            statusFilterMenu()
            Spacer()
            if !availableGenres.isEmpty {
                genreFilterMenu()
            }
        }
    }

    /// The source's kinds as capsule pills — Anime | Manga —
    /// matching `LibrarySourceSwitcher`'s pill style.
    @ViewBuilder private var mediaTypeSegment: some View {
        HStack(spacing: 8) {
            ForEach(vm.source.mediaKinds, id: \.self) { kind in
                mediaTypePill(title: kind.pillTitle, systemImage: kind.pillIcon, kind: kind)
            }
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
            .overlay(Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : .clear, lineWidth: 1))
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

    /// Hidden link for anime DetailView (the page WITH episodes). Driven
    /// by `openAnime` after async module resolution succeeds — pushes
    /// DetailView with the resolved SearchItem + moduleId so the user
    /// lands directly on the episode list, not the stats-only
    /// AniListDetailView.
    @ViewBuilder private var animeDetailNavLink: some View {
        NavigationLink(
            destination: Group {
                if let item = pendingAnimeDetailItem {
                    DetailView(item: item, moduleId: pendingAnimeDetailModuleId)
                }
            },
            isActive: $animeDetailLinkActive
        ) { EmptyView() }
        .hidden()
    }

    /// Hidden link for anime entries without a linked module: opens
    /// AniListDetailView (which has its own data loading — no module
    /// href needed). This prevents the blank page that occurred when
    /// pushing DetailView with an empty href.
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
        newEpisodes.markOpened(entry)
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

    /// Anime entries: ALWAYS navigate to DetailView (the page with episodes).
    /// If the entry has a linked module, use it directly. If not, open the
    /// AniList-backed detail which has its own data loading (doesn't need a
    /// module href). NEVER route to a module-less DetailView with an empty
    /// href (blank page — DetailViewModel.load() guards on it) — every anime
    /// tap from Library lands on a working page, every time, no exceptions.
    private func openAnime(_ entry: LibraryEntry) {
        newEpisodes.markOpened(entry)
        // Branch 1: entry already has a linked module source — go
        // straight to DetailView with that module (no resolution needed).
        if let source = entry.localSource, source.kind == .module,
           let href = source.detailHref, !href.isEmpty {
            pendingAnimeDetailItem = SearchItem(
                title: entry.media.title.displayTitle,
                image: entry.media.coverImage.best ?? "",
                href: href)
            pendingAnimeDetailModuleId = source.moduleId
            animeDetailLinkActive = true
            return
        }

        // Branch 2: no linked module — open AniListDetailView which has
        // its own data loading (doesn't need a module href). This is the
        // same page that Search/Browse/Home navigate to for anime.
        pendingAnimeMedia = entry.media
        animeLinkActive = true
    }

    /// Manga entries: tap opens the reader detail (resolving a module first for
    /// provider-synced rows); the pencil opens the edit sheet.
    @ViewBuilder
    private func mangaRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            editEntry(entry)
        }
        .zoomSource(entry.id, in: sheetZoom)
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

    /// The account chip — notifications and profile, or signing in.
    @ViewBuilder
    private var accountToolbarItem: some View {
        if isActiveProviderAuthenticated {
            HStack(spacing: 10) {
                if activeProviderType == .anilist {
                    Button {
                        anilistAuth.unreadNotificationCount = 0
                        showNotifications = true
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 17, weight: .medium))
                            .notificationBadge(count: anilistAuth.unreadNotificationCount)
                    }
                    Divider().frame(height: 16)
                }

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
            Menu {
                signInMenuItems
            } label: {
                Text("Sign In")
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
        let noun = vm.mediaType.noun
        if !searchText.isEmpty {
            return "No \(noun) matching \"\(searchText)\"."
        }
        let listName = vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType)
        if vm.isLocal {
            return "Add \(noun) to \(listName) from any title's detail screen."
        }
        return "Add \(noun) to \(listName) on \(activeProviderType.displayName)."
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
            if let quick = quickProgress(entry) {
                Button { Task { await quick.run() } } label: {
                    Label(quick.title, systemImage: quick.icon)
                }
                .tint(.green)
            }
        }
        .contextMenu {
            libraryContextMenu(for: entry)
        }
        #endif
    }

    /// Ours: the row's long-press menu — move to any status, toggle private, remove.
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

    /// The one-step progress a row's swipe and a card's menu offer: one more episode or
    /// chapter, preserving the canonical score by passing it in the active format.
    private func quickProgress(_ entry: LibraryEntry) -> (title: String, icon: String, run: () async -> Void)? {
        return (entry.media.isManga ? "+1 CH" : "+1 EP", "plus.circle.fill", {
            // Pass the score in the active format so the canonical value is preserved (not
            // reinterpreted in a new scale).
            await vm.update(entry: entry, status: entry.status, progress: entry.progress + 1,
                            score: entry.displayScore(in: scoreFormat))
        })
    }

    /// Module-scraped and AniList/MAL entries navigate to a detail screen. Anime rows use
    /// `openAnime` (module-first routing → DetailView with episodes) instead of a synchronous
    /// NavigationLink to AniListDetailView (which has no episode list).
    @ViewBuilder
    private func navigableRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            editEntry(entry)
        }
        .zoomSource(entry.id, in: sheetZoom)
        .overlay(alignment: .center) {
            if resolvingAnimeId == entry.media.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openAnime(entry) }
    }

    /// Local imported files have no detail screen — tapping the row resumes playback.
    @ViewBuilder
    private func localFileRow(_ entry: LibraryEntry, source: LocalSource) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            editEntry(entry)   // tap the row content → edit sheet
        }
        .zoomSource(entry.id, in: sheetZoom)
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
        List {
            #if os(iOS)
            // The header rows live in the List in every state — loading, empty and error too —
            // so the List is always the first scroll view on screen. The source switcher scrolls
            // sideways, and a horizontal scroll view ahead of the List takes over the
            // `.searchable` bar, which opening a show then tears down (b49f014).
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
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
            if showsLibraryList {
                entryRows
            } else {
                statusContent
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // Only Retry itself responds; a List otherwise turns a row's lone button
                    // into a tap target for the whole row.
                    .buttonStyle(.borderless)
            }
            #else
            entryRows
            #endif
        }
        .softScrollEdges()
        .listStyle(.plain)
        .gooeyRefreshable { await refreshLibrary() }
    }

    private func refreshLibrary() async {
        // An explicit user request, so it always checks — the away-time throttle is
        // for automatic checks only.
        async let count: Void = refreshUnreadCountIfNeeded()
        await vm.refresh()
        await count
    }

    @ViewBuilder
    private var entryRows: some View {
        if gridLayout {
            gridRows
        } else {
            ForEach(displayedEntries, id: \.media.id) { entry in
                entryRow(entry)
            }
        }
    }

    // MARK: - Grid

    private var gridColumns: Int {
        #if os(iOS)
        horizontalSizeClass == .regular ? 6 : 3
        #else
        6
        #endif
    }

    #if os(iOS)
    /// The grid, in a scroll view of its own rather than the List. As List rows (a row per line
    /// of posters) holding a card lifted the whole line, so the menu seemed to belong to the
    /// row. The header rows come first in it, as in the List, so this scroll view is still the
    /// first on screen and keeps the search bar.
    private var gridScroll: some View {
        ScrollView {
            VStack(spacing: 0) {
                LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    .padding(.top, 4).padding(.bottom, 6)
                mediaTypeSegment
                    .padding(.horizontal, 16).padding(.bottom, 6)
                filterCapsuleRow
                    .padding(.horizontal, 16).padding(.bottom, 10)
                if showsLibraryList {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                             count: gridColumns),
                              spacing: 18) {
                        ForEach(displayedEntries, id: \.media.id) { entry in
                            gridCard(entry)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    statusContent
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.bottom, 24)
        }
        .softScrollEdges()
        .gooeyRefreshable { await refreshLibrary() }
    }

    /// A card: tap opens it, the pencil edits it, the long-press menu acts on it.
    private func gridCard(_ entry: LibraryEntry) -> some View {
        Button { openFromGrid(entry) } label: {
            LibraryGridCard(entry: entry, scoreFormat: scoreFormat)
        }
        .buttonStyle(LibraryCardButtonStyle())
        .overlay(alignment: .topLeading) {
            // Over the poster's corner, outside the card's own button so it isn't swallowed.
            GeometryReader { geo in
                Button { editEntry(entry) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(entry.media.title.displayTitle)")
                // Bottom-right of the 2:3 poster, above the progress bar.
                .position(x: geo.size.width - 20, y: geo.size.width * 1.5 - 24)
            }
        }
        .zoomSource(entry.id, in: sheetZoom)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            libraryContextMenu(for: entry)
            Divider()
            if let quick = quickProgress(entry) {
                Button { Task { await quick.run() } } label: { Label(quick.title, systemImage: quick.icon) }
            }
        }
    }
    #endif

    /// The grid, a List row per line of posters, so the List stays lazy and keeps the search bar.
    private var gridRows: some View {
        let columns = gridColumns
        let entries = displayedEntries
        let lines = stride(from: 0, to: entries.count, by: columns).map {
            Array(entries[$0..<min($0 + columns, entries.count)])
        }
        return ForEach(lines, id: \.first?.media.id) { line in
            HStack(alignment: .top, spacing: 12) {
                ForEach(line, id: \.media.id) { entry in
                    LibraryGridCard(entry: entry, scoreFormat: scoreFormat)
                        .zoomSource(entry.id, in: sheetZoom)
                        .contentShape(Rectangle())
                        .onTapGesture { openFromGrid(entry) }
                        .contextMenu {
                            libraryContextMenu(for: entry)
                            Divider()
                            if let quick = quickProgress(entry) {
                                Button { Task { await quick.run() } } label: { Label(quick.title, systemImage: quick.icon) }
                            }
                        }
                }
                // Keeps a short last line's posters the same size as the rest.
                ForEach(line.count..<columns, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif
            .listRowBackground(Color.clear)
        }
    }

    /// What tapping the title's row does, for a grid card — module-first, like the list.
    private func openFromGrid(_ entry: LibraryEntry) {
        if entry.media.isManga {
            openManga(entry)
        } else if let source = entry.localSource, source.kind == .localFile {
            resumeLocalFile(source)
        } else {
            openAnime(entry)
        }
    }

    private func editEntry(_ entry: LibraryEntry) {
        if !vm.isLocal && anilistAuth.isLoggedIn && malAuth.isLoggedIn && !dualSync {
            pendingEntry = entry
            showProviderPicker = true
        } else {
            selectedEntry = entry
        }
    }

    /// What shows in place of the entries while loading, after an error, or when the list is empty.
    @ViewBuilder
    private var statusContent: some View {
        if vm.isLoading {
            ProgressView()
        } else if let error = vm.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "wifi.slash")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await vm.refresh() } }
            }
        } else {
            ContentUnavailableView(
                emptyStateTitle,
                systemImage: emptyStateIcon,
                description: Text(emptyStateDescription)
            )
        }
    }

    // MARK: - Library content

    private var libraryContentBase: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // One List (or, laid out as a grid, one scroll view) in every state, the header rows
            // included — see `entriesList`.
            if gridLayout {
                gridScroll
            } else {
                entriesList
            }
            #else
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
            mediaTypeSegment
                .padding(.horizontal, 16)
                .padding(.top, 6)
            // Combined row: Status on left, Genres on right
            filterCapsuleRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if vm.isLoading || vm.error != nil || displayedEntries.isEmpty {
                statusContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entriesList
            }
            #endif
        }
        // Hidden programmatic links — ours: module-first routing for anime + manga rows.
        .background { mangaNavLink }
        .background { aniListMangaNavLink }
        .background { animeDetailNavLink }
        .background { animeNavLink }
        .navigationDestinationCompat(isPresented: $showNotifications) {
            NotificationsView(vm: profileVM)
        }
        .toolbarZoomSource("sort", in: sheetZoom, placement: toolbarItemPlacement[0]) { sortMenu }
        .toolbarZoomSource("account", in: sheetZoom, placement: toolbarItemPlacement[1]) { accountToolbarItem }
        .task { await vm.autoRefreshIfNeeded() }
        .task(id: vm.entries.map(\.media.uniqueId)) { await newEpisodes.observe(vm.entries) }
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
            else if !malAuth.isLoggedIn, case .provider = vm.source { vm.selectSource(sourceAfterSignOut) }
        }
        .onChangeOf(malAuth.isLoggedIn) { newValue in
            if newValue { vm.selectSource(.provider(.mal)) }
            else if !anilistAuth.isLoggedIn, case .provider = vm.source { vm.selectSource(sourceAfterSignOut) }
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
                        if !vm.isLocal && vm.mediaType != .manga && dualSync
                            && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
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
                        if !vm.isLocal && vm.mediaType != .manga && dualSync
                            && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
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
                }
            )
            .zoomingOut(of: entry.id, in: sheetZoom)
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
                    progressUnit: media.isManga ? "chapter" : "episode",
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
                // From the row "Edit on which service?" was asked about.
                .zoomingOut(of: pendingEntry?.id ?? 0, in: sheetZoom)
            }
        }
        .adaptiveSheet(isPresented: $showProfile) {
            if activeProviderType == .mal, let uid = malAuth.userId {
                ProfileView(userId: uid, username: malAuth.username ?? "Profile", avatarURL: malAuth.avatarURL)
            } else if let uid = anilistAuth.userId, let username = anilistAuth.username {
                ProfileView(userId: uid, username: username, avatarURL: anilistAuth.avatarURL)
            } else {
                profileUnavailable
            }
        }
        .adaptiveSheet(isPresented: $showManageCollections) {
            ManageCollectionsView()
                .zoomingOut(of: "sort", in: sheetZoom, fromToolbar: true)
        }
    }
}

private extension MediaKind {
    var pillTitle: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        }
    }

    var pillIcon: String {
        switch self {
        case .anime: return "tv"
        case .manga: return "book"
        }
    }

    /// "Add shows to Watching." / "Add anime to Planning."
    var noun: String {
        switch self {
        case .anime: return "anime"
        case .manga: return "manga"
        }
    }
}

// MARK: - Library row

/// A title in the Library's grid: its poster with score and a progress bar, its name and
/// where the viewer is below.
private struct LibraryGridCard: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal

    private var progressText: String {
        let unit = entry.media.isManga ? "Ch" : "Ep"
        if let total = entry.media.episodes, total > 0 { return "\(unit) \(entry.progress) of \(total)" }
        return "\(unit) \(entry.progress)"
    }

    /// How far through, when the total's known.
    private var fraction: Double? {
        guard let total = entry.media.episodes, total > 0 else { return nil }
        return min(Double(entry.progress) / Double(total), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: entry.media.coverImage.thumb ?? "")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        // Keeps the bar and the edit button readable on a light poster.
                        LinearGradient(stops: [.init(color: .clear, location: 0.6),
                                               .init(color: .black.opacity(0.6), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                )
                .overlay(alignment: .bottom) {
                    if let fraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(.white)
                                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry.score > 0 {
                        HStack(spacing: 2) {
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill").font(.system(size: 7))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    NewEpisodesBadge(entry: entry).padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                // Two lines' room whatever the title, so a row's cards line up below.
                ZStack(alignment: .topLeading) {
                    Text("A\nA").hidden().accessibilityHidden(true)
                    CardTitle(entry.media.title.displayTitle)
                        .multilineTextAlignment(.leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .hiddenWithCardTitles()
                Text(progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "+2" on a show you're watching with two aired episodes you haven't, and a red dot when
/// they came out since you last opened it.
private struct NewEpisodesBadge: View {
    let entry: LibraryEntry
    @ObservedObject private var tracker = NewEpisodeTracker.shared
    @AppStorage(NewEpisodeTracker.badgesKey) private var enabled = true

    var body: some View {
        let count = tracker.unwatched(entry)
        if enabled, count > 0 {
            let isNew = tracker.isNewSinceOpened(entry)
            Text("+\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.blue, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if isNew {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                    }
                }
                .accessibilityLabel(isNew ? "\(count) new episodes, new since you last opened it"
                                          : "\(count) episodes to watch")
        }
    }
}

/// A gentle press for a grid card, in place of a List row's grey highlight.
private struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

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
                        CachedAsyncImage(urlString: entry.media.coverImage.thumb ?? "")
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
                CardTitle(entry.media.title.displayTitle)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NewEpisodesBadge(entry: entry)
                }

                if let total = entry.media.episodes, total > 0 {
                    ProgressView(value: min(Double(entry.progress), Double(total)), total: Double(total))
                        .tint(.primary)
                        .scaleEffect(x: 1, y: 0.8, anchor: .center)
                        .frame(maxWidth: 180)
                }

                HStack(spacing: 8) {
                    if let avg = entry.media.averageScore {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 9))
                            Text("\(avg)%")
                                .font(.caption2.weight(.semibold))
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
                        }
                        .foregroundStyle(.yellow)
                    }
                    if let ts = entry.updatedAt {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
        .fullTitleContextMenu(entry.media.title.displayTitle)
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
