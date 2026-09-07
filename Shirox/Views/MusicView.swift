import SwiftUI

// MARK: - Music Tab
//
// A dedicated Music section for the app — openings, endings, and the anime
// they belong to, all real data from MyAnimeList's theme database (through
// the AnimeMusicService). Design goals:
//
//   • Feels like its own section, not a bolted-on list: hero header,
//     featured openers rail, endings rail, filter chips, and its own
//     search — all in the app's card-based, capsule-badge design language.
//   • Custom UI everywhere (search field, chips, cards, empty/error
//     states) — no Apple-default placeholders.
//   • Honest data: songs appear exactly as MAL returns them; entries that
//     can't be parsed are skipped; an unreachable source shows a custom
//     retry card, never a blank page or invented data.

struct MusicView: View {
    @StateObject private var vm = MusicViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    searchField
                    filterChips

                    if vm.isLoading && vm.openings.isEmpty && vm.endings.isEmpty && vm.searchResults == nil {
                        loadingGrid
                    } else if let error = vm.error, vm.openings.isEmpty && vm.endings.isEmpty {
                        errorCard(error)
                    } else if let results = vm.searchResults {
                        searchResultsSection(results)
                    } else {
                        if !vm.filteredOpenings.isEmpty {
                            sectionHeader("Featured Openings", icon: "music.note", tint: .pink)
                            featuredRail(vm.filteredOpenings)
                        }
                        if !vm.filteredEndings.isEmpty {
                            sectionHeader("Featured Endings", icon: "music.note.list", tint: .indigo)
                            featuredRail(vm.filteredEndings)
                        }
                        if vm.openings.isEmpty && vm.endings.isEmpty && !vm.isLoading {
                            emptyCard
                        }
                    }
                    Spacer().frame(height: 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Music")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .tint(.appAccent)
        .task { await vm.loadFeaturedIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                Text("Openings & Endings")
                    .font(.title3.weight(.heavy))
            }
            Text("Every song straight from the anime database — tap a track to jump to its anime.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search anime or song", text: $vm.searchText)
                .font(.body)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await vm.runSearch() } }
            if !vm.searchText.isEmpty {
                Button {
                    vm.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            if vm.isSearching {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(MusicFilter.allCases) { filter in
                let selected = vm.filter == filter
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        vm.filter = filter
                    }
                } label: {
                    Text(filter.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(selected ? Color.appAccent : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Sections

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
        }
    }

    /// Horizontal rail of large "now playing" style cards.
    private func featuredRail(_ songs: [AnimeMusicService.AnimeSong]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(songs.prefix(20)) { song in
                    MusicFeaturedCard(song: song, width: sizeClass == .regular ? 230 : 190)
                }
            }
        }
    }

    private func searchResultsSection(_ results: [AnimeMusicService.AnimeSong]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Results", icon: "magnifyingglass", tint: .blue)
            if results.isEmpty {
                emptySearchCard
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(results) { song in
                        MusicSongRow(song: song)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var loadingGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 200)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Couldn't load music")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await vm.reload() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Color.appAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var emptySearchCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("No themes found")
                .font(.headline)
            Text("That anime has no openings or endings listed in the database.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("No music loaded yet")
                .font(.headline)
            Text("Pull down or tap retry once your connection is back.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Filter

enum MusicFilter: String, CaseIterable, Identifiable {
    case all, openings, endings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .openings: return "Openings"
        case .endings: return "Endings"
        }
    }
}

// MARK: - View Model

@MainActor
final class MusicViewModel: ObservableObject {
    @Published var openings: [AnimeMusicService.AnimeSong] = []
    @Published var endings: [AnimeMusicService.AnimeSong] = []
    @Published var searchText: String = "" { didSet { scheduleSearch() } }
    @Published var searchResults: [AnimeMusicService.AnimeSong]?
    @Published var isSearching = false
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter: MusicFilter = .all

    private var loaded = false
    private var searchDebounceTask: Task<Void, Never>?

    var filteredOpenings: [AnimeMusicService.AnimeSong] {
        filter == .all || filter == .openings ? openings : []
    }
    var filteredEndings: [AnimeMusicService.AnimeSong] {
        filter == .all || filter == .endings ? endings : []
    }

    func loadFeaturedIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        loaded = true
        error = nil
        if openings.isEmpty || endings.isEmpty {
            isLoading = true
        }
        do {
            async let op: [AnimeMusicService.AnimeSong] = AnimeMusicService.shared.featured(kind: .opening)
            async let ed: [AnimeMusicService.AnimeSong] = AnimeMusicService.shared.featured(kind: .ending)
            let (o, e) = try await (op, ed)
            openings = o
            endings = e
            if o.isEmpty && e.isEmpty {
                error = "The anime database didn't return any theme songs. It may be temporarily unavailable."
            }
        } catch {
            if openings.isEmpty && endings.isEmpty {
                self.error = "MyAnimeList's theme data is temporarily unreachable. \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        let query = searchText
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Clearing the field returns to the featured layout.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                searchResults = nil
                isSearching = false
            }
            return
        }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(query: query)
        }
    }

    func runSearch() async {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await runSearch(query: query)
    }

    private func runSearch(query: String) async {
        // Ignore a stale debounce if the field changed in the meantime.
        guard query == searchText else { return }
        isSearching = true
        error = nil
        do {
            let results = try await AnimeMusicService.shared.search(query)
            guard query == searchText else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                searchResults = results
            }
        } catch {
            guard query == searchText else { return }
            searchResults = []
        }
        isSearching = false
    }

    func clearSearch() {
        searchDebounceTask?.cancel()
        searchText = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            searchResults = nil
        }
    }
}

