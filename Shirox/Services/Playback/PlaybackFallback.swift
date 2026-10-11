import AVFoundation

/// The two engines the player can run on.
enum PlaybackEngineKind: String, CaseIterable {
    /// AVPlayer: Picture in Picture and AirPlay video, but only the formats Apple plays.
    case native
    /// libmpv: more containers, codecs and subtitle styles; no Picture in Picture or AirPlay video.
    case mpv
}

/// Which engine plays a stream, and what the player does when one fails — apart from the view.
enum PlaybackFallback {

    /// Containers AVPlayer can't open at all, so they start on MPV whatever the setting says.
    static let mpvOnlyExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts", "ogv"]

    static func initialEngine(preferred: PlaybackEngineKind, url: URL) -> PlaybackEngineKind {
        if preferred == .mpv { return .mpv }
        return mpvOnlyExtensions.contains(url.pathExtension.lowercased()) ? .mpv : .native
    }

    /// AVFoundation's ways of saying it can't read or decode the media — no new URL will help, a
    /// different player might. It often wraps the real reason a level or two down.
    static func isUnsupportedFormat(_ error: Error?) -> Bool {
        let formatCodes: Set<Int> = [
            AVError.fileFormatNotRecognized.rawValue,
            AVError.failedToParse.rawValue,
            AVError.decodeFailed.rawValue,
            AVError.decoderNotFound.rawValue,
            AVError.formatUnsupported.rawValue,
        ]
        var current = error.map { $0 as NSError }
        for _ in 0..<3 {
            guard let nsError = current else { return false }
            if nsError.domain == AVFoundationErrorDomain, formatCodes.contains(nsError.code) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    enum Decision: Equatable {
        /// Re-extract a fresh URL and try again on the same engine.
        case refetch
        /// Carry on in MPV from the same position.
        case switchToMPV
        /// Offer the manual retry.
        case giveUp
    }

    /// What to do when the item fails to load.
    /// - Native: a format error goes to MPV at once. Anything else re-fetches first — an expired
    ///   CDN URL is the usual cause — and goes to MPV once a fresh one has failed too, or when
    ///   there's no way to get one.
    /// - MPV: a re-fetch is the only thing left to try, once.
    static func decision(after error: Error?, engine: PlaybackEngineKind,
                         canRefetch: Bool, hasRefetched: Bool) -> Decision {
        let refetchLeft = canRefetch && !hasRefetched
        switch engine {
        case .native:
            if isUnsupportedFormat(error) { return .switchToMPV }
            return refetchLeft ? .refetch : .switchToMPV
        case .mpv:
            return refetchLeft ? .refetch : .giveUp
        }
    }

    // MARK: - Waiting

    /// Whether a wait is the engine still opening its stream, left to finish rather than watched
    /// for a stall. mpv gives up on a dead source by itself, so a slow open is just slow: a
    /// far-away server took it 15 s, and the watchdog offered Retry just before it would have
    /// played. AVPlayer can wait forever on a wedged request, so its waits stay watched.
    static func waitIsOpening(engine: PlaybackEngineKind, isItemReady: Bool, isItemFailed: Bool) -> Bool {
        engine == .mpv && !isItemReady && !isItemFailed
    }

    /// How long an open left to finish may take before it counts as failed — past mpv's own
    /// 60-second network timeout; nil for an engine whose open is watched instead.
    static func openingPatience(for engine: PlaybackEngineKind) -> TimeInterval? {
        engine == .mpv ? 75 : nil
    }

    /// When the loading screen says an open left to finish is taking a while.
    static let slowOpeningHint: TimeInterval = 6

    /// Whether a wait watched for the watchdog's whole interval is a stall: nothing moved. A
    /// moved playhead is a seek landing somewhere unbuffered; a grown buffer is a slow
    /// connection catching up, which recovering would only restart.
    static func isStalled(playheadMoved: Double, bufferGrew: Double) -> Bool {
        abs(playheadMoved) < 0.5 && bufferGrew < 0.5
    }
}

/// Tells a stream that died mid-episode from one that played to its end, from mpv's log.
///
/// When a stream's segments stop loading (an expired CDN token after a phone call, or a seek
/// back into segments the server no longer serves), ffmpeg's HLS demuxer doesn't fail. It logs
/// "Failed to open segment", skips that segment and tries the next, and races through the rest
/// of the episode to EOF. The playhead lands at the end, the end check passes, and the player
/// moved on to the next episode. The abandoned one was synced as watched on the way past, or
/// left with no progress. This counts the failures so the engine can report a dead stream from
/// where it was before they started.
struct SegmentFailureWatch {
    /// This many failures close together mean the source is gone, not one bad segment.
    static let failuresToGiveUp = 3
    /// How close together they have to be.
    static let window: TimeInterval = 20

    private var failures: [Date] = []
    /// The playhead when the current run of failures started.
    private(set) var positionBeforeFailures: Double?

    static func isSegmentFailure(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("failed to open segment")
            || (lower.contains("hls") && lower.contains("skipping"))
            || lower.contains("failed to reload playlist")
    }

    /// Records a log line. True once the failures add up to a dead stream.
    mutating func record(_ line: String, position: Double, at now: Date = Date()) -> Bool {
        guard Self.isSegmentFailure(line) else { return false }
        failures.removeAll { now.timeIntervalSince($0) > Self.window }
        if failures.isEmpty { positionBeforeFailures = position }
        failures.append(now)
        return failures.count >= Self.failuresToGiveUp
    }

    /// Whether an EOF now follows segment failures, so it's the demuxer giving up, not the end.
    func endIsFailure(at now: Date = Date()) -> Bool {
        guard let last = failures.last else { return false }
        return now.timeIntervalSince(last) <= Self.window
    }

    mutating func reset() {
        failures = []
        positionBeforeFailures = nil
    }
}

/// When mpv should switch hardware decoding back on after falling back to software.
///
/// mpv gives VideoToolbox up after three failed frames in a row and decodes the rest of the file
/// in software. A few corrupt packets at a stream's start were enough: every frame up to the next
/// keyframe fails, and a film decoded in software at 1080p kept an iPhone 16 at ~45% CPU. The
/// fallback stays quick, as a file VideoToolbox can't decode at all would otherwise blank for
/// seconds; hardware is tried again once playback has moved past the bad stretch, and given up on
/// for the file when that retry fails at once.
struct HardwareDecodeRetry {
    /// How far playback goes on in software before hardware is tried again.
    static let delay: Double = 10
    /// A fallback this soon after a retry means the retry failed.
    static let failedRetryWindow: Double = 5

    /// The position mpv fell back to software at, while a retry is due.
    private var fellBackAt: Double?
    private var retriedAt: Double?
    private var gaveUp = false

    /// mpv reports the decoder it now uses.
    mutating func decoderChanged(toHardware: Bool, at position: Double) {
        guard !toHardware else {
            fellBackAt = nil
            return
        }
        if let retriedAt, abs(position - retriedAt) < Self.failedRetryWindow {
            gaveUp = true
            fellBackAt = nil
            return
        }
        fellBackAt = position
    }

    /// True once, when hardware decoding should be switched back on.
    mutating func shouldRetry(at position: Double) -> Bool {
        guard !gaveUp, let fellBackAt, position - fellBackAt >= Self.delay else { return false }
        self.fellBackAt = nil
        retriedAt = position
        return true
    }

    mutating func reset() {
        fellBackAt = nil
        retriedAt = nil
        gaveUp = false
    }
}
