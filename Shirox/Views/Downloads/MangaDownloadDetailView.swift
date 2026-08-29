#if os(iOS)
import SwiftUI

/// Custom manga download detail page — v2.14 rework, sharing the anime
/// page's design (see `DownloadDetailView`): one hero card with the cover
/// and a live progress-ring badge, a stats strip (pages / progress), a
/// single grouped info card, and state-aware actions:
///   - completed — Read Chapter (opens the reader on the local pages) and
///     Delete
///   - failed — Retry and Remove from List
///   - downloading / pending — Cancel
///
/// Since v2.11 every manga download tap (downloading, completed, or
/// failed) routes here — never to the offline reading page.
struct MangaDownloadDetailView: View {
    let item: MangaDownloadItem

    @ObservedObject private var mdm = MangaDownloadManager.shared
    @ObservedObject private var moduleManager = ModuleManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var readerContext: ReaderContext?

    /// Always render the freshest copy of the item from the manager so
    /// progress, state and error update live while the page is open.
    private var liveItem: MangaDownloadItem {
        mdm.items.first(where: { $0.id == item.id }) ?? item
    }

    private var moduleName: String {
        if !liveItem.moduleId.isEmpty {
            return moduleManager.modules.first(where: { $0.id == liveItem.moduleId })?.sourceName
                ?? liveItem.moduleId
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

    private var ringIcon: String? {
        switch liveItem.state {
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .pending: return "hourglass"
        case .downloading: return nil
        }
    }

    private var pagesOnDisk: Int {
        liveItem.state == .completed
            ? liveItem.pageFiles.count
            : Int((liveItem.progress * Double(max(liveItem.totalPages, 1))).rounded())
    }

    private var totalPages: Int {
        max(liveItem.totalPages, liveItem.pageFiles.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                statsCard
                infoCard
                actionSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(liveItem.mangaTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
    }

    // MARK: - Hero (cover + ring badge + title block)

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(urlString: liveItem.coverImage)
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
            .padding(.trailing, 10)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                DownloadStatusBadge(
                    text: status.text,
                    color: status.color,
                    systemImage: status.icon
                )

                Text(liveItem.mangaTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(liveItem.chapterName)
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
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Stats strip

    private var statsCard: some View {
        HStack(spacing: 0) {
            DownloadStatBlock(value: "\(pagesOnDisk) / \(totalPages)", label: "Pages")
            statDivider
            DownloadStatBlock(value: "\(Int(liveItem.progress * 100))%", label: "Progress")
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
        rows.append(DownloadInfoRow(icon: "book.fill", label: "Chapter", value: liveItem.chapterName))
        rows.append(DownloadInfoRow(
            icon: "square.grid.2x2.fill",
            label: "Pages",
            value: "\(totalPages) page\(totalPages == 1 ? "" : "s")"
        ))
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
                Button {
                    readChapter()
                } label: {
                    Label("Read Chapter", systemImage: "book.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
                .controlSize(.large)

                Button(role: .destructive) {
                    mdm.remove(liveItem)
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
                    mdm.retry(liveItem)
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button(role: .destructive) {
                    mdm.remove(liveItem)
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
                    mdm.remove(liveItem)
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

    // MARK: - Reader launching

    /// Builds a ReaderContext from the chapters this manga has on disk (so
    /// next/previous navigation inside the reader stays offline) and opens
    /// the reader on the tapped chapter, resuming the last-read page if the
    /// user was mid-chapter.
    private func readChapter() {
        Haptics.light()
        let chapters = mdm.downloadedChapters(forMangaHref: liveItem.mangaHref)
        guard let idx = chapters.firstIndex(where: { $0.href == liveItem.chapterHref }) else {
            ToastManager.shared.show(
                title: "Manga",
                message: "Downloaded pages are missing — re-download to read",
                icon: "exclamationmark.circle.fill",
                iconColor: .red
            )
            return
        }

        let last = MangaProgressManager.shared.lastRead(for: liveItem.mangaHref)
        let isResume = last?.chapterHref == liveItem.chapterHref

        readerContext = ReaderContext(
            mangaTitle: liveItem.mangaTitle,
            mangaHref: liveItem.mangaHref,
            coverImage: liveItem.coverImage,
            moduleId: liveItem.moduleId,
            chapters: chapters,
            chapterIndex: idx,
            resumePage: isResume ? last?.pageIndex : nil,
            resumeFraction: isResume ? last?.pageFraction : nil,
            match: nil
        )
    }
}
#endif
