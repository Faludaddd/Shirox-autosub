#if os(iOS)
import SwiftUI
import UIKit

/// Custom download detail view with circular progress ring, ETA, speed,
/// Find File (share sheet), and rich metadata. Shown when tapping a download row.
struct DownloadDetailView: View {
    let item: DownloadItem

    @ObservedObject private var dm = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    private var liveItem: DownloadItem {
        dm.items.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                ringSection
                infoSection
                actionSection
            }
            .padding(20)
        }
        .navigationTitle(liveItem.mediaTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Header with poster

    private var headerCard: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(urlString: liveItem.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 70, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Progress ring

    private var ringSection: some View {
        VStack(spacing: 12) {
            CircularProgressView(progress: liveItem.progress, state: liveItem.state)
                .frame(width: 140, height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(liveItem.progress * 100)) percent, \(liveItem.state.rawValue)")

            if liveItem.state == .downloading || liveItem.state == .pending {
                HStack(spacing: 20) {
                    statLabel(liveItem.speedFormatted, "Speed")
                    statLabel(liveItem.etaFormatted, "Remaining")
                    if liveItem.totalBytes != nil {
                        statLabel("\(liveItem.bytesReceivedFormatted) / \(liveItem.totalBytesFormatted)", "Downloaded")
                    }
                }
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statLabel(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(spacing: 8) {
            if let fileName = liveItem.fileName {
                infoRow("doc.fill", "File", fileName)
            }
            if liveItem.isHLS {
                infoRow("film.fill", "Type", "HLS Stream")
            } else if liveItem.fileName != nil {
                infoRow("film.fill", "Type", "MP4 Video")
            }
            infoRow("calendar.fill", "Queued", liveItem.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = liveItem.completedAt {
                infoRow("checkmark.seal.fill", "Completed", completed.formatted(date: .abbreviated, time: .shortened))
            }
            if let sub = liveItem.relativeSubtitlePath {
                infoRow("captions.bubble.fill", "Subtitles", sub)
            }
            if let err = liveItem.error, liveItem.state == .failed {
                infoRow("exclamationmark.triangle.fill", "Error", err).foregroundStyle(.red)
            }
        }
    }

    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: 12) {
            if liveItem.state == .completed, let fileURL = downloadedFileURL {
                Button { findFile(fileURL) } label: {
                    Label("Find File", systemImage: "folder.badge.magnifyingglass")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
                .controlSize(.large)

                Button { shareFile(fileURL) } label: {
                    Label("Share File", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if liveItem.state == .failed {
                Button { dm.retry(liveItem) } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }
            if liveItem.state == .downloading || liveItem.state == .pending {
                Button(role: .destructive) { dm.remove(liveItem); dismiss() } label: {
                    Label("Cancel Download", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if liveItem.state == .completed {
                Button(role: .destructive) { dm.remove(liveItem); dismiss() } label: {
                    Label("Delete Download", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
            }
        }
    }

    private var downloadedFileURL: URL? {
        guard let fileName = liveItem.fileName else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads").appendingPathComponent(fileName)
    }

    private func shareFile(_ url: URL) {
        Haptics.light()
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    /// Reveals the file in the iOS Files app via UIDocumentPickerViewController.
    private func findFile(_ url: URL) {
        Haptics.light()
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audiovisualContent, .item])
        picker.shouldShowFileExtensions = true
        root.present(picker, animated: true)
    }
}

private struct CircularProgressView: View {
    let progress: Double
    let state: DownloadState

    private var displayProgress: Double { state == .completed ? 1.0 : progress }
    private var ringColor: Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .pending: return .orange
        case .downloading: return .appAccent
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
            Circle().trim(from: 0, to: displayProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: displayProgress)
            if state == .downloading {
                Text("\(Int(displayProgress * 100))%")
                    .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(ringColor)
            } else {
                Image(systemName: state == .completed ? "checkmark.circle.fill" : state == .failed ? "exclamationmark.triangle.fill" : "hourglass")
                    .font(.system(size: 30))
                    .foregroundStyle(ringColor)
            }
        }
    }
}
#endif
