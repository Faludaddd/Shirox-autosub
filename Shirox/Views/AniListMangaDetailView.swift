import SwiftUI

/// Full standalone AniList detail page for manga — mirrors AniListDetailView's
/// structure (hero, metadata, statistics, synopsis, relations) but for manga.
/// Has a "Start Reading" button that resolves the manga module and pushes
/// MangaDetailView (the source page) for chapter reading.
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil

    @State private var media: Media?
    @State private var resolvedItem: SearchItem?
    @State private var phase: Phase = .loading
    @State private var showLibraryEdit = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
    @AppStorage("showStatistics") private var showStatistics = true
    @EnvironmentObject private var moduleManager: ModuleManager

    private enum Phase: Equatable { case loading, ready, noModule, notFound, error(String) }

    init(mediaId: Int, preloadedMedia: Media? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
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
                #if os(iOS)
                readButton(media: media)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                #endif
                if let edges = media.relations?.edges {
                    let mangaRelations = edges.filter { $0.node.isManga }
                    if !mangaRelations.isEmpty {
                        relationsSection(mangaRelations)
                            .padding(.top, 16)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .coordinateSpace(name: "mangaAnilistScroll")
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(media: Media) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("mangaAnilistScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                CachedAsyncImage(urlString: media.bannerImage ?? media.coverImage.best ?? "")
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

    // MARK: - Read button

    @ViewBuilder
    private func readButton(media: Media) -> some View {
        if let item = resolvedItem {
            NavigationLink {
                MangaDetailView(item: item)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                        .font(.caption.weight(.bold))
                    Text("Start Reading")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            // No module match — show a disabled-style button
            HStack(spacing: 6) {
                Image(systemName: "book.fill")
                    .font(.caption.weight(.bold))
                Text("No Module Match")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
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

        // Load library entry if logged in
        if AniListAuthManager.shared.isLoggedIn {
            existingEntry = (try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId, type: .manga))
                .flatMap { AniListProvider.shared.mapEntry($0) }
        }

        // Try to resolve a manga module for the "Start Reading" button
        let hasMangaModule = moduleManager.modules.contains { $0.isManga }
        guard hasMangaModule else {
            phase = .noModule
            return
        }

        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media!.title.searchTitle) {
            resolvedItem = item
            phase = .ready
        } else {
            phase = .notFound
        }
        #else
        phase = .noModule
        #endif
    }
}
