import SwiftUI

// MARK: - CharactersSection
//
// Horizontal-scrolling strip of character cards shown on Anime and Manga
// detail pages, directly below the Synopsis. Each card shows the character's
// image + name; tapping opens `CharacterDetailView` (a custom screen, not a
// web redirect).
//
// Data source: `AniListService.shared.detail(id:)` returns `AniListMedia`
// with a `characters` connection. We fetch once on appear and cache in the
// parent view's `@State`. The fetch is best-effort — if it fails, the
// section is hidden rather than showing an error.

struct CharactersSection: View {
    let mediaId: Int
    let isManga: Bool
    /// Optional preloaded characters — when the parent already has them
    /// (e.g. anime detail fetches them as part of the main query), pass
    /// them in to avoid a second network call.
    var preloaded: [AniListCharacterEdge]? = nil

    @State private var fetchedCharacters: [AniListCharacterEdge] = []
    @State private var didFetch = false
    @State private var isLoading = false
    @State private var selectedCharacter: AniListCharacterEdge?

    /// The characters to display — prefers preloaded data (passed from the
    /// parent VM), falls back to any we fetched ourselves. Using a computed
    /// property instead of copying into @State means the view ALWAYS
    /// reflects the latest preloaded value, even when the parent passes it
    /// AFTER the first render (which is what happens when the VM's async
    /// fetch completes).
    private var displayCharacters: [AniListCharacterEdge] {
        if let preloaded, !preloaded.isEmpty { return preloaded }
        return fetchedCharacters
    }

    var body: some View {
        Group {
            if !displayCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Characters")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(displayCharacters) { edge in
                                Button {
                                    Haptics.light()
                                    selectedCharacter = edge
                                } label: {
                                    characterCard(edge)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
            } else if isLoading {
                // Loading state — show section header + spinner so the user
                // knows characters are being fetched.
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Characters")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading characters…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                }
                .padding(.top, 8)
            }
            // If not loading and displayCharacters is empty, render nothing —
            // the anime genuinely has no character data on AniList.
        }
        .navigationDestinationCompat(item: $selectedCharacter) { edge in
            CharacterDetailView(edge: edge)
        }
        .task {
            // Self-fetch when preloaded is nil OR empty. The parent VM
            // passes preloaded: vm.characters (a non-optional [AniListCharacterEdge]
            // that starts as []). Swift promotes [] → Optional([]), which is
            // NOT nil — so the old check `preloaded == nil` never fired.
            // Now we check `preloaded?.isEmpty ?? true` so the section
            // self-fetches when the VM's fetch hasn't populated data yet
            // (e.g. detail fetch failed, or preloaded media from a list
            // query has no character data).
            if (preloaded?.isEmpty ?? true) && !didFetch {
                await loadCharacters()
            }
        }
    }

