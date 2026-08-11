import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    // Continue Watching context-menu navigation. Driven from here so the hidden
    // NavigationLink that performs the push sits OUTSIDE the ScrollView below.
    @State private var cwNavTarget: ContinueWatchingNavTarget?
    @State private var readerContext: ReaderContext?
    /// Controls navigation to the notifications page via NavigationLink.
    @State private var navigateToNotifications = false

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
                            #if os(iOS)
                            if !continueWatching.items.isEmpty {
                                ContinueWatchingSection(items: continueWatching.items, navTarget: $cwNavTarget)
                            }
                            if !mangaProgress.items.isEmpty {
                                ContinueReadingSection(items: mangaProgress.items, readerContext: $readerContext)
                            }
                            #endif
                            if !vm.trending.isEmpty {
                                FeaturedCarousel(items: vm.trending)
                            }
                            Text("Discover")
                                .font(.title3.weight(.bold))
                                .padding(.horizontal, 16)
                            if !vm.trending.isEmpty {
                                AnimeSection(title: "Trending Now",     items: vm.trending, category: .trending)
                            }
                            if !vm.seasonal.isEmpty {
                                AnimeSection(title: "This Season",      items: vm.seasonal, category: .seasonal)
                            }
                            Text("Browse")
                                .font(.title3.weight(.bold))
                                .padding(.horizontal, 16)
                            if !vm.popular.isEmpty {
                                AnimeSection(title: "All-Time Popular", items: vm.popular,  category: .popular)
                            }
                            if !vm.topRated.isEmpty {
                                AnimeSection(title: "Top Rated",        items: vm.topRated, category: .topRated)
                            }
                            if !vm.recentlyCompleted.isEmpty {
                                AnimeSection(title: "Recently Completed", items: vm.recentlyCompleted, category: .popular)
                            }
                            if !vm.upcoming.isEmpty {
                                AnimeSection(title: "Upcoming",         items: vm.upcoming,    category: .trending)
                            }
                        }
                        Spacer().frame(height: 28)
                    }
                    .refreshable {
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
    @State private var selectedTab = 1000
    @State private var containerWidth: CGFloat = 0
    @State private var stretchAmount: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var realItems: [Media] { items.prefix(8).map { $0 } }
    private var displayCount: Int { realItems.count }

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
            : UIScreen.main.bounds.height * 0.6

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
                TabView(selection: $selectedTab) {
                    ForEach(0..<2000, id: \.self) { index in
                        if !displayItems.isEmpty {
                            FeaturedCard(media: displayItems[index % displayCount], isWide: isIPad)
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

                        Text(currentMedia.title.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if let desc = currentMedia.plainDescription, !desc.isEmpty {
                            Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 8)
                        }

                        NavigationLink {
                            AniListDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                Text("Watch").fontWeight(.semibold)
                            }
                            .foregroundStyle(platformBackground)
                            .frame(width: 130, height: 42)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            }

            PageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
        .onAppear {
            if displayCount > 0 {
                selectedTab = (1000 / displayCount) * displayCount
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
                                    }
                                    if let genres = media.genres, !genres.isEmpty {
                                        ForEach(genres.prefix(2), id: \.self) { genre in
                                            Text(genre)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.white.opacity(0.15), in: Capsule())
                                        }
                                    }
                                }

                                NavigationLink {
                                    AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                        Text("Watch").fontWeight(.semibold)
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

private struct FeaturedCard: View {
    let media: Media
    var isWide: Bool = false

    private var aspectRatio: CGFloat {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return 2.0 / 3.0
        #else
        return 16.0 / 9.0
        #endif
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
                // iPhone: portrait with horizontal parallax
                GeometryReader { geo in
                    let pageOffset = geo.frame(in: .global).minX
                    let buffer: CGFloat = 100
                    TVDBPosterImage(media: media)
                        .frame(width: geo.size.width + buffer, height: geo.size.height)
                        .offset(x: -(buffer / 2) - pageOffset * 0.25)
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
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
/// Shows anime (AniList) and/or Western TV (TVMaze) episode schedules grouped by day,
/// with controls for content source (Anime / Western / Combined), timezone (Local / UTC),
/// and a look-ahead window (set in `ScheduleSettingsPage`). Each entry shows a card with
/// poster, badges, countdown, air-time capsule, and a notification bell.
struct ScheduleView: View {
    @State private var entries: [UnifiedScheduleEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?

    // User-facing controls. `mode` and `useUTC` are seeded from persisted defaults on first
    // appearance; the user can override them via the segmented pickers without changing the
    // default. `windowDays` is bound to `@AppStorage` so changes from `ScheduleSettingsPage`
    // propagate live.
    @AppStorage("scheduleWindowDays")    private var windowDays: Int = 7
    @State private var mode:   ScheduleMode = ScheduleSettings.defaultMode
    @State private var useUTC: Bool         = ScheduleSettings.defaultUseUTC

    // Day strip selection (index into `buildBuckets()`).
    @State private var selectedDayIndex: Int = 0

    // Pending episode-notification schedule ids — drives the bell's on/off state.
    @State private var scheduledIds: Set<Int> = []

    // Drives push navigation to the AniList detail view from context menus.
    // `navigationDestinationCompat` honors this on iOS (NavigationView shim), macOS, and tvOS.
    @State private var detailMediaId: Int?

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
        // Hidden NavigationLink that performs the push when `detailMediaId` is set
        // (used by the "View Details" context-menu action — context menus can't host a
        // NavigationLink themselves).
        .navigationDestinationCompat(item: $detailMediaId) { mediaId in
            AniListDetailView(mediaId: mediaId, preloadedMedia: nil)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: mode) { _ inTask { await load() } }
        .onChange(of: windowDays) { _ inTask { await load() } }
        .onChange(of: useUTC) { _ inselectedDayIndex = 0 }
    }

    // MARK: - Content

    @ViewBuilder
    private var scheduleContent: some View {
        let buckets = buildBuckets()
        let safeIndex = min(max(selectedDayIndex, 0), max(buckets.count - 1, 0))

        VStack(spacing: 0) {
            // Controls
            VStack(spacing: 10) {
                Picker("Content", selection: $mode) {
                    ForEach(ScheduleMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Timezone", selection: $useUTC) {
                    Text("Local").tag(false)
                    Text("UTC").tag(true)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)

            // Day strip with item counts
            if !buckets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(buckets.indices, id: \.self) { index in
                            dayStripTab(bucket: buckets[index], index: index, isSelected: index == safeIndex)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            // Selected day entries
            if safeIndex < buckets.count {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(buckets[safeIndex].entries) { entry in
                            ScheduleCard(
                                entry: entry,
                                useUTC: useUTC,
                                isNotificationOn: scheduledIds.contains(entry.id),
                                onToggleNotification: { toggleNotification(for: entry) },
                                onAddToPlanning:     { addToLibrary(entry, status: .planning) },
                                onAddToWatching:     { addToLibrary(entry, status: .current) },
                                onViewDetails:       { openDetails(for: entry) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func dayStripTab(bucket: ScheduleDayBucket, index: Int, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedDayIndex = index
            }
        } label: {
            VStack(spacing: 2) {
                Text(bucket.shortTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(bucket.entries.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.primary.opacity(0.35) : .clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
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
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startTs = Int(startOfToday.timeIntervalSince1970)
        let endTs = startTs + max(windowDays, 1) * 86_400

        var fetched: [UnifiedScheduleEntry] = []
        do {
            switch mode {
            case .anime:
                let items = try await AniListService.shared.airingSchedules(from: startTs, to: endTs)
                fetched = items.map { UnifiedScheduleEntry(item: $0) }

            case .western:
                let items = try await WesternScheduleService.shared.fetchSchedule(dayCount: windowDays)
                fetched = items.compactMap { entry -> UnifiedScheduleEntry? in
                    // Drop Western entries without an air timestamp — they can't be bucketed.
                    guard entry.airTimestamp != nil else { return nil }
                    return UnifiedScheduleEntry(entry: entry)
                }

            case .combined:
                // Fan out both fetches concurrently; await them together.
                async let animeFetch   = try await AniListService.shared.airingSchedules(from: startTs, to: endTs)
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
            entries = fetched.sorted { $0.airingAt < $1.airingAt }

            // Reset to the first (earliest) day after every reload.
            selectedDayIndex = 0

            // Refresh the pending-notification set so the bells reflect current state.
            scheduledIds = await EpisodeNotificationManager.shared.scheduledScheduleIds()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Day bucketing (timezone-aware)

    /// Groups entries into day buckets using either the local calendar or a UTC calendar,
    /// depending on the timezone toggle. This bypasses `ScheduleDayBucket.build` (which is
    /// hard-wired to `Calendar.current`) so the day boundaries match the displayed times.
    private func buildBuckets() -> [ScheduleDayBucket] {
        let calendar = useUTC ? Self.utcCalendar : Calendar.current
        var grouped: [Date: [UnifiedScheduleEntry]] = [:]
        for entry in entries {
            let airDate = Date(timeIntervalSince1970: TimeInterval(entry.airingAt))
            let dayStart = calendar.startOfDay(for: airDate)
            grouped[dayStart, default: []].append(entry)
        }
        return grouped.keys.sorted().map { day in
            let dayEntries = grouped[day] ?? []
            let sorted = dayEntries.sorted { $0.airingAt < $1.airingAt }
            return ScheduleDayBucket(date: day, entries: sorted)
        }
    }

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    // MARK: - Bell (notifications)

    /// Toggles the episode-airing notification for `entry` on or off via
    /// `EpisodeNotificationManager`. Scheduling requires notification authorization; if
    /// the user hasn't granted it, we prompt and bail out on denial.
    private func toggleNotification(for entry: UnifiedScheduleEntry) {
        if scheduledIds.contains(entry.id) {
            EpisodeNotificationManager.shared.cancel(scheduleId: entry.id)
            scheduledIds.remove(entry.id)
            ToastManager.shared.show(message: "Notification cancelled", type: .info)
            return
        }
        Task {
            let granted = await EpisodeNotificationManager.shared.requestAuthorization()
            guard granted else {
                ToastManager.shared.show(
                    message: "Enable notifications in Settings to receive episode alerts",
                    type: .warning
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
                ToastManager.shared.show(message: "Notification scheduled", type: .success)
            } else {
                ToastManager.shared.show(
                    message: "Could not schedule — episode may have already aired",
                    type: .warning
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
                message: "Western shows can't be tracked here — add them on AniList first",
                type: .info
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
                ToastManager.shared.show(
                    message: "Added to \(status.displayName)",
                    type: .success
                )
            } catch {
                ToastManager.shared.show(
                    message: "Failed: \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }

    // MARK: - Detail navigation

    /// Sets `detailMediaId` so `navigationDestinationCompat` pushes the AniList detail view.
    /// Only anime entries have an AniList detail page to push to.
    private func openDetails(for entry: UnifiedScheduleEntry) {
        guard let mediaId = entry.aniListMediaId else {
            ToastManager.shared.show(
                message: "Western shows don't have an AniList detail page",
                type: .info
            )
            return
        }
        detailMediaId = mediaId
    }
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
        .contextMenu {
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
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("21 days").tag(21)
                    Text("30 days").tag(30)
                }
                .onChange(of: windowDays) { _, value in
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
                .onChange(of: defaultMode) { _, value in
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
                .onChange(of: defaultUseUTC) { _, value in
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
            ZStack {
                Circle().fill(Color.secondary.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: iconName).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(description).font(.subheadline).lineLimit(2)
                Text(timestamp).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
