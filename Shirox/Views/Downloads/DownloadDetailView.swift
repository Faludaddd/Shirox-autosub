#if os(iOS)
import SwiftUI
import UIKit

/// Custom download detail page — v2.14 rework.
///
/// One hero card (poster with a live progress-ring badge, title block and
/// status), a stats strip while transferring, a single grouped info card,
/// and state-aware actions. The anime and manga detail pages share the
/// components at the bottom of this file, so both halves of the Downloads
/// tab look and behave identically.
///
/// Shown when tapping any anime download row (in-progress, completed, or
/// failed) — the ring badge, file metadata, ETA/speed, Find File / Share
/// File actions, Retry (failed) / Cancel (downloading) / Delete
/// (completed) buttons all live here.
struct DownloadDetailView: View {
    let item: DownloadItem

    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var moduleManager = ModuleManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Always render the freshest copy of the item from the manager so
    /// progress, state and error update live while the page is open.
    private var liveItem: DownloadItem {
        dm.items.first(where: { $0.id == item.id }) ?? item
    }

    private var moduleName: String {
        if let id = liveItem.moduleId, !id.isEmpty {
            return moduleManager.modules.first { $0.id == id }?.sourceName ?? id
        }
        return "Unknown Source"
    }

    private var status: (text: String, color: Color, icon: String) {
        switch liveItem.state {
        case .downloading: return ("Downloading", .blue, "arrow.down.circle.fill")
        case .pending: return ("Waiting", .orange, "hourglass.fill")
        case .completed: return ("Completed", .green, "checkmark.circle.fill")
        case .failed: return ("Failed", .red, "exclamationmark.triangle.fill")
        }
    }

    /// nil only while downloading — the ring then renders its live
    /// percentage instead of a state glyph.
    private var ringIcon: String? {
        switch liveItem.state {
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .pending: return "hourglass"
        case .downloading: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                if liveItem.state == .downloading || liveItem.state == .pending {
                    statsCard
                }
                infoCard
                actionSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(liveItem.mediaTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero (poster + ring badge + title block)

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: liveItem.imageUrl)
                    .aspectRatio(2/3, contentMode: .fit)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 2)

                DownloadRingView(
                    progress: liveItem.state == .completed ? 1 : liveItem.progress,
                    color: status.color,
                    icon: ringIcon
                )
                .frame(width: 44, height: 44)
                .background(Circle().fill(.thinMaterial))
                .offset(x: 15, y: 15)
            }
            // Layout slack so the offset ring badge stays inside the card
            // and never clips against the text column.
            .padding(.trailing, 10)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                DownloadStatusBadge(
                    text: status.text,
                    color: status.color,
                    systemImage: status.icon
                )

                Text(liveItem.mediaTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(liveItem.episodeTitle ?? "EP \(liveItem.episodeNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(moduleName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let stream = liveItem.streamTitle {
                    HStack(spacing: 5) {
                        Image(systemName: "film.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(stream)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Stats strip (transfers only)

    private var statsCard: some View {
        HStack(spacing: 0) {
            DownloadStatBlock(value: liveItem.speedFormatted, label: "Speed")
            statDivider
            DownloadStatBlock(
                value: liveItem.state == .downloading ? liveItem.etaFormatted : "--",
                label: "Remaining"
            )
            if liveItem.totalBytes != nil {
                statDivider
                DownloadStatBlock(
                    value: "\(liveItem.bytesReceivedFormatted) / \(liveItem.totalBytesFormatted)",
                    label: "Downloaded"
                )
            }
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: 30)
    }

    // MARK: - Info card

    private var infoRows: [DownloadInfoRow] {
        var rows: [DownloadInfoRow] = []
        if let fileName = liveItem.fileName {
            rows.append(DownloadInfoRow(icon: "doc.fill", label: "File", value: fileName))
        }
        if liveItem.isHLS {
            rows.append(DownloadInfoRow(icon: "film.fill", label: "Type", value: "HLS Stream"))
        } else if liveItem.fileName != nil {
            rows.append(DownloadInfoRow(icon: "film.fill", label: "Type", value: "MP4 Video"))
        }
        rows.append(DownloadInfoRow(icon: "square.stack.3d.up.fill", label: "Module", value: moduleName))
        rows.append(DownloadInfoRow(
            icon: "calendar.fill",
            label: "Queued",
            value: liveItem.createdAt.formatted(date: .abbreviated, time: .shortened)
        ))
        if let completed = liveItem.completedAt {
            rows.append(DownloadInfoRow(
                icon: "checkmark.seal.fill",
                label: "Completed",
                value: completed.formatted(date: .abbreviated, time: .shortened)
            ))
        }
        if let sub = liveItem.relativeSubtitlePath {
            rows.append(DownloadInfoRow(icon: "captions.bubble.fill", label: "Subtitles", value: sub))
        }
        if let err = liveItem.error, liveItem.state == .failed {
            rows.append(DownloadInfoRow(
                icon: "exclamationmark.triangle.fill",
                label: "Error",
                value: err,
                isAlert: true
            ))
        }
        return rows
    }

    private var infoCard: some View {
        DownloadInfoCard(rows: infoRows)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: 12) {
            switch liveItem.state {
            case .completed:
                if let fileURL = downloadedFileURL {
                    HStack(spacing: 12) {
                        Button {
                            findFile(fileURL)
                        } label: {
                            Label("Find File", systemImage: "folder.badge.magnifyingglass")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            shareFile(fileURL)
                        } label: {
                            Label("Share File", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appAccent)
                        .controlSize(.large)
                    }
                }
                Button(role: .destructive) {
                    dm.remove(liveItem)
                    dismiss()
                } label: {
                    Label("Delete Download", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)

            case .failed:
                Button {
                    dm.retry(liveItem)
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button(role: .destructive) {
                    dm.remove(liveItem)
                    dismiss()
                } label: {
                    Label("Remove from List", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)

            case .downloading, .pending:
                Button(role: .destructive) {
                    dm.remove(liveItem)
                    dismiss()
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
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

// MARK: - Shared download-detail components (anime + manga pages, v2.14)

/// Compact capsule status badge — one look across both detail pages.
struct DownloadStatusBadge: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Small progress ring used as a badge on the hero poster (and as the
/// aggregate indicator in the Downloads tab status header). While
/// `icon == nil` the ring renders its live percentage instead of a glyph.
struct DownloadRingView: View {
    let progress: Double
    let color: Color
    let icon: String?

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: clamped)
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                Text("\(Int(clamped * 100))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
        }
    }
}

/// One labelled value in the horizontal stats strip.
struct DownloadStatBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single key/value line inside the grouped info card.
struct DownloadInfoRow: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    var isAlert = false
}

/// One grouped card of key/value rows separated by hairline dividers —
/// replaces the old stack of individually-boxed rows.
struct DownloadInfoCard: View {
    let rows: [DownloadInfoRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Image(systemName: row.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(row.isAlert ? .red : .secondary)
                        .frame(width: 24)
                    Text(row.label)
                        .font(.subheadline)
                        .foregroundStyle(row.isAlert ? .red : .secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(row.isAlert ? .red : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                if row.id != rows.last?.id {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
#endif
