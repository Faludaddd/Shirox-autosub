#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Custom download detail view — opened when the user taps a download row
/// (in-progress, failed, or completed) in the Downloads tab. Shows a large
/// circular progress ring with percentage, ETA, download speed, file size,
/// and a "Find File" button (opens the iOS Files app at the file location).
///
/// For completed downloads, the ring shows 100% and the "Find File" + "Play"
/// buttons are enabled. For in-progress downloads, the ring animates live.
/// For failed downloads, the ring shows the last progress and a Retry button.
struct DownloadDetailView: View {
    let item: DownloadItem

    @ObservedObject private var dm = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFileShared = false

    /// Live-updating copy of the item from the DownloadManager (so the view
    /// reflects progress changes without being re-initialized).
    private var liveItem: DownloadItem {
        dm.items.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                headerCard
                progressCard
                detailCards
                actionButtons
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(liveItem.mediaTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(urlString: liveItem.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(liveItem.mediaTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(liveItem.episodeTitle ?? "Episode \(liveItem.episodeNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let stream = liveItem.streamTitle {
                    Text(stream)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                statusBadge
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusBadge: some View {
        let (text, color, icon): (String, Color, String) = {
            switch liveItem.state {
            case .downloading: return ("Downloading", .blue, "arrow.down.circle.fill")
            case .pending: return ("Waiting", .orange, "hourglass.fill")
            case .completed: return ("Completed", .green, "checkmark.circle.fill")
            case .failed: return ("Failed", .red, "exclamationmark.triangle.fill")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Progress card (circular ring + ETA)

    private var progressCard: some View {
        VStack(spacing: 16) {
            CircularProgressView(
                progress: liveItem.progress,
                state: liveItem.state
            )
            .frame(width: 160, height: 160)

            if liveItem.state == .downloading || liveItem.state == .pending {
                etaRow
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var etaRow: some View {
        HStack(spacing: 24) {
            if let speed = liveItem.lastSpeedBytesPerSec, speed > 0 {
                VStack(spacing: 2) {
                    Text(formatSpeed(speed))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("Speed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let eta = liveItem.estimatedSecondsRemaining {
                VStack(spacing: 2) {
                    Text(formatETA(eta))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let downloaded = liveItem.bytesDownloaded, let total = liveItem.totalBytes {
                VStack(spacing: 2) {
                    Text("\(formatBytes(downloaded)) / \(formatBytes(total))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("Downloaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Detail cards (file info)

    private var detailCards: some View {
        VStack(spacing: 12) {
            if let fileName = liveItem.fileName {
                DetailRow(icon: "doc.fill", label: "File", value: fileName)
            }
            if let started = liveItem.startedAt {
                DetailRow(icon: "clock.fill", label: "Started", value: started.formatted(date: .omitted, time: .shortened))
            }
            DetailRow(icon: "calendar.fill", label: "Queued", value: liveItem.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = liveItem.completedAt {
                DetailRow(icon: "checkmark.seal.fill", label: "Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
            }
            if liveItem.isHLS {
                DetailRow(icon: "film.fill", label: "Type", value: "HLS Stream")
            } else if liveItem.fileName != nil {
                DetailRow(icon: "film.fill", label: "Type", value: "MP4 Video")
            }
            if let sub = liveItem.relativeSubtitlePath {
                DetailRow(icon: "captions.bubble.fill", label: "Subtitles", value: sub)
            }
            if let err = liveItem.error, liveItem.state == .failed {
                DetailRow(icon: "exclamationmark.triangle.fill", label: "Error", value: err)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if liveItem.state == .completed {
                if let fileURL = downloadedFileURL {
                    Button {
                        shareFile(fileURL)
                    } label: {
                        Label("Find File", systemImage: "folder.badge.magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
                    .controlSize(.large)
                }
            }

            if liveItem.state == .failed {
                Button {
                    dm.retry(liveItem)
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }

            if liveItem.state == .downloading || liveItem.state == .pending {
                Button(role: .destructive) {
                    dm.remove(liveItem)
                    dismiss()
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if liveItem.state == .completed {
                Button(role: .destructive) {
                    dm.remove(liveItem)
                    dismiss()
                } label: {
                    Label("Delete Download", systemImage: "trash.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
            }
        }
    }

    // MARK: - File access

    private var downloadedFileURL: URL? {
        guard let fileName = liveItem.fileName else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads").appendingPathComponent(fileName)
    }

    private func shareFile(_ url: URL) {
        Haptics.light()
        // Present the iOS share sheet / Files app integration. On iOS this
        // opens the system share sheet which includes "Save to Files" as an
        // option — the standard way to "find" a file in the Files app.
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.url = url
        picker.shouldShowFileExtensions = true
        root.present(picker, animated: true)
    }

    // MARK: - Formatting

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 1 { return "—" }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins < 60 {
            return String(format: "%dm %ds", mins, secs)
        }
        let hours = mins / 60
        let remMins = mins % 60
        return String(format: "%dh %dm", hours, remMins)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        } else {
            return "\(bytes) B"
        }
    }
}

// MARK: - Circular Progress Ring

private struct CircularProgressView: View {
    let progress: Double
    let state: DownloadState

    private var displayProgress: Double {
        switch state {
        case .completed: return 1.0
        case .pending: return 0.0
        case .failed: return progress  // show last-known progress
        case .downloading: return progress
        }
    }

    private var ringColor: Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .pending: return .orange
        case .downloading: return .appAccent
        }
    }

    private var statusIcon: String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pending: return "hourglass"
        case .downloading: return "arrow.down.circle.fill"
        }
    }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 10)

            // Progress arc
            Circle()
                .trim(from: 0, to: displayProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: displayProgress)

            // Center content
            VStack(spacing: 4) {
                if state == .downloading {
                    Text("\(Int(displayProgress * 100))%")
                        .font(.system(size: 32, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(ringColor)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(ringColor)
                }
            }
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif
