#if os(iOS)
import SwiftUI

/// Custom manga download detail view — the manga counterpart of the anime
/// `DownloadDetailView` (v2.11).
///
/// Previously every manga row in the Downloads tab pushed
/// `MangaDetailView(offlineChapters:)` — the offline reading page — which is
/// NOT the custom download page. Now all manga download taps (downloading,
/// completed, or failed) route here, mirroring the anime flow:
///   - header card with the manga cover, title, chapter name and status badge
///   - circular progress ring with page stats
///   - info section (chapter, module, pages, queued/completed dates, error)
///   - actions: Read Chapter (completed — opens the reader on the local
///     pages), Delete (completed), Cancel (downloading/pending),
///     Retry (failed)
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
        moduleManager.modules.first(where: { $0.id == liveItem.moduleId })?.sourceName
            ?? (liveItem.moduleId.isEmpty ? "Unknown Source" : liveItem.moduleId)
    }

    private var pagesOnDisk: Int {
        liveItem.state == .completed ? liveItem.pageFiles.count : Int((liveItem.progress * Double(max(liveItem.totalPages, 1))).rounded())
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
        .navigationTitle(liveItem.mangaTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismiss() }
            }
        }
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
    }

    // MARK: - Header with cover

    private var headerCard: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(urlString: liveItem.coverImage)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 70, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(liveItem.mangaTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(liveItem.chapterName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(moduleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            MangaDownloadRing(progress: liveItem.progress, state: liveItem.state)
                .frame(width: 140, height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(liveItem.progress * 100)) percent, \(liveItem.state.rawValue)")

            HStack(spacing: 20) {
                statLabel("\(pagesOnDisk) / \(max(liveItem.totalPages, liveItem.pageFiles.count))", "Pages")
                statLabel("\(Int(liveItem.progress * 100))%", "Progress")
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
            infoRow("book.fill", "Chapter", liveItem.chapterName)
            infoRow("square.grid.2x2.fill", "Pages", "\(max(liveItem.pageFiles.count, liveItem.totalPages)) page\(max(liveItem.pageFiles.count, liveItem.totalPages) == 1 ? "" : "s")")
            infoRow("square.stack.3d.up.fill", "Module", moduleName)
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
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: 12) {
            if liveItem.state == .completed {
                Button { readChapter() } label: {
                    Label("Read Chapter", systemImage: "book.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
                .controlSize(.large)

                Button(role: .destructive) { mdm.remove(liveItem); dismiss() } label: {
                    Label("Delete Download", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            }
            if liveItem.state == .failed {
                Button { mdm.retry(liveItem) } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button(role: .destructive) { mdm.remove(liveItem); dismiss() } label: {
                    Label("Remove from List", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            }
            if liveItem.state == .downloading || liveItem.state == .pending {
                Button(role: .destructive) { mdm.remove(liveItem); dismiss() } label: {
                    Label("Cancel Download", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
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

// MARK: - Ring

private struct MangaDownloadRing: View {
    let progress: Double
    let state: MangaDownloadState

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
