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
    /// When set, navigates to MangaDetailView for batch download selection.
    @State private var pendingDownloadItem: SearchItem?
    @State private var downloadNavActive = false
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
        .background {
            NavigationLink(
                destination: Group {
                    if let item = pendingDownloadItem {
                        MangaDetailView(item: item)
                    }
                },
                isActive: $downloadNavActive
            ) { EmptyView() }
            .hidden()
        }
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
            // Module selector — manga modules only.
            ToolbarItem(placement: .topBarTrailing) {
                ModuleSelectorMenu(mediaType: .manga)
            }
            // Edit (pencil) button — fetches fresh entry data before
            // opening the edit sheet, so the sheet always shows the current
            // status/progress/private state (not stale data from launch).
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
                // Primary read/continue button — full width, no icon siblings.
                // Previously this row had 5 fixed-width 46×46 circle buttons
                // competing for space (connections toggle, download/select
                // mode, jump-to-latest, invert order, reset progress), which
                // truncated the primary button's label to "Con…" even with
                // .layoutPriority(1) and .minimumScaleFactor(0.7). The
                // secondary actions now live in the Chapters section header
                // itself (see `chaptersSection`) — colocated with the list
                // they actually control, the same way a section-local toolbar
                // sits next to its list. The jump-to-latest button was
                // removed entirely (low value, contributed to crowding). The
                // connections/people toggle was removed because the relations
                // section is already shown above the chapters list — switching
                // tabs just hid the chapters, it didn't surface any new info.
                #if os(iOS)
                readButton(media: media)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                #endif
                // Section order matches the anime AniList page:
                // Button → Relations → Chapters → Characters → Recommendations.
                // (Previously this branched on a `selectedTab` toggle between
                // a chapters view and a connections view. The connections view
                // was redundant — the relations section is already shown
                // above the chapters list in the default view, so switching
                // tabs just hid the chapters. The toggle was removed.)
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
                // Characters + Recommendations — placed AFTER the chapters/
                // connections section, matching the anime AniList page:
                // Synopsis → Buttons → Episodes/Chapters → Characters → Recommendations
                CharactersSection(mediaId: media.id, isManga: true,
                                  preloaded: preloadedCharacters)
                    .padding(.top, 16)
                RecommendationsSection(mediaId: media.id, isManga: true,
                                       preloaded: preloadedRecommendations)
                    .padding(.top, 8)
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
            // Section-local toolbar: title + count badge on the left,
            // secondary action icons on the right. These actions were
            // previously jammed into the hero button row above, where they
            // crowded the primary "Continue Chapter" button and caused its
            // label to truncate to "Con…". Moving them here gives the
            // primary button the full row width AND colocates the actions
            // with the list they actually control.
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
                // Selection-mode / batch-download toggle. Sized to match
                // anime's episodes section header (36×36, ultraThinMaterial
                // background, 1pt stroke) — the previous 32×32 frame was
                // too small and looked cramped against the Chapters title.
                if !chapters.isEmpty {
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode { selectedChapterHrefs.removeAll() }
                        }
                    } label: {
                        Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelectionMode ? platformBackground : .primary)
                            .frame(width: 36, height: 36)
                            .background(
                                isSelectionMode ? Color.primary : .ultraThinMaterial,
                                in: Circle()
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                // Invert chapter order — toggles newestFirst. Fixes the
                // index-mismatch bug where tapping chapter 25 in inverted
                // mode opened chapter 1 (see chapterRow's realIndex).
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
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                // Reset reading progress — only shows if the user actually
                // has progress for this manga.
                if let item = resolvedItem,
                   MangaProgressManager.shared.hasProgress(mangaHref: item.href) {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
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
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayChapters.enumerated()), id: \.element.id) { idx, chapter in
                        chapterRow(chapter, index: idx, isSelected: selectedChapterHrefs.contains(chapter.href))
                    }
                }
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: MangaChapter, index: Int, isSelected: Bool = false) -> some View {
        // Read status — mirrors anime's EpisodeRowView exactly: every row
        // has a filled circle of the same size; unread chapters show the
        // chapter number on a Color.primary fill, read chapters show a
        // white checkmark on a Color.green fill (with a matching colored
        // drop shadow). The previous batch's "remove the numbered pill"
        // approach was wrong — anime keeps the numbered circle and just
        // changes its fill + content for completed items, which is what
        // we now do here too.
        let mangaHref = resolvedItem?.href ?? ""
        let isRead = MangaProgressManager.shared.isChapterRead(
            mangaHref: mangaHref, chapterHref: chapter.href)
        // Real index in the ORIGINAL chapters array — needed because
        // `index` (from ForEach over displayChapters) is the position in
        // the possibly-reversed display order, but openReader's index
        // parameter controls next/prev navigation within the reader and
        // must correspond to the chapter's real position. Without this,
        // inverting the order (newestFirst=true) made tapping chapter 25
        // open chapter 1 (and vice versa) — the displayed position no
        // longer matched the real position.
        let realIndex = chapters.firstIndex(where: { $0.id == chapter.id }) ?? index
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
            HStack(spacing: 12) {
                ZStack {
                    if isSelectionMode {
                        // Selection mode — keep the existing checkmark
                        // circle (legitimate use: communicates selection state).
                        Circle()
                            .fill(isSelected ? Color.appAccent : Color.primary.opacity(0.08))
                            .frame(width: 36, height: 36)
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        // Non-selection — same 36×36 filled circle for every
                        // row, with fill + content varying by read status
                        // (matches anime's EpisodeRowView conditional:
                        // isComplete ? Color.green : Color.primary for fill,
                        // checkmark vs. number for content).
                        Circle()
                            .fill(isRead ? Color.green : Color.primary)
                            .frame(width: 36, height: 36)
                            .shadow(color: (isRead ? Color.green : Color.primary).opacity(0.3),
                                    radius: 4, y: 2)
                        if isRead {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Text(chapter.displayNumber)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(platformBackground)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
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
        // Long-press context menu to manually toggle read/unread —
        // matches MangaDetailView's MangaChapterRowView.
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
            }
        }
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
            } else if let first = chapters.first {
                openReader(chapter: first, index: 0)
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
