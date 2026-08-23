#if os(iOS)
import SwiftUI

/// Download module/stream picker — delegates to the new custom
/// `ModuleStreamPickerView` (the same one used by the Watch / Change Stream
/// flow). The old iOS-default List + DownloadModuleRow + DownloadStreamPickerView
/// has been removed (~420 lines of dead code).
///
/// The picker handles:
///   - Module selection (anime modules only, filtered at the data source)
///   - Stream selection (custom card-based UI with quality badges)
///   - Single-stream auto-selection (when there's only one stream)
///   - Cloudflare verification (inline)
///   - No Auto Pick Module
struct DownloadModulePickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], String?) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager

    var body: some View {
        ModuleStreamPickerView(
            mediaId: mediaId,
            animeTitle: animeTitle,
            episodeNumber: episodeNumber,
            onDismiss: { onDismiss() },
            onStreamsLoaded: { streams, selectedStream, showHref, availableCount, episodeHref in
                let stream = selectedStream ?? streams.first
                if let stream {
                    onStreamsLoaded([stream], episodeHref)
                }
            }
        )
        .environmentObject(moduleManager)
    }
}
#endif
