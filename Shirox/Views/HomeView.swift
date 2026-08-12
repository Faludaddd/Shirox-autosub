import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    // #111 — Observing AniListAuthManager here lets HomeView re-render the
    // Continue Watching section's signed-out prompt card the moment the user
    // completes (or signs out of) AniList auth, without needing a manual reload.
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    // Continue Watching context-menu navigation. Driven from here so the hidden
    // NavigationLink that performs the push sits OUTSIDE the ScrollView below.
    @State private var cwNavTarget: ContinueWatchingNavTarget?
    @State private var readerContext: ReaderContext?
    /// Controls navigation to the notifications page via NavigationLink.
    @State private var navigateToNotifications = false
    /// Drives the custom pull-to-refresh overlay (#98). Toggled at the start/end
    /// of the `.refreshable` task so `CustomRefreshControl` can spin while the
    /// reload is in flight. The system `.refreshable` spinner still drives the
    /// gesture; this just adds a branded overlay on top.
    @State private var isRefreshing = false
    // Requirement #3 — Top search icon and inline search bar removed.
    // The only search entry point is the bottom search tab (AniList-only).
    // Issue #5 — Browse Categories layout toggle. Defaults to `false` so the
    // carousel layout (AnimeSection horizontal strips) is the DEFAULT. When
    // ON, the grid layout (CategoryGridCard tiles) is shown instead.
    @AppStorage("browseCategoriesGridLayout") private var browseCategoriesGridLayout = false

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        NavigationStack {
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
                            Button("Retry") { Task { await vm.reload() } }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // ────────────────────────────────────────────────────────
                            // 1. HERO — Full-bleed featured carousel.
                            //    The ONLY hero element on the page; everything below it
                            //    is supporting content (grid + continue watching).
                            // ────────────────────────────────────────────────────────
                            if !vm.trending.isEmpty {
                                FeaturedCarousel(items: vm.trending)
                            }

                            // ────────────────────────────────────────────────────────
                            // 2. CONTINUE WATCHING / READING — horizontal strips
                            //    directly under the hero carousel. Kept iOS-only; on
                            //    tvOS/macOS these resume cards don't render.
                            // ────────────────────────────────────────────────────────
                            #if os(iOS)
                            if !continueWatching.items.isEmpty {
                                ContinueWatchingSection(items: continueWatching.items, navTarget: $cwNavTarget)
                            } else if !anilistAuth.isLoggedIn {
                                // #111 — When the user has no Continue Watching
                                // items AND is signed out, surface a sign-in
                                // prompt card in the same slot so the section
                                // isn't just invisible. Tapping the button pushes
                                // SourcesSettingsPage, where the user can connect
                                // AniList (and MAL) — once authed + watched, the
                                // real ContinueWatchingSection takes over here.
                                ContinueWatchingSignInPrompt()
                            }
                            if !mangaProgress.items.isEmpty {
                                ContinueReadingSection(items: mangaProgress.items, readerContext: $readerContext)
                            }
                            #endif

                            // ────────────────────────────────────────────────────────
                            // 3. BROWSE CATEGORIES — Issue #5. Two layouts, controlled
                            //    by `browseCategoriesGridLayout`:
                            //      • Default (setting OFF): horizontal carousels
                            //      • Alternate (setting ON): 2-column grid of tiles
                            //    The grid layout (currently shown) is now the NON-
                            //    default — it only appears when the setting is ON.
                            // ────────────────────────────────────────────────────────
                            if browseCategoriesGridLayout {
                                browseCategoriesGrid
                            } else {
                                AnimeSection(title: "This Season", items: vm.seasonal, category: .seasonal)
                                AnimeSection(title: "Trending Now", items: vm.trending, category: .trending)
                                AnimeSection(title: "All-Time Popular", items: vm.popular, category: .popular)
                                AnimeSection(title: "Top Rated", items: vm.topRated, category: .topRated)
                                AnimeSection(title: "Recently Completed", items: vm.recentlyCompleted, category: .popular)
                                AnimeSection(title: "Upcoming", items: vm.upcoming, category: .trending)
                            }

                            Spacer().frame(height: 28)
                        }
                    }
                    .refreshable {
                        // #96 — Light haptic when the user pulls to refresh.
                        Haptics.light()
                        // #98 — toggle the custom refresh overlay while the reload is in
                        // flight. `defer` guarantees the overlay clears even if a task throws.
                        isRefreshing = true
                        defer { isRefreshing = false }
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await vm.reload() }
                            group.addTask {
                                // Sequential: both sync funcs mutate the same CW store across
                                // await points, so running them concurrently could clobber items.
                                await ContinueWatchingManager.shared.syncWithAniList()
                                await ContinueWatchingManager.shared.syncWithMAL()
                            }
                        }
                    }
                    .coordinateSpace(name: "homeScroll")
                    // #98 — overlay the custom branded refresh control at the top of the
                    // scroll view. Applied OUTSIDE `.ignoresSafeArea` so the overlay lands
                    // below the status bar / notch, not under it. The control is only
                    // rendered while `isRefreshing` is true, so the resting state is clean.
                    .overlay(alignment: .top) {
                        if isRefreshing {
                            CustomRefreshControl(isRefreshing: $isRefreshing)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.horizontal, 80)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .zIndex(100)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: isRefreshing)
                    .ignoresSafeArea(edges: .top)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(TransparentNavBarModifier())
            #endif
            .toolbar {
                // Issue #2 — Notifications and Settings are grouped together
                // on the trailing side so they're visually adjacent. Both
                // remain functional and accessible; no duplicates.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: NotificationsPage()) {
                        Image(systemName: "bell")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ProviderMenuButton()
                }
            }
            // Outside the ScrollView: the hidden NavigationLink that performs the push.
            .continueWatchingNavigation($cwNavTarget)
            // Requirement #3 — Top search icon removed. The only search entry
            // point is the bottom search tab (AniList-only).
            #if os(iOS)
            .fullScreenCover(item: $readerContext) { ctx in
                MangaReaderView(context: ctx)
            }
            #endif
        }
        .task { await vm.load() }
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            // Reclaim local-file copies left by cancelled picks or finished/removed items.
            ContinueWatchingManager.shared.pruneOrphanedLocalImports()
            #endif
        }
    }

    // MARK: - Browse Categories Grid (#120 correction)
    //
    // The "built" grid layout — a 2-column LazyVGrid of `CategoryGridCard`
    // tiles, one per browse category. Each tile shows a representative cover
    // image (from the first item in that category's loaded data), a gradient
    // wash, the category title, and the item count. Tapping a tile pushes
    // `BrowseView` for that category.
    //
    // This layout was deleted in a prior pass; #120 correction restores it as
    // the DEFAULT browse layout (switched via `browseCategoriesGridLayout`).
    @ViewBuilder
    private var browseCategoriesGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse Categories")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(browseGridItems, id: \.title) { item in
                    NavigationLink {
                        BrowseView(category: item.category)
                    } label: {
                        CategoryGridCard(
                            title: item.title,
                            count: item.count,
                            iconName: item.iconName,
                            gradientColors: item.gradientColors,
                            imageURL: item.imageURL
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Config for each tile in the browse grid. `category` is the
    /// `BrowseCategory` used to fetch the full list when the tile is tapped;
    /// `count`/`imageURL` are seeded from the already-loaded HomeViewModel
    /// arrays so the tiles aren't empty while the full BrowseView loads.
    private struct BrowseGridItem {
        let title: String
        let category: BrowseCategory
        let iconName: String
        let gradientColors: [Color]
        let count: Int
        let imageURL: String?
    }

    private var browseGridItems: [BrowseGridItem] {
        [
            BrowseGridItem(
                title: "This Season", category: .seasonal, iconName: "leaf.fill",
                gradientColors: [Color.green.opacity(0.6), Color.teal.opacity(0.5)],
                count: vm.seasonal.count,
                imageURL: vm.seasonal.first?.coverImage.best
            ),
            BrowseGridItem(
                title: "Trending Now", category: .trending, iconName: "flame.fill",
                gradientColors: [Color.orange.opacity(0.6), Color.red.opacity(0.5)],
                count: vm.trending.count,
                imageURL: vm.trending.first?.coverImage.best
            ),
            BrowseGridItem(
                title: "All-Time Popular", category: .popular, iconName: "star.fill",
                gradientColors: [Color.purple.opacity(0.6), Color.indigo.opacity(0.5)],
                count: vm.popular.count,
                imageURL: vm.popular.first?.coverImage.best
            ),
            BrowseGridItem(
                title: "Top Rated", category: .topRated, iconName: "trophy.fill",
                gradientColors: [Color.yellow.opacity(0.6), Color.orange.opacity(0.5)],
                count: vm.topRated.count,
                imageURL: vm.topRated.first?.coverImage.best
            ),
            // #120 — Recently Completed and Upcoming use .popular/.trending as
            // fetch fallbacks (BrowseCategory only has 4 cases), but the tile
            // titles and gradients are distinct so the grid reads as 6 entries.
            BrowseGridItem(
                title: "Recently Completed", category: .popular, iconName: "checkmark.seal.fill",
                gradientColors: [Color.blue.opacity(0.6), Color.cyan.opacity(0.5)],
                count: vm.recentlyCompleted.count,
                imageURL: vm.recentlyCompleted.first?.coverImage.best
            ),
            BrowseGridItem(
                title: "Upcoming", category: .trending, iconName: "clock.fill",
                gradientColors: [Color.gray.opacity(0.6), Color.secondary.opacity(0.5)],
                count: vm.upcoming.count,
                imageURL: vm.upcoming.first?.coverImage.best
            ),
        ]
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [Media]
    // `selectedTab` starts in the *middle* rotation of a `displayCount * 3`
    // page window so the user can swipe freely in both directions. A bounded
    // window (previously 2000) keeps the TabView cheap; an edge-reset in
    // `onChange(of: selectedTab)` silently bounces the selection back to the
    // middle rotation when the user swipes into the first/last rotation, so the
    // carousel still *feels* infinite without materialising thousands of pages.
    @State private var selectedTab = 0
    @State private var containerWidth: CGFloat = 0
    @State private var stretchAmount: CGFloat = 0
    @State private var hasInteracted = false
    @State private var didSetup = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var realItems: [Media] { items.prefix(8).map { $0 } }
    private var displayCount: Int { realItems.count }

    /// Three rotations of `displayCount` — enough headroom in both swipe
    /// directions for the edge-reset to fire before the user ever sees a hard
    /// stop. Falls back to a single rotation when there's only one item.
    private var pageCount: Int { max(displayCount * 3, displayCount) }

    private var currentIndex: Int {
        guard displayCount > 0 else { return 0 }
        return selectedTab % displayCount
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let isIPad = sizeClass == .regular
        let effectiveWidth = containerWidth > 0 ? containerWidth : UIScreen.main.bounds.width
        let imageHeight: CGFloat = isIPad
            ? effectiveWidth * (9.0 / 16.0)
            : UIScreen.main.bounds.height - 140

        let displayItems = realItems
        let currentMedia = displayItems.isEmpty ? items[0] : displayItems[currentIndex]

        VStack(spacing: 0) {
            ZStack {
                // Pull-down sensor: sibling of TabView so re-evaluation never cascades into
                // TabView layout. Preference fires max(0,scrollY); stretchAmount only changes
                // when the user is pulling down — stable (= 0) during normal scroll and swipes.
                GeometryReader { proxy in
                    Color.clear.preference(key: CarouselStretchKey.self,
                                           value: max(0, proxy.frame(in: .named("homeScroll")).minY))
                }

                // iPad fanart background behind the cards
                if isIPad, !displayItems.isEmpty {
                    TVDBPosterImage(media: displayItems[currentIndex], type: .fanart)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // TabView: completely stable — fixed height, zero scroll dependency.
                // Images live inside FeaturedCard so they move naturally with swipe gestures.
                // The page count is `displayCount * 3` (bounded, was 2000) — see
                // `pageCount` / the edge-reset in `onChange(of: selectedTab)` for how
                // the infinite-wrap illusion is preserved with far fewer materialised pages.
                TabView(selection: $selectedTab) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        if !displayItems.isEmpty {
                            // `.equatable()` is applied directly to `FeaturedCard`
                            // (which conforms to Equatable) so the wrapper can
                            // short-circuit body re-evaluation; `.tag` is applied
                            // *after* so TabView selection always propagates.
                            FeaturedCard(media: displayItems[index % displayCount], isWide: isIPad)
                                .equatable()
                                .allowsHitTesting(false)
                                .tag(index)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
            }
            .frame(height: imageHeight)
            // Elastic stretch: render-only transforms — layout size never changes so
            // UIScrollView's bounce is never disrupted.
            // scaleEffect grows the image from the top anchor.
            // offset cancels the bounce displacement so the top edge stays pinned at screen y=0.
            .scaleEffect(1 + stretchAmount / imageHeight, anchor: .top)
            .offset(y: -stretchAmount)
            .onPreferenceChange(CarouselStretchKey.self) { y in stretchAmount = y }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChangeOf(geo.size.width) { w in containerWidth = w }
                }
            )
            .mask(alignment: .bottom) { Rectangle().frame(height: imageHeight + 2000) }
            .background {
                // Hidden preloader — triggers image fetch for all items into NSCache
                ForEach(displayItems.indices, id: \.self) { i in
                    TVDBPosterImage(media: displayItems[i], type: .fanart)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    TVDBPosterImage(media: displayItems[i], type: .poster)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: platformBackground.opacity(0.5), location: 0.38),
                            .init(color: platformBackground.opacity(0.88), location: 0.68),
                            .init(color: platformBackground, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 360)
                    .allowsHitTesting(false)

                    VStack(spacing: 10) {
                        Text(currentMedia.title.displayTitle)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        // Genre capsules — replace the previous multi-line description
                        // (which was too dense for a carousel). Up to 3 tags, capped.
                        if let genres = currentMedia.genres, !genres.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(genres.prefix(3), id: \.self) { g in
                                    Text(g)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.1), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                }
                            }
                        }

                        NavigationLink {
                            AniListDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.caption.weight(.bold))
                                Text("Watch").font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.primary)
                            .frame(width: 130, height: 38)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        // "Slide to browse" hint — fades out after the first swipe.
                        if !hasInteracted {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.compact.left")
                                    .font(.subheadline.weight(.bold))
                                Text("Slide to browse")
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "chevron.compact.right")
                                    .font(.subheadline.weight(.bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .animation(.easeOut(duration: 0.35), value: hasInteracted)
                }
            }

            PageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
        .onAppear {
            if displayCount > 0 {
                // Start in the middle rotation so the user can swipe in both
                // directions before the edge-reset kicks in.
                selectedTab = displayCount
            }
            // Defer enabling the swipe detector until the next runloop tick so
            // the initial `selectedTab` assignment above (which shifts from 0
            // to `displayCount`) isn't mistaken for a user swipe and instantly
            // dismiss the hint.
            DispatchQueue.main.async { didSetup = true }
        }
        .onChange(of: selectedTab) { _ in
            guard didSetup else { return }
            // First swipe dismisses the "Slide to browse" hint.
            if !hasInteracted { hasInteracted = true }
            // Infinite-wrap edge reset: when the user swipes into the first or
            // last rotation of the `displayCount * 3` window, silently jump
            // back to the equivalent slot in the middle rotation. Dispatched
            // async with animations disabled so the reset is invisible — the
            // visual page (`selectedTab % displayCount`) is unchanged, so no
            // content shifts. This is what lets a bounded TabView feel infinite.
            guard displayCount > 1 else { return }
            if selectedTab < displayCount || selectedTab >= displayCount * 2 {
                let middleSlot = displayCount + (selectedTab % displayCount)
                guard selectedTab != middleSlot else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { selectedTab = middleSlot }
                }
            }
        }
        #elseif !os(tvOS)
        MacFeaturedCarousel(items: realItems)
        #endif
    }
}

