import Foundation
import Combine
import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
import VLCKitSPM
import MediaPlayer
#endif

// MARK: - Music Player

/// In-app theme playback — the engine behind the Music section.
///
/// AnimeThemes serves its media as WebM video (v.animethemes.moe) and
/// Opus-in-Ogg audio (a.animethemes.moe). Neither container decodes in
/// AVFoundation, so playback runs on VLCKit (libVLC) — a real decoder for
/// both formats, same SPM binary-package mechanism as GoogleCast.
///
/// The manager is a process-wide singleton so music keeps playing while
/// the user browses the app: the mini-player bar (root overlay) and the
/// expanded player sheet both observe it. On platforms without VLCKit
/// (macOS / Catalyst / tvOS builds) the engine reports `playbackAvailable
/// == false` — browsing still works and the UI disables play controls
/// with an honest hint instead of pretending.
@MainActor
final class MusicPlayerManager: NSObject, ObservableObject {

    static let shared = MusicPlayerManager()

    // MARK: - Published state (observed by the mini bar + player sheet)

    /// The queue as it was set — the source of truth for next/previous.
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var currentIndex: Int = -1
    /// nil when nothing is loaded.
    @Published private(set) var currentTrack: MusicTrack?
    @Published private(set) var isPlaying = false
    /// True from the moment a media is being opened until it actually
    /// starts (VLC's buffering state).
    @Published private(set) var isBuffering = false
    /// Playback position in seconds (0 when nothing is loaded).
    @Published private(set) var positionSeconds: Double = 0
    /// Total duration in seconds (0 until the media is parsed).
    @Published private(set) var durationSeconds: Double = 0
    /// Honest failure message (VLC error state / no playable link). nil
    /// when healthy.
    @Published var playbackError: String?
    /// When true the player renders the theme's VIDEO (the actual OP/ED
    /// sequence); false = audio-only streaming (smaller, background-
    /// friendly). Toggling restarts the current track at its position.
    @Published var videoMode = false
    /// True when a full-screen/expanded player is presented (drives the
    /// mini bar visibility).
    @Published var isExpanded = false

    /// Whether this build can play media at all (VLCKit present).
    let playbackAvailable: Bool

    var isQueueEmpty: Bool { queue.isEmpty }

    // MARK: - Engine (iOS only)

    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
    private let player = VLCMediaPlayer()
    /// A progress ticker driving published position updates (VLC pushes
    /// time-changed notifications ~250ms apart, but the slider wants a
    /// steady, main-actor cadence).
    private var ticker: Timer?
    private var remoteCommandsConfigured = false
    #else
    // No engine on this platform — playback controls degrade honestly.
    #endif

    private override init() {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        playbackAvailable = true
        #else
        playbackAvailable = false
        #endif
        super.init()
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        player.delegate = self
        #endif
    }

    // MARK: - Playback control

    /// Plays `track` and remembers `allTracks` as the queue (the rail the
    /// user tapped in — next/previous stay within it).
    func play(track: MusicTrack, queue allTracks: [MusicTrack]) {
        guard playbackAvailable else { return }
        let cleanedQueue = allTracks.filter { $0.audioLink != nil || $0.videoLink != nil }
        self.queue = cleanedQueue.isEmpty ? [track] : cleanedQueue
        let index = cleanedQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        load(index: index, autoplay: true)
    }

