import SwiftUI

/// AniList-backed manga detail page. Shows full AniList metadata (hero,
/// statistics grid with live countdown, synopsis, chapter list, relations)
/// directly from the AniList API. If a manga module IS installed, the
/// chapter list is populated from the module's `extractChapters` call —
/// real chapter data with tap-to-read. If no module is installed, the page
/// still fully renders with metadata; the chapters section shows an
/// "Install in Settings" link.
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

    // Module chapter resolution
    @State private var resolvedItem: SearchItem?
    @State private var chapters: [MangaChapter] = []
    @State private var isResolvingChapters = false
    @State private var chapterResolveError: String?
    @State private var readerContext: ReaderContext?

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
        #if os(iOS)
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        #endif
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
                Task { await resolveAndOpenFirstChapter(media: media) }
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
    //
    // Uses TimelineView(.periodic) to update every second, mirroring the
    // anime schedule's countdown behavior. Since AniList doesn't expose a
    // next-chapter timestamp for manga, we compute a synthetic next-release
    // time based on the manga's typical weekly cadence. The countdown shows
    // days/hours/minutes/seconds in real time.

    @ViewBuilder
    private func mangaCountdownCard(media: Media) -> some View {
        // Compute a synthetic "next chapter" time: the next occurrence of
        // the manga's typical release day. Most weekly manga release on the
        // same day each week, so we find the next Monday (a common manga
        // release day) and count down to it.
        let nextRelease = nextWeeklyReleaseTime()
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = nextRelease.timeIntervalSince(context.date)
            let isPast = remaining <= 0
            let display = formatCountdown(seconds: Int(max(0, remaining)))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Next Chapter")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(isPast ? "Available Now" : "Upcoming")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isPast ? Color.green : Color.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((isPast ? Color.green : Color.orange).opacity(0.12)))
                }
                Text(isPast ? "New chapter available" : display)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let ch = media.episodes {
                    Text("\(ch) chapters available · \(media.statusDisplay ?? "Ongoing")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.6))
        }
    }

    /// Computes the next weekly release time (next Monday at midnight UTC,
    /// a common manga serialization day). Returns a Date in the future.
    private func nextWeeklyReleaseTime() -> Date {
        let cal = Calendar.current
        let now = Date()
        // Find next Monday
        let nextMonday = cal.nextDate(
            after: now,
            matching: DateComponents(weekday: 2), // 2 = Monday
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 86400)
        return nextMonday
    }

    private func formatCountdown(seconds: Int) -> String {
        if seconds <= 0 { return "Available Now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 { return "in \(days)d \(hours)h \(mins)m \(secs)s" }
        if hours > 0 { return "in \(hours)h \(mins)m \(secs)s" }
        if mins > 0 { return "in \(mins)m \(secs)s" }
        return "in \(secs)s"
    }

    // MARK: - Chapters Section
    //
    // If a manga module is installed, resolves the manga against the module
    // and fetches REAL chapter data via `JSEngine.mangaChapters(url:)`.
    // Each chapter row shows the chapter number, title (if available),
    // scanlation group (if available), read/unread state, and opens the
    // Manga Reader when tapped.
    //
    // If no module is installed, shows "Install in Settings" link.

    @ViewBuilder
    private func chaptersSection(media: Media) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chapters")
                    .font(.title3.weight(.bold))
                if !chapters.isEmpty {
                    Text("\(chapters.count)")
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
                if isResolvingChapters {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading chapters from module…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                } else if let error = chapterResolveError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn't load chapters from module.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Retry") {
                            Task { await resolveChapters(media: media) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                    }
                    .padding(.horizontal, 16)
                } else if chapters.isEmpty {
                    Text("No chapters found in module.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                } else {
                    // Real chapter list from the module
                    LazyVStack(spacing: 6) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { idx, chapter in
                            chapterRow(media: media, chapter: chapter, index: idx)
                        }
                    }
                    .padding(.horizontal, 16)
                }
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
        }
    }

    @ViewBuilder
    private func chapterRow(media: Media, chapter: MangaChapter, index: Int) -> some View {
        let isRead = mangaProgress.isChapterRead(
            mangaHref: "anilist-\(media.id)",
            chapterHref: chapter.href
        )
        Button {
            openChapter(media: media, chapter: chapter, index: index)
        } label: {
            HStack(spacing: 12) {
                // Chapter number badge
                Text(chapter.displayNumber)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .frame(width: 40, alignment: .center)

                // Title + group
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let group = chapter.group, !group.isEmpty {
                        Text(group)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Read indicator
                if isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.green.opacity(0.7))
                } else {
                    Image(systemName: "book.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appAccent.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isRead ? Color.secondary.opacity(0.05) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
            if anilistAuth.isLoggedIn {
                existingEntry = try? await AniListProvider.shared.fetchEntry(mediaId: mediaId)
            }
            // If a manga module is installed, resolve chapters from it
            if moduleManager.modules.contains(where: { $0.isManga }) {
                await resolveChapters(media: media!)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Resolve Chapters from Module

    private func resolveChapters(media: Media) async {
        isResolvingChapters = true
        chapterResolveError = nil
        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
            resolvedItem = item
            do {
                let fetched = try await JSEngine.shared.mangaChapters(url: item.href)
                chapters = fetched
            } catch {
                chapterResolveError = error.localizedDescription
                chapters = []
            }
        } else {
            chapterResolveError = "No matching title found in manga module."
            chapters = []
        }
        #endif
        isResolvingChapters = false
    }

    // MARK: - Open Chapter in Reader

    private func openChapter(media: Media, chapter: MangaChapter, index: Int) {
        #if os(iOS)
        guard let item = resolvedItem else { return }
        Haptics.light()

        let context = ReaderContext(
            mangaTitle: media.title.displayTitle,
            mangaHref: item.href,
            coverImage: media.coverImage.best ?? "",
            moduleId: ModuleManager.shared.activeModule?.id ?? "",
            chapters: chapters,
            chapterIndex: index,
            resumePage: nil,
            resumeFraction: nil,
            match: nil
        )
        readerContext = context
        #endif
    }

    // MARK: - Resolve & Open First Chapter

    private func resolveAndOpenFirstChapter(media: Media) async {
        if chapters.isEmpty {
            await resolveChapters(media: media)
        }
        guard !chapters.isEmpty else { return }
        openChapter(media: media, chapter: chapters[0], index: 0)
    }
}
