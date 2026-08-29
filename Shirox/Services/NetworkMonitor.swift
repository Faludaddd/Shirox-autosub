#if os(iOS)
import Foundation
import Network
import Combine

/// Single source of truth for the device's current network class (v2.13).
///
/// Wraps `NWPathMonitor` and exposes whether the active path is a metered
/// connection (cellular, personal hotspot, some VPNs). The "Download Over
/// WiFi Only" setting — which existed in the Downloads settings page since
/// long ago but was never read by any download code — is now enforced by
/// both `DownloadManager` and `MangaDownloadManager` through this monitor:
///   - new downloads don't START while on cellular, and
///   - in-flight downloads are paused when the path drops to cellular,
///     resuming automatically when Wi-Fi returns.
///
/// The monitor starts lazily on first access of `shared` and delivers its
/// first path update within milliseconds of start; managers tolerate the
/// brief unknown window (see DownloadManager.init's delayed first
/// processQueue).
@MainActor
final class NetworkMonitor: ObservableObject {

    nonisolated(unsafe) static let shared = NetworkMonitor()

    /// True when the current path is cellular, a personal hotspot, or
    /// otherwise metered ("expensive" in Network.framework terms). Downloads
    /// gated on Wi-Fi-only treat this as "not on Wi-Fi".
    @Published private(set) var isOnCellular: Bool = false

    /// True when there is no usable connection at all. Kept for future use
    /// (e.g. surfacing offline state); Wi-Fi gating keys off `isOnCellular`
    /// so an offline device simply doesn't start downloads either way.
    @Published private(set) var isOffline: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.shirox.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) || path.isExpensive
            let offline = path.status != .satisfied
            // Hop to the main actor: @Published consumers (managers, settings
            // UI) are all main-actor bound.
            Task { @MainActor in
                guard let self else { return }
                if self.isOnCellular != cellular { self.isOnCellular = cellular }
                if self.isOffline != offline { self.isOffline = offline }
            }
        }
        monitor.start(queue: queue)
    }
}
#endif