// MARK: - Featured Card

/// Large "now playing" style card: anime artwork, gradient scrim, theme
/// badge, song title, artist, anime name.
struct MusicFeaturedCard: View {
    let song: AnimeMusicService.AnimeSong
    let width: CGFloat

    var body: some View {
        NavigationLink {
            MusicAnimeRouter(song: song)
        } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(urlString: song.coverImage ?? "")
                    .frame(width: width, height: width * 0.62)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.15), .black.opacity(0.82)],
                            startPoint: .center, endPoint: .bottom)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        kindBadge
                        if let number = song.number {
                            Text("#\(number)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    Spacer()
                    Text(song.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                    if let artist = song.artist {
                        Text(artist)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Text(song.animeTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(10)
            }
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(MusicCardPressStyle())
    }

    private var kindBadge: some View {
        Text(song.kind.rawValue)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(song.kind == .opening ? Color.pink.opacity(0.85) : Color.indigo.opacity(0.85))
            )
    }
}

// MARK: - Song Row

struct MusicSongRow: View {
    let song: AnimeMusicService.AnimeSong

    var body: some View {
        NavigationLink {
            MusicAnimeRouter(song: song)
        } label: {
            HStack(spacing: 12) {
                // Artwork
                ZStack {
                    CachedAsyncImage(urlString: song.coverImage ?? "")
                        .frame(width: 62, height: 62)
                        .clipped()
                    if song.coverImage == nil {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 62, height: 62)
                            .background(Color.secondary.opacity(0.12))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Song info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    if let artist = song.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(song.animeTitle + (song.episodesRange.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                Text(song.kind.rawValue)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(song.kind == .opening ? .pink : .indigo)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill((song.kind == .opening ? Color.pink : Color.indigo).opacity(0.12))
                    )
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(MusicCardPressStyle())
    }
}

// MARK: - Navigation router
//
// Songs only know their MyAnimeList id. The router resolves the AniList
// cross-id (offline mapping cache first, one lookup on miss) and then
// pushes the standard anime detail page. When no mapping exists it still
// pushes with the MAL id + a preloaded minimal media — the detail view's
// own MAL-id resolution then decides what it can honestly load.

struct MusicAnimeRouter: View {
    let song: AnimeMusicService.AnimeSong
    @State private var resolvedId: Int?
    @State private var resolved = false

    var body: some View {
        Group {
            if let id = resolvedId {
                AniListDetailView(mediaId: id, preloadedMedia: preloadedMedia)
            } else if !resolved {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.15)
                    Text("Opening anime…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Unmapped title — push with the MAL id so the detail
                // page's fallback machinery handles it.
                AniListDetailView(mediaId: song.animeMALId, preloadedMedia: preloadedMedia)
            }
        }
        .task {
            guard !resolved else { return }
            resolvedId = await AnimeMusicService.shared.anilistId(for: song)
            resolved = true
        }
    }

    private var preloadedMedia: Media {
        Media(
            id: resolvedId ?? song.animeMALId,
            idMal: song.animeMALId,
            provider: .mal,
            title: MediaTitle(romaji: song.animeTitle, english: nil, native: nil),
            coverImage: MediaCoverImage(large: song.coverImage, extraLarge: song.coverImage),
            bannerImage: nil,
            description: nil,
            episodes: nil,
            status: nil,
            averageScore: nil,
            genres: nil,
            season: nil,
            seasonYear: song.animeYear,
            nextAiringEpisode: nil,
            relations: nil,
            type: "TV",
            format: nil,
            studioNames: nil, source: nil, duration: nil, airDateRange: nil
        )
    }
}

// MARK: - Press style

struct MusicCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
