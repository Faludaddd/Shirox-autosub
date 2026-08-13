import SwiftUI

/// AniList-backed manga detail: loads AniList metadata, resolves a manga-module
/// `SearchItem` (via MangaModuleResolver), then presents MangaDetailView seeded
/// with the metadata. The manga analog of AniListDetailView (which stays anime).
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil

    @State private var media: Media?
    @State private var resolvedItem: SearchItem?
    @State private var phase: Phase = .loading
    @EnvironmentObject private var moduleManager: ModuleManager

    private enum Phase: Equatable { case loading, ready, noModule, notFound, error(String) }

    init(mediaId: Int, preloadedMedia: Media? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        _media = State(initialValue: preloadedMedia)
    }

    var body: some View {
        Group {
            if let media, let resolvedItem, phase == .ready {
                MangaDetailView(item: resolvedItem, aniListMedia: media)
            } else if phase == .noModule {
                ContentUnavailableView("No Manga Module",
                    systemImage: "book.closed",
                    description: Text("Install a manga module to read chapters."))
            } else if phase == .notFound {
                ContentUnavailableView("Not Found",
                    systemImage: "magnifyingglass",
                    description: Text("No match for this title in your manga module. Try searching for it directly in the Search tab."))
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

        // Check if any manga module is installed first
        let hasMangaModule = moduleManager.modules.contains { $0.isManga }
        guard hasMangaModule else {
            phase = .noModule
            return
        }

        #if os(iOS)
        // Module is installed — try to resolve the title against it
        if let item = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
            resolvedItem = item
            phase = .ready
        } else {
            // Module is installed but search returned no results.
            // This could be a network error, a CF challenge, or the title
            // genuinely doesn't exist in this module. Show a helpful message
            // rather than "no module" since the module IS installed.
            phase = .notFound
        }
        #else
        phase = .noModule
        #endif
    }
}
