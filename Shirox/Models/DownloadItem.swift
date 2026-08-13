import Foundation

enum DownloadState: String, Codable {
    case pending
    case downloading
    case completed
    case failed
}

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    
    // Media Identity
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    
    // Module Integration
    let moduleId: String?
    let detailHref: String?
    let episodeHref: String
    let streamTitle: String?
    /// nil while the batch-download pipeline is still extracting the stream URL for this
    /// item. processQueue() ignores items where this is nil; a separate task is responsible
    /// for filling it in and then re-triggering the queue.
    var streamURL: URL?
    var headers: [String: String]

    // Subtitles
    var subtitleURL: URL?
    var subtitleHeaders: [String: String]?

    // Status
    var state: DownloadState
    var progress: Double
    var error: String?

    // Download speed / ETA tracking (transient — not persisted to the manifest;
    // populated live by the URLSession delegate while downloading, nil otherwise).
    // Optional so old manifests without these keys decode without error.
    var bytesDownloaded: Int64? = nil
    var totalBytes: Int64? = nil
    var startedAt: Date? = nil
    var lastSpeedBytesPerSec: Double? = nil

    /// ETA in seconds, computed from current speed and remaining bytes.
    /// Nil when speed or total bytes are unknown.
    var estimatedSecondsRemaining: Double? {
        guard let speed = lastSpeedBytesPerSec, speed > 0,
              let total = totalBytes, let downloaded = bytesDownloaded,
              total > downloaded else { return nil }
        return Double(total - downloaded) / speed
    }

    // File Info
    var fileName: String? // Points to the .mp4 or .m3u8 file
    var relativeSubtitlePath: String?
    
    // Timing
    let createdAt: Date
    var completedAt: Date?
    
    // Task Tracking
    var taskIdentifier: Int?
    var retryCount: Int = 0
    
    // Helper to determine if we should use HLS playback
    var isHLS: Bool {
        fileName?.lowercased().hasSuffix(".m3u8") ?? false
    }
}
