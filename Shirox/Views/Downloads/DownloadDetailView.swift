#if os(iOS)
import SwiftUI
import UIKit

/// Custom download detail view with circular progress ring, ETA, speed,
/// and Find File button. Shown when tapping a download row.
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

    private var ringSection: some View {
        VStack(spacing: 12) {
            CircularProgressView(progress: liveItem.progress, state: liveItem.state)
                .frame(width: 160, height: 160)

            if liveItem.state == .downloading {
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

    private var infoSection: some View {
        VStack(spacing: 8) {
            if let fileName = liveItem.fileName {
                infoRow("doc.fill", "File", fileName)
            }
            infoRow("calendar.fill", "Queued", liveItem.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = liveItem.completedAt {
                infoRow("checkmark.seal.fill", "Completed", completed.formatted(date: .abbreviated, time: .shortened))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: 12) {
            if liveItem.state == .completed, let fileURL = downloadedFileURL {
                Button { shareFile(fileURL) } label: {
                    Label("Find File", systemImage: "folder.badge.magnifyingglass")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
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
                    .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(ringColor)
            } else {
                Image(systemName: state == .completed ? "checkmark.circle.fill" : state == .failed ? "exclamationmark.triangle.fill" : "hourglass")
                    .font(.system(size: 32))
                    .foregroundStyle(ringColor)
            }
        }
    }
}
#endif
