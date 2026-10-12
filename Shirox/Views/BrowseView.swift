import SwiftUI

/// Batch 26 — the STABLE identifier every browse surface routes by.
/// A Home row, a grid tile and the See All page it opens all carry one
/// of these; the destination page runs the exact query the identifier
/// names. Never an array index, never a display title, never a route
/// shared by multiple categories.
enum BrowseQuery: Hashable {
    /// The six standard charts (trending / seasonal / popular / …).
    case category(BrowseCategory)
    /// A genre page — keyed by the genre SLUG (the discovery database's
    /// own category identifier).
    case genre(DiscoveryGenre)
    /// v2.33 — a Top Chart with its selected time window (nil = the chart
    /// has no period set / offers none). The shelf, its period chip and the
    /// See All page all carry the SAME pair, so a row titled "Top Anime —
    /// Weekly" can only ever page through the weekly window's list.
    case chart(TopChart, ChartPeriod?)

    /// Page title for the See All destination.
    var title: String {
        switch self {
        case .category(let category): return category.title
        case .genre(let genre): return genre.displayName
        case .chart(let chart, let period):
            return period.map { "\(chart.title) — \($0.title)" } ?? chart.title
        }
    }

    /// The unified-chain browse call this query runs — the SAME one for
    /// the Home shelf (page 1) and the See All grid (pages 1…N).
    func load(page: Int) async throws -> [Media] {
        switch self {
        case .category(let category):
            return try await UnifiedProviderSystem.shared.browse(category: category, page: page)
        case .genre(let genre):
            return try await UnifiedProviderSystem.shared.browse(genre: genre, page: page)
        case .chart(let chart, let period):
            return try await UnifiedProviderSystem.shared.browse(chart: chart, period: period, page: page)
        }
    }
}

struct BrowseView: View {
    let query: BrowseQuery
    @StateObject private var vm: BrowseViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(query: BrowseQuery) {
        self.query = query
        _vm = StateObject(wrappedValue: BrowseViewModel(query: query))
    }

    /// Backward-compatible category initializer (existing callers).
    init(category: BrowseCategory) {
        self.init(query: .category(category))
    }

    private var columnCount: Int {
        #if os(iOS)
        return sizeClass == .regular ? 4 : 2
        #else
        return 4
        #endif
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty, let error = vm.error {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.retry() } }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.items, id: \.uniqueId) { media in
                            NavigationLink {
                                AniListDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                AniListCardView(media: media)
                                    .equatable()
                            }
                            .contentShape(Rectangle())
                            .buttonStyle(BrowseCardPressStyle())
                            // v2.32 — the unified long-press menu every
                            // card surface shares.
                            .unifiedCardMenu(media)
                        }

                        // Infinite scroll sentinel
                        if vm.hasMore {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await vm.loadMore() } }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView()
                            .padding(.bottom, 16)
                    }
                }
                .refreshable { await vm.retry() }
            }
        }
        .navigationTitle(query.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await vm.loadMore() }
    }
}

private struct BrowseCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Top Charts (v2.33)
//
// A Top Chart is a Home discovery row that can be scoped to a TIME WINDOW:
// the top of what premiered in the last day / week / month / quarter /
// year, ranked by the chart's own metric (popularity, favourites…). The
// window is a REAL AniList query parameter (`startDate_greater`, AniList's
// own FuzzyDateInt), never a fabricated ranking: changing the period runs
// a different query and gets different results.
//
// The pieces:
//   • `ChartPeriod`     — the window vocabulary (daily…yearly)
//   • `TopChart`        — one chart's definition (metric, filters, periods)
//   • `ChartShelfModel` — the per-row loader (stale-guarded, chain-cached)
//   • `ChartSection`    — the row: header + period chip + See All + shelf
//
// Honesty rules the design, the same way they rule BrowseCategory:
//   • Only charts whose metric can MEANINGFULLY be windowed offer a
//     period picker (favourites and scores need time to accumulate, so
//     they start at Weekly; airing/upcoming/hidden-gems charts offer none).
//   • Period-windowed queries run through the AniList leg of the chain
//     only — no fallback provider silently serves a DIFFERENT list under
//     a "Weekly" heading.

// MARK: Chart period

