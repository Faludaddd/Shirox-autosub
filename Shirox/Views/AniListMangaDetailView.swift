import SwiftUI

/// AniList-backed manga detail: loads AniList metadata, resolves a manga-module
/// `SearchItem` (via MangaModuleResolver), then presents MangaDetailView seeded
/// with the metadata. The manga analog of AniListDetailView (which stays anime).
///
/// This is the ORIGINAL source's working implementation — it delegates to
/// MangaDetailView which handles chapter loading and reader opening. Our
/// custom layout (hero, statistics, countdown) is layered on top via the
/// aniListMedia parameter that MangaDetailView receives.
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil

    @State private var media: Media?
    @State private var resolvedItem: SearchItem?
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, ready, noModule, notFound, error(String) }

    init(mediaId: Int, preloadedMedia: Media? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        _media = State(initialValue: preloadedMedia)
    }

    var body: some View {
        Group {
            if let media, let resolvedItem, phase == .ready {
                // Delegate to the ORIGINAL MangaDetailView which handles:
                // - Chapter list loading from the module
                // - Chapter selection → MangaReaderView opening
                // - Reading progress saving
                // - Statistics, synopsis, relations
                MangaDetailView(item: resolvedItem, aniListMedia: media)
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
    }

    private func resolve() async {
        guard phase == .loading else { return }
        if media == nil {
            do { media = try await AniListProvider.shared.mangaDetail(id: mediaId) }
            catch { phase = .error(error.localizedDescription); return }
        }
        guard let media else { phase = .error("No data"); return }
        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
            resolvedItem = item
            phase = .ready
        } else {
            phase = ModuleManager.shared.modules.contains { $0.isManga } ? .notFound : .noModule
        }
        #else
        phase = .noModule
        #endif
    }
}
