import Combine

#if os(iOS)
import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var mdm = MangaDownloadManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager

    /// Shows the "Clear Completed" confirmation dialog (v2.12). The action
    /// removes every completed anime episode AND manga chapter (with their
    /// files) in one pass; downloading/pending/failed entries stay.
    @State private var showingClearCompletedConfirm = false

    // MARK: - Grouping

    private struct MediaGroup: Identifiable {
        let id: String
        let mediaTitle: String
        let imageUrl: String
        let items: [DownloadItem]
    }

    private struct ModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let iconUrl: String?
        let iconData: String?
        let mediaGroups: [MediaGroup]
    }

    private var inProgress: [DownloadItem] {
        dm.items.filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var failed: [DownloadItem] {
        dm.items.filter { $0.state == .failed }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var moduleGroups: [ModuleGroup] {
        let completed = dm.items.filter { $0.state == .completed }
        let byModule = Dictionary(grouping: completed) { $0.moduleId ?? "" }

        return byModule.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let moduleName = module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId)

            let byMedia = Dictionary(grouping: items) { $0.mediaTitle }
            let mediaGroups = byMedia.map { title, eps in
                MediaGroup(
                    id: title,
                    mediaTitle: title,
                    imageUrl: eps.first?.imageUrl ?? "",
                    items: eps.sorted { $0.episodeNumber < $1.episodeNumber }
                )
            }.sorted { $0.mediaTitle < $1.mediaTitle }

            return ModuleGroup(
                id: moduleId,
                moduleName: moduleName,
                iconUrl: module?.iconUrl,
                iconData: module?.iconData,
                mediaGroups: mediaGroups
            )
        }.sorted { $0.moduleName < $1.moduleName }
    }

    // MARK: - Manga grouping

    private struct MangaGroup: Identifiable {
        let id: String            // mangaHref
        let mangaTitle: String
        let coverImage: String
        let moduleId: String
        let items: [MangaDownloadItem]
    }

    private struct MangaModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let iconUrl: String?
        let iconData: String?
        let mangaGroups: [MangaGroup]
    }

    private var mangaInProgress: [MangaDownloadItem] {
        mdm.items.filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.mangaTitle < $1.mangaTitle }
    }
    private var mangaFailed: [MangaDownloadItem] {
        mdm.items.filter { $0.state == .failed }.sorted { $0.mangaTitle < $1.mangaTitle }
    }

    private var mangaModuleGroups: [MangaModuleGroup] {
        let completed = mdm.items.filter { $0.state == .completed }
        return Dictionary(grouping: completed) { $0.moduleId }.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let byManga = Dictionary(grouping: items) { $0.mangaHref }
            let groups = byManga.map { href, chs in
                MangaGroup(
                    id: href, mangaTitle: chs.first?.mangaTitle ?? href,
                    coverImage: chs.first?.coverImage ?? "", moduleId: moduleId,
                    items: chs.sorted { $0.chapterNumber < $1.chapterNumber })
            }.sorted { $0.mangaTitle < $1.mangaTitle }
            return MangaModuleGroup(
                id: moduleId,
                moduleName: module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId),
                iconUrl: module?.iconUrl, iconData: module?.iconData, mangaGroups: groups)
        }.sorted { $0.moduleName < $1.moduleName }
    }

    // MARK: - Body

    /// Builds the destination view for a tapped DownloadItem.
    ///
    /// The custom Anime Downloads page (`DownloadDetailView`) is the
    /// single destination for ANY anime download tap — in-progress,
    /// completed, or failed. It renders the circular progress ring,
    /// file metadata, ETA/speed, "Find File" / "Share File" actions,
    /// Retry (failed) / Cancel (downloading) / Delete (completed)
    /// buttons, and the existing `DownloadItem` data is passed straight
    /// through — so the downloaded episode's metadata, file name, and
    /// progress are preserved.
    ///
    /// v2.11 — manga downloads get the same treatment: every manga row
    /// (downloading, completed, failed) now routes to the custom
    /// `MangaDownloadDetailView` (ring, page stats, Read Chapter /
    /// Retry / Cancel / Delete) instead of pushing the offline reading
    /// page (`MangaDetailView` with offlineChapters) that only lists
    /// downloaded chapters.
    @ViewBuilder
    private func detailDestination(for item: DownloadItem) -> some View {
        DownloadDetailView(item: item)
    }

    @ViewBuilder
    private func mangaDetailDestination(for item: MangaDownloadItem) -> some View {
        MangaDownloadDetailView(item: item)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dm.items.isEmpty && mdm.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes and chapters you download will appear here")
                    )
                } else {
                    List {
                        // Downloading / Pending — tappable to open the custom
                        // download detail page (ring, stats, cancel).
                        if !inProgress.isEmpty {
                            Section("Downloading") {
                                ForEach(inProgress) { item in
                                    NavigationLink {
                                        detailDestination(for: item)
                                    } label: {
                                        DownloadProgressRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { dm.remove(item) } label: {
                                            Label("Cancel Download", systemImage: "xmark.circle")
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { dm.remove(item) } label: {
                                            Label("Cancel", systemImage: "xmark")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }

                        // Completed — grouped by module → media → episodes.
                        // Tapping an episode opens the custom download detail
                        // page (progress ring, file info, Find File / Share
                        // File, Delete).
                        ForEach(moduleGroups) { moduleGroup in
                            Section {
                                ForEach(moduleGroup.mediaGroups) { mediaGroup in
                                    ForEach(mediaGroup.items) { item in
                                        completedEpisodeRow(item)
                                    }
                                }
                            } header: {
                                ModuleSectionHeader(
                                    name: moduleGroup.moduleName,
                                    iconUrl: moduleGroup.iconUrl,
                                    iconData: moduleGroup.iconData
                                )
                            }
                        }

                        // Failed — tappable to open the custom download detail
                        // page for retry or to inspect what failed.
                        if !failed.isEmpty {
                            Section("Failed") {
                                ForEach(failed) { item in
                                    NavigationLink {
                                        detailDestination(for: item)
                                    } label: {
                                        DownloadProgressRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { dm.retry(item) } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                        }
                                        Button(role: .destructive) { dm.remove(item) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { dm.remove(item) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }

                        // Manga — in progress (custom download detail page)
                        if !mangaInProgress.isEmpty {
                            Section("Downloading Manga") {
                                ForEach(mangaInProgress) { item in
                                    NavigationLink {
                                        mangaDetailDestination(for: item)
                                    } label: {
                                        MangaDownloadProgressRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { mdm.remove(item) } label: {
                                            Label("Cancel", systemImage: "xmark")
                                        }.tint(.red)
                                    }
                                }
                            }
                        }

                        // Manga — completed (module → manga → chapters).
                        // v2.11 — every chapter is its own row (mirroring the
                        // anime per-episode layout) and taps open the custom
                        // MangaDownloadDetailView with its Read Chapter /
                        // Delete actions — no more offline reading page.
                        ForEach(mangaModuleGroups) { moduleGroup in
                            Section {
                                ForEach(moduleGroup.mangaGroups) { mediaGroup in
                                    ForEach(mediaGroup.items) { item in
                                        completedMangaChapterRow(item)
                                    }
                                }
                            } header: {
                                ModuleSectionHeader(name: moduleGroup.moduleName, iconUrl: moduleGroup.iconUrl, iconData: moduleGroup.iconData)
                            }
                        }

                        // Manga — failed (custom download detail page with
                        // Retry / Remove)
                        if !mangaFailed.isEmpty {
                            Section("Failed Manga") {
                                ForEach(mangaFailed) { item in
                                    NavigationLink {
                                        mangaDetailDestination(for: item)
                                    } label: {
                                        MangaDownloadProgressRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { mdm.remove(item) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }.tint(.red)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                // v2.12 — Clear Completed. The only bulk action the page was
                // missing: swiping rows one by one after a 50-episode batch
                // download was misery. Hidden while nothing is completed.
                // NOTE: the `if` lives INSIDE the ToolbarItem's view content
                // (ViewBuilder.buildIf, iOS 13+) — an `if` directly in the
                // toolbar builder needs ToolbarContentBuilder.buildIf, which
                // is iOS 16+ and this target ships iOS 15.
                ToolbarItem(placement: .primaryAction) {
                    if completedCount > 0 {
                        Button {
                            showingClearCompletedConfirm = true
                        } label: {
                            Label("Clear Completed", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            .confirmationDialog(
                "Clear \(completedCount) Completed Download\(completedCount == 1 ? "" : "s")?",
                isPresented: $showingClearCompletedConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Completed", role: .destructive) {
                    Haptics.medium()
                    dm.clearCompleted()
                    mdm.clearCompleted()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the files for all completed episodes and chapters from this device. Downloads still in progress, waiting, or failed are kept.")
            }
        }
    }

    /// Total completed entries (anime episodes + manga chapters) — drives
    /// the toolbar visibility and the confirmation copy.
    private var completedCount: Int {
        dm.items.filter { $0.state == .completed }.count
            + mdm.items.filter { $0.state == .completed }.count
    }

    /// A completed manga chapter row — extracted for the same
    /// type-checker-budget reason as `completedEpisodeRow` above.
    @ViewBuilder
    private func completedMangaChapterRow(_ item: MangaDownloadItem) -> some View {
        NavigationLink {
            mangaDetailDestination(for: item)
        } label: {
            MangaDownloadProgressRow(item: item)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { mdm.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { mdm.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// A completed anime episode row. Extracted from the three-level
    /// ForEach nesting in `body` (module → media → episode) because the
    /// whole List expression was tipping the Swift type-checker over its
    /// time budget once the toolbar/confirmation dialog landed (v2.12 —
    /// "unable to type-check this expression in reasonable time").
    @ViewBuilder
    private func completedEpisodeRow(_ item: DownloadItem) -> some View {
        NavigationLink {
            detailDestination(for: item)
        } label: {
            DownloadProgressRow(item: item)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { dm.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { dm.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }
}

// MARK: - Module Section Header

private struct ModuleSectionHeader: View {
    let name: String
    let iconUrl: String?
    let iconData: String?

    var body: some View {
        HStack(spacing: 6) {
            CachedAsyncImage(urlString: iconUrl ?? "", base64String: iconData)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
                .lineLimit(1)
        }
    }
}

// MARK: - Progress Row (downloading / pending / failed)

private struct DownloadProgressRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.episodeTitle ?? "EP \(item.episodeNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                switch item.state {
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.accentColor)
                            .frame(maxWidth: .infinity, minHeight: 6)
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if item.speedFormatted != "--" {
                        Text("\(item.speedFormatted) · \(item.etaFormatted) left")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .pending:
                    Text("Waiting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                case .failed:
                    HStack(spacing: 8) {
                        Text("Failed")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            DownloadManager.shared.retry(item)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.appAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                default:
                    EmptyView()
                }
            }

            Spacer()

            switch item.state {
            case .downloading:
                ProgressView().controlSize(.small)
            case .pending:
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Manga Progress Row (downloading / pending / failed)

private struct MangaDownloadProgressRow: View {
    let item: MangaDownloadItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.coverImage)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mangaTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.chapterName).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                switch item.state {
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress).tint(.accentColor)
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                case .pending:
                    Text("Waiting…").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                case .failed:
                    HStack(spacing: 8) {
                        Text("Failed").font(.caption2.weight(.semibold)).foregroundStyle(.red).lineLimit(1)
                        Spacer()
                        Button { MangaDownloadManager.shared.retry(item) } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.bold()).foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.appAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                default:
                    EmptyView()
                }
            }
            Spacer()
            switch item.state {
            case .downloading: ProgressView().controlSize(.small)
            case .pending: Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default: EmptyView()
            }
        }
    }
}

#endif
