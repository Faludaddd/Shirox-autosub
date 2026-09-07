import SwiftUI

// MARK: - Music Section (AnimeThemes.moe)
//
// A dedicated Music section for the app — anime openings, endings, and
// insert songs, all real data from AnimeThemes.moe (the dedicated anime
// theme database) through its official GraphQL API. Opened from the
// music-note icon beside the manga toggle in the Home toolbar.
//
// Design goals:
//   • Feels like its own section, not a bolted-on list: hero header,
//     featured rail (the provider's own shuffle), this season's
//     openings & endings, an artists rail, and its own search.
//   • Custom UI everywhere (search field, chips, cards, empty/error/
//     loading states) — the app's card + capsule-badge design language.
//   • REAL playback: tapping a theme plays its media inside the app
//     (AnimeThemes → theme → entry → media → MusicPlayerManager, powered
//     by VLCKit for the provider's WebM/Opus formats). Music never opens
//     AnimeThemes in Safari.
//   • Independent from AniList — the section keeps working while AniList
//     is down (data AND playback have zero AniList dependency).
//   • Honest data: everything comes from the provider; fields the
//     provider doesn't have simply don't render; failures show a retry
//     card, never a blank page.

struct MusicView: View {
    @StateObject private var vm = MusicViewModel()

    var body: some View {
        // NOTE: no NavigationStack here — pushed from the Home toolbar, the
        // page rides the HOME stack (its navigationDestinationCompat drives
        // the anime/artist pushes). The macOS sidebar wraps this view in
        // its own stack where it's the root (see ShiroxApp).
        ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    searchField
                    filterChips

                    if vm.isSearchActive {
                        searchResultsSection
                    } else if vm.isLoading && vm.featured.isEmpty && vm.seasonOpenings.isEmpty && vm.seasonEndings.isEmpty {
                        loadingGrid
                    } else if let error = vm.error, vm.featured.isEmpty, vm.seasonOpenings.isEmpty, vm.seasonEndings.isEmpty {
                        errorCard(error)
                    } else {
                        if !vm.filteredFeatured.isEmpty {
                            sectionHeader("Featured Themes", icon: "shuffle", tint: .pink)
                            themeRail(vm.filteredFeatured)
                        }
                        if !vm.filteredSeasonOpenings.isEmpty {
                            sectionHeader("This Season's Openings", icon: "play.circle.fill", tint: Color.appAccent)
                            themeRail(vm.filteredSeasonOpenings)
                        }
                        if !vm.filteredSeasonEndings.isEmpty {
                            sectionHeader("This Season's Endings", icon: "stop.circle.fill", tint: .indigo)
                            themeRail(vm.filteredSeasonEndings)
                        }
                        if !vm.artists.isEmpty {
                            sectionHeader("Artists This Season", icon: "person.2.fill", tint: .orange)
                            artistsRail(vm.artists)
                        }
                        if vm.featured.isEmpty && vm.seasonOpenings.isEmpty && vm.seasonEndings.isEmpty && !vm.isLoading {
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
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .tint(.appAccent)
            .task { await vm.loadIfNeeded() }
            .refreshable { await vm.reload() }
            // Card → anime-page navigation (hidden link drives the push on
            // every OS the app supports — see navigationDestinationCompat).
        .navigationDestinationCompat(item: $vm.pendingAnimeSlug) { slug in
            MusicAnimePage(slug: slug)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                Text("Anime Openings & Endings")
                    .font(.title3.weight(.heavy))
            }
            Text("Streaming from AnimeThemes — tap any theme to play it right here.")
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
            TextField("Search anime, songs, or artists", text: $vm.searchText)
                .font(.body)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { await vm.runSearchNow() }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicFilter.allCases, id: \.self) { filter in
                    let selected = vm.filter == filter
                    Button {
                        Haptics.selection()
                        vm.filter = filter
                    } label: {
                        HStack(spacing: 6) {
                            if let icon = filter.icon {
                                Image(systemName: icon)
                                    .font(.caption2.weight(.bold))
                            }
                            Text(filter.label)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected ? Color.appAccent.opacity(0.16) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.appAccent.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .foregroundStyle(selected ? Color.appAccent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsSection: some View {
        if vm.isSearching && vm.searchThemes.isEmpty && vm.searchArtists.isEmpty {
            loadingGrid
        } else if let error = vm.searchError, vm.searchThemes.isEmpty, vm.searchArtists.isEmpty {
            errorCard(error)
        } else if vm.searchThemes.isEmpty && vm.searchArtists.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("No themes found")
                    .font(.headline)
                Text("Nothing on AnimeThemes matches “\(vm.searchText)”. Try the anime's full name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            if !vm.searchThemes.isEmpty {
                sectionHeader("Themes", icon: "music.note", tint: .pink)
                VStack(spacing: 10) {
                    ForEach(vm.searchThemes) { theme in
                        MusicThemeRow(
                            theme: theme,
                            queue: vm.searchThemes,
                            onAnimeTap: { slug in vm.pendingAnimeSlug = slug })
                    }
                }
            }
            if !vm.searchArtists.isEmpty {
                sectionHeader("Artists", icon: "person.fill", tint: .orange)
                VStack(spacing: 10) {
                    ForEach(vm.searchArtists) { artist in
                        MusicArtistRow(artist: artist)
                    }
                }
            }
        }
    }

    // MARK: - Rails

    private func themeRail(_ themes: [ATTheme]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(themes) { theme in
                    MusicThemeCard(
                        theme: theme,
                        queue: themes,
                        onAnimeTap: { slug in vm.pendingAnimeSlug = slug })
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func artistsRail(_ artists: [ATArtist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(artists) { artist in
                    MusicArtistRow(artist: artist, compact: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline.weight(.bold))
            Spacer(minLength: 0)
        }
    }

    // MARK: - States

    private var loadingGrid: some View {
        VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 120, height: 10)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Couldn't reach AnimeThemes")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await vm.reload() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No themes yet")
                .font(.headline)
            Text("Pull to refresh — AnimeThemes updates its database with every airing season.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Navigation
}

// MARK: - Filter

enum MusicFilter: String, CaseIterable {
    case all = "All"
    case openings = "Openings"
    case endings = "Endings"
    case artists = "Artists"

    var label: String { rawValue }

    var icon: String? {
        switch self {
        case .all:      return nil
        case .openings: return "play.fill"
        case .endings:  return "stop.fill"
        case .artists:  return "person.2.fill"
        }
    }
}

// MARK: - Theme card (rail)

struct MusicThemeCard: View {
    let theme: ATTheme
    let queue: [ATTheme]
    var onAnimeTap: (String) -> Void

    @ObservedObject private var player = MusicPlayerManager.shared
    private let cornerRadius: CGFloat = 14

    private var track: MusicTrack {
        MusicTrack(theme: theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Artwork + play overlay + type badge.
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(urlString: theme.animeRef?.coverImage ?? "")
                    .frame(width: 158, height: 100)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.7)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                Text(theme.badge)
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(6)

                if player.currentTrack?.id == theme.id {
                    // Currently playing — live indicator.
                    MusicPlayingIndicator()
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 158, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if player.currentTrack?.id == theme.id {
                    player.togglePlayPause()
                } else {
                    player.play(track: track, queue: queue.map { MusicTrack(theme: $0) })
                }
            }

            // Title + artist + anime (tap anime → its theme page).
            VStack(alignment: .leading, spacing: 3) {
                Text(theme.songTitle ?? theme.kindLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(theme.artistLine ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let ref = theme.animeRef, !ref.title.isEmpty {
                    Button {
                        onAnimeTap(ref.slug)
                    } label: {
                        HStack(spacing: 3) {
                            Text(ref.title)
                                .font(.caption2.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(Color.appAccent.opacity(0.9))
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 7)
        }
        .frame(width: 158, alignment: .leading)
    }
}

// MARK: - Theme row (search results / anime pages)

struct MusicThemeRow: View {
    let theme: ATTheme
    let queue: [ATTheme]
    var onAnimeTap: (String) -> Void

    @ObservedObject private var player = MusicPlayerManager.shared

    private var track: MusicTrack { MusicTrack(theme: theme) }
    private var isCurrent: Bool { player.currentTrack?.id == theme.id }

    var body: some View {
        HStack(spacing: 12) {
            // Artwork + play state.
            ZStack {
                CachedAsyncImage(urlString: theme.animeRef?.coverImage ?? "")
                    .frame(width: 56, height: 56)
                    .clipped()
                Rectangle().fill(Color.black.opacity(isCurrent ? 0.35 : 0))
                if isCurrent {
                    MusicPlayingIndicator()
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if isCurrent {
                    player.togglePlayPause()
                } else {
                    player.play(track: track, queue: queue.map { MusicTrack(theme: $0) })
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.badge)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                        .foregroundStyle(Color.appAccent)
                    Text(theme.songTitle ?? theme.kindLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let artist = theme.artistLine {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let ref = theme.animeRef, !ref.title.isEmpty {
                    Button {
                        onAnimeTap(ref.slug)
                    } label: {
                        HStack(spacing: 3) {
                            Text(ref.title)
                                .font(.caption2.weight(.medium))
                            if let year = ref.year {
                                Text("· \(String(year))")
                                    .font(.caption2)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(Color.appAccent.opacity(0.9))
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            if let quality = theme.playableMedia?.qualityLabel {
                Text(quality)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? Color.appAccent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Live "playing" indicator

struct MusicPlayingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: animating ? 13 : 5)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .onAppear { animating = true }
    }
}

// MARK: - Artist row

struct MusicArtistRow: View {
    let artist: ATArtist
    var compact: Bool = false

    var body: some View {
        NavigationLink {
            MusicArtistPage(artist: artist)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.14))
                    Image(systemName: "person.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Artist")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Music anime page (all themes of one anime)

struct MusicAnimePage: View {
    let slug: String
    @StateObject private var vm = MusicAnimeViewModel()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let error = vm.error {
                    MusicErrorCard(message: error) {
                        Task { await vm.load(slug: slug) }
                    }
                } else if let anime = vm.anime {
                    MusicAnimeHeader(anime: anime, themes: vm.anime?.themes ?? [])
                    if !vm.playableThemes.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(vm.playableThemes) { theme in
                                MusicThemeRow(theme: theme, queue: vm.playableThemes, onAnimeTap: { _ in })
                            }
                        }
                    } else {
                        MusicEmptyCard(
                            icon: "music.note",
                            title: "No playable themes",
                            message: "AnimeThemes lists no opening or ending media for this anime yet.")
                    }
                }
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(vm.anime?.displayTitle.isEmpty == false ? vm.anime!.displayTitle : "Themes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: slug) { await vm.load(slug: slug) }
    }
}

@MainActor
final class MusicAnimeViewModel: ObservableObject {
    @Published var anime: ATAnime?
    @Published var isLoading = false
    @Published var error: String?

    var playableThemes: [ATTheme] {
        guard let anime else { return [] }
        // Attach THIS anime as each theme's ref — rows, artwork, and the
        // player all show the correct parent (no cross-anime data).
        let ref = ATThemeAnimeRef(animeId: anime.id,
                                  slug: anime.slug,
                                  title: anime.displayTitle,
                                  coverImage: anime.coverImage,
                                  year: anime.year,
                                  anilistId: anime.anilistId)
        return anime.themes
            .filter { $0.playableMedia != nil }
            .map { $0.attaching(animeRef: ref) }
    }

    func load(slug: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let anime = try await AnimeThemesService.shared.animeForSlug(slug)
            self.anime = anime
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Header for one anime inside Music: cover, title, meta, and the exact
/// AniList navigation (via the provider's own resource mapping).
struct MusicAnimeHeader: View {
    let anime: ATAnime
    let themes: [ATTheme]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(urlString: anime.coverImage ?? "")
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(anime.displayTitle)
                        .font(.headline.weight(.bold))
                        .lineLimit(2)
                    // Meta chips — only what the provider actually gives.
                    HStack(spacing: 6) {
                        ForEach(metaChips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    Spacer(minLength: 2)
                }
            }

            // The exact anime page — the provider carries the AniList id.
            if let anilistId = anime.anilistId {
                NavigationLink {
                    AniListDetailView(mediaId: anilistId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open in Shirox")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                    .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var metaChips: [String] {
        var chips: [String] = []
        if let year = anime.year { chips.append(String(year)) }
        if let season = anime.season { chips.append(season.capitalized) }
        if let format = anime.format { chips.append(format) }
        return chips
    }
}

// MARK: - Music artist page

struct MusicArtistPage: View {
    let artist: ATArtist
    @StateObject private var vm = MusicArtistViewModel()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let error = vm.error {
                    MusicErrorCard(message: error) {
                        Task { await vm.load(slug: artist.slug) }
                    }
                } else {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color.orange.opacity(0.14))
                            Text(String(artist.name.prefix(1)).uppercased())
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name)
                                .font(.headline.weight(.bold))
                            Text("\(vm.themes.count) theme\(vm.themes.count == 1 ? "" : "s") on AnimeThemes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                    if !vm.themes.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(vm.themes) { theme in
                                MusicThemeRow(theme: theme, queue: vm.themes, onAnimeTap: { _ in })
                            }
                        }
                    } else {
                        MusicEmptyCard(
                            icon: "music.note",
                            title: "No playable themes",
                            message: "This artist's songs have no theme media on AnimeThemes yet.")
                    }
                }
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.slug) { await vm.load(slug: artist.slug) }
    }
}

@MainActor
final class MusicArtistViewModel: ObservableObject {
    @Published var themes: [ATTheme] = []
    @Published var isLoading = false
    @Published var error: String?

    func load(slug: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await AnimeThemesService.shared.artistDetail(slug: slug)
            self.themes = result.themes
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Shared small cards

struct MusicErrorCard: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Couldn't reach AnimeThemes")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

struct MusicEmptyCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - View model

@MainActor
final class MusicViewModel: ObservableObject {
    @Published var featured: [ATTheme] = []
    @Published var seasonOpenings: [ATTheme] = []
    @Published var seasonEndings: [ATTheme] = []
    @Published var artists: [ATArtist] = []
    @Published var searchThemes: [ATTheme] = []
    @Published var searchArtists: [ATArtist] = []
    @Published var searchText = "" {
        didSet { searchDidChange() }
    }
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var filter: MusicFilter = .all
    @Published var isLoading = false
    @Published var error: String?
    /// Set when a card's anime area is tapped — MusicView drives the push
    /// via navigationDestinationCompat.
    @Published var pendingAnimeSlug: String?

    var isSearchActive: Bool { !searchText.isEmpty }

    private var loaded = false
    private var searchDebounce: Task<Void, Never>?

    // Filtered rails — the chips only reorder what's already loaded.
    var filteredFeatured: [ATTheme] { applyFilter(featured) }
    var filteredSeasonOpenings: [ATTheme] { applyFilter(seasonOpenings) }
    var filteredSeasonEndings: [ATTheme] { applyFilter(seasonEndings) }

    private func applyFilter(_ themes: [ATTheme]) -> [ATTheme] {
        guard filter != .artists else { return [] }
        switch filter {
        case .openings: return themes.filter { $0.type == "OP" }
        case .endings:  return themes.filter { $0.type == "ED" }
        default:        return themes
        }
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        loaded = true
        isLoading = true
        error = nil
        // Sequential load with the service's pacing — AnimeThemes allows
        // 90 req/min; 4 requests per page load is far under budget.
        do {
            featured = try await AnimeThemesService.shared.featuredThemes(limit: 12)
        } catch { recordListError(error) }
        do {
            seasonOpenings = try await AnimeThemesService.shared.currentSeasonThemes(kind: "OP", limit: 20)
        } catch { recordListError(error) }
        do {
            seasonEndings = try await AnimeThemesService.shared.currentSeasonThemes(kind: "ED", limit: 20)
        } catch { recordListError(error) }
        do {
            artists = try await AnimeThemesService.shared.currentSeasonArtists(limit: 12)
        } catch { /* artists are supplementary — a failure here isn't fatal */ }
        isLoading = false
    }

    private func recordListError(_ error: Error) {
        guard featured.isEmpty, seasonOpenings.isEmpty, seasonEndings.isEmpty else { return }
        self.error = error.localizedDescription
    }

    // MARK: - Search (debounced + cancellable)

    private func searchDidChange() {
        searchDebounce?.cancel()
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchThemes = []
            searchArtists = []
            searchError = nil
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(query: query)
        }
    }

    func runSearchNow() async {
        searchDebounce?.cancel()
        await runSearch(query: searchText)
    }

    private func runSearch(query: String) async {
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            searchThemes = try await AnimeThemesService.shared.searchAnime(query, kind: kindForFilter)
        } catch {
            searchThemes = []
            searchError = error.localizedDescription
        }
        // Artists are the "Artists" chip's content — only fetched when the
        // filter is on artists (or always? keep it cheap: only on artists).
        if filter == .artists {
            do {
                searchArtists = try await AnimeThemesService.shared.searchArtists(query)
            } catch {
                searchArtists = []
            }
        } else {
            searchArtists = []
        }
    }

    private var kindForFilter: String? {
        switch filter {
        case .openings: return "OP"
        case .endings:  return "ED"
        default:        return nil
        }
    }

    func clearSearch() {
        searchText = ""
        searchThemes = []
        searchArtists = []
        searchError = nil
    }
}

// MARK: - Anime detail integration (openings & endings on the anime page)

/// v2.23 — The anime page's Themes section: this anime's openings and
/// endings from AnimeThemes, resolved through the provider's EXACT
/// AniList resource mapping (no title matching — the right anime's
/// themes, always). Each row plays its media in-app through the shared
/// player; a footer link opens the full Music page for that anime.
///
/// Hidden entirely when AnimeThemes has no themes for the anime (most
/// common cause: the anime simply isn't in their database yet). A failed
/// lookup stays silent — the section is supplementary, never an error
/// surface on the anime page.
#if os(iOS)
struct AnimeThemesSection: View {
    let anilistId: Int

    @State private var themes: [ATTheme]?
    @State private var animeInfo: ATAnime?

    /// Themes carrying THIS anime as their ref (artwork + player show the
    /// correct parent — the mapping is the provider's own AniList id).
    private var playable: [ATTheme] {
        guard let animeInfo, let themes else { return [] }
        let ref = ATThemeAnimeRef(animeId: animeInfo.id,
                                  slug: animeInfo.slug,
                                  title: animeInfo.displayTitle,
                                  coverImage: animeInfo.coverImage,
                                  year: animeInfo.year,
                                  anilistId: animeInfo.anilistId)
        return themes
            .filter { $0.playableMedia != nil }
            .map { $0.attaching(animeRef: ref) }
    }

    var body: some View {
        Group {
            if !playable.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    ForEach(playable) { theme in
                        MusicThemeRow(theme: theme, queue: playable, onAnimeTap: { _ in })
                    }
                }
            }
        }
        .task(id: anilistId) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.appAccent)
            Text("Themes")
                .font(.headline.weight(.bold))
            Spacer(minLength: 0)
            Text("AnimeThemes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        do {
            // The provider's own mapping: findAnimeByExternalSite(site:
            // ANILIST, id:) → the anime's real themes.
            let anime = try await AnimeThemesService.shared.animeForExternalId(site: "ANILIST", id: anilistId)
            animeInfo = anime
            themes = anime?.themes
        } catch {
            // Supplementary data — a failure here never breaks the anime
            // page. Stay silent; next visit retries (45s failure cache).
            themes = nil
        }
    }
}
#endif