/// The time window a chart can be scoped to. Each period maps to a real
/// `startDate_greater` filter (premiered within the window), so "Top Anime
/// — Weekly" is genuinely the top of this week's premieres — a different
/// query, different results, no relabeled all-time list.
enum ChartPeriod: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }

    /// Length of the window in days (inclusive of today).
    var days: Int {
        switch self {
        case .daily: return 1
        case .weekly: return 7
        case .monthly: return 30
        case .quarterly: return 90
        case .yearly: return 365
        }
    }

    /// One-line explanation shown under the period picker's title.
    var subtitle: String {
        switch self {
        case .daily: return "Premiering today"
        case .weekly: return "The last 7 days"
        case .monthly: return "The last 30 days"
        case .quarterly: return "The last 90 days"
        case .yearly: return "The last 365 days"
        }
    }

    /// The window's start as AniList's FuzzyDateInt (YYYYMMDD) — the same
    /// parameter shape the advanced-search query has used since v2.2x.
    var fuzzyStart: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let c = cal.dateComponents([.year, .month, .day], from: start)
        return (c.year ?? 2026) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }
}

// MARK: Chart definition

/// One chart row on Home (or Manga Home): what it ranks by, the extra
/// AniList filters that define it, and which time windows it offers.
struct TopChart: Identifiable, Hashable {
    /// Stable routing identifier — also the cache key and the persistence
    /// key for the selected period ("home.chart.period.<id>").
    let id: String
    /// The row's heading ("Top Anime").
    let title: String
    /// SF Symbol for accessibility labels.
    let icon: String
    /// AniList MediaSort the windowed query ranks by.
    let sort: String
    /// Genre slug (DiscoveryGenre) for genre charts, else nil.
    var genreSlug: String? = nil
    /// AniList format filter ("MOVIE" for Top Movies), else nil.
    var format: String? = nil
    /// `averageScore_greater` — Hidden Gems / Underrated floor.
    var minScore: Int? = nil
    /// `popularity_lesser` — Hidden Gems / Underrated ceiling.
    var maxPopularity: Int? = nil
    /// Chart only currently-airing titles (status: RELEASING).
    var airingOnly: Bool = false
    /// The windows this chart offers. Empty = no period chip.
    var periods: [ChartPeriod] = []
    /// The window a fresh install starts on.
    var defaultPeriod: ChartPeriod? = nil
    /// Manga charts query type MANGA and use the manga card/destination.
    var isManga: Bool = false

    var hasPeriods: Bool { !periods.isEmpty }

    /// The period a fresh install uses (first offering when unset).
    var initialPeriod: ChartPeriod? { defaultPeriod ?? periods.first }

    // The windows each metric can honestly support:
    //   • popularity accrues fast — every window, Daily included, is real;
    //   • favourites and scores need voters/time — they start at Weekly.
    private static let everyWindow: [ChartPeriod] = [.daily, .weekly, .monthly, .quarterly, .yearly]
    private static let scoredWindows: [ChartPeriod] = [.weekly, .monthly, .quarterly, .yearly]

    // MARK: Standard charts

    static let topAnime = TopChart(
        id: "top-anime", title: "Top Anime", icon: "chart.bar.fill",
        sort: "POPULARITY_DESC",
        periods: everyWindow, defaultPeriod: .weekly)

    static let topMovies = TopChart(
        id: "top-movies", title: "Top Movies", icon: "film.fill",
        sort: "POPULARITY_DESC", format: "MOVIE",
        periods: everyWindow, defaultPeriod: .weekly)

    static let mostFavorited = TopChart(
        id: "most-favorited", title: "Most Favorited", icon: "heart.fill",
        sort: "FAVOURITES_DESC",
        periods: scoredWindows, defaultPeriod: .weekly)

    /// Currently airing, ranked by popularity. No period chip — "airing"
    /// is already the filter; a premiere window on top of it would be a
    /// different chart wearing this one's title.
    static let topAiring = TopChart(
        id: "top-airing", title: "Top Airing", icon: "dot.radiowaves.left.and.right",
        sort: "POPULARITY_DESC", airingOnly: true)

    /// High scores, modest audiences — critically liked but underwatched.
    /// Real AniList parameters (averageScore_greater + popularity_lesser),
    /// not a hand-picked list.
    static let hiddenGems = TopChart(
        id: "hidden-gems", title: "Hidden Gems", icon: "sparkles",
        sort: "SCORE_DESC", minScore: 75, maxPopularity: 150_000)

