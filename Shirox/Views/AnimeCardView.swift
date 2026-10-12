import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AnimeCardView: View {
    let item: SearchItem

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    CachedAsyncImage(urlString: item.image)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
    }
}

// MARK: - Unified anime/manga card context menu (v1.20 behavior, restored v2.32)
//
// ONE shared long-press menu for every anime/manga poster card in the app —
// the Home shelves, the Search results grid and the Browse/See All grids.
// SwiftUI's `.contextMenu` provides the interaction contract for free:
// long-press on a touchscreen, right-click (or control-click) on the desktop,
// never fires on a tap, a scroll or a swipe, and cancels cleanly when the
// finger moves or the system cancels the touch.
//
// The actions are the real library writes behind every other card menu in
// the app (`AniListLibraryService.updateEntry`) plus a direct link out to
// the title's AniList page. Nothing is shown that the system below can't do.

struct UnifiedAnimeContextMenu: ViewModifier {
    let media: Media
    /// Reading Mode cards list manga statuses and link to the manga page.
    var isManga: Bool = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                updateEntry(status: .planning)
            } label: {
                Label("Add to Planning", systemImage: "bookmark")
            }
            Button {
                updateEntry(status: .current)
            } label: {
                Label(isManga ? "Add to Reading" : "Add to Watching", systemImage: isManga ? "book.circle" : "play.circle")
            }
            Button {
                updateEntry(status: .completed)
            } label: {
                Label("Mark as Completed", systemImage: "checkmark.circle")
            }
            if media.id > 0 {
                Button {
                    openAniListPage()
                } label: {
                    Label("View on AniList", systemImage: "safari")
                }
            }
        }
    }

    private func updateEntry(status: MediaListStatus) {
        let type: MediaListType = isManga ? .manga : .anime
        Task {
            do {
                try await AniListLibraryService.shared.updateEntry(
                    mediaId: media.id, status: status, progress: 0, score: nil, type: type)
                await MainActor.run {
                    ToastManager.shared.show(
                        title: media.title.displayTitle,
                        message: status == .current
                            ? (isManga ? "Added to Reading" : "Added to Watching")
                            : status == .completed ? "Marked as Completed" : "Added to Planning",
                        icon: "checkmark.circle.fill",
                        iconColor: .green
                    )
                }
            } catch {
                await MainActor.run {
                    ToastManager.shared.show(
                        title: "Couldn't update list",
                        message: error.localizedDescription,
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red
                    )
                }
            }
        }
    }

    private func openAniListPage() {
        let kind = isManga ? "manga" : "anime"
        guard let url = URL(string: "https://anilist.co/\(kind)/\(media.id)") else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

extension View {
    /// The unified long-press menu for an anime or manga poster card.
    func unifiedCardMenu(_ media: Media, isManga: Bool = false) -> some View {
        modifier(UnifiedAnimeContextMenu(media: media, isManga: isManga))
    }
}
