import SwiftUI

// MARK: - AppleHomeContent (Batch 27)
//
// The APPLE presentation of the anime Home page — the DEFAULT native
// iOS look, built from plain system components:
//   • a standard paged TabView hero (system page dots) with a plain
//     banner, title, score and synopsis — no custom gradient machinery,
//     no logo pipeline, no elastic stretch
//   • standard section headers (title + plain "See All" chevron links)
//   • simple poster cards (rounded rectangle, title + status caption
//     UNDER the image, score badge) — no gradient overlay, no shadow
//     stacks, no custom pill rows
//   • native pull-to-refresh
//
// FEATURE PARITY with the Shirox home — the exact same data drives both:
// the same shelves, the same Continue Watching section, the same genre
// shelves, the same stable-query See All routing, the same context-menu
// actions, the same navigation destinations, the same snapshot fallback.
// Only the rendering is native.

struct AppleHomeContent: View {
    @ObservedObject var vm: HomeViewModel
    @ObservedObject var continueWatching: ContinueWatchingManager
    @ObservedObject var anilistAuth: AniListAuthManager
    @Binding var cwNavTarget: ContinueWatchingNavTarget?
    @Binding var browseCategoriesGridLayout: Bool

    @State private var heroPage = 0

    private var heroItems: [Media] {
        MediaNormalizer.carouselItems(from: vm.trending, isManga: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !heroItems.isEmpty {
                    nativeHero
                }

                #if os(iOS)
                if !continueWatching.items.isEmpty {
                    ContinueWatchingSection(items: continueWatching.items, navTarget: $cwNavTarget)
                } else if !anilistAuth.isLoggedIn {
                    ContinueWatchingSignInPrompt()
                }
                #endif

                if browseCategoriesGridLayout {
                    // Shared grid tiles (native-styled already).
                    AppleCategoriesGrid(vm: vm)
                } else {
                    nativeSection("This Season", items: vm.seasonal, category: .seasonal)
                    nativeSection("Trending Now", items: vm.trending, category: .trending)
                    nativeSection("All-Time Popular", items: vm.popular, category: .popular)
                    nativeSection("Top Rated", items: vm.topRated, category: .topRated)
                    nativeSection("Recently Completed", items: vm.recentlyCompleted, category: .recentlyCompleted)
                    nativeSection("Upcoming", items: vm.upcoming, category: .upcoming)
                    ForEach(DiscoveryService.homeShelfGenres) { genre in
                        if let items = vm.genreShelves[genre.slug], !items.isEmpty {
                            nativeSection(genre.displayName, items: items, genre: genre)
                        }
                    }
                }
                Spacer().frame(height: 28)
            }
        }
        .refreshable {
            await vm.reload()
            await ContinueWatchingManager.shared.syncWithAniList()
            await ContinueWatchingManager.shared.syncWithMAL()
        }
    }

    // MARK: - Native hero (standard paged banner)

    /// A standard `TabView` page carousel with the system page indicator:
    /// banner art (fallback cover), the title, score, and a 2-line
    /// synopsis centered over a plain material — the stock iOS pattern,
    /// zero custom chrome.
    private var nativeHero: some View {
        VStack(spacing: 8) {
            TabView(selection: $heroPage) {
                ForEach(Array(heroItems.enumerated()), id: \.element.id) { index, media in
                    NavigationLink {
                        AniListDetailView(mediaId: media.id, preloadedMedia: media)
                    } label: {
                        AppleHeroCard(media: media)
                    }
                    .buttonStyle(.plain)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Native section

    /// Standard iOS section: a title + a plain chevron "See All" link,
    /// and a horizontal scroll of simple poster cards.
    private func nativeSection(_ title: String, items: [Media], category: BrowseCategory) -> some View {
        AppleMediaSection(title: title, items: items, query: .category(category))
    }

    private func nativeSection(_ title: String, items: [Media], genre: DiscoveryGenre) -> some View {
        AppleMediaSection(title: title, items: items, query: .genre(genre))
    }
}

// MARK: - Apple hero card (plain system styling)

private struct AppleHeroCard: View {
    let media: Media

    var body: some View {
        ZStack(alignment: .bottom) {
            // Banner (cover fallback) — plain fill, no parallax, no custom
            // artwork chain; the provider's own banner URL is the native
            // contract.
            CachedAsyncImage(urlString: media.bannerImage ?? media.coverImage.best ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Standard legibility material — system dark blur.
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 110)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let score = media.averageScore {
                        Label(score.averageScoreOutOf10, systemImage: "star.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.palette)
                    }
                    if let year = media.seasonYear, year > 0 {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let format = media.format, !format.isEmpty {
                        Text(format)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let genres = media.genres?.prefix(2), !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let desc = media.plainDescription, !desc.isEmpty {
                    Text(String(desc.prefix(110)) + (desc.count > 110 ? "…" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(media.title.displayTitle)
    }
}

// MARK: - Apple media section (standard header + simple cards)

struct AppleMediaSection: View {
    let title: String
    let items: [Media]
    let query: BrowseQuery
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var cardWidth: CGFloat {
        #if os(iOS)
        sizeClass == .regular ? 180 : 140
        #else
        180
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    BrowseView(query: query)
                } label: {
                    HStack(spacing: 2) {
                        Text("See All")
                            .font(.subheadline)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .imageScale(.small)
                    }
                    .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items, id: \.id) { media in
                        NavigationLink {
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                        } label: {
                            ApplePosterCard(media: media)
                                .frame(width: cardWidth)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button {
                                        Task {
                                            try? await AniListLibraryService.shared.updateEntry(
                                                mediaId: media.id, status: .planning, progress: 0, score: nil)
                                        }
                                    } label: {
                                        Label("Add to Planning", systemImage: "bookmark")
                                    }
                                    Button {
                                        Task {
                                            try? await AniListLibraryService.shared.updateEntry(
                                                mediaId: media.id, status: .current, progress: 0, score: nil)
                                        }
                                    } label: {
                                        Label("Add to Watching", systemImage: "play.circle")
                                    }
                                    Button {
                                        Task {
                                            try? await AniListLibraryService.shared.updateEntry(
                                                mediaId: media.id, status: .completed, progress: 0, score: nil)
                                        }
                                    } label: {
                                        Label("Mark as Completed", systemImage: "checkmark.circle")
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(media.id)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Apple poster card (the native card design)
//
// The stock iOS poster card: rounded cover, the title and status line
// UNDER the image (no gradient overlay, no shadow stack), score shown
// as a small system-styled badge. Same data object as every other
// surface; the same 2:3 poster proportion as the Shirox card.

struct ApplePosterCard: View {
    let media: Media

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? media.coverImage.best ?? "")
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let score = media.averageScore, score > 0 {
                        Label(score.averageScoreOutOf10, systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(media.title.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let statusLine = media.posterStatusText {
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(media.title.displayTitle)
    }
}

// MARK: - Apple categories grid (native tile presentation of the grid toggle)

/// The grid layout in Apple presentation: the same category tiles the
/// user's layout toggle asks for, rendered with plain system styling —
/// cover image, material overlay, title + count. Tapping pushes the
/// same BrowseView the Shirox tiles push (same stable categories).
private struct AppleCategoriesGrid: View {
    @ObservedObject var vm: HomeViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var tiles: [(title: String, category: BrowseCategory, icon: String, count: Int, image: String?)] {
        [
            ("This Season", .seasonal, "sparkles.tv", vm.seasonal.count, vm.seasonal.first?.coverImage.best),
            ("Trending Now", .trending, "flame.fill", vm.trending.count, vm.trending.first?.coverImage.best),
            ("All-Time Popular", .popular, "chart.bar.fill", vm.popular.count, vm.popular.first?.coverImage.best),
            ("Top Rated", .topRated, "trophy.fill", vm.topRated.count, vm.topRated.first?.coverImage.best),
            ("Recently Completed", .recentlyCompleted, "checkmark.seal.fill", vm.recentlyCompleted.count, vm.recentlyCompleted.first?.coverImage.best),
            ("Upcoming", .upcoming, "clock.fill", vm.upcoming.count, vm.upcoming.first?.coverImage.best),
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tiles, id: \.category) { tile in
                NavigationLink {
                    BrowseView(query: .category(tile.category))
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let image = tile.image {
                                CachedAsyncImage(urlString: image)
                            } else {
                                Rectangle().fill(Color.secondary.opacity(0.15))
                            }
                        }
                        .aspectRatio(1.6, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        Rectangle().fill(.ultraThinMaterial)

                        HStack(spacing: 6) {
                            Image(systemName: tile.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appAccent)
                            Text(tile.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(10)
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 0)
            }
        }
        .padding(.horizontal, 16)
    }
}