    /// The same idea one tier deeper: even higher scores on even smaller
    /// audiences — a genuinely different query, not Hidden Gems relabeled.
    static let underrated = TopChart(
        id: "underrated", title: "Underrated", icon: "star.bubble",
        sort: "SCORE_DESC", minScore: 80, maxPopularity: 60_000)

    // MARK: Genre charts

    /// "Top <Genre>" rows. Built from the discovery taxonomy's own slugs,
    /// so each row's query, chip and See All page share ONE genre identity.
    /// Every genre here is AniList-indexed except Isekai (an AniList TAG,
    /// not a genre) — Isekai therefore offers no period chip: its list
    /// comes from MAL's own real genre ranking, and claiming a window no
    /// provider can actually query would be a fabricated filter.
    static let genreChartSlugs: [String] = [
        "romance", "action", "adventure", "comedy", "fantasy", "science-fiction",
        "mystery", "thriller", "drama", "horror", "slice-of-life",
        "sports", "supernatural", "psychological", "isekai",
    ]

    static let genreCharts: [TopChart] = genreChartSlugs.compactMap { slug in
        guard let genre = DiscoveryGenre.bySlug(slug) else { return nil }
        let anilistIndexed = slug != "isekai"
        return TopChart(
            id: "genre-\(slug)",
            title: "Top \(genre.displayName)",
            icon: "tag.fill",
            sort: "POPULARITY_DESC",
            genreSlug: slug,
            periods: anilistIndexed ? everyWindow : [],
            defaultPeriod: anilistIndexed ? .weekly : nil)
    }

    /// The chart rows Manga Home gains (the standard manga shelves —
    /// Trending / All-Time Popular / Top Rated / Latest — stay as they are).
    static let mangaCharts: [TopChart] = [
        TopChart(
            id: "top-manga", title: "Top Manga", icon: "books.vertical.fill",
            sort: "POPULARITY_DESC",
            periods: everyWindow, defaultPeriod: .weekly, isManga: true),
    ]
}

// MARK: Chart shelf model

/// Loads one chart row's page 1 through the unified chain (health-gated,
/// deduped, disk-cached — the same machinery every other shelf uses).
@MainActor
final class ChartShelfModel: ObservableObject {
    @Published private(set) var items: [Media] = []
    @Published private(set) var isLoading = false

    private let chart: TopChart
    /// Stale-guard: only the newest load may publish. A slow Daily fetch
    /// that returns after the user already switched to Weekly is dropped,
    /// never layered over the newer selection.
    private var generation = 0

    init(chart: TopChart) {
        self.chart = chart
    }

    func load(period: ChartPeriod?) async {
        generation += 1
        let gen = generation
        isLoading = true
        do {
            let list = try await UnifiedProviderSystem.shared.browse(chart: chart, period: period, page: 1)
            guard gen == generation else { return }
            withAnimation(.easeOut(duration: 0.25)) { items = list }
        } catch {
            // A chart row that can't be served stays empty and hidden — the
            // standard shelves carry the page (the old genre-shelf contract).
            guard gen == generation else { return }
            items = []
        }
        if gen == generation { isLoading = false }
    }
}

// MARK: Chart section view