// MARK: - macOS Featured Carousel (lightweight, no TabView with 2000 items)

#if os(macOS) || targetEnvironment(macCatalyst)
private struct MacFeaturedCarousel: View {
    let items: [Media]
    @State private var currentIndex = 0
    @State private var timer: Timer?

    private var displayItems: [Media] { Array(items.prefix(8)) }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let cardHeight = geo.size.width * (9.0 / 16.0)
            ZStack(alignment: .bottom) {
                if !displayItems.isEmpty {
                    let media = displayItems[currentIndex]
                    ZStack(alignment: .bottomLeading) {
                        // Banner background
                        Group {
                            if let bannerUrl = media.bannerImage {
                                CachedAsyncImage(urlString: bannerUrl)
                            } else {
                                LinearGradient(
                                    colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.3)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: cardHeight)
                        .clipped()

                        // Gradient overlay
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(width: geo.size.width, height: cardHeight)

                        // Cover + text + watch button
                        HStack(alignment: .bottom, spacing: 12) {
                            CachedAsyncImage(urlString: media.coverImage.best ?? "")
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(radius: 4)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(media.title.displayTitle)
                                    .font(.title2).fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)

                                if let desc = media.plainDescription, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(2)
                                }

                                HStack(spacing: 8) {
                                    if let score = media.averageScore {
                                        Label("\(score)%", systemImage: "star.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.yellow)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    if let genres = media.genres, !genres.isEmpty {
                                        ForEach(genres.prefix(2), id: \.self) { genre in
                                            Text(genre)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.white.opacity(0.15), in: Capsule())
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }
                                }

                                NavigationLink {
                                    AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                        Text("Watch").fontWeight(.semibold)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(platformBackground)
                                    .frame(width: 110, height: 36)
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                    }
                    .frame(width: geo.size.width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                    .id(currentIndex)
                }

                PageIndicator(numberOfPages: displayItems.count, currentPage: currentIndex)
                    .padding(.bottom, 6)
            }
            .frame(width: geo.size.width, height: cardHeight)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard displayItems.count > 1 else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                currentIndex = (currentIndex + 1) % displayItems.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
#endif

// MARK: - Page Indicator (animated pill style)

private struct PageIndicator: View {
    let numberOfPages: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<numberOfPages, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: index == currentPage ? 20 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
    }
}

// MARK: - Featured Card (platform‑specific layout)

private struct FeaturedCard: View, Equatable {
    let media: Media
    var isWide: Bool = false

    private var aspectRatio: CGFloat {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return 2.0 / 3.0
        #else
        return 16.0 / 9.0
        #endif
    }

    static func == (lhs: FeaturedCard, rhs: FeaturedCard) -> Bool {
        // `Media.==` is keyed on `uniqueId`, so two cards render identically
        // whenever they point at the same title + wide flag. Used by
        // `.equatable()` in the carousel's ForEach to skip diffing the heavy
        // image/gradient tree on every TabView re-evaluation.
        lhs.media == rhs.media && lhs.isWide == rhs.isWide
    }

    var body: some View {
        Group {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if isWide {
                // iPad: fanart with horizontal parallax
                Color.clear
                    .overlay(
                        ZStack {
                            GeometryReader { geo in
                                let minX = geo.frame(in: .global).minX
                                let screenW = geo.size.width > 0 ? geo.size.width : 1
                                let extra: CGFloat = 80
                                let px = -(extra / 2) - minX * (extra / (2 * screenW))
                                TVDBPosterImage(media: media, type: .fanart)
                                    .frame(width: geo.size.width + extra, height: geo.size.height)
                                    .offset(x: px)
                                    .clipped()
                            }
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.4), location: 0.5),
                                    .init(color: .black.opacity(0.92), location: 1)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let pageOffset = geo.frame(in: .global).minX
                    let imageURL = media.coverImage.extraLarge ?? media.coverImage.large ?? ""
                    ZStack {
                        if let url = URL(string: imageURL) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable()
                                        .scaledToFill()
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .clipped()
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(x: -pageOffset * 0.25)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                }
                .clipped()
            }
            #else
            // macOS: banner background + poster overlay
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomLeading) {
                        bannerBackground
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        CachedAsyncImage(urlString: media.coverImage.best ?? "")
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 4)
                            .padding(.leading, 16)
                            .padding(.bottom, 12)

                        textContent
                            .padding(.leading, 16 + 80 + 8)
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            #endif
        }
    }

    // MARK: - Banner Background (macOS only)
    @ViewBuilder
    private var bannerBackground: some View {
        if let bannerUrlString = media.bannerImage {
            CachedAsyncImage(urlString: bannerUrlString)
        } else {
            gradientPlaceholder
        }
    }

    // MARK: - Text Content (shared)
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.title.displayTitle)
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(2)

            if let desc = media.plainDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let genres = media.genres, !genres.isEmpty {
                    ForEach(genres.prefix(2), id: \.self) { genre in
                        Text(genre)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var coverFallback: some View {
        TVDBPosterImage(media: media)
    }

    private var gradientPlaceholder: some View {
        LinearGradient(
            colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Anime Section

private struct AnimeSection: View {
    let title: String
    let items: [Media]
    let category: BrowseCategory
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var cardWidth: CGFloat {
        #if os(iOS)
        return sizeClass == .regular ? 190 : 155
        #else
        return 190
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 36, height: 3)
                }
                Spacer()
                NavigationLink {
                    BrowseView(category: category)
                } label: {
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { media in
                        NavigationLink {
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                        } label: {
                            AniListCardView(media: media)
                        }
                        .buttonStyle(HomePressStyle())
                        .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Carousel Stretch Preference

private struct CarouselStretchKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Press Style

private struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Adds a subtle accent-tinted glow while the card is pressed so the
        // "Selected category grid cards" feel responsive — gated by the user's
        // global Glow preference (Settings → Appearance → Glow).
        let glowOn: Bool = configuration.isPressed && Color.glowEnabled
        return configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .shadow(
                color: glowOn ? Color.appAccent.opacity(Color.glowIntensity * 0.6) : .clear,
                radius: glowOn ? CGFloat(21 * Color.glowIntensity) : 0
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Category Grid Card
//
// Large tappable tile used in the Home "Spotlight + Grid" layout. Each tile is
// 160pt tall, shows a representative image from its category, layered with a
// category-specific gradient + a dark legibility gradient, an icon badge, and
// the title + item count anchored to the bottom. Tapping is handled by the
// NavigationLink that wraps the card in the Home grid.

private struct CategoryGridCard: View, Equatable {
    let title: String
    let count: Int
    let iconName: String
    let gradientColors: [Color]
    let imageURL: String?

    private static let tileHeight: CGFloat = 180

    static func == (lhs: CategoryGridCard, rhs: CategoryGridCard) -> Bool {
        // Cards are static config (title/count/icon/gradient/imageURL); when
        // none of those change, the whole gradient+image stack can be skipped
        // during a Home re-render (e.g. when `vm.trending` updates and the
        // surrounding ScrollView re-evaluates).
        lhs.title == rhs.title && lhs.count == rhs.count
            && lhs.iconName == rhs.iconName && lhs.imageURL == rhs.imageURL
            && lhs.gradientColors.count == rhs.gradientColors.count
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Base layer: representative cover image if available, otherwise the
            // category gradient fills the whole tile so the card never looks
            // empty while images are still loading (or for offline categories).
            if let url = imageURL, !url.isEmpty {
                CachedAsyncImage(urlString: url)
                    .aspectRatio(contentMode: .fill)
                    .frame(height: Self.tileHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: Self.tileHeight)
                .frame(maxWidth: .infinity)
            }

            // Brand-tinted gradient wash — ties the image to the category color
            // even once the cover has loaded.
            LinearGradient(
                colors: [
                    gradientColors.first?.opacity(0.35) ?? .clear,
                    gradientColors.last?.opacity(0.65) ?? .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: Self.tileHeight)
            .frame(maxWidth: .infinity)
            .blendMode(.overlay)

            // Bottom-up dark gradient for text legibility over any image.
            LinearGradient(
                colors: [
                    .black.opacity(0.05),
                    .black.opacity(0.55),
                    .black.opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.tileHeight)
            .frame(maxWidth: .infinity)

            // Foreground content: icon badge (top-left) + count capsule
            // (top-right) + title (bottom).
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                    Spacer()
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(14)
        }
        .frame(height: Self.tileHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Schedule Settings (persisted)

/// Persisted schedule preferences, read by `ScheduleView` (defaults) and edited by
/// `ScheduleSettingsPage`. Stored in `UserDefaults` so `@AppStorage` can observe them.
enum ScheduleSettings {
    private static let windowDaysKey    = "scheduleWindowDays"
    private static let defaultModeKey   = "scheduleDefaultMode"
    private static let defaultUseUTCKey = "scheduleDefaultUseUTC"

    /// Look-ahead window in days (7/14/21/30). Defaults to 7.
    static var windowDays: Int {
        let stored = UserDefaults.standard.object(forKey: windowDaysKey) as? Int ?? 7
        return [7, 14, 21, 30].contains(stored) ? stored : 7
    }

    /// Default content mode. #124 — Schedule is Anime-only now; any persisted
    /// Western/Combined value is silently coerced back to `.anime` so the
    /// schedule view never enters a dead code path.
    static var defaultMode: ScheduleMode {
        let raw = UserDefaults.standard.string(forKey: defaultModeKey) ?? ScheduleMode.anime.rawValue
        let parsed = ScheduleMode(rawValue: raw) ?? .anime
        return parsed == .anime ? .anime : .anime
    }

    /// Default timezone toggle — `true` to show times in UTC. Defaults to local.
    static var defaultUseUTC: Bool {
        // `bool(forKey:)` returns `false` when the key is missing, which matches our default.
        UserDefaults.standard.bool(forKey: defaultUseUTCKey)
    }

    static func setWindowDays(_ days: Int) {
        let clamped = [7, 14, 21, 30].contains(days) ? days : 7
        UserDefaults.standard.set(clamped, forKey: windowDaysKey)
    }
    static func setDefaultMode(_ mode: ScheduleMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultModeKey)
    }
    static func setDefaultUseUTC(_ flag: Bool) {
        UserDefaults.standard.set(flag, forKey: defaultUseUTCKey)
    }
}

// MARK: - Schedule View

/// Schedule page — opened via the calendar icon in HomeView's toolbar.
///
/// Shows anime (AniList) and/or Western TV (TVMaze) episode schedules grouped by day.
/// Content source (Anime / Western / Combined), timezone (Local / UTC), and the
/// look-ahead window are all configured in `ScheduleSettingsPage` (gear icon) and
/// read live from `@AppStorage` here — the schedule tab itself has no pickers for
/// them, so it always reflects whatever the user picked in Settings. Each entry
/// shows a card with poster, badges, countdown, air-time capsule, and a
/// notification bell.
struct ScheduleView: View {
    @State private var entries: [UnifiedScheduleEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?

    // All three preferences are bound to the persisted defaults edited in
    // `ScheduleSettingsPage` — changes there propagate live into the schedule
    // tab via `@AppStorage`. There are no segmented pickers in the tab itself.
    @AppStorage("scheduleWindowDays")    private var windowDays: Int = 7
    @AppStorage("scheduleDefaultMode")   private var mode:   ScheduleMode = .anime
    @AppStorage("scheduleDefaultUseUTC") private var useUTC: Bool         = false

    // Calendar navigation. `monthStart` is the first day of the currently displayed
    // month; `selectedDate` is the day whose episodes are shown below the grid. Both
    // are start-of-day dates in the active calendar (local or UTC) so they line up
    // with the day buckets produced by `buildBuckets()`. The grid renders the whole
    // month (plus leading/trailing days from adjacent months to fill the 7-column
    // layout), replacing the previous 7-day week view (#80).
    @State private var monthStart: Date = ScheduleView.startOfMonth(for: Date(), utc: ScheduleSettings.defaultUseUTC)
    @State private var selectedDate: Date = ScheduleView.calendarFor(utc: ScheduleSettings.defaultUseUTC).startOfDay(for: Date())

    // Pending episode-notification schedule ids — drives the bell's on/off state.
    @State private var scheduledIds: Set<Int> = []

    // Drives push navigation to the schedule detail view from card taps and
    // context menus. `navigationDestinationCompat` honors this on iOS
    // (NavigationView shim), macOS, and tvOS. The detail view itself pushes
    // `AniListDetailView` via its own NavigationLink when the user taps
    // "View Full Details" — see `ScheduleDetailView` (#107).
    @State private var detailEntry: UnifiedScheduleEntry?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    scheduleLoadingView
                } else if let loadError = loadError, entries.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(loadError)
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Retry") { Task { await load() } }
                        }
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing Airing",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("No episodes in the next \(windowDays) day\(windowDays == 1 ? "" : "s") for this mode.")
                    )
                } else {
                    scheduleContent
                }
            }
            #if os(iOS)
            .background(Color(.systemBackground))
            #endif
            .navigationTitle("Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ScheduleSettingsPage()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationDestinationCompat(item: $detailEntry) { entry in
                ScheduleDetailView(
                    entry: entry,
                    useUTC: useUTC,
                    isNotificationOn: scheduledIds.contains(entry.id),
                    onToggleNotification: { toggleNotification(for: entry) }
                )
            }
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: mode) { _ in Task { await load() } }
            .onChange(of: windowDays) { _ in Task { await load() } }
            .onChange(of: useUTC) { _ in resetCalendarToToday() }
        }
    }

    // MARK: - Content

    // Issue #1/#3/#11 — Schedule date layouts. Each window range has its own
    // DISTINCT date selector design. The anime cards (ScheduleCard list) below
    // the selector are IDENTICAL across all ranges — only the date section
    // changes. The full Schedule pipeline (cards → countdown → notify →
    // notifications) is preserved untouched.
    @ViewBuilder
    private var scheduleContent: some View {
        let buckets = buildBuckets()
        let countByDay = Dictionary(uniqueKeysWithValues: buckets.map { ($0.date, $0.entries.count) })
        let selectedBucket = buckets.first(where: { calendar.isDate($0.date, inSameDayAs: selectedDate) })

        ScrollView {
            VStack(spacing: 0) {
                switch windowDays {
                case 30:  dateSelector1Month(buckets: buckets, countByDay: countByDay)
                default:  dateSelectorWeeks(buckets: buckets, countByDay: countByDay, dayCount: windowDays)
                }

                // ─── ANIME CARDS (identical for all ranges) ─────────────
                // Issue #11 — The anime card section is NOT changed. It uses
                // the original ScheduleCard design with live countdown,
                // notify-when-aired bell, and action buttons.
                if let bucket = selectedBucket, !bucket.entries.isEmpty {
                    LazyVStack(spacing: 12) {
                        HStack {
                            Text(bucket.shortTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 7, height: 7)
                                Text("\(bucket.entries.count) episode\(bucket.entries.count == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.red)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                        }
                        ForEach(bucket.entries) { entry in
                            NavigationLink {
                                ScheduleDetailView(
                                    entry: entry,
                                    useUTC: useUTC,
                                    isNotificationOn: scheduledIds.contains(entry.id),
                                    onToggleNotification: { toggleNotification(for: entry) }
                                )
                            } label: {
                                ScheduleCard(
                                    entry: entry,
                                    useUTC: useUTC,
                                    isNotificationOn: scheduledIds.contains(entry.id),
                                    onToggleNotification: { toggleNotification(for: entry) },
                                    onAddToPlanning:     { addToLibrary(entry, status: .planning) },
                                    onAddToWatching:     { addToLibrary(entry, status: .current) },
                                    onViewDetails:       { detailEntry = entry }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No episodes airing this day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func dateSelectorWeeks(buckets: [ScheduleDayBucket], countByDay: [Date: Int], dayCount: Int) -> some View {
        let today = calendar.startOfDay(for: Date())
        let days: [Date] = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(days, id: \.self) { (day: Date) in
                        let count = countByDay[day] ?? 0
                        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
                        let isToday = calendar.isDateInToday(day)
                        let hasEpisodes = count > 0
                        let dayNum = calendar.component(.day, from: day)
                        let dayLabel = weekdayShort(for: day)
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selectedDate = day
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text(dayLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? .white : .secondary)
                                Text("\(dayNum)")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                if hasEpisodes {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 5, height: 5)
                                } else if isToday {
                                    Circle()
                                        .fill(Color.red.opacity(0.5))
                                        .frame(width: 5, height: 5)
                                } else {
                                    Spacer().frame(height: 5)
                                }
                            }
                            .frame(width: 58, height: 72)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? Color.appAccent : Color.secondary.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        isToday && !isSelected ? Color.red.opacity(0.4) : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .id(day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo(today, anchor: .center)
            }
        }
    }

    // MARK: - 1 Month Date Selector
    //
    // Issue #3 — Shows ONLY the current calendar month. No prev/next
    // navigation buttons, no month swiping, no trailing/leading days from
    // adjacent months. The month auto-updates when the real calendar month
    // changes (monthStart is always derived from the current date, never
    // from user navigation).
    //
    // Layout: clean calendar grid with weekday headers. Only current-month
    // days are shown — no greyed-out adjacent-month dates.

    @ViewBuilder
    private func dateSelector1Month(buckets: [ScheduleDayBucket], countByDay: [Date: Int]) -> some View {
        // Issue #3 — monthStart is ALWAYS the current month. The user cannot
        // navigate. When the real calendar month changes, this re-derives
        // from Date() automatically.
        let currentMonthStart = ScheduleView.startOfMonth(for: Date(), utc: useUTC)
        let monthDays = currentMonthOnlyDays(from: currentMonthStart)

        VStack(spacing: 0) {
            // Month header — NO navigation arrows (Issue #3).
            Text(monthYearHeader(for: currentMonthStart))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
                .padding(.bottom, 8)

            // Weekday labels (Sun–Sat)
            HStack(spacing: 6) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Calendar grid — ONLY current-month days. No leading/trailing
            // days from adjacent months (Issue #3). Empty cells pad the
            // start of the grid so the 1st aligns with the correct weekday.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                spacing: 4
            ) {
                ForEach(monthDays, id: \.self) { day in
                    if let day = day {
                        let count = countByDay[day] ?? 0
                        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
                        let isToday = calendar.isDateInToday(day)
                        let dayNum = calendar.component(.day, from: day)
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selectedDate = day
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(dayNum)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                if count > 0 {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 5, height: 5)
                                } else if isToday {
                                    Circle()
                                        .fill(Color.red.opacity(0.5))
                                        .frame(width: 5, height: 5)
                                } else {
                                    Spacer().frame(height: 5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        isSelected ? Color.primary.opacity(0.35) :
                                        (isToday ? Color.primary.opacity(0.3) : Color.clear),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Empty cell for weekday alignment (no adjacent-month day)
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .frame(minHeight: 48)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Helpers for date selectors

    /// Short weekday abbreviation (e.g. "Mon", "Tue").
    private func weekdayShort(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = calendar.locale ?? Locale.current
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    /// Month/year header for a specific month start date.
    private func monthYearHeader(for monthStart: Date) -> String {
        let f = DateFormatter()
        f.locale = calendar.locale ?? Locale.current
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthStart)
    }

    /// Issue #3 — Returns only the days in the current month, plus leading
    /// `nil` entries for weekday alignment. NO trailing/leading days from
    /// adjacent months.
    private func currentMonthOnlyDays(from monthStart: Date) -> [Date?] {
        let cal = calendar
        guard let monthInterval = cal.dateInterval(of: .month, for: monthStart) else { return [] }
        let firstDay = monthInterval.start
        let weekdayOfFirst = cal.component(.weekday, from: firstDay)
        // Pad with nils so the 1st aligns with the correct weekday column.
        // weekday is 1-based (1=Sunday), and our grid starts with Sunday.
        var days: [Date?] = Array(repeating: nil, count: weekdayOfFirst - 1)
        var current = firstDay
        while current < monthInterval.end {
            days.append(current)
            current = cal.date(byAdding: .day, value: 1, to: current) ?? current
        }
        return days
    }



    private var scheduleLoadingView: some View {
        VStack(spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 56, height: 80)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 140, height: 10)
                        HStack(spacing: 6) {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 50, height: 18)
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 36, height: 18)
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 60, height: 18)
                        }
                    }
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Loading

    /// Fetches schedule entries from the source(s) selected by `mode`, starting at the
    /// beginning of today (not the current moment) so episodes that aired earlier today
    /// stay visible. Combined mode fetches both sources concurrently via `async let`.
    ///
    /// #93 — For the anime source, we first probe `AniListService`'s in-memory
    /// cache (populated by the splash preload). If the cache has fresh data
    /// covering this exact window we skip the network call entirely — so when
    /// the preload completed during the 3.5s splash, `ScheduleView` renders
    /// instantly with no spinner.
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Fetch window is always anchored to local-midnight today (independent of the
        // display timezone toggle) so the same set of episodes is fetched regardless of
        // whether times are shown in Local or UTC. Named `fetchCalendar` to avoid
        // shadowing the `calendar` computed property below.
        let fetchCalendar = Calendar.current
        let startOfToday = fetchCalendar.startOfDay(for: Date())
        let startTs = Int(startOfToday.timeIntervalSince1970)
        let endTs = startTs + max(windowDays, 1) * 86_400

        var fetched: [UnifiedScheduleEntry] = []
        do {
            switch mode {
            case .anime:
                // #93 — Cache hit from the splash preload? Skip the network.
                if let cached = AniListService.shared.cachedAiringSchedules(from: startTs, to: endTs) {
                    fetched = cached.map { UnifiedScheduleEntry(item: $0) }
                } else {
                    let items = try await AniListService.shared.airingSchedules(from: startTs, to: endTs)
                    fetched = items.map { UnifiedScheduleEntry(item: $0) }
                }

            case .western, .combined:
                // #124 — Western and Combined are no longer selectable from
                // settings; `ScheduleSettings.defaultMode` always coerces to
                // `.anime`. Treat any stale persisted value as Anime so the
                // schedule stays functional instead of crashing into a dead
                // TVMaze path the user can no longer opt into.
                if let cached = AniListService.shared.cachedAiringSchedules(from: startTs, to: endTs) {
                    fetched = cached.map { UnifiedScheduleEntry(item: $0) }
                } else {
                    let items = try await AniListService.shared.airingSchedules(from: startTs, to: endTs)
                    fetched = items.map { UnifiedScheduleEntry(item: $0) }
                }
            }

            // Defensive filter: drop anything that fell before the start of today.
            fetched = fetched.filter { $0.airingAt >= startTs }
            // Sort by popularity (desc) first, then airing time (asc) for ties so the
            // most popular shows surface to the top of each day's section.
            entries = fetched.sorted {
                if $0.popularity != $1.popularity {
                    return $0.popularity > $1.popularity
                }
                return $0.airingAt < $1.airingAt
            }

            // Reset the calendar to today after every reload.
            resetCalendarToToday()

            // Refresh the pending-notification set so the bells reflect current state.
            scheduledIds = await EpisodeNotificationManager.shared.scheduledScheduleIds()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// #93 — Helper used by the `.combined` branch of `load()`. Returns the
    /// cached schedule entries for the window if the splash preload already
    /// populated them, otherwise fetches fresh. Kept as a separate function
    /// so it can be wrapped in `async let` alongside the Western fetch.
    private func fetchAnimeCachedOrFresh(from: Int, to: Int) async throws -> [AniListAiringScheduleItem] {
        if let cached = AniListService.shared.cachedAiringSchedules(from: from, to: to) {
            return cached
        }
        return try await AniListService.shared.airingSchedules(from: from, to: to)
    }

    // MARK: - Day bucketing & calendar grid (timezone-aware)

    /// Active calendar — local or UTC, with Sunday (`firstWeekday = 1`) as the first day
    /// so the 7-column grid always starts on Sunday. The local branch keeps using
    /// `Calendar.current` (preserving the previous bucketing behaviour); only the UTC
    /// branch forces a Gregorian calendar with a UTC timezone.
    private var calendar: Calendar {
        Self.calendarFor(utc: useUTC)
    }

    private static func calendarFor(utc: Bool) -> Calendar {
        var cal: Calendar
        if utc {
            cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        } else {
            cal = Calendar.current
        }
        cal.firstWeekday = 1
        return cal
    }

    /// Sunday of the week containing `date`, in the active calendar.
    private static func startOfWeek(for date: Date, utc: Bool) -> Date {
        let cal = calendarFor(utc: utc)
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// First day of the month containing `date`, in the active calendar. Used as
    /// the anchor for the month-grid view (#80) — `monthStart` always points at
    /// the 1st of the displayed month so the grid can be built deterministically.
    private static func startOfMonth(for date: Date, utc: Bool) -> Date {
        let cal = calendarFor(utc: utc)
        return cal.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// Groups entries into day buckets using the active calendar (local or UTC). This
    /// bypasses `ScheduleDayBucket.build` (which is hard-wired to `Calendar.current`) so
    /// the day boundaries match the displayed times. The bucket keys are start-of-day
    /// `Date`s, which line up 1:1 with the dates produced by `currentMonthGridDays()`
    /// so the calendar grid can look up each day's episode count directly.
    private func buildBuckets() -> [ScheduleDayBucket] {
        let cal = calendar
        var grouped: [Date: [UnifiedScheduleEntry]] = [:]
        for entry in entries {
            let airDate = Date(timeIntervalSince1970: TimeInterval(entry.airingAt))
            let dayStart = cal.startOfDay(for: airDate)
            grouped[dayStart, default: []].append(entry)
        }
        return grouped.keys.sorted().map { day in
            let dayEntries = grouped[day] ?? []
            // Within each day: higher popularity first, then earlier air time.
            let sorted = dayEntries.sorted {
                if $0.popularity != $1.popularity {
                    return $0.popularity > $1.popularity
                }
                return $0.airingAt < $1.airingAt
            }
            return ScheduleDayBucket(date: day, entries: sorted)
        }
    }

    /// All days needed to fill the 7-column grid for the displayed month — every
    /// day in `monthStart`'s month plus leading days from the previous month (so
    /// the grid starts on Sunday) and trailing days from the next month (so the
    /// grid ends on Saturday). The result is always a whole number of weeks; for
    /// a standard month this is 4–6 rows of 7. Capped at 42 days (6 rows) as a
    /// safety net. Out-of-month days are styled grey by `dayCell` (#80).
    private func currentMonthGridDays() -> [Date] {
        let cal = calendar
        guard let monthInterval = cal.dateInterval(of: .month, for: monthStart),
              let firstWeekInterval = cal.dateInterval(of: .weekOfYear, for: monthInterval.start) else {
            return []
        }
        var days: [Date] = []
        var current = firstWeekInterval.start
        // Keep adding days until we've fully covered the month AND the row count
        // is a whole number of weeks. The 42-day cap guards against pathological
        // calendar configurations.
        while current < monthInterval.end || days.count % 7 != 0 {
            days.append(current)
            current = cal.date(byAdding: .day, value: 1, to: current) ?? current
            if days.count >= 42 { break }
        }
        return days
    }

    /// Short weekday symbols (Sun, Mon, …, Sat) for the active calendar's locale.
    private var weekdayLabels: [String] {
        Array(calendar.shortWeekdaySymbols.prefix(7))
    }

    /// Month/year header — always a single "August 2026" string driven by
    /// `monthStart` (the first day of the displayed month). With the month-grid
    /// view (#80) there's no longer any ambiguity about which month to show,
    /// so the previous fallback logic (which picked Wednesday of the visible
    /// week when the selection fell outside it) is no longer needed.
    private var monthYearHeader: String {
        let cal = calendar
        let f = DateFormatter()
        f.locale = cal.locale ?? Locale.current
        f.timeZone = cal.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthStart)
    }

    /// Shifts the displayed month by `months` (±1). The selection follows into
    /// the new month, keeping the same day-of-month when possible. If the new
    /// month is shorter (e.g. Jan 31 → Feb 28), the selection clamps to the
    /// last day of the new month so it always lands on a valid date (#80).
    private func shiftMonth(by months: Int) {
        let cal = calendar
        withAnimation(.easeOut(duration: 0.2)) {
            guard let newMonthStart = cal.date(byAdding: .month, value: months, to: monthStart) else { return }
            monthStart = newMonthStart
            // Preserve the selected day-of-month in the new month, clamping to
            // the last valid day if the new month is shorter (e.g. Jan 31 → Feb 28).
            if let maxDay = cal.range(of: .day, in: .month, for: newMonthStart) {
                let wantedDay = min(cal.component(.day, from: selectedDate), maxDay.count)
                var comps = cal.dateComponents([.year, .month], from: newMonthStart)
                comps.day = wantedDay
                if let newSelected = cal.date(from: comps) {
                    selectedDate = cal.startOfDay(for: newSelected)
                }
            }
        }
    }

    /// Snaps the calendar back to today — used after a reload and after a timezone
    /// toggle so the user lands on the current day in the new calendar.
    private func resetCalendarToToday() {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let newMonthStart = Self.startOfMonth(for: Date(), utc: useUTC)
        withAnimation(.easeOut(duration: 0.2)) {
            selectedDate = today
            monthStart = newMonthStart
        }
    }

    // MARK: - Bell (notifications)

    /// Toggles the episode-airing notification for `entry` on or off via
    /// `EpisodeNotificationManager`. Scheduling requires notification authorization; if
    /// the user hasn't granted it, we prompt and bail out on denial.
    private func toggleNotification(for entry: UnifiedScheduleEntry) {
        if scheduledIds.contains(entry.id) {
            EpisodeNotificationManager.shared.cancel(scheduleId: entry.id)
            scheduledIds.remove(entry.id)
            ToastManager.shared.show(
                title: "Schedule",
                message: "Notification cancelled",
                icon: "info.circle.fill",
                iconColor: .accentColor
            )
            return
        }
        Task {
            let granted = await EpisodeNotificationManager.shared.requestAuthorization()
            guard granted else {
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Enable notifications in Settings to receive episode alerts",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
                return
            }
            let mediaId = entry.aniListMediaId ?? 0
            let result = await EpisodeNotificationManager.shared.schedule(
                scheduleId: entry.id,
                mediaId: mediaId,
                title: entry.title,
                episode: entry.episode,
                airingAt: entry.airingAt
            )
            switch result {
            case .success:
                scheduledIds.insert(entry.id)
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Notification scheduled",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
            case .alreadyAired:
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "This episode has already aired",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            case .phoneNotificationsDisabled:
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Phone notifications are disabled in Settings",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            case .permissionDenied:
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Notification permission was denied",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            case .failed(let error):
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Failed: \(error)",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            }
        }
    }

    // MARK: - Library actions

    /// Adds `entry` to the user's AniList library under the given status (Planning or Watching).
    /// Only anime entries (which carry an AniList media id) can be tracked this way.
    private func addToLibrary(_ entry: UnifiedScheduleEntry, status: MediaListStatus) {
        guard let mediaId = entry.aniListMediaId else {
            ToastManager.shared.show(
                title: "Library",
                message: "Western shows can't be tracked here — add them on AniList first",
                icon: "info.circle.fill",
                iconColor: .accentColor
            )
            return
        }
        Task {
            do {
                try await AniListLibraryService.shared.updateEntry(
                    mediaId: mediaId,
                    status: status,
                    progress: 0
                )
                // #96 — Success haptic when the entry lands in the user's library.
                Haptics.success()
                ToastManager.shared.show(
                    title: "Library",
                    message: "Added to \(status.displayName)",
                    icon: "plus.circle.fill",
                    iconColor: .green
                )
            } catch {
                ToastManager.shared.show(
                    title: "Library",
                    message: "Failed: \(error.localizedDescription)",
                    icon: "exclamationmark.circle.fill",
                    iconColor: .red
                )
            }
        }
    }

    // MARK: - Detail navigation

    // NOTE: Direct push of `AniListDetailView` from the schedule list was removed in #107.
    // Card taps and the "View Details" context-menu action now push `ScheduleDetailView`,
    // which itself hosts the "View Full Details" NavigationLink to `AniListDetailView`
    // for anime entries. Western entries have no AniList media id, so the detail view
    // shows an informational hint in place of that button.
}

// MARK: - Schedule Card

/// One row in the schedule list. Shows poster, title, EP badge, colored format badge,
/// source badge, countdown, air-time capsule, and a notification bell. Long-press for a
/// context menu with library actions and "View Details".
private struct ScheduleCard: View {
    let entry: UnifiedScheduleEntry
    let useUTC: Bool
    let isNotificationOn: Bool
    let onToggleNotification: () -> Void
    let onAddToPlanning: () -> Void
    let onAddToWatching: () -> Void
    let onViewDetails: () -> Void

    private var timeZone: TimeZone {
        useUTC ? (TimeZone(identifier: "UTC") ?? .current) : .current
    }

    /// Compact "Apr 15, 3:00 PM" capsule, formatted in the selected timezone.
    private var airTimeCapsule: String {
        let date = Date(timeIntervalSince1970: TimeInterval(entry.airingAt))
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    /// Color for the format badge. Avoids blue/indigo (per app style guide).
    private var formatBadgeColor: Color {
        switch (entry.format ?? "").uppercased() {
        case "TV":      return .green
        case "MOVIE":   return .pink
        case "OVA":     return .orange
        case "ONA":     return .teal
        case "SPECIAL": return .yellow
        case "MUSIC":   return .gray
        default:        return .gray
        }
    }

    private var sourceBadgeColor: Color {
        entry.source == .anime ? .purple : .cyan
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Poster
            CachedAsyncImage(urlString: entry.coverImage ?? "")
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                )

            // Title + badges + countdown + time capsule
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Badges — all `.fixedSize()` so they sit on one row instead of stacking.
                HStack(spacing: 6) {
                    Text(entry.episodeBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .fixedSize()

                    if let format = entry.format, !format.isEmpty {
                        Text(format)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(formatBadgeColor.opacity(0.22), in: Capsule())
                            .foregroundStyle(formatBadgeColor)
                            .fixedSize()
                    }

                    Text(entry.source == .anime ? "Anime" : "Western")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sourceBadgeColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(sourceBadgeColor)
                        .fixedSize()

                    if entry.isStreamingRelease {
                        Label("Stream", systemImage: "play.tv.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                            .fixedSize()
                    }
                }

                // Countdown + time capsule
                HStack(spacing: 8) {
                    Text(entry.countdownDisplay)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(airTimeCapsule)
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }

            Spacer(minLength: 4)

            // Notification bell
            Button(action: onToggleNotification) {
                Image(systemName: isNotificationOn ? "bell.badge.fill" : "bell.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isNotificationOn ? Color.yellow : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            isNotificationOn ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.1)
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isNotificationOn ? "Cancel notification" : "Schedule notification")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .modifier(ScheduleCardContextMenu(
            entry: entry,
            onAddToPlanning: onAddToPlanning,
            onAddToWatching: onAddToWatching,
            onViewDetails: onViewDetails
        ))
    }
}

// MARK: - Schedule Card Context Menu (with long-press preview)

/// Context-menu modifier for `ScheduleCard`.
///
/// On iOS 16+ / macOS 13+ / tvOS 17+, attaches a larger preview (poster + title +
/// episode badge) that SwiftUI shows above the menu when the user long-presses the
/// card. On older OSes (e.g. iOS 15) the `preview` parameter isn't available, so we
/// fall back to the default system preview.
private struct ScheduleCardContextMenu: ViewModifier {
    let entry: UnifiedScheduleEntry
    let onAddToPlanning: () -> Void
    let onAddToWatching: () -> Void
    let onViewDetails: () -> Void

    @ViewBuilder private var menuItems: some View {
        Button {
            onAddToPlanning()
        } label: {
            Label("Add to Planning", systemImage: "calendar.badge.plus")
        }
        Button {
            onAddToWatching()
        } label: {
            Label("Add to Watching", systemImage: "play.circle")
        }
        Button {
            onViewDetails()
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
    }

    /// Larger preview shown above the context menu — poster, title, and episode badge.
    @ViewBuilder private var previewContent: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(urlString: entry.coverImage ?? "")
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            Text(entry.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 220)

            Text(entry.episodeBadge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, tvOS 17, *) {
            content.contextMenu {
                menuItems
            } preview: {
                previewContent
            }
        } else {
            // iOS 15 / older: no `preview` parameter — default preview is used.
            content.contextMenu {
                menuItems
            }
        }
    }
}

// MARK: - Schedule Detail View (#107)

/// Purpose-built detail screen for a single schedule entry.
///
/// Unlike `AniListDetailView` (a full media page), this view focuses on the *airing
/// countdown* — a big, live-updating timer front and center, with a full-width poster,
/// episode/format badges, air date+time, genres, a Set Reminder toggle, and a
/// "View Full Details" button that pushes the standard AniList detail page for anime
/// entries. The whole screen sits on a frosted-glass material backdrop so it reads as a
/// distinct, glanceable "what's airing next" surface rather than a second detail page.
struct ScheduleDetailView: View {
    let entry: UnifiedScheduleEntry
    let useUTC: Bool
    let isNotificationOn: Bool
    let onToggleNotification: () -> Void

    private var timeZone: TimeZone {
        useUTC ? (TimeZone(identifier: "UTC") ?? .current) : .current
    }

    /// Color for the format badge — mirrors `ScheduleCard.formatBadgeColor`. Avoids
    /// blue/indigo per the app style guide.
    private var formatBadgeColor: Color {
        switch (entry.format ?? "").uppercased() {
        case "TV":      return .green
        case "MOVIE":   return .pink
        case "OVA":     return .orange
        case "ONA":     return .teal
        case "SPECIAL": return .yellow
        case "MUSIC":   return .gray
        default:        return .gray
        }
    }

    private var sourceBadgeColor: Color {
        entry.source == .anime ? .purple : .cyan
    }

    /// Absolute air date + time formatted in the selected timezone (Local / UTC).
    private var airDateTimeDisplay: String {
        let date = Date(timeIntervalSince1970: TimeInterval(entry.airingAt))
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroPoster
                contentSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(frostedBackground)
        .navigationTitle(entry.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Hero Poster

    /// Full-width, 200pt-tall cover image with a bottom-up dark gradient scrim for
    /// text legibility, plus the format + source badges pinned to the top-trailing
    /// corner over the image.
    private var heroPoster: some View {
        ZStack(alignment: .top) {
            CachedAsyncImage(urlString: entry.coverImage ?? "")
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.0), .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let format = entry.format, !format.isEmpty {
                        Text(format)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(formatBadgeColor.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(entry.source == .anime ? "Anime" : "Western")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(sourceBadgeColor.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(12)
            }
        }
        .frame(height: 200)
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Title — large bold.
            Text(entry.title)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Episode number badge — slightly larger than the card's.
            Text(entry.episodeBadge)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.18), in: Capsule())
                .fixedSize()

            // BIG countdown timer — live-updating via TimelineView, reuses
            // `entry.countdownDisplay` so the wording matches the schedule list.
            countdownCard

            // Air date + time row.
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(airDateTimeDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Genres — only when the schedule entry actually carries them.
            if let genres = entry.genres, !genres.isEmpty {
                genresSection(genres: genres)
            }

            // Action buttons.
            VStack(spacing: 10) {
                reminderButton
                viewFullDetailsButton
            }
            .padding(.top, 4)
        }
        .padding(20)
    }

    // MARK: - Countdown Card

    /// Prominent countdown display. `TimelineView` re-evaluates
    /// `entry.countdownDisplayWithSeconds` every 1s so the timer stays live
    /// down to the second — the detail view is the one place we want full
    /// granularity (days / hours / minutes / seconds). The label switches
    /// between "Airs In" (future) and "Aired" (past) to match the countdown's
    /// tense.
    private var countdownCard: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            let display = entry.countdownDisplayWithSeconds
            let isPast = display.hasPrefix("aired")
            VStack(alignment: .leading, spacing: 6) {
                Text(isPast ? "Aired" : "Airs In")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(display)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Reminder Button

    private var reminderButton: some View {
        Button(action: onToggleNotification) {
            Label(
                isNotificationOn ? "Reminder Set" : "Set Reminder",
                systemImage: isNotificationOn ? "bell.badge.fill" : "bell.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isNotificationOn
                    ? Color.yellow.opacity(0.22)
                    : Color.accentColor.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .foregroundStyle(isNotificationOn ? Color.yellow : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isNotificationOn ? "Cancel reminder" : "Set reminder")
    }

    // MARK: - View Full Details Button

    /// Pushes the standard `AniListDetailView` for anime entries that have an AniList
    /// media id. Western entries (no AniList cross-reference) get an informational hint
    /// instead — they have no full detail page in the app.
    @ViewBuilder
    private var viewFullDetailsButton: some View {
        if let mediaId = entry.aniListMediaId {
            NavigationLink {
                AniListDetailView(mediaId: mediaId, preloadedMedia: nil)
            } label: {
                Label("View Full Details", systemImage: "info.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Color.secondary.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Western shows don't have an AniList detail page")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }

    // MARK: - Genres

    @ViewBuilder
    private func genresSection(genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Genres")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .foregroundStyle(.primary)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Frosted Background

    /// Frosted-glass material backdrop spanning the whole screen (including under the
    /// safe area) — gives the detail page a distinct, airy feel versus the standard
    /// list/detail backgrounds. The opaque hero poster covers the top 200pt; the content
    /// below shows the frosted glass behind it.
    private var frostedBackground: some View {
        Rectangle()
            .fill(.regularMaterial)
            .ignoresSafeArea()
    }
}

// MARK: - Schedule Settings Page

/// Settings page for the schedule — pushed from the gear icon in `ScheduleView`'s toolbar.
/// Edits the persisted defaults: look-ahead window (7/14/21/30 days), and default timezone
/// (Local / UTC).
///
/// #124 — Content Mode picker was removed: the schedule now only ever shows
/// Anime. Western and Combined are no longer selectable. Section HEADERS are
/// intentionally retained here (#121 correction — Schedule settings is exempt
/// from the global "remove all section headers" rule).
struct ScheduleSettingsPage: View {
    @State private var windowDays: Int        = ScheduleSettings.windowDays
    @State private var defaultUseUTC: Bool    = ScheduleSettings.defaultUseUTC

    var body: some View {
        Form {
            Section {
                Picker("Window Range", selection: $windowDays) {
                    Text("1 Week").tag(7)
                    Text("2 Weeks").tag(14)
                    Text("3 Weeks").tag(21)
                    Text("1 Month").tag(30)
                }
                .onChange(of: windowDays) { value in
                    ScheduleSettings.setWindowDays(value)
                }
            } header: {
                Text("Window Range")
            } footer: {
                Text("How many days ahead to fetch and display in the schedule. AniList airing data covers the full window.")
            }

            Section {
                Picker("Default Timezone", selection: $defaultUseUTC) {
                    Text("Local").tag(false)
                    Text("UTC").tag(true)
                }
                .onChange(of: defaultUseUTC) { value in
                    ScheduleSettings.setDefaultUseUTC(value)
                }
            } header: {
                Text("Timezone")
            } footer: {
                Text("Whether air times are shown in your local timezone or UTC by default.")
            }
        }
        .navigationTitle("Schedule Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Notifications Page

/// Notifications page — opened via the bell icon in HomeView's toolbar.
struct NotificationsPage: View {
    @State private var notifications: [AniListNotification] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && notifications.isEmpty {
                notifLoadingView
            } else if let error = error, notifications.isEmpty {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.slash", description: Text(error))
            } else if notifications.isEmpty {
                ContentUnavailableView("No Notifications", systemImage: "bell.slash", description: Text("You're all caught up!"))
            } else {
                // Issue #6 — Redesigned Notifications layout. Uses a
                // ScrollView + LazyVStack of card-style rows instead of a
                // plain List, so the larger artwork and redesigned card
                // layout can breathe with proper spacing and hierarchy.
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(notifications, id: \.id) { notification in
                            NotificationRow(notification: notification)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private var notifLoadingView: some View {
        // Issue #6 — Skeleton matches the redesigned NotificationRow layout:
        // a 75×105 rounded-rectangle poster placeholder on the left and
        // three stacked text bars on the right.
        VStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(alignment: .top, spacing: 16) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 75, height: 105)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 100, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 16)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 200, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 60, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private func load() async {
        isLoading = true; error = nil
        do { notifications = try await AniListSocialService.shared.fetchNotifications() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

// Issue #6 — Redesigned NotificationRow with 50% larger artwork (75×105,
// up from 50×70) and a new card-style layout. The row is now a self-
// contained rounded-rect card with:
//   • Larger poster/avatar on the left (75×105 for covers, 75×75 for avatars)
//   • Type badge overlay scaled up proportionally (28pt, up from 20pt)
//   • Wider 16pt spacing between artwork and text
//   • Clearer hierarchy: category label → description → timestamp
//   • Card background + padding so each notification feels intentional
private struct NotificationRow: View {
    let notification: AniListNotification
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(iconColor)
                        .lineLimit(1)
                        .textCase(.uppercase)
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !timestamp.isEmpty {
                    Text(timestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Icon (cover image / avatar / fallback placeholder)
    //
    // Issue #6 — Artwork increased by 50%: covers 50×70 → 75×105, avatars
    // 50×50 → 75×75. The type badge overlay scaled up proportionally
    // (20→28pt). The placeholder uses the same 75×105 footprint.

    @ViewBuilder
    private var iconView: some View {
        if let coverURL = coverImageURL, !coverURL.isEmpty {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: coverURL)
                    .frame(width: 75, height: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(iconColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .offset(x: 6, y: 6)
            }
            .frame(width: 81, height: 111)
        } else if let avatarURL = avatarURL, !avatarURL.isEmpty {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: avatarURL)
                    .frame(width: 75, height: 75)
                    .clipShape(Circle())
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(iconColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
            .frame(width: 81, height: 81)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 75, height: 105)
                Image(systemName: iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 81, height: 111)
        }
    }

    /// Best available cover image URL for notifications that carry a media
    /// object (airing + media addition/data-change/merge). Returns nil for
    /// notification types without one so the avatar / placeholder paths can
    /// take over.
    private var coverImageURL: String? {
        switch notification {
        case .airing(let n):
            return n.media?.coverImage?.best
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            return n.media?.coverImage?.best
        default:
            return nil
        }
    }

    /// Avatar URL for user-driven notifications (follows, activity, threads).
    /// These notifications have no media object, so we show the actor's avatar
    /// as the thumbnail instead.
    private var avatarURL: String? {
        switch notification {
        case .following(let n):
            return n.user?.avatar?.large
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            return n.user?.avatar?.large
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            return n.user?.avatar?.large
        default:
            return nil
        }
    }

    /// Per-type tint for the small badge overlay so a glance is enough to tell
    /// a follow (green) from an activity like (pink) from an airing (blue).
    private var iconColor: Color {
        switch notification {
        case .airing:                                return .blue
        case .following:                             return .green
        case .activityMessage:                       return .purple
        case .activityReply, .activityReplySubscribed,
             .activityMention:                       return .orange
        case .activityLike, .activityReplyLike:      return .pink
        case .threadCommentMention, .threadCommentReply,
             .threadCommentSubscribed, .threadCommentLike,
             .threadLike:                            return .yellow
        case .mediaAddition, .mediaDataChange,
             .mediaMerge:                            return .gray
        case .mediaDeletion:                         return .red
        case .unknown:                               return .gray
        }
    }

    private var iconName: String {
        switch notification {
        case .airing: return "tv"
        case .following: return "person.fill.checkmark"
        case .activityMessage, .activityReply, .activityReplySubscribed, .activityMention: return "bubble.left.fill"
        case .activityLike, .activityReplyLike: return "heart.fill"
        case .threadCommentMention, .threadCommentReply, .threadCommentSubscribed, .threadCommentLike, .threadLike: return "text.bubble.fill"
        case .mediaAddition, .mediaDataChange, .mediaMerge: return "arrow.triangle.2.circlepath"
        case .mediaDeletion: return "trash.fill"
        case .unknown: return "bell.fill"
        }
    }

    /// #3 (revised) — Short, ALL-CAPS category label that sits above the full
    /// description on the right of the poster. Gives the row a clear visual
    /// hierarchy at a glance: "NEW EPISODE / Episode 4 of Frieren aired / 2h
    /// ago" reads much better than a single dense sentence. The label is
    /// tinted with `iconColor` so it pairs with the corner badge on the
    /// poster.
    private var title: String {
        switch notification {
        case .airing:                                return "New Episode"
        case .following:                             return "New Follow"
        case .activityMessage:                       return "Message"
        case .activityReply, .activityReplySubscribed: return "Reply"
        case .activityMention:                       return "Mention"
        case .activityLike, .activityReplyLike:      return "Like"
        case .threadCommentMention, .threadCommentReply,
             .threadCommentSubscribed, .threadCommentLike: return "Thread Comment"
        case .threadLike:                            return "Liked Thread"
        case .mediaAddition:                         return "Media Added"
        case .mediaDataChange:                       return "Media Updated"
        case .mediaMerge:                            return "Media Merged"
        case .mediaDeletion:                         return "Media Deleted"
        case .unknown:                               return "Notification"
        }
    }

    private var description: String {
        switch notification {
        case .airing(let n):
            let title = n.media?.title?.romaji ?? n.media?.title?.english ?? "New Episode"
            return "Episode \(n.episode) of \(title) is now available"
        case .following(let n): return n.context ?? "Started following you"
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            return n.context ?? "Activity notification"
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            return n.context ?? "Thread notification"
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            return n.context ?? "Media update"
        case .mediaDeletion(let n): return n.context ?? "Media deleted"
        case .unknown: return "Notification"
        }
    }

    private var timestamp: String {
        let ts = notification.createdAt
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        // Reuse a single shared formatter — constructing one per row per render
        // is wasteful in a long notifications list.
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Shared formatter (thread-safe once initialised). Formatter creation is
    /// comparatively expensive, so a single lazy static serves the whole list.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Continue Watching Sign-In Prompt (#111)

#if os(iOS)
/// Placeholder card shown in the Continue Watching slot when the user has no
/// resume items AND is signed out of AniList. Mirrors the visual rhythm of the
/// real `ContinueWatchingSection` (heavy title + accent rule + a single
/// full-width card) so the home screen doesn't have an awkward empty gap where
/// Continue Watching would normally live.
///
/// Tapping the card's "Sign in" button pushes `SourcesSettingsPage`, where the
/// user can connect AniList (and MAL). Once they're authed and have watched
/// something, `ContinueWatchingManager` populates `items` and the real
/// `ContinueWatchingSection` replaces this prompt automatically (driven by
/// HomeView's `@ObservedObject anilistAuth` + `@ObservedObject continueWatching`
/// bindings).
private struct ContinueWatchingSignInPrompt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header — matches ContinueWatchingSection's header
            // (heavy title + 36pt accent rule) so the slot reads as the same
            // "Continue Watching" section, just in its signed-out state.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Continue Watching")
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 36, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            // Single full-width prompt card. Person icon + copy on the left,
            // "Sign in" button pinned to the trailing edge. Wrapped in a
            // NavigationLink so the whole card is tappable as well as the
            // explicit button — both push SourcesSettingsPage.
            NavigationLink {
                SourcesSettingsPage()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent.opacity(0.15))
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(Color.appAccent)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sign in to continue watching")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Connect AniList to sync your progress and pick up where you left off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    // Explicit "Sign in" capsule so the affordance is
                    // unambiguous even if the user doesn't realise the whole
                    // card is tappable. `.buttonStyle(.plain)` keeps the
                    // NavigationLink handling the actual navigation.
                    Text("Sign in")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.appAccent)
                        )
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(HomePressStyle())
            .padding(.horizontal, 16)
        }
    }
}
#endif
