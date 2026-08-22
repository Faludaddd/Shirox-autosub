#if os(iOS)
import SwiftUI

// MARK: - Continue Reading context-menu navigation

enum ContinueReadingNavTarget {
    case detail(mangaHref: String, mangaTitle: String, coverImage: String, moduleId: String)
    case anilist(Int)
}

@ViewBuilder
private func crNavDestination(_ target: ContinueReadingNavTarget) -> some View {
    switch target {
    case let .detail(mangaHref, mangaTitle, coverImage, moduleId):
        MangaDetailView(
            item: SearchItem(title: mangaTitle, image: coverImage, href: mangaHref)
        )
        .onAppear {
            Task { @MainActor in
                if let module = ModuleManager.shared.modules.first(where: { $0.id == moduleId }) {
                    ModuleManager.shared.selectModule(module)
                }
            }
        }
    case .anilist(let id):
        AniListMangaDetailView(mediaId: id)
    }
}

extension View {
    func continueReadingNavigation(_ target: Binding<ContinueReadingNavTarget?>) -> some View {
        self.navigationDestinationCompat(item: target) { crNavDestination($0) }
    }
}

struct ContinueReadingSection: View {
    let items: [MangaReadingItem]
    @Binding var readerContext: ReaderContext?
    @Binding var navTarget: ContinueReadingNavTarget?
    @State private var loadingHref: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Same responsive card width as MangaSection and AnimeSection —
    /// 190pt on iPad, 155pt on iPhone. This ensures the Continue Reading
    /// poster size matches the posters in Trending Manga / All-Time Popular.
    private var cardWidth: CGFloat {
        #if os(iOS)
        return sizeClass == .regular ? 190 : 155
        #else
        return 190
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Continue Reading")
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        // Use .contentShape + .onTapGesture instead of Button
                        // to avoid a known SwiftUI gesture conflict: Button
                        // inside a LazyHStack with .contextMenu can have its
                        // tap target misaligned with the visual card after
                        // the LazyHStack recycles views during scroll. This
                        // was causing "tapping the first poster opens the
                        // second one" — the Button's captured `item` didn't
                        // match the visual position after recycling.
                        // .contentShape(Rectangle()) + .onTapGesture is
                        // stable across LazyHStack recycling because the
                        // gesture is attached to the view itself, not a
                        // Button wrapper that SwiftUI might reuse.
                        ContinueReadingCardDisplay(
                            item: item,
                            isLoading: loadingHref == item.mangaHref
                        )
                        .frame(width: cardWidth)
                        .contentShape(Rectangle())
                        .onTapGesture { open(item) }
                        .contextMenu {
                            if let aniListId = MangaMatchManager.shared.cachedMatch(mangaHref: item.mangaHref)?.aniListID {
                                Button {
                                    navTarget = .anilist(aniListId)
                                } label: {
                                    Label("View on AniList", systemImage: "book.closed")
                                }
                            }
                            Button(role: .destructive) {
                                MangaProgressManager.shared.remove(item)
                            } label: {
                                Label("Remove", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func open(_ item: MangaReadingItem) {
        guard loadingHref == nil else { return }
        loadingHref = item.mangaHref
        Task {
            defer { loadingHref = nil }
            guard let module = ModuleManager.shared.modules.first(where: { $0.id == item.moduleId }) else {
                ToastManager.shared.show(
                    title: "Reader",
                    message: "Module no longer installed",
                    icon: "exclamationmark.circle.fill",
                    iconColor: .red
                )
                return
            }
            if ModuleManager.shared.moduleReadyId != module.id {
                guard await ModuleManager.shared.selectAndAwaitReady(module) else {
                    ToastManager.shared.show(
                        title: "Reader",
                        message: "Failed to load \(module.sourceName)",
                        icon: "exclamationmark.circle.fill",
                        iconColor: .red
                    )
                    return
                }
            }
            do {
                let chapters = try await JSEngine.shared.mangaChapters(url: item.mangaHref)
                guard !chapters.isEmpty else {
                    ToastManager.shared.show(
                        title: "Reader",
                        message: "No chapters found",
                        icon: "exclamationmark.circle.fill",
                        iconColor: .red
                    )
                    return
                }
                let idx = chapters.firstIndex(where: { $0.href == item.chapterHref }) ?? 0
                // Off-by-one fix: if the exact href match fails, try
                // matching by chapter number as a fallback. The href might
                // differ if the module changed its URL scheme.
                let resolvedIdx: Int = {
                    if chapters.indices.contains(idx), chapters[idx].href == item.chapterHref {
                        return idx
                    }
                    // Fallback: match by chapter number
                    if let numIdx = chapters.firstIndex(where: { $0.number == item.chapterNumber }) {
                        return numIdx
                    }
                    return 0
                }()
                let isResume = chapters[resolvedIdx].href == item.chapterHref
                readerContext = ReaderContext(
                    mangaTitle: item.mangaTitle,
                    mangaHref: item.mangaHref,
                    coverImage: item.coverImage,
                    moduleId: item.moduleId,
                    chapters: chapters,
                    chapterIndex: resolvedIdx,
                    resumePage: isResume ? item.pageIndex : nil,
                    resumeFraction: isResume ? item.pageFraction : nil,
                    match: MangaMatchManager.shared.cachedMatch(mangaHref: item.mangaHref)
                )
            } catch {
                ToastManager.shared.show(
                    title: "Reader",
                    message: "Failed to load chapters",
                    icon: "exclamationmark.circle.fill",
                    iconColor: .red
                )
            }
        }
    }
}

// MARK: - Card display (pure visual)

struct ContinueReadingCardDisplay: View {
    let item: MangaReadingItem
    var isLoading = false

    private var progressLabel: String {
        let page = min(item.pageIndex + 1, max(item.totalPages, 1))
        return "\(item.chapterName) • \(page)/\(item.totalPages)"
    }

    private var progressFraction: Double {
        MangaProgressManager.progressFraction(pageIndex: item.pageIndex, totalPages: item.totalPages)
    }

    var body: some View {
        // 2:3 vertical poster card (manga-specific layout, distinct from
        // anime's 16:9 horizontal ContinueWatchingCard).
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                CachedAsyncImage(urlString: item.coverImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            )
            .overlay(alignment: .topLeading) {
                Text(item.chapterName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(progressLabel)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)

                        Text(item.mangaTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottom) {
                if progressFraction > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.white.opacity(0.2)
                            Color.primary
                                .frame(width: geo.size.width * progressFraction)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView().tint(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
    }
}
#endif