    func togglePlayPause() {
        guard playbackAvailable, currentTrack != nil else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
        }
        updateNowPlayingInfo()
        #endif
    }

    func next() {
        guard playbackAvailable, !queue.isEmpty, currentIndex < queue.count - 1 else { return }
        load(index: currentIndex + 1, autoplay: true)
    }

    func previous() {
        guard playbackAvailable, !queue.isEmpty else { return }
        // Standard music behavior: > 3s into the track restarts it,
        // otherwise go back one.
        if positionSeconds > 3, currentIndex >= 0 {
            seek(to: 0)
            return
        }
        guard currentIndex > 0 else { seek(to: 0); return }
        load(index: currentIndex - 1, autoplay: true)
    }

    /// Seek to a time interval within the current track.
    func seek(to seconds: Double) {
        guard playbackAvailable, currentTrack != nil else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        player.time = VLCTime(int: Int32(seconds) * 1000)
        positionSeconds = seconds
        updateNowPlayingInfo()
        #endif
    }

    /// Stops playback and clears the queue.
    func stop() {
        guard playbackAvailable else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        player.stop()
        ticker?.invalidate(); ticker = nil
        #endif
        queue = []
        currentIndex = -1
        currentTrack = nil
        isPlaying = false
        isBuffering = false
        positionSeconds = 0
        durationSeconds = 0
        playbackError = nil
        isExpanded = false
    }

    /// Toggles video rendering for the current track (restarts in place).
    func setVideoMode(_ on: Bool) {
        guard on != videoMode, currentTrack != nil else { return }
        videoMode = on
        guard playbackAvailable else { return }
        load(index: currentIndex, autoplay: isPlaying || on, preservePosition: true)
    }

    // MARK: - Video surface (the expanded player's video area)

    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
    /// Attaches the VLC drawable for video rendering. Called by the
    /// UIViewRepresentable video surface when it appears.
    func attachVideoSurface(_ view: UIView) {
        player.drawable = view
    }

    func detachVideoSurface(_ view: UIView) {
        // The surface is being torn down — clear the drawable (VLC keeps
        // playing audio with no drawable attached).
        player.drawable = nil
    }
    #endif

    // MARK: - Loading

    private func load(index: Int, autoplay: Bool, preservePosition: Bool = false) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        currentIndex = index
        currentTrack = track
        playbackError = nil
        isBuffering = true
        positionSeconds = 0
        durationSeconds = 0
        let resumeAt = preservePosition ? positionSeconds : 0

        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
        // Audio-only by default (the .ogg stream): smaller transfer, keeps
        // playing with the screen off / app backgrounded. Video mode uses
        // the .webm link — the actual OP/ED sequence with sound.
        let url: URL?
        if videoMode, let video = track.videoLink {
            url = URL(string: video)
        } else if let audio = track.audioLink {
            url = URL(string: audio)
        } else if let video = track.videoLink {
            url = URL(string: video)
        } else {
            url = nil
        }
        guard let url else {
            isBuffering = false
            playbackError = "This theme has no playable media."
            return
        }
        player.stop()
        player.media = VLCMedia(url: url)
        if autoplay {
            player.play()
            isPlaying = true
        }
        if resumeAt > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.seek(to: resumeAt)
            }
        }
        startTicker()
        configureRemoteCommands()
        updateNowPlayingInfo()
        #else
        isBuffering = false
        playbackError = "Playback isn't available on this device."
        #endif
    }

    // MARK: - Progress ticker + lock screen

    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                let pos = self.player.position // 0…1 while playing
                let timeMs = self.player.time?.value ?? 0
                let lengthMs = self.player.media?.length?.value ?? 0
                self.positionSeconds = Double(timeMs) / 1000.0
                self.durationSeconds = lengthMs > 0 ? Double(lengthMs) / 1000.0 : self.durationSeconds
                if lengthMs <= 0 && pos > 0 && self.durationSeconds == 0 {
                    // Media length not parsed yet — estimate from position
                    // once we have both (VLC parses asynchronously).
                    if pos > 0.02, self.positionSeconds > 0 {
                        self.durationSeconds = self.positionSeconds / Double(pos)
                    }
                }
            }
        }
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let track = currentTrack {
            info[MPMediaItemPropertyTitle] = track.title
            info[MPMediaItemPropertyArtist] = track.artist ?? track.animeTitle
            info[MPMediaItemPropertyAlbumTitle] = track.animeTitle
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Artwork loads asynchronously — filled in when it arrives.
        if let cover = currentTrack?.coverImage, let url = URL(string: cover) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                Task { @MainActor [weak self] in
                    guard let self, self.currentTrack?.coverImage == cover else { return }
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    current[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }.resume()
        }
    }
    #endif
}

// MARK: - VLC delegate

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
extension MusicPlayerManager: VLCMediaPlayerDelegate {

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .playing:
                self.isPlaying = true
                self.isBuffering = false
                self.playbackError = nil
            case .buffering:
                self.isBuffering = true
            case .ended:
                self.isPlaying = false
                self.isBuffering = false
                // Auto-advance — the queue keeps the music going.
                if self.currentIndex < self.queue.count - 1 {
                    self.next()
                } else {
                    self.positionSeconds = self.durationSeconds
                }
            case .stopped:
                self.isPlaying = false
                self.isBuffering = false
            case .error:
                self.isPlaying = false
                self.isBuffering = false
                self.playbackError = "Playback failed — the theme's media couldn't be streamed. Skip or try again."
            default:
                break
            }
            self.updateNowPlayingInfo()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        // The ticker owns steady main-actor position updates.
    }
}
#endif
