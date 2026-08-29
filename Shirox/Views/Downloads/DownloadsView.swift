import Combine

#if os(iOS)
import SwiftUI

/// Downloads tab — v2.14 full layout rework.
///
/// The old page stacked six flat List sections (anime and manga duplicated
/// for every state) and grouped completed downloads by SOURCE MODULE,
/// dumping every episode of every show into one alphabetized pile under a
/// module header. The rework replaces that with:
///
///   - a pinned status header: aggregate progress ring, total speed,
///     transfer size and a Wi-Fi / Cellular / Offline network pill;
///   - All / Anime / Manga filter chips with live counts (appear once both
///     content types exist);
///   - ONE merged "In Progress" section and ONE merged "Failed" section —
///     anime and manga rows interleaved, each row self-describing;
///   - "Retry All" directly in the Failed section header;
///   - completed downloads grouped by SERIES (not module): each show is one
///     row (poster, episode/chapter count, source name) that drills into a
///     per-show page listing everything downloading, failed and downloaded
///     for that title, with a per-show "Delete All";
///   - the module/source is demoted to a caption on rows — in a downloads
///     list you care about WHAT you downloaded, not which source served it.
struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var mdm = MangaDownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var moduleManager: ModuleManager

    /// Mirrors the setting both download managers gate on (v2.13) so the
    /// header can say "Waiting for Wi-Fi" instead of a bare "Waiting".
    @AppStorage("downloadOverWiFiOnly") private var wifiOnly = false

    /// Content filter for the whole page (v2.14).
    @State private var filter: DownloadFilter = .all

    /// Shows the "Clear Completed" confirmation dialog (v2.12). The action
    /// removes every completed anime episode AND manga chapter (with their
    /// files) in one pass; downloading/pending/failed entries stay.
    @State private var showingClearCompletedConfirm = false

    /// The series-level "Delete All" request awaiting confirmation — set
    /// from a show row's swipe action or context menu (v2.14).
    @State private var showDeleteRequest: ShowDeleteRequest?

    // MARK: - Filters

    private enum DownloadFilter: String, CaseIterable {
        case all, anime, manga

        var label: String {
            switch self {
            case .all: return "All"
            case .anime: return "Anime"
            case .manga: return "Manga"
            }
        }

        var icon: String {
            switch self {
            case .all: return "tray.full"
            case .anime: return "tv"
            case .manga: return "book"
            }
        }
    }

    // MARK: - Aggregate stats (drive the pinned status header)

    private var downloadingCount: Int {
        dm.items.filter { $0.state == .downloading }.count
            + mdm.items.filter { $0.state == .downloading }.count
    }

    private var waitingCount: Int {
        dm.items.filter { $0.state == .pending }.count
            + mdm.items.filter { $0.state == .pending }.count
    }

    private var failedTotal: Int {
        dm.items.filter { $0.state == .failed }.count
            + mdm.items.filter { $0.state == .failed }.count
    }

    private var activeTotal: Int { downloadingCount + waitingCount }

    /// Mean progress across everything currently downloading (both types).
    private var activeAverageProgress: Double {
        var sum = 0.0
        var count = 0
        for item in dm.items where item.state == .downloading { sum += item.progress; count += 1 }
        for item in mdm.items where item.state == .downloading { sum += item.progress; count += 1 }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Manga items carry no speed telemetry — the aggregate is anime-only,
    /// and is hidden when it's zero.
    private var aggregateSpeed: Double {
        dm.items.filter { $0.state == .downloading }
            .compactMap { $0.bytesPerSecond }
            .reduce(0, +)
    }

    private var aggregateBytes: (received: Int64, total: Int64)? {
        let downloading = dm.items.filter { $0.state == .downloading && $0.totalBytes != nil }
        guard !downloading.isEmpty else { return nil }
        let received = downloading.compactMap { $0.bytesReceived }.reduce(Int64(0), +)
        let total = downloading.compactMap { $0.totalBytes }.reduce(Int64(0), +)
        return (received, total)
    }

    /// True when the Wi-Fi-only gate is armed AND the device is on a metered
    /// connection — pending rows then say "Waiting for Wi-Fi…".
    private var wifiGated: Bool { wifiOnly && networkMonitor.isOnCellular }

    // MARK: - Row collections (respecting the filter)

    private var activeEntries: [DownloadListEntry] {
        var result: [DownloadListEntry] = []
        if filter != .manga {
            result += dm.items
                .filter { $0.state == .downloading || $0.state == .pending }
                .map { DownloadListEntry.anime($0) }
        }
        if filter != .anime {
            result += mdm.items
                .filter { $0.state == .downloading || $0.state == .pending }
                .map { DownloadListEntry.manga($0) }
        }
        return result.sorted { lhs, rhs in
            if lhs.isDownloading != rhs.isDownloading { return lhs.isDownloading }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.number < rhs.number
        }
    }

    private var failedEntries: [DownloadListEntry] {
        var result: [DownloadListEntry] = []
        if filter != .manga {
            result += dm.items.filter { $0.state == .failed }.map { DownloadListEntry.anime($0) }
        }
        if filter != .anime {
            result += mdm.items.filter { $0.state == .failed }.map { DownloadListEntry.manga($0) }
        }
        return result.sorted { lhs, rhs in
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.number < rhs.number
        }
    }

    // MARK: - Completed, grouped by series

    private var animeShowGroups: [AnimeShowGroup] {
        guard filter != .manga else { return [] }
        let completed = dm.items.filter { $0.state == .completed }
        // Same key style clearCompleted() uses for snapshot orphan cleanup:
        // a series is scoped per (module, title).
        return Dictionary(grouping: completed) { "\($0.moduleId ?? "*")::\($0.mediaTitle)" }
            .map { key, items in
                AnimeShowGroup(
                    id: key,
                    title: items[0].mediaTitle,
                    moduleId: items[0].moduleId,
                    posterURL: items[0].imageUrl,
                    completed: items.sorted { $0.episodeNumber < $1.episodeNumber }
                )
            }
            .sorted { $0.title < $1.title }
    }

    private var mangaShowGroups: [MangaShowGroup] {
        guard filter != .anime else { return [] }
        let completed = mdm.items.filter { $0.state == .completed }
        return Dictionary(grouping: completed) { $0.mangaHref }
            .map { href, items in
                MangaShowGroup(
                    id: href,
                    title: items[0].mangaTitle,
                    moduleId: items[0].moduleId,
                    posterURL: items[0].coverImage,
                    completed: items.sorted { $0.chapterNumber < $1.chapterNumber }
                )
            }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Visibility flags

    private var hasAnyContent: Bool { !dm.items.isEmpty || !mdm.items.isEmpty }

    private var hasBothTypes: Bool { !dm.items.isEmpty && !mdm.items.isEmpty }

    private var filteredHasContent: Bool {
        switch filter {
        case .all: return hasAnyContent
        case .anime: return !dm.items.isEmpty
        case .manga: return !mdm.items.isEmpty
        }
    }

    private var showStatusHeader: Bool { activeTotal > 0 || failedTotal > 0 }

    private var animeCount: Int { dm.items.count }
    private var mangaCount: Int { mdm.items.count }

    private func chipCount(_ f: DownloadFilter) -> Int {
        switch f {
        case .all: return animeCount + mangaCount
        case .anime: return animeCount
        case .manga: return mangaCount
        }
    }

    /// Total completed entries (anime episodes + manga chapters) — drives
    /// the toolbar visibility and the confirmation copy.
    private var completedCount: Int {
        dm.items.filter { $0.state == .completed }.count
            + mdm.items.filter { $0.state == .completed }.count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showStatusHeader || hasBothTypes {
                    headerZone
                }

                if !hasAnyContent {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes and chapters you download will appear here")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !filteredHasContent {
                    ContentUnavailableView(
                        "No \(filter.label) Downloads",
                        systemImage: filter.icon,
                        description: Text("Your \(filter.label.lowercased()) download list is empty")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    downloadList
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
            // Series-level "Delete All" confirm (v2.14). Attached to the
            // outer VStack — the Clear Completed dialog attaches to the
            // List, so the two dialogs never fight over one presentation.
            .confirmationDialog(
                showDeleteRequest.map { "Delete \($0.title)?" } ?? "Delete",
                isPresented: Binding(
                    get: { showDeleteRequest != nil },
                    set: { if !$0 { showDeleteRequest = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete All Downloads", role: .destructive) {
                    guard let request = showDeleteRequest else { return }
                    Haptics.medium()
                    if !request.animeTargets.isEmpty { dm.removeItems(request.animeTargets) }
                    if !request.mangaTargets.isEmpty { mdm.removeItems(request.mangaTargets) }
                    showDeleteRequest = nil
                }
                Button("Cancel", role: .cancel) {
                    showDeleteRequest = nil
                }
            } message: {
                if let request = showDeleteRequest {
                    let total = request.animeTargets.count + request.mangaTargets.count
                    Text("Deletes all \(total) download\(total == 1 ? "" : "s") for this title"
                        + (request.downloadingCount > 0
                           ? ", including \(request.downloadingCount) still downloading"
                           : "")
                        + ". The files are removed from this device.")
                }
            }
        }
    }

    // MARK: - Pinned header zone (status card + filter chips)

    private var headerZone: some View {
        VStack(spacing: 10) {
            if showStatusHeader {
                statusHeaderCard
            }
            if hasBothTypes {
                filterChipRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var statusHeaderCard: some View {
        HStack(spacing: 12) {
            ZStack {
                if downloadingCount > 0 {
                    DownloadRingView(
                        progress: activeAverageProgress,
                        color: .appAccent,
                        icon: nil
                    )
                    .frame(width: 40, height: 40)
                } else if waitingCount > 0 {
                    Image(systemName: "hourglass.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 40, height: 40)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(statusSubtitle.text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(statusSubtitle.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if activeTotal > 0 {
                networkPill
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var statusTitle: String {
        if downloadingCount > 0 {
            var text = "Downloading \(downloadingCount)"
            if waitingCount > 0 { text += " · \(waitingCount) waiting" }
            return text
        }
        if waitingCount > 0 {
            return "\(waitingCount) waiting"
        }
        return "\(failedTotal) failed"
    }

    private var statusSubtitle: (text: String, color: Color) {
        if downloadingCount > 0 {
            var parts: [String] = []
            if aggregateSpeed > 0 {
                parts.append(DownloadItem.formatSpeed(aggregateSpeed))
            }
            if let bytes = aggregateBytes, bytes.total > 0 {
                parts.append("\(DownloadItem.formatBytes(bytes.received)) / \(DownloadItem.formatBytes(bytes.total))")
            }
            if !parts.isEmpty { return (parts.joined(separator: " · "), .secondary) }
            return ("\(Int(activeAverageProgress * 100))%", .secondary)
        }
        if waitingCount > 0 && wifiGated {
            return ("Waiting for Wi-Fi", .orange)
        }
        if waitingCount > 0 {
            return ("Queued", .secondary)
        }
        return ("Retry from the list below", .secondary)
    }

    /// Live network class pill — mirrors the status line wording added under
    /// the Wi-Fi toggle in Downloads settings (v2.13). Only meaningful while
    /// something is queued or transferring.
    private var networkPill: some View {
        let pill: (icon: String, text: String, color: Color) = {
            if networkMonitor.isOffline {
                return ("wifi.slash", "Offline", .red)
            }
            if wifiGated {
                return ("wifi.slash", "Cellular", .orange)
            }
            return ("wifi", "Wi-Fi", .green)
        }()
        return HStack(spacing: 5) {
            Image(systemName: pill.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(pill.text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(pill.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(pill.color.opacity(0.12), in: Capsule())
    }

    private var filterChipRow: some View {
        HStack(spacing: 8) {
            ForEach(DownloadFilter.allCases, id: \.self) { candidate in
                filterChip(candidate)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ candidate: DownloadFilter) -> some View {
        let selected = filter == candidate
        return Button {
            guard filter != candidate else { return }
            Haptics.light()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                filter = candidate
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: candidate.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(candidate.label)
                    .font(.caption.weight(.semibold))
                Text("\(chipCount(candidate))")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .opacity(selected ? 0.85 : 0.6)
            }
            .foregroundStyle(selected ? Color.appAccentForeground : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? Color.appAccent : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - The list

    private var downloadList: some View {
        List {
            if !activeEntries.isEmpty { activeSection }
            if !failedEntries.isEmpty { failedSection }
            if !animeShowGroups.isEmpty || !mangaShowGroups.isEmpty { onDeviceSection }
        }
        .listStyle(.insetGrouped)
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

    private var activeSection: some View {
        Section("In Progress") {
            ForEach(activeEntries) { entry in
                activeRow(entry)
            }
        }
    }

    @ViewBuilder
    private func activeRow(_ entry: DownloadListEntry) -> some View {
        switch entry {
        case .anime(let item):
            NavigationLink {
                DownloadDetailView(item: item)
            } label: {
                AnimeDownloadRow(item: item, waitingForWifi: wifiGated)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { dm.remove(item) } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { dm.remove(item) } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .tint(.red)
            }
        case .manga(let item):
            NavigationLink {
                MangaDownloadDetailView(item: item)
            } label: {
                MangaDownloadRow(item: item, waitingForWifi: wifiGated)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { mdm.remove(item) } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { mdm.remove(item) } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
    }

    private var failedSection: some View {
        Section {
            ForEach(failedEntries) { entry in
                failedRow(entry)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Failed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    Haptics.medium()
                    dm.retryAllFailed()
                    mdm.retryAllFailed()
                } label: {
                    Label("Retry All", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
            .textCase(nil)
        }
    }

    @ViewBuilder
    private func failedRow(_ entry: DownloadListEntry) -> some View {
        switch entry {
        case .anime(let item):
            NavigationLink {
                DownloadDetailView(item: item)
            } label: {
                AnimeDownloadRow(item: item, waitingForWifi: wifiGated)
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
        case .manga(let item):
            NavigationLink {
                MangaDownloadDetailView(item: item)
            } label: {
                MangaDownloadRow(item: item, waitingForWifi: wifiGated)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { mdm.retry(item) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
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
    }

    private var onDeviceSection: some View {
        Section("On This Device") {
            ForEach(animeShowGroups) { group in
                animeShowRow(group)
            }
            ForEach(mangaShowGroups) { group in
                mangaShowRow(group)
            }
        }
    }

    private func animeShowRow(_ group: AnimeShowGroup) -> some View {
        NavigationLink {
            AnimeShowDownloadsView(
                title: group.title,
                posterURL: group.posterURL,
                moduleId: group.moduleId
            )
        } label: {
            ShowRowContent(
                posterURL: group.posterURL,
                title: group.title,
                countText: "\(group.completed.count) episode\(group.completed.count == 1 ? "" : "s")",
                countIcon: "tv",
                moduleName: moduleName(for: group.moduleId)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                requestShowDelete(
                    title: group.title,
                    animeTargets: dm.items.filter { $0.mediaTitle == group.title && $0.moduleId == group.moduleId },
                    mangaTargets: []
                )
            } label: {
                Label("Delete All", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                requestShowDelete(
                    title: group.title,
                    animeTargets: dm.items.filter { $0.mediaTitle == group.title && $0.moduleId == group.moduleId },
                    mangaTargets: []
                )
            } label: {
                Label("Delete All", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func mangaShowRow(_ group: MangaShowGroup) -> some View {
        NavigationLink {
            MangaShowDownloadsView(
                title: group.title,
                posterURL: group.posterURL,
                mangaHref: group.id
            )
        } label: {
            ShowRowContent(
                posterURL: group.posterURL,
                title: group.title,
                countText: "\(group.completed.count) chapter\(group.completed.count == 1 ? "" : "s")",
                countIcon: "book",
                moduleName: moduleName(for: group.moduleId)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                requestShowDelete(
                    title: group.title,
                    animeTargets: [],
                    mangaTargets: mdm.items.filter { $0.mangaHref == group.id }
                )
            } label: {
                Label("Delete All", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                requestShowDelete(
                    title: group.title,
                    animeTargets: [],
                    mangaTargets: mdm.items.filter { $0.mangaHref == group.id }
                )
            } label: {
                Label("Delete All", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func requestShowDelete(
        title: String,
        animeTargets: [DownloadItem],
        mangaTargets: [MangaDownloadItem]
    ) {
        showDeleteRequest = ShowDeleteRequest(
            title: title,
            animeTargets: animeTargets,
            mangaTargets: mangaTargets
        )
    }

    private func moduleName(for id: String?) -> String {
        guard let id, !id.isEmpty else { return "Unknown Source" }
        return moduleManager.modules.first { $0.id == id }?.sourceName ?? id
    }
}

// MARK: - Mixed-list entry (one enum so anime and manga rows can share a
// single sorted ForEach)

private enum DownloadListEntry: Identifiable {
    case anime(DownloadItem)
    case manga(MangaDownloadItem)

    var id: UUID {
        switch self {
        case .anime(let item): return item.id
        case .manga(let item): return item.id
        }
    }

    var isDownloading: Bool {
        switch self {
        case .anime(let item): return item.state == .downloading
        case .manga(let item): return item.state == .downloading
        }
    }

    var title: String {
        switch self {
        case .anime(let item): return item.mediaTitle
        case .manga(let item): return item.mangaTitle
        }
    }

    var number: Double {
        switch self {
        case .anime(let item): return Double(item.episodeNumber)
        case .manga(let item): return item.chapterNumber
        }
    }
}

// MARK: - Show groups + delete request payload

private struct AnimeShowGroup: Identifiable {
    let id: String          // "<moduleId>::<title>"
    let title: String
    let moduleId: String?
    let posterURL: String
    let completed: [DownloadItem]
}

private struct MangaShowGroup: Identifiable {
    let id: String          // mangaHref
    let title: String
    let moduleId: String
    let posterURL: String
    let completed: [MangaDownloadItem]
}

private struct ShowDeleteRequest {
    let title: String
    let animeTargets: [DownloadItem]
    let mangaTargets: [MangaDownloadItem]

    var downloadingCount: Int {
        animeTargets.filter { $0.state == .downloading || $0.state == .pending }.count
            + mangaTargets.filter { $0.state == .downloading || $0.state == .pending }.count
    }
}

// MARK: - Series row content (shared by anime and manga show rows)

private struct ShowRowContent: View {
    let posterURL: String
    let title: String
    let countText: String
    let countIcon: String
    let moduleName: String

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: posterURL)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 50, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: countIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(countText) · \(moduleName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Row views (all states — reused by the main list AND the per-show
// drill-down pages)

struct AnimeDownloadRow: View {
    let item: DownloadItem
    var waitingForWifi: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(episodeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                statusDetail
            }

            Spacer(minLength: 0)

            trailingIcon
        }
    }

    private var episodeLine: String {
        if let episodeTitle = item.episodeTitle, !episodeTitle.isEmpty {
            return "EP \(item.episodeNumber) · \(episodeTitle)"
        }
        return "EP \(item.episodeNumber)"
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .tint(.accentColor)
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
            Text(waitingForWifi ? "Waiting for Wi-Fi…" : "Waiting…")
                .font(.caption2)
                .foregroundStyle(waitingForWifi ? .orange : .secondary)
                .lineLimit(1)
        case .failed:
            HStack(spacing: 8) {
                Text(item.error ?? "Failed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 4)
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
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: item.isHLS ? "folder.fill" : "play.rectangle.fill")
                    .font(.system(size: 9))
                Text(item.isHLS ? "HLS" : "MP4")
                    .font(.system(size: 10, weight: .semibold))
                if let completed = item.completedAt {
                    Text("· \(completed.formatted(date: .numeric, time: .omitted))")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch item.state {
        case .downloading:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .completed:
            EmptyView()
        }
    }
}

struct MangaDownloadRow: View {
    let item: MangaDownloadItem
    var waitingForWifi: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.coverImage)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mangaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.chapterName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                statusDetail
            }

            Spacer(minLength: 0)

            trailingIcon
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .tint(.accentColor)
                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .pending:
            Text(waitingForWifi ? "Waiting for Wi-Fi…" : "Waiting…")
                .font(.caption2)
                .foregroundStyle(waitingForWifi ? .orange : .secondary)
                .lineLimit(1)
        case .failed:
            HStack(spacing: 8) {
                Text(item.error ?? "Failed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    MangaDownloadManager.shared.retry(item)
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
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 9))
                Text("\(max(item.pageFiles.count, item.totalPages)) page\(max(item.pageFiles.count, item.totalPages) == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold))
                if let completed = item.completedAt {
                    Text("· \(completed.formatted(date: .numeric, time: .omitted))")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch item.state {
        case .downloading:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .completed:
            EmptyView()
        }
    }
}

// MARK: - Per-show drill-down (anime)

/// Everything the Downloads tab knows about ONE anime series: a header card
/// (poster, module, counts, on-disk size) followed by that show's rows in
/// every state — in progress, failed, and downloaded — each linking to the
/// download detail page. "Delete All" removes every item for the series in
/// one confirmed action (v2.14).
struct AnimeShowDownloadsView: View {
    let title: String
    let posterURL: String
    let moduleId: String?

    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloadOverWiFiOnly") private var wifiOnly = false
    @State private var confirmingDeleteAll = false

    private var items: [DownloadItem] {
        dm.items.filter { $0.mediaTitle == title && $0.moduleId == moduleId }
    }

    private var inProgress: [DownloadItem] {
        items
            .filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private var failed: [DownloadItem] {
        items.filter { $0.state == .failed }.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private var completed: [DownloadItem] {
        items.filter { $0.state == .completed }.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private var wifiGated: Bool { wifiOnly && networkMonitor.isOnCellular }

    private var onDiskBytes: Int64 {
        completed.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
    }

    var body: some View {
        List {
            Section {
                headerCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { item in
                        NavigationLink {
                            DownloadDetailView(item: item)
                        } label: {
                            AnimeDownloadRow(item: item, waitingForWifi: wifiGated)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { dm.remove(item) } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                            .tint(.red)
                        }
                    }
                }
            }

            if !failed.isEmpty {
                Section("Failed") {
                    ForEach(failed) { item in
                        NavigationLink {
                            DownloadDetailView(item: item)
                        } label: {
                            AnimeDownloadRow(item: item, waitingForWifi: wifiGated)
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

            if !completed.isEmpty {
                Section("Episodes") {
                    ForEach(completed) { item in
                        NavigationLink {
                            DownloadDetailView(item: item)
                        } label: {
                            AnimeDownloadRow(item: item, waitingForWifi: wifiGated)
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
            }

            if items.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing Left",
                        systemImage: "trash",
                        description: Text("All downloads for this series were removed")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !items.isEmpty {
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        }
        .confirmationDialog(
            "Delete all downloads for \(title)?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Haptics.medium()
                let targets = items
                dm.removeItems(targets)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every episode for this series — including any still downloading — and removes the files from this device.")
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(urlString: posterURL)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: "tv")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(completed.count) of \(items.count) episode\(items.count == 1 ? "" : "s") downloaded")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(sourceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if onDiskBytes > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(DownloadItem.formatBytes(onDiskBytes)) on disk")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !failed.isEmpty {
                    Text("\(failed.count) failed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var sourceName: String {
        if let id = moduleId, !id.isEmpty {
            return moduleManager.modules.first { $0.id == id }?.sourceName ?? id
        }
        return "Unknown Source"
    }
}

// MARK: - Per-show drill-down (manga)

/// The manga counterpart of `AnimeShowDownloadsView` (v2.14): header card
/// (cover, source, chapter counts) plus that series' chapters in every
/// state, each linking to `MangaDownloadDetailView`. "Delete All" removes
/// every chapter for the series in one confirmed action.
struct MangaShowDownloadsView: View {
    let title: String
    let posterURL: String
    let mangaHref: String

    @ObservedObject private var mdm = MangaDownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloadOverWiFiOnly") private var wifiOnly = false
    @State private var confirmingDeleteAll = false

    private var items: [MangaDownloadItem] {
        mdm.items.filter { $0.mangaHref == mangaHref }
    }

    private var inProgress: [MangaDownloadItem] {
        items
            .filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.chapterNumber < $1.chapterNumber }
    }

    private var failed: [MangaDownloadItem] {
        items.filter { $0.state == .failed }.sorted { $0.chapterNumber < $1.chapterNumber }
    }

    private var completed: [MangaDownloadItem] {
        items.filter { $0.state == .completed }.sorted { $0.chapterNumber < $1.chapterNumber }
    }

    private var wifiGated: Bool { wifiOnly && networkMonitor.isOnCellular }

    private var moduleId: String { items.first?.moduleId ?? "" }

    var body: some View {
        List {
            Section {
                headerCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { item in
                        NavigationLink {
                            MangaDownloadDetailView(item: item)
                        } label: {
                            MangaDownloadRow(item: item, waitingForWifi: wifiGated)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { mdm.remove(item) } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                            .tint(.red)
                        }
                    }
                }
            }

            if !failed.isEmpty {
                Section("Failed") {
                    ForEach(failed) { item in
                        NavigationLink {
                            MangaDownloadDetailView(item: item)
                        } label: {
                            MangaDownloadRow(item: item, waitingForWifi: wifiGated)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { mdm.retry(item) } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
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
                }
            }

            if !completed.isEmpty {
                Section("Chapters") {
                    ForEach(completed) { item in
                        NavigationLink {
                            MangaDownloadDetailView(item: item)
                        } label: {
                            MangaDownloadRow(item: item, waitingForWifi: wifiGated)
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
                }
            }

            if items.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing Left",
                        systemImage: "trash",
                        description: Text("All downloads for this series were removed")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !items.isEmpty {
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        }
        .confirmationDialog(
            "Delete all downloads for \(title)?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Haptics.medium()
                let targets = items
                mdm.removeItems(targets)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every chapter for this series — including any still downloading — and removes the files from this device.")
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(urlString: posterURL)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: "book")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(completed.count) of \(items.count) chapter\(items.count == 1 ? "" : "s") downloaded")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(sourceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !failed.isEmpty {
                    Text("\(failed.count) failed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var sourceName: String {
        guard !moduleId.isEmpty else { return "Unknown Source" }
        return moduleManager.modules.first { $0.id == moduleId }?.sourceName ?? moduleId
    }
}

#endif
