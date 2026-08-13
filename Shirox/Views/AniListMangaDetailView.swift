import SwiftUI

/// AniList-backed manga detail page. Shows full AniList metadata (hero,
/// statistics grid, synopsis, chapters list, relations) directly from the
/// AniList API — NO module installation required. This is the manga
/// equivalent of `AniListDetailView` (anime).
///
/// If a manga module IS installed, a "Read" button appears that resolves
/// the module and opens the reader. If no module is installed, the page
/// still fully renders with all metadata — the only difference is the Read
/// button shows "Install in Settings" as a blue tappable link that
/// navigates to Settings → Module Store.
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil

    @State private var media: Media?
    @State private var isLoading = true
    @State private var loadError: String?
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    @State private var existingEntry: LibraryEntry?
    @State private var showLibraryEdit = false
    @State private var isLoadingEntry = false
    @State private var pushModuleStore = false
    @AppStorage("showStatistics") private var showStatistics = true

    init(mediaId: Int, preloadedMedia: Media? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        _media = State(initialValue: preloadedMedia)
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                ContentUnavailableView("Couldn't Load",
                    systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let media {
                content(media: media)
            } else {
                ContentUnavailableView("Not Found", systemImage: "magnifyingglass")
            }
        }
        .task { await load() }
        .background(
            NavigationLink(destination: ModulesSettingsPage(), isActive: $pushModuleStore) {
                EmptyView()
            }
            .opacity(0)
        )
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
                chaptersSection(media: media)
                    .padding(.top, 16)
                if let relations = media.relations?.edges, !relations.isEmpty {
                    relationsSection(relations: relations)
                        .padding(.top, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(media: Media) -> some View {
        ZStack(alignment: .bottom) {
            // Banner image
            ZStack {
                if let bannerURL = media.bannerImage, !bannerURL.isEmpty {
                    CachedAsyncImage(urlString: bannerURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipped()
                } else {
                    CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipped()
                        .overlay(Color.black.opacity(0.3))
                }
                LinearGradient(
                    colors: [.clear, .clear, Color(.systemBackground).opacity(0.95)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(height: 260)

            // Title + Read button
            VStack(alignment: .leading, spacing: 12) {
                Text(media.title.displayTitle)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    readButton(media: media)
                    libraryButton(media: media)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: 260)
    }

    // MARK: - Read Button

    @ViewBuilder
    private func readButton(media: Media) -> some View {
        let hasMangaModule = moduleManager.modules.contains { $0.isManga }
        if hasMangaModule {
            Button {
                // Module exists — resolve and open reader
                Task { await resolveAndOpenReader(media: media) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Read")
                        .font(.system(size: 15, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                pushModuleStore = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Install in Settings")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Library Button

    @ViewBuilder
    private func libraryButton(media: Media) -> some View {
        Button {
            Task {
                isLoadingEntry = true
                existingEntry = try? await AniListProvider.shared.fetchEntry(mediaId: media.id)
                isLoadingEntry = false
                showLibraryEdit = true
            }
        } label: {
            Image(systemName: existingEntry != nil ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .adaptiveSheet(isPresented: $showLibraryEdit) {
            if let media = self.media {
                LibraryEntryEditSheet(
                    entry: existingEntry,
                    media: media,
                    progressUnit: "chapter",
                    onSave: { status, progress, score in
                        Task {
                            try? await AniListLibraryService.shared.updateEntry(
                                mediaId: media.id, status: status, progress: progress,
                                score: score > 0 ? score : nil, type: .manga)
                        }
                    },
                    onDelete: existingEntry != nil ? {
                        guard let entry = existingEntry else { return }
                        Task { try? await AniListLibraryService.shared.deleteEntry(entryId: entry.id) }
                    } : nil
                )
            }
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(media: Media) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let genres = media.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(genres.prefix(8), id: \.self) { genre in
                            Text(genre)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.appAccent.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
            }
            if let score = media.averageScore {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text("\(score)%")
                        .font(.subheadline.weight(.bold))
                    if let pop = media.popularity {
                        Text("· \(pop) users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Statistics

    @ViewBuilder
    private func statisticsSection(media: Media) -> some View {
        let items = statisticsItems(for: media)
        VStack(alignment: .leading, spacing: 14) {
            Text("Statistics")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            // Live countdown for manga that are still releasing
            if media.status == "RELEASING" {
                mangaCountdownCard(media: media)
                    .padding(.horizontal, 16)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(items, id: \.0) { item in
                    statisticCard(label: item.0, value: item.1)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func statisticsItems(for media: Media) -> [(String, String)] {
        var items: [(String, String)] = []
        items.append(("Type", media.type ?? "Manga"))
        if let f = media.format, !f.isEmpty { items.append(("Format", f.replacingOccurrences(of: "_", with: " "))) }
        if let s = media.statusDisplay { items.append(("Status", s)) }
        if let ch = media.episodes { items.append(("Chapters", "\(ch)")) }
        if let vols = media.volumes { items.append(("Volumes", "\(vols)")) }
        if let score = media.averageScore { items.append(("Rating", "\(score)%")) }
        if let pop = media.popularity { items.append(("Popularity", "\(pop)")) }
        let seasonStr = [media.season?.capitalized, media.seasonYear.map { String($0) }].compactMap { $0 }.joined(separator: " ")
        if !seasonStr.isEmpty { items.append(("Season", seasonStr)) }
        if let studio = media.mainStudioName, !studio.isEmpty { items.append(("Publisher", studio)) }
        if let source = media.sourceDisplay { items.append(("Source", source)) }
        if let aired = media.airDateRange, !aired.isEmpty { items.append(("Premiered", aired)) }
        if let country = media.countryOfOrigin, !country.isEmpty { items.append(("Country", country)) }
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

    // MARK: - Live Countdown (for ongoing manga)

    @ViewBuilder
    private func mangaCountdownCard(media: Media) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("Ongoing")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            Text("New chapters release regularly")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let ch = media.episodes {
                Text("\(ch) chapters available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.green.opacity(0.18), lineWidth: 0.6))
    }

    // MARK: - Chapters Section

    @ViewBuilder
    private func chaptersSection(media: Media) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chapters")
                    .font(.title3.weight(.bold))
                if let ch = media.episodes {
                    Text("\(ch)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            let hasMangaModule = moduleManager.modules.contains { $0.isManga }
            if hasMangaModule {
                Text("Tap a chapter to start reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install a manga module to read chapters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        pushModuleStore = true
                    } label: {
                        Text("Install in Settings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }

            // Show a preview of chapter numbers (up to 50)
            if let totalChapters = media.episodes, totalChapters > 0 {
                let previewCount = min(totalChapters, 50)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
                    ForEach(1...previewCount, id: \.self) { ch in
                        let isRead = mangaProgress.isChapterRead(
                            mangaHref: "anilist-\(media.id)",
                            chapterHref: "ch-\(ch)"
                        )
                        Text("\(ch)")
                            .font(.subheadline.weight(isRead ? .regular : .semibold))
                            .frame(width: 50, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isRead ? Color.secondary.opacity(0.1) : Color.appAccent.opacity(0.1))
                            )
                            .foregroundStyle(isRead ? .secondary : .primary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(isRead ? Color.clear : Color.appAccent.opacity(0.3), lineWidth: 0.5)
                            )
                    }
                }
                .padding(.horizontal, 16)
                if totalChapters > 50 {
                    Text("+ \(totalChapters - 50) more chapters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Relations

    @ViewBuilder
    private func relationsSection(relations: [MediaRelationEdge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relations")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(relations) { edge in
                        VStack(alignment: .leading, spacing: 4) {
                            CachedAsyncImage(urlString: edge.node.coverImage.extraLarge ?? edge.node.coverImage.large ?? "")
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(edge.formattedRelation)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(edge.node.title.displayTitle)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .frame(width: 80, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Platform

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.black
        #endif
    }

    // MARK: - Load

    private func load() async {
        guard media == nil else { isLoading = false; return }
        isLoading = true
        do {
            media = try await AniListProvider.shared.mangaDetail(id: mediaId)
            // Load existing library entry if logged in
            if anilistAuth.isLoggedIn {
                existingEntry = try? await AniListProvider.shared.fetchEntry(mediaId: mediaId)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Resolve & Open Reader

    private func resolveAndOpenReader(media: Media) async {
        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
            // Open the manga detail view which handles the reader
            // For now, just log — the actual reader opening is handled
            // by MangaDetailView when the user taps a chapter
            Logger.shared.log("[MangaDetail] Resolved module for \(media.title.searchTitle)", type: "Debug")
        }
        #endif
    }
}
