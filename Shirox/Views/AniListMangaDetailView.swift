import SwiftUI

/// Full standalone AniList detail page for manga — the PRIMARY manga detail
/// page. Combines what used to be two pages into one:
///
///   1. AniList metadata (hero, statistics, synopsis, characters,
///      recommendations, relations) — pulled from AniList.
///   2. Module-sourced chapter list — pulled from the active manga module
///      via `MangaModuleResolver`, then rendered inline as a chapters
///      section. Tapping a chapter opens the reader directly.
///
/// Previously this page had a "Start Reading" button that pushed a separate
/// `MangaDetailView` (the chapter-list page). That extra hop is gone — the
/// chapters now live directly on this page, below the AniList metadata.
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil
    var autoStartReading: Bool = false

    @State private var media: Media?
    @State private var resolvedItem: SearchItem?
    @State private var phase: Phase = .loading
    @State private var showLibraryEdit = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
    @State private var autoNavigated = false
    /// Chapters fetched from the resolved manga module. nil = not yet
    /// loaded; empty = loaded but module had no chapters for this title.
    @State private var chapters: [MangaChapter] = []
    @State private var isLoadingChapters = false
    @State private var chaptersError: String?
    @State private var readerContext: ReaderContext?
    @State private var match: MangaMatch?
    @State private var enrichment: Media?
    /// Preloaded characters + recommendations from the raw AniList manga
    /// fetch — passed to CharactersSection / RecommendationsSection so they
    /// render without a second network call.
    @State private var preloadedCharacters: [AniListCharacterEdge] = []
    @State private var preloadedRecommendations: [AniListRecommendation] = []
    @AppStorage("showStatistics") private var showStatistics = true
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case loading, ready, noModule, notFound, error(String) }

    init(mediaId: Int, preloadedMedia: Media? = nil, autoStartReading: Bool = false) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        self.autoStartReading = autoStartReading
        _media = State(initialValue: preloadedMedia)
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        Group {
            if let media = media, phase == .ready || preloadedMedia != nil {
                content(media: media)
            } else if phase == .noModule {
                ContentUnavailableView("No Manga Module",
                    systemImage: "book.closed",
                    description: Text("Install a manga module to read chapters."))
            } else if phase == .notFound {
                ContentUnavailableView("Not Found",
                    systemImage: "magnifyingglass",
                    description: Text("No match for this title in your manga module."))
            } else if case .error(let msg) = phase {
                ContentUnavailableView("Couldn't Load",
                    systemImage: "exclamationmark.triangle", description: Text(msg))
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await resolve() }
        // Item 6: auto-navigate to source page when opened from carousel
        .onChangeOf(resolvedItem) { item in
            guard autoStartReading, let item, !autoNavigated else { return }
            autoNavigated = true
            // autoStartReading now opens the first chapter directly instead
            // of pushing a separate detail page.
            if let first = chapters.first {
                openReader(chapter: first, index: 0)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        .toolbar {
            // Module selector — manga modules only. Sits in the trailing
            // toolbar so it's reachable while reading. The menu's Settings
            // entry deep-links into ModulesSettingsPage(mediaType: .manga).
            ToolbarItem(placement: .topBarTrailing) {
                ModuleSelectorMenu(mediaType: .manga)
            }
        }
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private func content(media: Media) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(media: media)
                metadataSection(media: media)
                if showStatistics {
                    statisticsSection(media: media)
                        .padding(.top, 16)
                }
                if let desc = media.plainDescription, !desc.isEmpty {
                    SynopsisSection(text: desc)
                        .padding(.top, 16)
                }
                // Characters + Recommendations — directly below the synopsis.
                // Data is preloaded from the resolve() call's raw AniList
                // fetch, so these sections render without a second network
                // call. Hidden if empty.
                CharactersSection(mediaId: media.id, isManga: true,
                                  preloaded: preloadedCharacters)
                    .padding(.top, 16)
                RecommendationsSection(mediaId: media.id, isManga: true,
                                       preloaded: preloadedRecommendations)
                    .padding(.top, 8)
                if let edges = media.relations?.edges {
                    let mangaRelations = edges.filter { $0.node.isManga }
                    if !mangaRelations.isEmpty {
                        relationsSection(mangaRelations)
                            .padding(.top, 16)
                    }
                }
                // Chapters — fetched from the resolved manga module. This is
                // the old "Start Reading" destination, now inlined so the
                // user goes straight from the manga detail page to reading
                // without an intermediate navigation hop.
                chaptersSection
                    .padding(.top, 16)
            }
            .padding(.bottom, 30)
        }
        .coordinateSpace(name: "mangaAnilistScroll")
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Chapters section (inlined from MangaDetailView)

    @ViewBuilder
    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chapters")
                    .font(.title3.weight(.bold))
                Spacer()
                if !chapters.isEmpty {
                    Text("\(chapters.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 16)

            if isLoadingChapters {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading chapters…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if let error = chaptersError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await loadChapters() } }
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if chapters.isEmpty {
                // No chapters — either no module matched, or the module had
                // no results. Show a helpful empty state.
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    if phase == .noModule {
                        Text("Install a manga module to read chapters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if phase == .notFound {
                        Text("No chapters found in your manga module.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("No chapters available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { idx, chapter in
                        chapterRow(chapter, index: idx)
                    }
                }
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: MangaChapter, index: Int) -> some View {
        Button {
            openReader(chapter: chapter, index: index)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Text(chapter.displayNumber)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text((chapter.title?.isEmpty ?? true) ? "Chapter \(chapter.displayNumber)" : chapter.title!)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Chapter")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if index < chapters.count - 1 {
            Divider()
                .padding(.leading, 60)
        }
    }

    /// Opens the manga reader for a chapter. Builds a `ReaderContext` from
    /// the resolved `SearchItem` + the chapter list, then presents it via
    /// `.fullScreenCover`. This is the same path the old `MangaDetailView`
    /// used — just hoisted into this page so the extra navigation hop is
    /// gone.
    private func openReader(chapter: MangaChapter, index: Int) {
        #if os(iOS)
        guard let item = resolvedItem else { return }
        readerContext = ReaderContext(
            mangaTitle: item.title,
            mangaHref: item.href,
            coverImage: item.image,
            moduleId: moduleManager.activeModule?.id ?? "",
            chapters: chapters,
            chapterIndex: index,
            resumePage: nil,
            resumeFraction: nil,
            match: match
        )
        #endif
    }

    // MARK: - Hero

    /// Hero background. When AniList provides a dedicated `bannerImage`
    /// (different artwork from the cover), we use it directly. When no
    /// banner is available, we blur the cover image so the hero background
    /// reads as a distinct visual element from the sharp poster below —
    /// avoiding the "same image twice" problem where a manga's cover
    /// appears identically in both the hero and the poster slot.
    @ViewBuilder
    private func heroBackground(media: Media, width: CGFloat, height: CGFloat) -> some View {
        if let banner = media.bannerImage, !banner.isEmpty {
            // Dedicated banner — different artwork. Use directly.
            CachedAsyncImage(urlString: banner)
                .frame(width: width, height: height)
        } else if let coverURL = media.coverImage.best, !coverURL.isEmpty {
            // No banner — blur the cover so it's visually distinct from
            // the sharp poster. The blur + a subtle dark overlay gives the
            // hero depth without needing a second asset.
            CachedAsyncImage(urlString: coverURL)
                .frame(width: width, height: height)
                .blur(radius: 30)
                .overlay(Color.black.opacity(0.3))
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.2), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            // No image at all — solid color fallback.
            Color.secondary.opacity(0.2)
                .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func heroSection(media: Media) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("mangaAnilistScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                // Hero background: prefer a dedicated banner when AniList
                // provides one (different artwork from the cover). When no
                // banner is available, blur the cover image so the hero
                // background is visually distinct from the sharp poster
                // below — avoids the "same image twice" problem where a
                // manga's cover appears identically in both areas.
                heroBackground(media: media, width: proxy.size.width, height: imageH)
                    .frame(width: proxy.size.width, height: imageH)
                    .clipped()
                    .offset(y: imageY)
            }
            .frame(height: 420)
            .ignoresSafeArea(edges: .top)
            .mask(alignment: .bottom) { Rectangle().frame(height: 420 + 2000) }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: platformBackground.opacity(0.2), location: 0.45),
                    .init(color: platformBackground, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 420)

            HStack(alignment: .bottom, spacing: 14) {
                // Poster: use the best available cover image (extraLarge
                // preferred). This is distinct from the hero background
                // when a banner exists; when no banner, the hero is
                // blurred so the two still read as different visuals.
                CachedAsyncImage(urlString: media.coverImage.best ?? "")
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(media.title.displayTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        if let score = media.averageScore {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.caption2.weight(.bold))
                                Text("\(score)%")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                        if let status = media.statusDisplay {
                            Text(status)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                        if let year = media.seasonYear {
                            Text(String(year))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(media: Media) -> some View {
        if let genres = media.genres, !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(genres.prefix(6), id: \.self) { genre in
                        Text(genre)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Statistics

    @ViewBuilder
    private func statisticsSection(media: Media) -> some View {
        let items = statisticsItems(for: media)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Statistics")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items, id: \.0) { item in
                        statisticCard(label: item.0, value: item.1)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func statisticsItems(for media: Media) -> [(String, String)] {
        var items: [(String, String)] = []
        if let type = media.type, !type.isEmpty {
            items.append(("Type", type.replacingOccurrences(of: "_", with: " ").capitalized))
        }
        if let format = media.format, !format.isEmpty {
            items.append(("Format", format.replacingOccurrences(of: "_", with: " ").capitalized))
        }
        if let status = media.statusDisplay { items.append(("Status", status)) }
        if let chapters = media.episodes { items.append(("Chapters", "\(chapters)")) }
        if let volumes = media.volumes { items.append(("Volumes", "\(volumes)")) }
        if let score = media.averageScore { items.append(("Rating", "\(score)%")) }
        if let pop = media.popularity, pop > 0 { items.append(("Popularity", "\(pop)")) }
        let seasonStr = [media.season?.capitalized, media.seasonYear.map { String($0) }]
            .compactMap { $0 }.joined(separator: " ")
        if !seasonStr.isEmpty { items.append(("Season", seasonStr)) }
        if let aired = media.airDateRange, !aired.isEmpty { items.append(("Premiered", aired)) }
        if let source = media.sourceDisplay { items.append(("Source", source)) }
        if let studio = media.mainStudioName, !studio.isEmpty { items.append(("Author/Studio", studio)) }
        return items
    }

    @ViewBuilder
    private func statisticCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.2))
    }

    // MARK: - Relations

    @ViewBuilder
    private func relationsSection(_ edges: [MediaRelationEdge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relations")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(edges, id: \.node.id) { edge in
                        NavigationLink {
                            AniListMangaDetailView(mediaId: edge.node.id, preloadedMedia: edge.node)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CachedAsyncImage(urlString: edge.node.coverImage.best ?? "")
                                    .frame(width: 80, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(edge.relationType.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(edge.node.title.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(width: 80, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Resolve

    private func resolve() async {
        guard phase == .loading else { return }
        if media == nil {
            do { media = try await AniListProvider.shared.mangaDetail(id: mediaId) }
            catch { phase = .error(error.localizedDescription); return }
        }
        guard media != nil else { phase = .error("No data"); return }

        // Fetch raw AniList manga for characters + recommendations.
        // Best-effort: don't fail the whole page if this secondary fetch
        // errors. Uses the manga endpoint (includes characters + recs as
        // of the latest query update).
        if let raw = try? await AniListService.shared.mangaDetail(id: mediaId) {
            preloadedCharacters = raw.characters?.edges ?? []
            preloadedRecommendations = raw.recommendations?.nodes ?? []
        }

        // Load library entry if logged in
        if AniListAuthManager.shared.isLoggedIn {
            existingEntry = (try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId, type: .manga))
                .flatMap { AniListProvider.shared.mapEntry($0) }
        }

        // Try to resolve a manga module for chapter reading
        let hasMangaModule = moduleManager.modules.contains { $0.isManga }
        guard hasMangaModule else {
            phase = .noModule
            return
        }

        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media!.title.searchTitle) {
            resolvedItem = item
            // Also try to load an existing match so the reader can track
            // progress against AniList/MAL.
            match = await MangaMatchManager.shared.match(
                mangaHref: item.href, title: item.title)
            phase = .ready
            // Kick off chapter loading in the background — the page is
            // already showing; chapters fill in when ready.
            await loadChapters()
        } else {
            phase = .notFound
        }
        #else
        phase = .noModule
        #endif
    }

    /// Fetches chapters from the resolved manga module. Called after
    /// `resolve()` succeeds. Sets `chaptersError` on failure so the UI can
    /// show a retry button.
    private func loadChapters() async {
        guard let item = resolvedItem else { return }
        isLoadingChapters = true
        chaptersError = nil
        do {
            // Ensure the active manga module is loaded into JSEngine.
            // MangaModuleResolver.resolve already switched to a module, but
            // double-check in case the user switched modules via the
            // selector after resolve() ran.
            if moduleManager.activeModule?.isManga != true,
               let mangaModule = moduleManager.modules.first(where: { $0.isManga }) {
                _ = await moduleManager.selectAndAwaitReady(mangaModule)
            }
            let fetched = try await JSEngine.shared.mangaChapters(url: item.href)
            chapters = fetched
        } catch {
            chaptersError = error.localizedDescription
            chapters = []
        }
        isLoadingChapters = false
    }
}
