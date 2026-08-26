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
    @State private var showResetConfirmation = false
    @State private var newestFirst = false
    @State private var isSelectionMode = false
    @State private var selectedChapterHrefs: Set<String> = []
    /// 0 = chapters view, 1 = connections view (relations + reading order).
    /// Toggled by the people/social icon button, matching the anime page.
    @State private var selectedTab = 0
    #if os(iOS)
    @ObservedObject private var mangaDownloads = MangaDownloadManager.shared
    #endif
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
        // Reload chapters when the user switches manga modules via the
        // ModuleSelectorMenu. Without this, selecting a different source
        // from the dropdown does nothing — the chapter list stays stuck
        // on the originally matched module.
        .onChangeOf(moduleManager.activeModule) { newModule in
            guard let newModule, newModule.isManga, resolvedItem != nil else { return }
            Task { await loadChapters() }
        }
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
            // Both Modules and Edit Entry on the TRAILING (right) side.
            // Modules comes first (left of Edit Entry), Edit Entry is at
            // the far right. Each is its own independent ToolbarItem.
            ToolbarItem(placement: .topBarTrailing) {
                ModuleSelectorMenu(mediaType: .manga)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if AniListAuthManager.shared.isLoggedIn || MALAuthManager.shared.isLoggedIn {
                    Button {
                        Task {
                            isLoadingEntry = true
                            if AniListAuthManager.shared.isLoggedIn {
                                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId, type: .manga) {
                                    existingEntry = AniListProvider.shared.mapEntry(raw)
                                }
                            }
                            isLoadingEntry = false
                            showLibraryEdit = true
                        }
                    } label: {
                        if isLoadingEntry {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "pencil.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                    }
                    .disabled(isLoadingEntry)
                }
            }
        }
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        .adaptiveSheet(isPresented: $showLibraryEdit) {
            if let media = self.media {
                LibraryEntryEditSheet(
                    entry: existingEntry,
                    media: media,
                    progressUnit: "chapter",
                    onSave: { status, progress, score in
                        Task {
                            if AniListAuthManager.shared.isLoggedIn {
                                try? await AniListLibraryService.shared.updateEntry(
                                    mediaId: mediaId, status: status, progress: progress, score: score, type: .manga)
                                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId, type: .manga) {
                                    existingEntry = AniListProvider.shared.mapEntry(raw)
                                }
                            }
                        }
                    },
                    onDelete: existingEntry != nil ? {
                        if let entryId = existingEntry?.id {
                            existingEntry = nil
                            Task { try? await AniListLibraryService.shared.deleteEntry(entryId: entryId) }
                        }
                    } : nil,
                    onTogglePrivate: { newValue in
                        // Optimistically update the local entry so the toggle
                        // reflects immediately, then push to AniList.
                        if var e = existingEntry {
                            e.isPrivate = newValue
                            existingEntry = e
                        }
                        Task {
                            try? await AniListLibraryService.shared.updateEntry(
                                mediaId: mediaId,
                                status: existingEntry?.status ?? .current,
                                progress: existingEntry?.progress ?? 0,
                                score: existingEntry?.score ?? 0,
                                type: .manga, isPrivate: newValue)
                        }
                    }
                )
            }
        }
        .alert("Reset Progress", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                if let item = resolvedItem {
                    MangaProgressManager.shared.resetProgress(mangaHref: item.href)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your reading progress for this manga.")
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
                // Primary read/continue button + social/connections icon +
                // download icon — matches the anime AniList page's button row
                // layout exactly: Continue → people/social → download.
                // Previously the download button was in the chaptersSection
                // header — moving it here matches anime and fixes the
                // "duplicate download button" bug.
                #if os(iOS)
                HStack(spacing: 10) {
                    readButton(media: media)

                    // Social/connections icon — toggles between chapters view
                    // and connections view (relations + reading order).
                    // Mirrors the anime AniList page's button exactly.
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = selectedTab == 0 ? 1 : 0
                        }
                    } label: {
                        Image(systemName: selectedTab == 0 ? "person.3.fill" : "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selectedTab == 1 ? platformBackground : .primary)
                            .frame(width: 46, height: 46)
                            .background(
                                selectedTab == 1
                                    ? Color.primary
                                    : Color.clear,
                                in: Circle()
                            )
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    // Download / selection-mode toggle — in the action row,
                    // matching anime. Only shown when chapters are available.
                    if !chapters.isEmpty {
                        Button {
                            Haptics.selection()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode { selectedChapterHrefs.removeAll() }
                            }
                        } label: {
                            Image(systemName: isSelectionMode ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelectionMode ? platformBackground : .primary)
                                .frame(width: 46, height: 46)
                                .background(
                                    isSelectionMode ? Color.primary : Color.clear,
                                    in: Circle()
                                )
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                #endif
                // Characters + Recommendations — placed BEFORE the
                // chapters/connections section, matching the anime AniList
                // page's section order exactly:
                //   Synopsis → Buttons → Characters → Recommendations → Chapters/Connections
                // Some manga have 100+ chapters — having Characters/Recs
                // before the chapter list keeps them reachable without an
                // extremely long scroll.
                CharactersSection(mediaId: media.id, isManga: true,
                                  preloaded: preloadedCharacters)
                    .padding(.top, 16)
                RecommendationsSection(mediaId: media.id, isManga: true,
                                       preloaded: preloadedRecommendations)
                    .padding(.top, 8)
                // Section order: when selectedTab == 0, show Relations +
                // Chapters. When selectedTab == 1, show Connections view
                // (relations + reading order). Matches anime page.
                if selectedTab == 0 {
                    if let edges = media.relations?.edges {
                        let mangaRelations = edges.filter { $0.node.isManga }
                        if !mangaRelations.isEmpty {
                            relationsSection(mangaRelations)
                                .padding(.top, 16)
                        }
                    }
                    // Chapters — fetched from the resolved manga module.
                    chaptersSection
                        .padding(.top, 16)
                } else {
                    // Connections view (tab 1) — relations + reading order.
                    VStack(alignment: .leading, spacing: 20) {
                        if let edges = media.relations?.edges {
                            let mangaRelations = edges.filter { $0.node.isManga }
                            if !mangaRelations.isEmpty {
                                relationsSection(mangaRelations)
                                    .frame(maxWidth: .infinity)
                            } else {
                                VStack(spacing: 20) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                    Text("No relations found")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            }
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary.opacity(0.5))
                                Text("No relations found")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
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
            // Chapters section header: title + count badge on the left,
            // invert-order + reset-progress on the right. The download/
            // selection-mode toggle has been moved to the action-button row
            // above (matching the anime page's layout).
            #if os(iOS)
            HStack(spacing: 10) {
                Text("Chapters")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if !chapters.isEmpty {
                    Text("\(chapters.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer()
                // Invert chapter order — toggles newestFirst.
                // 46×46 to match the action-button row's buttons.
                if chapters.count > 1 {
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            newestFirst.toggle()
                        }
                    } label: {
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                // Reset reading progress — only shows if the user actually
                // has progress for this manga. 46×46 to match the rest.
                if let item = resolvedItem,
                   MangaProgressManager.shared.hasProgress(mangaHref: item.href) {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            #else
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
            #endif

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
                let displayChapters = newestFirst ? Array(chapters.reversed()) : chapters
                // Selection bar — appears when selection mode is active.
                // Has a "Download N" button that initiates batch download
                // of selected chapters via MangaDownloadManager.
                if isSelectionMode && !selectedChapterHrefs.isEmpty {
                    HStack {
                        Text("\(selectedChapterHrefs.count) selected")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            downloadSelectedChapters()
                        } label: {
                            Label("Download \(selectedChapterHrefs.count)", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(platformBackground)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .controlSize(.small)
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // Spacing 8 between cards — matches anime's episode list
                // spacing. No background/clipShape on the container because
                // each row now has its own RoundedRectangle card background
                // (matching EpisodeRowView's design).
                LazyVStack(spacing: 8) {
                    ForEach(Array(displayChapters.enumerated()), id: \.element.id) { idx, chapter in
                        chapterRow(chapter, index: idx, isSelected: selectedChapterHrefs.contains(chapter.href))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: MangaChapter, index: Int, isSelected: Bool = false) -> some View {
        // Matches anime's EpisodeRowView EXACTLY — same dimensions, spacing,
        // fonts, circle size, download button, play icon, card background,
        // progress bar, and press style. The only difference is the content
        // text ("Chapter N" vs "Episode N"). No separate smaller design.
        let mangaHref = resolvedItem?.href ?? ""
        let isRead = MangaProgressManager.shared.isChapterRead(
            mangaHref: mangaHref, chapterHref: chapter.href)
        let realIndex = chapters.firstIndex(where: { $0.id == chapter.id }) ?? index
        // Reading progress fraction (0...1) for the progress bar — matches
        // anime's `progress` parameter. Only shows for the last-read chapter
        // and only when it's not yet complete (< 0.9).
        let lastRead = MangaProgressManager.shared.lastRead(for: mangaHref)
        let progress: Double? = {
            guard let lastRead, lastRead.chapterHref == chapter.href, !isRead else { return nil }
            return MangaProgressManager.progressFraction(
                pageIndex: lastRead.pageIndex, totalPages: lastRead.totalPages)
        }()

        #if os(iOS)
        let dlState = mangaDownloadState(for: chapter)
        #endif

        Button {
            if isSelectionMode {
                if selectedChapterHrefs.contains(chapter.href) {
                    selectedChapterHrefs.remove(chapter.href)
                } else {
                    selectedChapterHrefs.insert(chapter.href)
                }
            } else {
                openReader(chapter: chapter, index: realIndex)
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if isSelectionMode {
                        ZStack {
                            Circle()
                                .strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.35), lineWidth: 2)
                                .frame(width: 40, height: 40)
                            if isSelected {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(platformBackground)
                            }
                        }
                    } else {
                        ZStack {
                            Circle()
                                .fill(isRead ? Color.green : Color.primary)
                                .frame(width: 40, height: 40)
                            if isRead {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text(chapter.displayNumber)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(platformBackground)
                            }
                        }
                        .shadow(color: Color.glowEnabled ? (isRead ? Color.green : Color.primary).opacity(0.3) : .clear,
                                radius: Color.glowEnabled ? 4 : 0, y: 2)
                    }

                    Text((chapter.title?.isEmpty ?? true) ? "Chapter \(chapter.displayNumber)" : chapter.title!)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    if !isSelectionMode {
                        HStack(spacing: 8) {
                            #if os(iOS)
                            if let state = dlState {
                                Group {
                                    switch state {
                                    case .completed:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .downloading:
                                        ProgressView().controlSize(.small)
                                    case .pending:
                                        Image(systemName: "hourglass")
                                            .foregroundStyle(.secondary)
                                    case .failed:
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.system(size: 16))
                            }
                            #endif

                            Image(systemName: "play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.1), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, (progress ?? 0) > 0 && !isRead && !isSelectionMode ? 6 : 12)

                if let p = progress, p > 0, !isRead, !isSelectionMode {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
            .background(
                isSelectionMode && isSelected
                    ? Color.primary.opacity(0.08)
                    : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            #if os(iOS)
            .opacity(isSelectionMode && (dlState == .completed || dlState == .downloading || dlState == .pending) ? 0.5 : 1.0)
            #endif
        }
        .buttonStyle(ChapterPressStyle())
        .contextMenu {
            if !isSelectionMode {
                if isRead {
                    Button {
                        MangaProgressManager.shared.markChapterUnread(
                            mangaHref: mangaHref, chapterHref: chapter.href)
                    } label: {
                        Label("Mark as Unread", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        MangaProgressManager.shared.markChapterRead(
                            mangaHref: mangaHref, chapterHref: chapter.href)
                    } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
                #if os(iOS)
                Divider()
                if let onDownload = chapterDownloadAction(for: chapter, state: dlState) {
                    if dlState == .completed {
                        Button(role: .destructive) { onDownload() } label: {
                            Label("Delete Download", systemImage: "trash")
                        }
                    } else {
                        Button { onDownload() } label: {
                            Label("Download Chapter", systemImage: "arrow.down.circle")
                        }
                        .disabled(dlState == .downloading || dlState == .pending)
                    }
                }
                #endif
            }
        }
    }

    #if os(iOS)
    /// Downloads all selected chapters via MangaDownloadManager.
    /// Called by the "Download N" button in the selection bar.
    private func downloadSelectedChapters() {
        guard let item = resolvedItem else { return }
        let ctx = MangaDownloadContext(
            mangaTitle: item.title,
            mangaHref: item.href,
            coverImage: item.image,
            moduleId: moduleManager.activeModule?.id ?? "")
        let toDownload = chapters.filter { selectedChapterHrefs.contains($0.href) }
        for chapter in toDownload {
            mangaDownloads.download(chapter: chapter, context: ctx)
        }
        // Exit selection mode after initiating downloads.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isSelectionMode = false
            selectedChapterHrefs.removeAll()
        }
        ToastManager.shared.show(
            title: "Downloads",
            message: "Started \(toDownload.count) chapter\(toDownload.count == 1 ? "" : "s")",
            icon: "arrow.down.circle.fill",
            iconColor: .green
        )
    }

    /// Returns the download state for a chapter, or nil if no download exists.
    private func mangaDownloadState(for chapter: MangaChapter) -> MangaDownloadState? {
        mangaDownloads.item(forChapterHref: chapter.href)?.state
    }

    /// Returns the appropriate download/delete action for a chapter based on
    /// its current download state. Returns nil if no module is resolved.
    private func chapterDownloadAction(for chapter: MangaChapter, state: MangaDownloadState?) -> (() -> Void)? {
        guard let item = resolvedItem else { return nil }
        let ctx = MangaDownloadContext(
            mangaTitle: item.title,
            mangaHref: item.href,
            coverImage: item.image,
            moduleId: moduleManager.activeModule?.id ?? "")
        if state == .completed {
            return {
                if let it = mangaDownloads.item(forChapterHref: chapter.href) {
                    mangaDownloads.remove(it)
                }
            }
        } else {
            return { mangaDownloads.download(chapter: chapter, context: ctx) }
        }
    }
    #endif

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
            // No banner — use the cover image directly (NO blur). The user
            // wants sharp artwork, not a muddy blurred background. The dark
            // overlay + gradient still gives the hero depth.
            CachedAsyncImage(urlString: coverURL)
                .frame(width: width, height: height)
                .overlay(Color.black.opacity(0.35))
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
                                Text(score.averageScoreOutOf10)
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

    // MARK: - Read button

    @ViewBuilder
    private func readButton(media: Media) -> some View {
        Button {
            // Continue reading: open the last-read chapter, or the first
            // chapter if no progress exists.
            if let first = chapters.first {
                let lastRead = MangaProgressManager.shared.lastRead(for: resolvedItem?.href ?? "")
                let idx = lastRead.flatMap { last in
                    chapters.firstIndex(where: { $0.href == last.chapterHref })
                } ?? 0
                openReader(chapter: chapters[idx], index: idx)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "book.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(chapters.isEmpty ? "No Chapters" : "Continue Chapter")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .layoutPriority(1)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(chapters.isEmpty || isLoadingChapters)
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
        if let score = media.averageScore { items.append(("Rating", score.averageScoreOutOf10)) }
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
                                    .frame(width: 110, height: 165)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(edge.relationType.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(edge.node.title.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(width: 110, alignment: .leading)
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
            catch {
                // Don't get stuck loading forever — show the error.
                phase = .error(error.localizedDescription)
                return
            }
        }
        guard media != nil else {
            phase = .error("No data")
            return
        }

        // Show the page immediately — the media is ready. Everything below
        // is secondary and shouldn't block the page from rendering.
        phase = .ready

        // Fetch raw AniList manga for characters + recommendations.
        // Best-effort: don't fail the whole page if this secondary fetch
        // errors. Runs in parallel with module resolution.
        async let charRecs: Void = fetchCharactersAndRecommendations()
        async let entry: Void = fetchLibraryEntry()
        async let moduleResolve: Void = resolveMangaModule()

        _ = await (charRecs, entry, moduleResolve)
    }

    private func fetchCharactersAndRecommendations() async {
        if let raw = try? await AniListService.shared.mangaDetail(id: mediaId) {
            preloadedCharacters = raw.characters?.edges ?? []
            preloadedRecommendations = raw.recommendations?.nodes ?? []
        }
    }

    private func fetchLibraryEntry() async {
        if AniListAuthManager.shared.isLoggedIn {
            existingEntry = (try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId, type: .manga))
                .flatMap { AniListProvider.shared.mapEntry($0) }
        }
    }

    private func resolveMangaModule() async {
        let hasMangaModule = moduleManager.modules.contains { $0.isManga }
        guard hasMangaModule else { return }

        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media!.title.searchTitle) {
            resolvedItem = item
            match = await MangaMatchManager.shared.match(
                mangaHref: item.href, title: item.title)
            await loadChapters()
        }
        #endif
    }

    /// Fetches chapters from the resolved manga module. Called after
    /// `resolve()` succeeds, or when the user switches modules via the
    /// ModuleSelectorMenu. When switching modules, re-resolves the title
    /// through the new module (the old href won't work cross-module).
    private func loadChapters() async {
        isLoadingChapters = true
        chaptersError = nil

        // When the user switches modules, the old resolvedItem.href won't
        // work with the new module — each module uses its own URL scheme.
        // Re-resolve the title through the active module to get a fresh
        // href that works with it.
        guard let media else {
            isLoadingChapters = false
            return
        }

        // Check if the current resolvedItem's href works with the active
        // module. If the active module changed, re-resolve.
        let needsReResolve: Bool = {
            guard let resolvedItem else { return true }
            // If the active module is the one that originally resolved,
            // we can reuse the href. Otherwise, re-resolve.
            return moduleManager.activeModule?.id != nil
                && resolvedItem.href != ""
                && moduleManager.moduleReadyId != moduleManager.activeModule?.id
        }()

        if needsReResolve {
            // Re-resolve through the new active module
            if let newItem = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
                resolvedItem = newItem
            } else {
                chapters = []
                chaptersError = "No results in \(moduleManager.activeModule?.sourceName ?? "this module")."
                isLoadingChapters = false
                return
            }
        }

        guard let item = resolvedItem else {
            isLoadingChapters = false
            return
        }

        do {
            // Ensure the active manga module is loaded into JSEngine.
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