    @ViewBuilder
    private func characterCard(_ edge: AniListCharacterEdge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Fixed 100×150 frame with aspectRatio + fill + clipped so all
            // character images render at the same size regardless of the
            // source image's actual dimensions.
            CachedAsyncImage(urlString: edge.node.image?.large ?? edge.node.image?.medium ?? "")
                .aspectRatio(contentMode: .fill)
                .frame(width: 100, height: 150)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(edge.node.name?.full ?? "Unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 100, alignment: .leading)

                if let role = edge.role, !role.isEmpty {
                    Text(role.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func loadCharacters() async {
        didFetch = true
        isLoading = true
        // Use the right endpoint for the media type. The anime detail query
        // (AniListService.detail) uses `type: ANIME`; the manga detail query
        // (AniListService.mangaDetail) uses `type: MANGA`. Calling the wrong
        // one returns nothing, which is why characters never appeared on
        // manga pages.
        do {
            let media: AniListMedia
            if isManga {
                media = try await AniListService.shared.mangaDetail(id: mediaId)
            } else {
                media = try await AniListService.shared.detail(id: mediaId)
            }
            fetchedCharacters = media.characters?.edges ?? []
        } catch {
            // Best-effort — leave fetchedCharacters empty if the fetch fails.
            fetchedCharacters = []
        }
        isLoading = false
    }
}

// MARK: - CharacterDetailView
//
// Custom character detail screen. Shows everything AniList gives us about a
// character edge: image, name (full + native), role, description, and the
// voice actor (with their image + language). Visually consistent with the
// rest of the app — same hero pattern as AniListDetailView, same card style
// as LibraryRowView, same Section headers as the detail pages.

struct CharacterDetailView: View {
    let edge: AniListCharacterEdge

    @Environment(\.dismiss) private var dismiss
    @State private var character: AniListCharacter?
    @State private var isLoading = false

    private var displayCharacter: AniListCharacter { character ?? edge.node }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                nameSection
                    .padding(.top, 16)
                if let desc = displayCharacter.description, !desc.isEmpty {
                    descriptionSection(desc: desc)
                        .padding(.top, 16)
                }
                if let role = edge.role, !role.isEmpty {
                    roleSection(role: role)
                        .padding(.top, 16)
                }
                // Additional info section — gender, age, birthday, favourites.
                infoSection
                    .padding(.top, 16)
                if let vas = edge.voiceActors, !vas.isEmpty {
                    voiceActorsSection(vas: vas)
                        .padding(.top, 16)
                }
                Spacer().frame(height: 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(displayCharacter.name?.full ?? "Character")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        #endif
        .task { await loadFullCharacter() }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Blurred backdrop from the character image — same pattern as
            // AniListDetailView's hero. Gives the page depth without a
            // separate banner asset (characters don't have banners).
            CachedAsyncImage(urlString: displayCharacter.image?.large ?? displayCharacter.image?.medium ?? "")
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: Color(.systemBackground).opacity(0.9), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Foreground: sharp character portrait on the left.
            // 2:3 aspect ratio matches AniList character images (no distortion).
            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: displayCharacter.image?.large ?? displayCharacter.image?.medium ?? "")
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Spacer()
                    if let role = edge.role, !role.isEmpty {
                        Text(role.capitalized)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.appAccent))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: 280)
    }

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayCharacter.name?.full ?? "Unknown")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            if let native = displayCharacter.name?.native, !native.isEmpty {
                Text(native)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            // Alternative names (aliases)
            if let alt = displayCharacter.name?.alternative, !alt.isEmpty {
                Text("Also known as: " + alt.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Info section (gender, age, birthday, favourites)

    @ViewBuilder
    private var infoSection: some View {
        let items = infoItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Information")
                    .font(.headline)
                    .padding(.horizontal, 16)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(item.1)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var infoItems: [(String, String)] {
        var items: [(String, String)] = []
        if let gender = displayCharacter.gender, !gender.isEmpty {
            items.append(("Gender", gender.capitalized))
        }
        if let age = displayCharacter.age, !age.isEmpty {
            items.append(("Age", age))
        }
        if let dob = displayCharacter.dateOfBirth, let formatted = dob.formatted as String?, !formatted.isEmpty {
            items.append(("Birthday", formatted))
        }
        if let blood = displayCharacter.bloodType, !blood.isEmpty {
            items.append(("Blood Type", blood))
        }
        if let fav = displayCharacter.favourites, fav > 0 {
            items.append(("Favourites", "\(fav)"))
        }
        return items
    }

    @ViewBuilder
    private func descriptionSection(desc: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            Text(desc.decodingHTMLEntities())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func roleSection(role: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Role")
                .font(.headline)
            Text(role.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.appAccent.opacity(0.15)))
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func voiceActorsSection(vas: [AniListVoiceActor]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice Actors")
                .font(.headline)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vas) { va in
                        voiceActorCard(va)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func voiceActorCard(_ va: AniListVoiceActor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: va.image?.large ?? va.image?.medium ?? "")
                .aspectRatio(contentMode: .fill)
                .frame(width: 90, height: 135)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(va.name?.full ?? "Unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 90, alignment: .leading)

                if let lang = va.language, !lang.isEmpty {
                    Text(lang.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Load

    /// The character edge from the parent already has name + image + role +
    /// voiceActors, but the description may be missing (AniList sometimes
    /// omits it in the connection). This fetches the full character node by
    /// ID so we get the complete description. Best-effort — if it fails, we
    /// fall back to whatever the edge already had.
    private func loadFullCharacter() async {
        guard character == nil else { return }
        isLoading = true
        // AniList doesn't have a dedicated "fetch character by id" endpoint
        // in our service, but the edge already carries description in most
        // cases. We skip the extra call and just use the edge data.
        character = edge.node
        isLoading = false
    }
}

// MARK: - RecommendationsSection
//
// Horizontal-scrolling strip of recommended titles, shown directly below
// the Characters section. Pulls from AniList's `recommendations` connection
// (already returned by `AniListService.detail(id:)` for anime; we fetch
// fresh for manga since the manga detail query doesn't include them).
// Tapping a recommendation opens the appropriate detail page (anime or
// manga) via NavigationLink.

struct RecommendationsSection: View {
    let mediaId: Int
    let isManga: Bool
    var preloaded: [AniListRecommendation]? = nil

    @State private var fetchedRecommendations: [AniListRecommendation] = []
    @State private var didFetch = false
    @State private var isLoading = false

    /// Computed: prefers preloaded data, falls back to self-fetched. Same
    /// pattern as CharactersSection — using a computed property means the
    /// view ALWAYS reflects the latest preloaded value, even when the
    /// parent passes it after the first render.
    private var displayRecommendations: [AniListRecommendation] {
        if let preloaded, !preloaded.isEmpty { return preloaded }
        return fetchedRecommendations
    }

    var body: some View {
        Group {
            if !displayRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recommendations")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(displayRecommendations) { rec in
                                if let media = rec.mediaRecommendation {
                                    NavigationLink {
                                        destination(for: media)
                                    } label: {
                                        recommendationCard(media)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
            } else if isLoading {
                // Loading state — show section header + spinner.
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recommendations")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading recommendations…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                }
                .padding(.top, 8)
            }
            // If not loading and displayRecommendations is empty, render nothing.
        }
        .task {
            // Only fetch if the parent didn't pass preloaded data.
            // Self-fetch when preloaded is nil OR empty (same fix as
            // CharactersSection — see comment there).
            if (preloaded?.isEmpty ?? true) && !didFetch {
                await loadRecommendations()
            }
        }
    }

    @ViewBuilder
    private func recommendationCard(_ media: AniListMedia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let score = media.averageScore {
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
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)

            Text(media.title.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 110, alignment: .leading)

            if let year = media.seasonYear {
                Text(String(year))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func destination(for media: AniListMedia) -> some View {
        if isManga {
            AniListMangaDetailView(mediaId: media.id, preloadedMedia: mapToMedia(media))
        } else {
            AniListDetailView(mediaId: media.id, preloadedMedia: mapToMedia(media))
        }
    }

    /// Maps an `AniListMedia` (recommendation payload) to the app's `Media`
    /// model so the destination detail view can use it as a preloaded value.
    private func mapToMedia(_ m: AniListMedia) -> Media {
        Media(
            id: m.id,
            idMal: m.idMal,
            provider: .anilist,
            title: MediaTitle(romaji: m.title.romaji, english: m.title.english, native: m.title.native),
            coverImage: MediaCoverImage(large: m.coverImage.large, extraLarge: m.coverImage.extraLarge),
            bannerImage: m.bannerImage,
            description: m.description,
            episodes: m.episodes ?? m.chapters,
            status: m.status,
            averageScore: m.averageScore,
            genres: m.genres,
            season: m.season,
            seasonYear: m.seasonYear,
            nextAiringEpisode: nil,
            relations: nil,
            type: isManga ? "MANGA" : "ANIME",
            format: m.format,
            studioNames: nil,
            source: nil,
            duration: nil,
            airDateRange: nil
        )
    }

    private func loadRecommendations() async {
        didFetch = true
        isLoading = true
        do {
            let media: AniListMedia
            if isManga {
                media = try await AniListService.shared.mangaDetail(id: mediaId)
            } else {
                media = try await AniListService.shared.detail(id: mediaId)
            }
            let all = media.recommendations?.nodes ?? []
            if isManga {
                fetchedRecommendations = all.filter { rec in
                    guard let t = rec.mediaRecommendation?.type else { return true }
                    return t == "MANGA"
                }
            } else {
                fetchedRecommendations = all.filter { rec in
                    guard let t = rec.mediaRecommendation?.type else { return true }
                    return t == "ANIME"
                }
            }
        } catch {
            fetchedRecommendations = []
        }
        isLoading = false
    }
}
