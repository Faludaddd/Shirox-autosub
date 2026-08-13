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

    // Download speed / ETA tracking (transient — optional so old manifests
    // decode without error; populated live by the URLSession delegate).
    var bytesReceived: Int64? = nil
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double? = nil

    /// ETA in seconds, computed from current speed and remaining bytes.
    var estimatedSecondsRemaining: Double? {
        guard let speed = bytesPerSecond, speed > 0,
              let total = totalBytes, let received = bytesReceived,
              total > received else { return nil }
        return Double(total - received) / speed
    }

    /// Human-readable ETA string ("2m 14s", "45s", or "--" when unknown).
    var etaFormatted: String {
        guard let seconds = estimatedSecondsRemaining, seconds > 0 else { return "--" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins < 60 { return String(format: "%dm %ds", mins, secs) }
        return String(format: "%dh %dm", mins / 60, mins % 60)
    }

    var bytesReceivedFormatted: String { Self.formatBytes(bytesReceived ?? 0) }
    var totalBytesFormatted: String { Self.formatBytes(totalBytes ?? 0) }
    var speedFormatted: String {
        guard let speed = bytesPerSecond, speed > 0 else { return "--" }
        return Self.formatSpeed(speed)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return String(format: "%.0f B/s", bytesPerSec)
    }

    // File Info
    var fileName: String?
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
