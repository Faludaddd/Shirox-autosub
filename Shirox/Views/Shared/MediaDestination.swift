import SwiftUI

/// Where a title opens: the anime detail page for everything in the app today
/// (Simkl title pages arrive with the Simkl port).
struct MediaDestination: View {
    let media: Media

    var body: some View {
        AniListDetailView(mediaId: media.id, preloadedMedia: media)
    }
}
