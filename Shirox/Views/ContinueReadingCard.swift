#if os(iOS)
import SwiftUI

// MARK: - Continue Reading context-menu navigation

/// Where a Continue Reading context-menu item wants to navigate.
enum ContinueReadingNavTarget {
    case detail(mangaHref: String, mangaTitle: String, coverImage: String, moduleId: String?, aniListID: Int?)
    case anilist(Int)
}

@ViewBuilder
private func crNavDestination(_ target: ContinueReadingNavTarget) -> some View {
    switch target {
    case let .detail(mangaHref, mangaTitle, coverImage, moduleId, aniListID):
        if let aid = aniListID {
            AniListMangaDetailView(mediaId: aid)
        } else {
            MangaDetailView(
                item: SearchItem(title: mangaTitle, image: coverImage, href: mangaHref),
                moduleId: moduleId
            )
        }
    case .anilist(let id):
        AniListMangaDetailView(mediaId: id)
    }
}

extension View {
    /// Drives Continue Reading context-menu navigation from the parent view.
    /// Attach outside the ScrollView. Uses `navigationDestinationCompat`,
    /// which pushes via a hidden `NavigationLink` on iOS (the app's
    /// `NavigationStack` is really a `NavigationView`, which ignores
    /// `navigationDestination(...)`).
    func continueReadingNavigation(_ target: Binding<ContinueReadingNavTarget?>) -> some View {
        self.navigationDestinationCompat(item: target) { crNavDestination($0) }
    }
}

/// "Continue Reading" row on Home: one card per manga with the last-read
/// chapter/page. Tapping re-activates the manga's module if needed, re-fetches
/// the chapter list (so prev/next works in the reader), then opens the reader
/// at the saved page.
struct ContinueReadingSection: View {
    let items: [MangaReadingItem]
    /// Owned by HomeView, drives its fullScreenCover.
    @Binding var readerContext: ReaderContext?
    /// Owned by the parent view, drives context-menu navigation.
    @Binding var navTarget: ContinueReadingNavTarget?
    @State private var loadingHref: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Continue Reading")
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 36, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            ContinueReadingCardDisplay(
                                item: item,
                                isLoading: loadingHref == item.mangaHref
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 160)
                        .contextMenu {
                            Button {
                                let match = MangaMatchManager.shared.cachedMatch(mangaHref: item.mangaHref)
                                navTarget = .detail(
                                    mangaHref: item.mangaHref,
                                    mangaTitle: item.mangaTitle,
                                    coverImage: item.coverImage,
                                    moduleId: item.moduleId,
                                    aniListID: match?.aniListID
                                )
                            } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
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
                let isResume = chapters[idx].href == item.chapterHref
                readerContext = ReaderContext(
                    mangaTitle: item.mangaTitle,
                    mangaHref: item.mangaHref,
                    coverImage: item.coverImage,
                    moduleId: item.moduleId,
                    chapters: chapters,
                    chapterIndex: idx,
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
        // 16:9 horizontal card matching ContinueWatchingCard's format.
        Color.clear
            .aspectRatio(16/9, contentMode: .fit)
            .overlay(
                CachedAsyncImage(urlString: item.coverImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            )
            .overlay(alignment: .topLeading) {
                Text(item.chapterName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
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
                .frame(height: 80)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(progressLabel)
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)

                        Text(item.mangaTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
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
