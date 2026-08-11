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
                            // 3. CATEGORY GRID — replaces the old vertical scroll of
                            //    AnimeSections. Six large tappable tiles, two columns.
                            //    Tapping any tile pushes BrowseView with that category.
                            // ────────────────────────────────────────────────────────
                            Text("Browse Categories")
                                .font(.title3.weight(.bold))
                                .padding(.horizontal, 16)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)
                                ],
                                spacing: 12
                            ) {
                                NavigationLink {
                                    BrowseView(category: .seasonal)
                                } label: {
                                    CategoryGridCard(
                                        title: "This Season",
                                        count: vm.seasonal.count,
                                        iconName: "calendar.badge.clock",
                                        gradientColors: [.green, .teal],
                                        imageURL: vm.seasonal.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())

                                NavigationLink {
                                    BrowseView(category: .trending)
                                } label: {
                                    CategoryGridCard(
                                        title: "Trending",
                                        count: vm.trending.count,
                                        iconName: "flame.fill",
                                        gradientColors: [.red, .orange],
                                        imageURL: vm.trending.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())

                                NavigationLink {
                                    BrowseView(category: .popular)
                                } label: {
                                    CategoryGridCard(
                                        title: "Popular",
                                        count: vm.popular.count,
                                        iconName: "star.fill",
                                        gradientColors: [.pink, .purple],
                                        imageURL: vm.popular.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())

                                NavigationLink {
                                    BrowseView(category: .topRated)
                                } label: {
                                    CategoryGridCard(
                                        title: "Top Rated",
                                        count: vm.topRated.count,
                                        iconName: "trophy.fill",
                                        gradientColors: [.orange, .yellow],
                                        imageURL: vm.topRated.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())

                                NavigationLink {
                                    BrowseView(category: .popular)
                                } label: {
                                    CategoryGridCard(
                                        title: "Recently Completed",
                                        count: vm.recentlyCompleted.count,
                                        iconName: "checkmark.seal.fill",
                                        gradientColors: [.gray, .black],
                                        imageURL: vm.recentlyCompleted.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())

                                NavigationLink {
                                    BrowseView(category: .trending)
                                } label: {
                                    CategoryGridCard(
                                        title: "Upcoming",
                                        count: vm.upcoming.count,
                                        iconName: "clock.arrow.circlepath",
                                        gradientColors: [.indigo, .purple],
                                        imageURL: vm.upcoming.first?.coverImage.best
                                    )
                                    .equatable()
                                }
                                .buttonStyle(HomePressStyle())
                            }
                            .padding(.horizontal, 16)
                            .animation(.easeInOut(duration: 0.3), value: vm.trending)

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
                // Schedule icon — matches the Notifications bell styling exactly
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: ScheduleView()) {
                        Image(systemName: "calendar")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                // Notifications bell — same styling as Schedule
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: NotificationsPage()) {
                        Image(systemName: "bell")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ProviderMenuButton()
                }
            }
            // Outside the ScrollView: the hidden NavigationLink that performs the push.
            .continueWatchingNavigation($cwNavTarget)
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
            : UIScreen.main.bounds.height * 0.55

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
                                Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                Text("Watch").fontWeight(.semibold)
                            }
                            .foregroundStyle(platformBackground)
                            .frame(width: 160, height: 42)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
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
                // iPhone: banner / cover image fills the ENTIRE card area.
                // #110 — Previously this used `TVDBPosterImage(media:type:.fanart)`
                // which performs an async TVDB lookup that can fail (returning
                // nothing), leaving the card empty or cropped to whatever
                // fallback the TVDB layer could find. Switching to
                // `CachedAsyncImage` with the banner URL directly (falling
                // back to the cover image's extraLarge / large variants) means
                // the image always renders from the AniList-provided URL
                // without the extra TVDB round-trip.
                //
                // The `.frame(maxWidth: .infinity, maxHeight: .infinity)` makes
                // the image fill the full card area edge-to-edge — no
                // `.aspectRatio`, no parallax buffer, no height constraint.
                // `CachedAsyncImage` already applies `.scaledToFill()` so the
                // image fills this frame completely (cropping only what
                // overflows), and `.clipped()` keeps the overflow contained.
                CachedAsyncImage(urlString: media.bannerImage ?? media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Default content mode (anime / western / combined). Defaults to anime.
    static var defaultMode: ScheduleMode {
        let raw = UserDefaults.standard.string(forKey: defaultModeKey) ?? ScheduleMode.anime.rawValue
        return ScheduleMode(rawValue: raw) ?? .anime
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
        // Hidden NavigationLink that performs the push when `detailEntry` is set
        // (used by the context-menu "View Details" action — context menus can't
        // host a NavigationLink themselves). Card taps use a direct NavigationLink
        // below; both land on `ScheduleDetailView` (#107).
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

    // MARK: - Content

    @ViewBuilder
    private var scheduleContent: some View {
        let buckets = buildBuckets()
        // Map each day's start-of-day date → episode count, for the calendar badges.
        let countByDay = Dictionary(uniqueKeysWithValues: buckets.map { ($0.date, $0.entries.count) })
        // #80 — All days needed to fill the 7-column month grid: every day in the
        // displayed month plus leading/trailing days from adjacent months so the
        // grid always starts on Sunday and ends on Saturday. Out-of-month days
        // are styled grey by `dayCell`.
        let monthDays = currentMonthGridDays()
        let selectedBucket = buckets.first(where: { calendar.isDate($0.date, inSameDayAs: selectedDate) })

        VStack(spacing: 0) {
            // Month header — always a single month/year (e.g. "August 2026")
            // driven by `monthStart` (the first day of the displayed month).
            // Prev/next arrows shift the calendar by one whole month (#80).
            HStack(spacing: 6) {
                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.1)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous month")

                Text(monthYearHeader)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.1)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next month")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            // Weekday labels (Sun–Sat) — single row above the 7-column grid.
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

            // Month grid — every day in the displayed month (plus leading/trailing
            // days from adjacent months to fill the 7-column layout). Standard
            // months fit in 4–6 rows of 7; cells are sized so 6 rows fit without
            // scrolling on a typical phone. Each cell shows the date number, an
            // episode-count badge (if > 0), a today marker, and a selection
            // highlight. Tapping a leading/trailing day shifts the calendar to
            // that month and selects the day.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                spacing: 4
            ) {
                ForEach(monthDays, id: \.self) { day in
                    dayCell(
                        date: day,
                        count: countByDay[day] ?? 0,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
                        isToday: calendar.isDateInToday(day),
                        isInMonth: calendar.isDate(day, equalTo: monthStart, toGranularity: .month)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            // Selected day's episodes.
            ScrollView {
                if let bucket = selectedBucket, !bucket.entries.isEmpty {
                    LazyVStack(spacing: 12) {
                        HStack {
                            Text(bucket.shortTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(bucket.entries.count) episode\(bucket.entries.count == 1 ? "" : "s")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(bucket.entries) { entry in
                            // #107 — Tapping the card pushes `ScheduleDetailView`
                            // (the purpose-built airing-countdown screen). The bell
                            // button inside the card keeps working via nested-button
                            // hit-testing (both use `.buttonStyle(.plain)`). The
                            // "View Full Details" button inside the detail view is
                            // what eventually pushes `AniListDetailView`.
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
    private func dayCell(date: Date, count: Int, isSelected: Bool, isToday: Bool, isInMonth: Bool) -> some View {
        Button {
            // Tapping a leading/trailing day from an adjacent month shifts the
            // calendar to that month and selects the tapped day (#80). Tapping
            // an in-month day just selects it.
            withAnimation(.easeOut(duration: 0.18)) {
                if !isInMonth {
                    let cal = calendar
                    monthStart = cal.dateInterval(of: .month, for: date)?.start ?? monthStart
                }
                selectedDate = date
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isInMonth ? Color.primary : Color.secondary.opacity(0.45))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.red)
                        )
                        .fixedSize()
                        .opacity(isInMonth ? 1 : 0.5)
                } else if isToday {
                    // Today marker — a filled primary-colored dot under days
                    // with no episodes. Only rendered for in-month days so the
                    // marker reads as "today" rather than just a spacer.
                    Circle()
                        .fill(isInMonth ? Color.primary : Color.primary.opacity(0.4))
                        .frame(width: 5, height: 5)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                        .opacity(isInMonth ? 1 : 0.35)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.35) :
                        (isToday && isInMonth ? Color.primary.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isSelected && Color.glowEnabled
                    ? Color.primary.opacity(Color.glowIntensity * 0.5) : .clear,
                radius: isSelected && Color.glowEnabled
                    ? CGFloat(17 * Color.glowIntensity) : 0
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelForDay(date, count: count, isInMonth: isInMonth))
    }

    private func accessibilityLabelForDay(_ date: Date, count: Int, isInMonth: Bool) -> String {
        let cal = calendar
        let f = DateFormatter()
        f.locale = cal.locale ?? Locale.current
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE, MMMM d"
        let base = f.string(from: date)
        let prefix = isInMonth ? "" : "Adjacent month — "
        if count > 0 {
            return "\(prefix)\(base), \(count) episode\(count == 1 ? "" : "s")"
        }
        return "\(prefix)\(base), no episodes"
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

            case .western:
                let items = try await WesternScheduleService.shared.fetchSchedule(dayCount: windowDays)
                fetched = items.compactMap { entry -> UnifiedScheduleEntry? in
                    // Drop Western entries without an air timestamp — they can't be bucketed.
                    guard entry.airTimestamp != nil else { return nil }
                    return UnifiedScheduleEntry(entry: entry)
                }

            case .combined:
                // Fan out both fetches concurrently; await them together. The
                // anime branch still honours the #93 cache probe.
                async let animeFetch = try await fetchAnimeCachedOrFresh(from: startTs, to: endTs)
                async let westernFetch = try await WesternScheduleService.shared.fetchSchedule(dayCount: windowDays)
                let (animeItems, westernItems) = try await (animeFetch, westernFetch)
                fetched = animeItems.map { UnifiedScheduleEntry(item: $0) }
                    + westernItems.compactMap { entry -> UnifiedScheduleEntry? in
                        guard entry.airTimestamp != nil else { return nil }
                        return UnifiedScheduleEntry(entry: entry)
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
            // For Western entries there's no AniList media id; pass 0 so a tap won't try to
            // deep-link into a non-existent detail page. The notification still fires normally.
            let mediaId = entry.aniListMediaId ?? 0
            let success = await EpisodeNotificationManager.shared.schedule(
                scheduleId: entry.id,
                mediaId: mediaId,
                title: entry.title,
                episode: entry.episode,
                airingAt: entry.airingAt
            )
            if success {
                scheduledIds.insert(entry.id)
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Notification scheduled",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
            } else {
                ToastManager.shared.show(
                    title: "Schedule",
                    message: "Could not schedule — episode may have already aired",
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
/// Edits the persisted defaults: look-ahead window (7/14/21/30 days), default content mode,
/// and default timezone (Local / UTC).
struct ScheduleSettingsPage: View {
    @State private var windowDays: Int        = ScheduleSettings.windowDays
    @State private var defaultMode: ScheduleMode = ScheduleSettings.defaultMode
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
                Text("How many days ahead to fetch and display in the schedule. Western TV data is limited to roughly 14 days; anime covers the full window.")
            }

            Section {
                Picker("Default Content", selection: $defaultMode) {
                    ForEach(ScheduleMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: defaultMode) { value in
                    ScheduleSettings.setDefaultMode(value)
                }
            } header: {
                Text("Content Mode")
            } footer: {
                Text("Which source to show by default when opening the schedule.")
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
                List {
                    ForEach(notifications, id: \.id) { notification in
                        NotificationRow(notification: notification)
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
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
        VStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(Color.secondary.opacity(0.15)).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 180, height: 10)
                    }
                    Spacer()
                }
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

private struct NotificationRow: View {
    let notification: AniListNotification
    var body: some View {
        HStack(spacing: 12) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(description).font(.subheadline).lineLimit(2)
                Text(timestamp).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Icon (cover image / avatar / fallback placeholder)

    /// Renders the notification's leading thumbnail. Prefers the media cover
    /// image (for airing + media* notifications), then the user's avatar (for
    /// follow/activity/thread notifications), and finally a plain SF Symbol
    /// badge. Each image variant still overlays a small SF Symbol so the
    /// notification type is identifiable at a glance even when the image
    /// hasn't loaded yet or the URL is nil.
    @ViewBuilder
    private var iconView: some View {
        if let coverURL = coverImageURL, !coverURL.isEmpty {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: coverURL)
                    .frame(width: 30, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: iconName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(iconColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 34, height: 46)
        } else if let avatarURL = avatarURL, !avatarURL.isEmpty {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: avatarURL)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                Image(systemName: iconName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(iconColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 40, height: 40)
        } else {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: iconName).font(.system(size: 14)).foregroundStyle(.secondary)
            }
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
