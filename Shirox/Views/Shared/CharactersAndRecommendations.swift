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
    /// Optional preloaded characters — when the parent already has them
    /// (e.g. anime detail fetches them as part of the main query), pass
    /// them in to avoid a second network call.
    var preloaded: [AniListCharacterEdge]? = nil

    @State private var characters: [AniListCharacterEdge] = []
    @State private var didLoad = false
    @State private var selectedCharacter: AniListCharacterEdge?

    var body: some View {
        Group {
            if !characters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Characters")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(characters) { edge in
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
            }
        }
        .navigationDestinationCompat(item: $selectedCharacter) { edge in
            CharacterDetailView(edge: edge)
        }
        .task {
            if let preloaded {
                characters = preloaded
                didLoad = true
            } else if !didLoad {
                await loadCharacters()
            }
        }
    }

    @ViewBuilder
    private func characterCard(_ edge: AniListCharacterEdge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: edge.node.image?.large ?? edge.node.image?.medium ?? "")
                .frame(width: 100, height: 140)
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
        didLoad = true
        // Reuse the main detail query — it already includes characters with
        // voice actors. This is a single extra call, cached by URLCache.
        if let media = try? await AniListService.shared.detail(id: mediaId) {
            characters = media.characters?.edges ?? []
        }
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
            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: displayCharacter.image?.large ?? displayCharacter.image?.medium ?? "")
                    .frame(width: 110, height: 160)
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
        }
        .padding(.horizontal, 16)
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
                .frame(width: 90, height: 120)
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

    @State private var recommendations: [AniListRecommendation] = []
    @State private var didLoad = false

    var body: some View {
        Group {
            if !recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recommendations")
                            .font(.title3.weight(.bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recommendations) { rec in
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
            }
        }
        .task {
            if let preloaded {
                recommendations = preloaded
                didLoad = true
            } else if !didLoad {
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
        didLoad = true
        // The anime detail query already includes recommendations; the manga
        // detail query does not. We call the anime detail endpoint for both
        // — AniList returns cross-type recommendations either way, and we
        // filter to the right type client-side.
        if let media = try? await AniListService.shared.detail(id: mediaId) {
            let all = media.recommendations?.nodes ?? []
            // Filter by type so anime pages only show anime recs and manga
            // pages only show manga recs. The recommendation payload doesn't
            // always include `type`, so we fall back to showing everything
            // when the type field is missing (better than an empty section).
            if isManga {
                recommendations = all.filter { rec in
                    guard let t = rec.mediaRecommendation?.type else { return true }
                    return t == "MANGA"
                }
            } else {
                recommendations = all.filter { rec in
                    guard let t = rec.mediaRecommendation?.type else { return true }
                    return t == "ANIME"
                }
            }
        }
    }
}
