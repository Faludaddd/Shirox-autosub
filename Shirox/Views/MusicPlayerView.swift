import SwiftUI

// MARK: - Music player surfaces
//
// The playback UI: a mini bar that floats above the tab bar whenever a
// track is loaded, and the expanded player (full screen cover) it opens.
// Both surfaces read the shared MusicPlayerManager — playback continues
// while the user browses anywhere in the app.

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
/// VLC's video drawable — a plain UIView the framework renders into.
struct MusicVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        MusicPlayerManager.shared.attachVideoSurface(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        MusicPlayerManager.shared.detachVideoSurface(uiView)
    }
}
#endif

// MARK: - Mini player bar

/// Slim "now playing" bar above the tab bar. Tap to expand; stop with the
/// trailing xmark; play/pause and next without expanding.
struct MusicMiniPlayerBar: View {
    @ObservedObject private var player = MusicPlayerManager.shared

    var body: some View {
        if let track = player.currentTrack, !player.isExpanded {
            HStack(spacing: 10) {
                // Artwork with a live play-state overlay.
                ZStack {
                    CachedAsyncImage(urlString: track.coverImage ?? "")
                        .frame(width: 42, height: 42)
                        .clipped()
                    if player.isBuffering || !player.isPlaying {
                        Rectangle().fill(Color.black.opacity(0.35))
                    }
                    if player.isBuffering {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.7)
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                // Title / artist.
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(track.artist ?? track.animeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { player.isExpanded = true }

                Spacer(minLength: 0)

                // Play / pause.
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Next.
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(player.currentIndex < player.queue.count - 1 ? 1 : 0.3)
                .disabled(player.currentIndex >= player.queue.count - 1)

                // Stop / clear.
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Expanded player sheet

/// The full player: artwork / video, seek bar, transport controls, the
/// upcoming queue, and the anime navigation — all reading the shared
/// player manager.
struct MusicPlayerSheet: View {
    @ObservedObject private var player = MusicPlayerManager.shared

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if let track = player.currentTrack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Stage: video (when enabled) or cover art.
                        stage(track)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)

                        // Track info.
                        infoSection(track)

                        // Transport.
                        transportSection

                        // Queue.
                        if player.queue.count > 1 {
                            queueSection
                        }

                        // Honest failure message.
                        if let error = player.playbackError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        // Attribution + capability note.
                        Text("Streaming from AnimeThemes · Opus/WebM via VLCKit")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 20)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("Nothing playing")
                        .font(.headline)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    player.isExpanded = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse player")
            .padding(.leading, 8)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop playback")
            .padding(.trailing, 8)
        }
    }

    // MARK: - Stage (video / artwork)

    @ViewBuilder
    private func stage(_ track: MusicTrack) -> some View {
        Group {
            #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(VLCKitSPM)
            if player.videoMode, track.videoLink != nil {
                MusicVideoSurface()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                artworkStage(track)
            }
            #else
            artworkStage(track)
            #endif
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }

    private func artworkStage(_ track: MusicTrack) -> some View {
        ZStack {
            CachedAsyncImage(urlString: track.coverImage ?? "")
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.55),
                            .init(color: Color(.systemBackground).opacity(0.85), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            if player.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                    .shadow(radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Info

    private func infoSection(_ track: MusicTrack) -> some View {
        VStack(spacing: 8) {
            // Type badge + quality + episodes (only real data).
            HStack(spacing: 6) {
                Text(track.themeSlug)
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.appAccent.opacity(0.15)))
                    .foregroundStyle(Color.appAccent)
                if let quality = track.qualityLabel {
                    Text(quality)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                if let episodes = track.episodesBadge {
                    Text("eps \(episodes)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }

            Text(track.title)
                .font(.title2.weight(.heavy))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(track.artist ?? track.animeTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Anime navigation (the provider's exact AniList mapping).
            if let anilistId = track.anilistAnimeId, !track.animeTitle.isEmpty {
                NavigationLink {
                    AniListDetailView(mediaId: anilistId)
                } label: {
                    HStack(spacing: 5) {
                        Text(track.animeTitle)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.appAccent.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Transport

    private var transportSection: some View {
        VStack(spacing: 14) {
            // Seek bar + times.
            VStack(spacing: 5) {
                MusicSeekSlider(
                    position: player.positionSeconds,
                    duration: player.durationSeconds) { target in
                    player.seek(to: target)
                }

                HStack {
                    Text(Self.timeString(player.positionSeconds))
                    Spacer()
                    Text(Self.timeString(player.durationSeconds))
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            // Main controls.
            HStack(spacing: 34) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.queue.isEmpty)
                .opacity(player.queue.isEmpty ? 0.35 : 1)

                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.appAccent, Color.appAccent.opacity(0.7)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)
                            .shadow(color: Color.appAccent.opacity(0.35), radius: 12, y: 5)
                        if player.isBuffering {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.1)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!player.playbackAvailable)
                .opacity(player.playbackAvailable ? 1 : 0.4)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.currentIndex >= player.queue.count - 1)
                .opacity(player.currentIndex >= player.queue.count - 1 ? 0.35 : 1)
            }
            .frame(maxWidth: .infinity)

            // Video / audio toggle (only when the theme has video).
            if player.currentTrack?.videoLink != nil, player.playbackAvailable {
                HStack(spacing: 6) {
                    Image(systemName: player.videoMode ? "video.fill" : "waveform")
                        .font(.caption.weight(.bold))
                    Text(player.videoMode ? "Video" : "Audio only")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.selection()
                    player.setVideoMode(!player.videoMode)
                }
            }

            if !player.playbackAvailable {
                Text("Playback isn't available on this build — browse the catalog, play on iPhone or iPad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next")
                .font(.headline.weight(.bold))
                .padding(.horizontal, 24)
            VStack(spacing: 8) {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 10) {
                        ZStack {
                            CachedAsyncImage(urlString: track.coverImage ?? "")
                                .frame(width: 38, height: 38)
                                .clipped()
                            if index == player.currentIndex {
                                Rectangle().fill(Color.black.opacity(0.4))
                                MusicPlayingIndicator()
                            }
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(track.artist ?? track.animeTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if index == player.currentIndex {
                            Circle().fill(Color.appAccent).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index == player.currentIndex
                                  ? Color.appAccent.opacity(0.08)
                                  : Color(.secondarySystemGroupedBackground))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard index != player.currentIndex else { return }
                        // Jump within the queue.
                        player.play(track: track, queue: player.queue)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Seek slider

/// Custom seek slider matching the app's design language (the system
/// slider's tint/knob don't fit the player's look).
struct MusicSeekSlider: View {
    let position: Double
    let duration: Double
    var onSeek: (Double) -> Void

    @State private var dragValue: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (dragValue ?? position) / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(
                        LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.75)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(5, width * progress), height: 5)
                Circle()
                    .fill(Color.appAccent)
                    .frame(width: dragValue != nil ? 18 : 14, height: 14)
                    .shadow(color: Color.appAccent.opacity(0.3), radius: 4, y: 1)
                    .offset(x: min(max(0, width * progress - 7), width - 14))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        dragValue = fraction * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        let target = fraction * duration
                        dragValue = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.15), value: progress)
    }
}
