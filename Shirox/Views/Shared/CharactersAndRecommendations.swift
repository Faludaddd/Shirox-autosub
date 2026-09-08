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
    /// Optional MAL ID — when the parent already has it (from the detail
    /// fetch's `idMal` field), pass it in so the character chain resolves
    /// the MAL leg without re-fetching the full detail.
    var malId: Int? = nil
    /// Optional preloaded characters — when the parent already has them
    /// (e.g. anime detail fetches them as part of the main query), pass
    /// them in to avoid a second network call.
    var preloaded: [AniListCharacterEdge]? = nil

    @State private var fetchedCharacters: [AniListCharacterEdge] = []
    @State private var didFetch = false
    @State private var isLoading = false
    @State private var selectedCharacter: AniListCharacterEdge?
    /// Batch 26 — set when EVERY provider in the character chain failed:
    /// the section shows its clean "unavailable" state instead of
    /// silently vanishing.
    @State private var charactersUnavailable = false
    /// Collapsed by default — the user taps the chevron to expand the
    /// character strip. Keeping it collapsed on first render avoids an
    /// overwhelming wall of character art on the detail page.
    @State private var isExpanded = false

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
                    sectionHeader
                    if isExpanded {
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
                }
                .padding(.top, 8)
            } else if isLoading {
                // Loading state — show section header + spinner so the user
                // knows characters are being fetched.
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    if isExpanded {
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
                }
                .padding(.top, 8)
            } else if charactersUnavailable {
                // Batch 26 — the clean UNAVAILABLE state: every provider in
                // the chain (TVDB → MAL → AniList → Kitsu) failed. The
                // section stays visible with an honest message instead of
                // silently disappearing; one tap retries the whole chain.
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    if isExpanded {
                        Button {
                            Task { await loadCharacters() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.exclamationmark")
                                    .font(.system(size: 20))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Characters unavailable right now")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Every character source is unreachable. Tap to retry.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.secondary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            // If not loading, not unavailable and displayCharacters is
            // empty, the title genuinely has no character data anywhere —
            // the section stays hidden for titles with no cast at all.
        }
        .navigationDestinationCompat(item: $selectedCharacter) { edge in
            CharacterDetailView(edge: edge, sourceMediaId: mediaId, sourceIsManga: isManga)
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

    /// Section header with chevron — tapping toggles `isExpanded`.
    /// Visually identical to the parent page's `collapsibleHeader` so the
    /// section reads as a single titled unit (no duplicate "Characters
    /// Characters" label).
    private var sectionHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Characters")
                    .font(.title3.weight(.bold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func characterCard(_ edge: AniListCharacterEdge) -> some View {
        // Batch 27 — the ONE shared portrait card: fixed 2:3, one size
        // (110×165), one radius, same fixed text zone — identical on
        // every character surface in the app.
        CharacterPortraitCard(
            imageURL: edge.node.image?.large ?? edge.node.image?.medium,
            name: edge.node.name?.full ?? "Unknown",
            subtitle: edge.role.map { $0.capitalized })
    }

    private func loadCharacters() async {
        didFetch = true
        isLoading = true
        charactersUnavailable = false
        // Batch 26 — anime characters run through the shared character
        // chain (TVDB → MAL → AniList → Kitsu — `CharacterService`), with
        // proper cross-provider id resolution. Manga keeps the AniList
        // mangaDetail path (the manga pipeline's metadata primary is
        // MangaBaka; character art comes from AniList when it's up).
        if !isManga {
            // Build a canonical Media stub for the chain (ids + provider
            // are what the chain resolves by — never the title). Provider
            // awareness matters: a page whose media.id IS a MAL id passes
            // matching malId — the stub then carries .mal so the chain's
            // AniList/Kitsu legs resolve through the RIGHT key.
            let stubIsMAL = (malId != nil && malId == mediaId)
            let stub = Media(
                id: mediaId, idMal: malId, provider: stubIsMAL ? .mal : .anilist,
                title: MediaTitle(romaji: nil, english: nil, native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil,
                status: nil, averageScore: nil, genres: nil,
                season: nil, seasonYear: nil, nextAiringEpisode: nil,
                relations: nil, type: "ANIME", format: nil,
                studioNames: nil, source: nil, duration: nil, airDateRange: nil)
            if let result = await CharacterService.shared.characters(for: stub, anilistEdges: nil, tvdbFields: nil) {
                fetchedCharacters = result.edges
            } else {
                fetchedCharacters = []
                charactersUnavailable = true
            }
        } else {
            await loadAniListCharacters()
        }
        isLoading = false
    }

    /// Loads characters from AniList (used for manga, or as fallback for anime)
    private func loadAniListCharacters() async {
        do {
            let media: AniListMedia
            if isManga {
                media = try await AniListService.shared.mangaDetail(id: mediaId)
            } else {
                media = try await AniListService.shared.detail(id: mediaId)
            }
            fetchedCharacters = media.characters?.edges ?? []
        } catch {
            fetchedCharacters = []
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
    /// Batch 27 — the anime/manga the user came FROM: powers the
    /// "More from this anime" strip (real cast of the SAME series, from
    /// the character chain — provider data, not a guess).
    var sourceMediaId: Int? = nil
    var sourceIsManga: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var character: AniListCharacter?
    @State private var isLoading = false
    /// Batch 27 — the full Jikan character profile (about, native name,
    /// favourites): fills the page through AniList outages.
    @State private var jikanProfile: MALDiscoveryService.JikanCharacter?
    /// Batch 27 — cast of the source series ("More from this anime").
    @State private var relatedCast: [AniListCharacterEdge] = []
    /// Animeography — all anime this character appears in (from Jikan)
    @State private var animeography: [MALDiscoveryService.JikanCharacterAnimeEntry] = []
    @State private var isLoadingAnimeography = false

    /// Collapsible section state — matches the Change Stream UI's card
    /// pattern. Description and Animeography default to collapsed so the
    /// page doesn't open with a wall of text. Info and Voice Actors default
    /// to expanded since they're compact and high-value.
    @State private var descriptionExpanded = false
    @State private var infoExpanded = true
    @State private var voiceActorsExpanded = true
    @State private var animeographyExpanded = false

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
                infoSection
                    .padding(.top, 16)
                // siteUrl is remote API data — parse safely instead of
                // force-unwrapping (a malformed URL from a cache/API glitch
                // must never crash the character sheet, v2.12).
                if let siteUrl = displayCharacter.siteUrl,
                   !siteUrl.isEmpty,
                   let url = URL(string: siteUrl) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari.fill")
                            Text("View on AniList")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
                if let vas = edge.voiceActors, !vas.isEmpty {
                    voiceActorsSection(vas: vas)
                        .padding(.top, 16)
                }
                characterStatsCard
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                // Animeography — all anime this character appears in
                animeographySection
                    .padding(.top, 16)
                relatedCastSection
                    .padding(.top, 16)
                Spacer().frame(height: 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        #endif
        .task { await loadFullCharacter() }
        .task { await loadAnimeography() }
        .task { await loadRelatedCast() }
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
        // Batch 27 — the Jikan full profile fills gaps through AniList
        // outages (native name, favourites) without replacing edge data.
        if let native = jikanProfile?.name_kanji, !native.isEmpty,
           displayCharacter.name?.native == nil {
            items.append(("Native Name", native))
        }
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
        // Collapsible card — matches the Change Stream UI's card design.
        // Collapsed by default since character bios can be very long.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    descriptionExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Description")
                        .font(.headline)
                    Spacer()
                    Image(systemName: descriptionExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if descriptionExpanded {
                Text(desc.cleanMarkdownAndHTML())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
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
        NavigationLink {
            VoiceActorDetailView(voiceActor: va)
        } label: {
            CharacterPortraitCard(
                imageURL: va.image?.large ?? va.image?.medium,
                name: va.name?.full ?? "Unknown",
                subtitle: va.language.map { $0.capitalized })
        }
        .buttonStyle(.plain)
    }

    // MARK: - More from this anime (Batch 27)

    /// The cast of the series the user came from — REAL provider data
    /// through the same character chain, excluding this character. Each
    /// card navigates to that character's own page (full navigation:
    /// Character → Anime → Character, no dead ends).
    @ViewBuilder
    private var relatedCastSection: some View {
        if !relatedCast.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("More from this \(sourceIsManga ? "series" : "anime")")
                    .font(.headline)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(relatedCast) { castEdge in
                            NavigationLink {
                                CharacterDetailView(
                                    edge: castEdge,
                                    sourceMediaId: sourceMediaId,
                                    sourceIsManga: sourceIsManga)
                            } label: {
                                CharacterPortraitCard(
                                    imageURL: castEdge.node.image?.large ?? castEdge.node.image?.medium,
                                    name: castEdge.node.name?.full ?? "Unknown",
                                    subtitle: castEdge.role.map { $0.capitalized })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Load

    /// Character stats card — shows a quick summary of key character info
    /// in a visually appealing card layout.
    @ViewBuilder
    private var characterStatsCard: some View {
        let items = statsCardItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Stats")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(items, id: \.0) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.2)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Text(item.1)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                }
            }
        }
    }

    private var statsCardItems: [(String, String, String)] {
        var items: [(String, String, String)] = []
        if let fav = displayCharacter.favourites, fav > 0 {
            items.append(("Favourites", "\(fav)", "heart.fill"))
        }
        if let id = displayCharacter.siteUrl?.components(separatedBy: "/").last, !id.isEmpty {
            items.append(("AniList ID", id, "number"))
        }
        if let gender = displayCharacter.gender, !gender.isEmpty {
            items.append(("Gender", gender.capitalized, "person.fill"))
        }
        if let age = displayCharacter.age, !age.isEmpty {
            items.append(("Age", age, "calendar"))
        }
        if let blood = displayCharacter.bloodType, !blood.isEmpty {
            items.append(("Blood", blood, "drop.fill"))
        }
        if let alt = displayCharacter.name?.alternative, !alt.isEmpty {
            items.append(("Also known as", alt.joined(separator: ", "), "tag.fill"))
        }
        return items
    }

    /// The character edge from the parent already has name + image + role +
    /// voiceActors, but the description may be missing (AniList sometimes
    /// omits it in the connection). This fetches the full character node by
    /// ID so we get the complete description. Best-effort — if it fails, we
    /// fall back to whatever the edge already had.
    private func loadFullCharacter() async {
        guard character == nil else { return }
        character = edge.node
        // Batch 27 — the FULL profile: Jikan's complete character record
        // (native name, full about, favourites) enriches the page even
        // while AniList's own character query is down. Field-level: the
        // edge's own data (image, role, VAs) is never replaced, only
        // gaps filled.
        let charId = edge.node.id
        guard charId > 0 else { return }
        if let full = try? await MALDiscoveryService.shared.character(characterId: charId) {
            jikanProfile = full
        }
    }

    /// Batch 27 — the cast of the series the user navigated from (same
    /// character chain the detail page uses; this character excluded).
    /// The Media stub carries the provider ids the chain needs (anilist
    /// id primary, MAL/TVDB ids when the parent page knew them).
    private func loadRelatedCast() async {
        guard let mediaId = sourceMediaId, mediaId > 0, relatedCast.isEmpty else { return }
        let stub = Media(
            id: mediaId,
            idMal: nil,
            provider: .anilist,
            title: MediaTitle(romaji: "", english: nil, native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil,
            description: nil,
            episodes: nil,
            status: nil,
            averageScore: nil,
            genres: nil,
            season: nil,
            seasonYear: nil,
            nextAiringEpisode: nil,
            relations: nil,
            type: sourceIsManga ? "MANGA" : "ANIME",
            format: nil,
            studioNames: nil,
            source: nil,
            duration: nil,
            airDateRange: nil)
        guard let result = await CharacterService.shared.characters(
            for: stub, anilistEdges: nil, tvdbFields: nil) else { return }
        relatedCast = result.edges.filter { $0.node.id != edge.node.id }
    }

    // MARK: - Animeography (all anime this character appears in)

    @ViewBuilder
    private var animeographySection: some View {
        // Collapsible card — matches the Change Stream UI's card design.
        // Collapsed by default since the animeography list can be long.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    animeographyExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "film.stack")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Appears In")
                        .font(.headline)
                    Spacer()
                    if !animeography.isEmpty {
                        Text("\(animeography.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Image(systemName: animeographyExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if animeographyExpanded {
                if !animeography.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(animeography.indices, id: \.self) { idx in
                                if let anime = animeography[idx].anime {
                                    NavigationLink {
                                        AniListDetailView(mediaId: anime.mal_id, preloadedMedia: MALDiscoveryService.shared.mapToMedia(anime))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            CachedAsyncImage(urlString: anime.images?.jpg?.large_image_url ?? anime.images?.jpg?.image_url ?? "")
                                                .aspectRatio(2/3, contentMode: .fill)
                                                .frame(width: CharacterPortraitCard.cardWidth, height: CharacterPortraitCard.cardHeight)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            Text(anime.title ?? "Unknown")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                                .frame(width: CharacterPortraitCard.cardWidth, alignment: .leading)
                                            if let role = animeography[idx].role, !role.isEmpty {
                                                Text(role)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if isLoadingAnimeography {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading appearances…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text("No appearance data available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
    }

    /// Fetches all anime this character appears in from MAL/Jikan.
    private func loadAnimeography() async {
        // Use the MAL character ID. For Jikan-sourced characters, the
        // id is the MAL character ID. For AniList-sourced characters,
        // we don't have a MAL ID, so skip (no animeography).
        let charId = edge.node.id
        guard charId > 0 else { return }
        isLoadingAnimeography = true
        do {
            animeography = try await MALDiscoveryService.shared.characterAnime(characterId: charId)
        } catch {
            animeography = []
        }
        isLoadingAnimeography = false
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
    /// Collapsed by default — the user taps the chevron to expand the
    /// recommendation strip. Matches the collapse-by-default behaviour
    /// of CharactersSection.
    @State private var isExpanded = false

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
                    sectionHeader
                    if isExpanded {
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
                }
                .padding(.top, 8)
            } else if isLoading {
                // Loading state — show section header + spinner.
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    if isExpanded {
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

    /// Section header with chevron — tapping toggles `isExpanded`.
    private var sectionHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Recommendations")
                    .font(.title3.weight(.bold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            Text(score.averageScoreOutOf10)
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

// MARK: - VoiceActorDetailView
//
// Full profile for a voice actor/person. Shows their photo, name,
// bio (about), birthday, website link, and a horizontal scroll of
// all anime they've voiced characters in. Fetched from MAL/Jikan's
// /people/{id}/anime endpoint.

struct VoiceActorDetailView: View {
    let voiceActor: AniListVoiceActor

    @State private var person: MALDiscoveryService.JikanPerson?
    @State private var animeRoles: [MALDiscoveryService.JikanPersonAnimeEntry] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero with VA photo
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(urlString: voiceActor.image?.large ?? voiceActor.image?.medium ?? "")
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
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(voiceActor.name?.full ?? "Unknown")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
                .frame(height: 280)

                // About / bio
                if let about = person?.about, !about.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        Text(about.cleanMarkdownAndHTML())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .padding(.horizontal, 16)
                    }
                }

                // Info section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Information")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    if let birthday = person?.birthday, !birthday.isEmpty {
                        infoRow("calendar", "Birthday", birthday)
                    }
                    if let website = person?.website, !website.isEmpty {
                        if let url = URL(string: website) {
                            Link(destination: url) {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe")
                                        .foregroundStyle(.secondary)
                                    Text("Website")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(website)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.appAccent)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }

                // Anime roles — all anime this person voiced characters in
                if !animeRoles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Anime Roles")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(animeRoles.indices, id: \.self) { idx in
                                    if let anime = animeRoles[idx].anime {
                                        NavigationLink {
                                            AniListDetailView(
                                                mediaId: anime.mal_id,
                                                preloadedMedia: MALDiscoveryService.shared.mapToMedia(anime))
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                CachedAsyncImage(urlString: anime.images?.jpg?.large_image_url ?? anime.images?.jpg?.image_url ?? "")
                                                    .aspectRatio(2/3, contentMode: .fill)
                                                    .frame(width: CharacterPortraitCard.cardWidth, height: CharacterPortraitCard.cardHeight)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                                Text(anime.title ?? "Unknown")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)
                                                    .frame(width: CharacterPortraitCard.cardWidth, alignment: .leading)
                                                if let char = animeRoles[idx].character {
                                                    Text(char.name ?? "")
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                } else if isLoading {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Anime Roles")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading roles…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    }
                }

                Spacer().frame(height: 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        #endif
        .task { await loadData() }
    }

    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func loadData() async {
        isLoading = true
        let personId = voiceActor.id
        guard personId > 0 else { isLoading = false; return }
        do {
            async let p = MALDiscoveryService.shared.person(personId: personId)
            async let roles = MALDiscoveryService.shared.personAnime(personId: personId)
            person = try await p
            animeRoles = try await roles
        } catch {
            // Best-effort
        }
        isLoading = false
    }
}