/// A Home row for one Top Chart: the accent-underlined header the other
/// shelves use, a period chip ("Weekly ▾") that opens a bottom-sheet
/// period picker where the chart offers windows, a See All that pages
/// through THE SAME chart+period, and the shared card shelf.
/// `nativeStyle` renders the SAME row in the Apple presentation's plain
/// system design (title3 header, borderless See All, ApplePosterCard) —
/// one component, both Home designs.
struct ChartSection: View {
    let chart: TopChart
    var nativeStyle: Bool = false
    @StateObject private var model: ChartShelfModel
    /// The selected window, persisted per chart so categories stay
    /// independent — Top Anime can sit on Monthly while Top Movies is on
    /// Weekly, and both survive relaunches.
    @AppStorage private var periodRaw: String
    @State private var showPeriodDialog = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cinematicRows) private var cinematic

    init(chart: TopChart, nativeStyle: Bool = false) {
        self.chart = chart
        self.nativeStyle = nativeStyle
        _model = StateObject(wrappedValue: ChartShelfModel(chart: chart))
        _periodRaw = AppStorage(wrappedValue: chart.initialPeriod?.rawValue ?? "",
                                "home.chart.period.\(chart.id)")
    }

    private var currentPeriod: ChartPeriod? {
        guard chart.hasPeriods else { return nil }
        return ChartPeriod(rawValue: periodRaw) ?? chart.initialPeriod
    }

    private var cardWidth: CGFloat {
        if cinematic { return CinematicMetrics.relationCardWidth }
        #if os(iOS)
        if nativeStyle { return sizeClass == .regular ? 180 : 140 }
        return sizeClass == .regular ? 190 : 155
        #else
        return nativeStyle ? 180 : 190
        #endif
    }

    var body: some View {
        // The chart row renders only when it has something to show — an
        // empty window (or a source outage) collapses the row the way the
        // genre shelves always have. The task/onChange live on the Group,
        // so the load still fires even while the row is collapsed.
        Group {
            if !model.items.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    HomeShelf(items: model.items) { media in
                        card(media)
                    }
                }
            }
        }
        .task { await model.load(period: currentPeriod) }
        .onChangeOf(periodRaw) { _ in
            Task { await model.load(period: currentPeriod) }
        }
        #if !os(macOS)
        .confirmationDialog("Time Period", isPresented: $showPeriodDialog, titleVisibility: .visible) {
            ForEach(chart.periods) { period in
                Button {
                    selectPeriod(period)
                } label: {
                    HStack {
                        Text("\(period.title) — \(period.subtitle)")
                        if period == currentPeriod {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        #endif
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if nativeStyle {
            // The Apple presentation's plain system header — the same
            // shape AppleMediaSection uses, with the period chip beside
            // the borderless See All link.
            HStack(alignment: .firstTextBaseline) {
                Text(chart.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 12) {
                    periodChip
                    seeAllButton
                }
            }
            .padding(.horizontal, 16)
        } else {
            HomeRowHeader(title: chart.title) {
                HStack(spacing: 8) {
                    periodChip
                    seeAllButton
                }
            }
        }
    }

    /// "Weekly ▾" — the dropdown arrow the period picker grows out of.
    @ViewBuilder
    private var periodChip: some View {
        if chart.hasPeriods {
            #if os(macOS)
            Menu {
                ForEach(chart.periods) { period in
                    Button {
                        selectPeriod(period)
                    } label: {
                        HStack {
                            Text(period.title)
                            if period == currentPeriod {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                chipLabel
            }
            #else
            Button {
                showPeriodDialog = true
            } label: {
                chipLabel
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Text(currentPeriod?.title ?? "")
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(Color.appAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    private var seeAllButton: some View {
        NavigationLink {
            BrowseView(query: .chart(chart, currentPeriod))
        } label: {
            if nativeStyle {
                HStack(spacing: 2) {
                    Text("See All")
                        .font(.subheadline)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                }
                .foregroundStyle(Color.appAccent)
            } else {
                HStack(spacing: 3) {
                    Text("See all")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
    }

    private func selectPeriod(_ period: ChartPeriod) {
        guard period.rawValue != periodRaw else { return }
        Haptics.selection()
        withAnimation(.easeOut(duration: 0.2)) {
            periodRaw = period.rawValue
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ media: Media) -> some View {
        if nativeStyle {
            // The Apple presentation's stock poster card — same chart
            // data, same navigation destination as every other card.
            NavigationLink {
                AniListDetailView(mediaId: media.id, preloadedMedia: media)
            } label: {
                ApplePosterCard(media: media)
                    .frame(width: cardWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .unifiedCardMenu(media)
        } else if chart.isManga {
            NavigationLink {
                AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
            } label: {
                MangaPosterCard(media: media)
                    .equatable()
            }
            .buttonStyle(MangaCardPressStyle())
            .frame(width: cardWidth)
            .unifiedCardMenu(media, isManga: true)
        } else {
            NavigationLink {
                MediaDestination(media: media)
            } label: {
                AniListCardView(media: media)
            }
            .buttonStyle(HomePressStyle())
            .frame(width: cardWidth)
            .unifiedCardMenu(media)
        }
    }
}

