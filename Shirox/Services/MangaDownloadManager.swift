#if os(iOS)
import Foundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class MangaDownloadManager: ObservableObject {
    static let shared = MangaDownloadManager()

    @Published private(set) var items: [MangaDownloadItem] = []

    /// Wi-Fi-only downloads (v2.13) — same key as the anime manager so one
    /// toggle governs both. New chapters don't start on cellular; in-flight
    /// chapters are paused (re-downloading their already-fetched pages is
    /// avoided where possible — pages on disk are rewritten atomically, so
    /// a restart simply overwrites them) and resume when Wi-Fi returns.
    @AppStorage("downloadOverWiFiOnly") private var downloadOverWiFiOnly = false {
        didSet { wifiPolicyChanged() }
    }

    /// Fires when NetworkMonitor reports the network class changed
    /// (Wi-Fi ↔ cellular). Re-evaluates the Wi-Fi-only policy.
    private var cellularCancellable: AnyCancellable?

    let downloadDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("MangaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Atomic manifest, sibling of MangaDownloads/ (so the orphan sweep never
    /// treats it as a stray artifact). Same durability reasoning as the video
    /// manager: UserDefaults can lose a write on kill and resurrect removed items.
    private var manifestURL: URL {
        downloadDir.deletingLastPathComponent().appendingPathComponent("manga_downloads_manifest.json")
    }

    // Chapter download tasks live here (populated in Task 3).
    var chapterTasks: [UUID: Task<Void, Never>] = [:]
    let maxConcurrentChapters = 2
    let maxPagesInFlight = 4

    private init() {
        _ = downloadDir
        load()
        reconcileDownloadsDirectory()
        observeAppLifecycle()
        cellularCancellable = NetworkMonitor.shared.$isOnCellular
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.wifiPolicyChanged() }
            }
    }

    /// Re-evaluates the Wi-Fi-only policy after either the toggle changed or
    /// the network class changed (v2.13).
    private func wifiPolicyChanged() {
        if downloadOverWiFiOnly, NetworkMonitor.shared.isOnCellular {
            pauseChaptersForCellular()
        } else {
            processQueue()
        }
    }

    /// Pauses in-flight chapter downloads because the device is on cellular
    /// and Wi-Fi-only is ON. Cancelled chapters go back to .pending ("Waiting")
    /// and restart automatically when Wi-Fi returns; pages already on disk are
    /// overwritten on the restart, so no stale partial files survive (writes
    /// are atomic — a page file on disk is always complete).
    private func pauseChaptersForCellular() {
        let active = items.filter { $0.state == .downloading }
        guard !active.isEmpty else { return }
        for item in active {
            chapterTasks[item.id]?.cancel()
            chapterTasks.removeValue(forKey: item.id)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].state = .pending
                items[idx].error = nil
            }
        }
        persist()
        ToastManager.shared.show(
            title: "Manga",
            message: "Paused — waiting for Wi-Fi",
            icon: "wifi.slash",
            iconColor: .orange
        )
    }

    // MARK: - Paths

    func folderURL(for id: UUID) -> URL {
        downloadDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// True when every page file for a completed item exists on disk.
    private func folderComplete(_ item: MangaDownloadItem) -> Bool {
        guard !item.pageFiles.isEmpty else { return false }
        let folder = folderURL(for: item.id)
        return item.pageFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    // MARK: - Lookups

    func item(forChapterHref href: String) -> MangaDownloadItem? {
        items.first { $0.chapterHref == href }
    }

    /// Ordered local file:// strings for a downloaded chapter, or nil. If a
    /// completed item's files vanished, flip it to .failed (never silently
    /// re-download) and return nil — same policy as the video getStream.
    func localPages(forChapterHref href: String) -> [String]? {
        guard let item = items.first(where: { $0.chapterHref == href && $0.state == .completed }) else { return nil }
        guard folderComplete(item) else {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].state = .failed
                items[idx].error = "Downloaded files are missing"
                items[idx].pageFiles = []
                items[idx].progress = 0
                persist()
            }
            return nil
        }
        let folder = folderURL(for: item.id)
        return item.pageFiles.map { folder.appendingPathComponent($0).absoluteString }
    }

    /// Reconstruct `MangaChapter`s from downloaded items for offline browsing,
    /// ascending by chapter number (index 0 = earliest), matching the reader's
    /// expectation.
    func downloadedChapters(forMangaHref href: String) -> [MangaChapter] {
        items
            .filter { $0.mangaHref == href && $0.state == .completed }
            .sorted { $0.chapterNumber < $1.chapterNumber }
            .map { item in
                MangaChapter(
                    href: item.chapterHref,
                    number: item.chapterNumber,
                    label: item.chapterName,
                    title: item.chapterName,
                    group: nil,
                    language: "en")
            }
    }

    // MARK: - Public enqueue

    func download(chapter: MangaChapter, context: MangaDownloadContext) {
        if items.contains(where: { $0.chapterHref == chapter.href }) {
            let existing = items.first { $0.chapterHref == chapter.href }
            let status = existing?.state == .completed ? "already downloaded" : "already in queue"
            ToastManager.shared.show(
                title: "Manga",
                message: "\(chapter.displayName) is \(status)",
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange
            )
            return
        }
        items.append(makeItem(chapter: chapter, context: context))
        persist()
        // Tell the user when the chapter will sit waiting (Wi-Fi-only on
        // cellular) instead of starting (v2.13).
        let waitingForWifi = downloadOverWiFiOnly && NetworkMonitor.shared.isOnCellular
        ToastManager.shared.show(
            title: "Manga",
            message: waitingForWifi
                ? "Added: \(context.mangaTitle) - \(chapter.displayName) — waiting for Wi-Fi"
                : "Added: \(context.mangaTitle) - \(chapter.displayName)",
            icon: "arrow.down.circle.fill",
            iconColor: .accentColor
        )
        processQueue()
    }

    func batchDownload(chapters: [MangaChapter], context: MangaDownloadContext) {
        var queued = 0
        for chapter in chapters where !items.contains(where: { $0.chapterHref == chapter.href }) {
            items.append(makeItem(chapter: chapter, context: context))
            queued += 1
        }
        guard queued > 0 else { return }
        persist()
        ToastManager.shared.show(
            title: "Manga",
            message: "Queued \(queued) chapter\(queued == 1 ? "" : "s")",
            icon: "arrow.down.circle.fill",
            iconColor: .accentColor
        )
        processQueue()
    }

    func retry(_ item: MangaDownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        chapterTasks[item.id]?.cancel()
        chapterTasks.removeValue(forKey: item.id)
        try? FileManager.default.removeItem(at: folderURL(for: item.id))
        items[idx].state = .pending
        items[idx].error = nil
        items[idx].progress = 0
        items[idx].pageFiles = []
        persist()
        processQueue()
    }

    private func makeItem(chapter: MangaChapter, context: MangaDownloadContext) -> MangaDownloadItem {
        MangaDownloadItem(
            id: UUID(),
            mangaTitle: context.mangaTitle,
            mangaHref: context.mangaHref,
            coverImage: context.coverImage,
            moduleId: context.moduleId,
            chapterHref: chapter.href,
            chapterNumber: chapter.number,
            chapterName: chapter.displayName,
            pageFiles: [],
            totalPages: 0,
            state: .pending,
            progress: 0,
            createdAt: Date())
    }

    // MARK: - Remove

    func remove(_ item: MangaDownloadItem) {
        chapterTasks[item.id]?.cancel()
        chapterTasks.removeValue(forKey: item.id)
        try? FileManager.default.removeItem(at: folderURL(for: item.id))
        items.removeAll { $0.id == item.id }
        persist()
        reconcileDownloadsDirectory()
        ToastManager.shared.show(
            title: "Manga",
            message: "Removed: \(item.mangaTitle) - \(item.chapterName)",
            icon: "trash.fill",
            iconColor: .accentColor
        )
        processQueue()
    }

    /// Bulk-removes every COMPLETED manga chapter download in one pass —
    /// the manga half of the "Clear Completed" toolbar action (v2.12).
    /// Downloading / pending / failed chapters are untouched; one summary
    /// toast replaces the per-item toasts `remove(_:)` would fire.
    func clearCompleted() {
        let completed = items.filter { $0.state == .completed }
        guard !completed.isEmpty else { return }

        for item in completed {
            try? FileManager.default.removeItem(at: folderURL(for: item.id))
        }

        items.removeAll { $0.state == .completed }
        persist()
        reconcileDownloadsDirectory()

        ToastManager.shared.show(
            title: "Manga",
            message: "Cleared \(completed.count) completed chapter\(completed.count == 1 ? "" : "s")",
            icon: "trash.fill",
            iconColor: .accentColor
        )
        processQueue()
    }

    /// Retries every failed manga chapter in one tap — the "Retry All"
    /// action in the Failed section header of the Downloads tab (v2.14).
    func retryAllFailed() {
        let failedItems = items.filter { $0.state == .failed }
        guard !failedItems.isEmpty else { return }
        for item in failedItems { retry(item) }
        ToastManager.shared.show(
            title: "Manga",
            message: "Retrying \(failedItems.count) failed chapter\(failedItems.count == 1 ? "" : "s")",
            icon: "arrow.clockwise",
            iconColor: .accentColor
        )
    }

    /// Bulk variant of `remove(_:)` — the manga side of the series-level
    /// "Delete All" action (v2.14): one pass, one summary toast, and targets
    /// may be in ANY state so deleting a series also cancels chapters that
    /// are still downloading.
    func removeItems(_ targets: [MangaDownloadItem]) {
        let ids = Set(targets.map { $0.id })
        guard !ids.isEmpty else { return }

        for item in targets {
            chapterTasks[item.id]?.cancel()
            chapterTasks.removeValue(forKey: item.id)
            try? FileManager.default.removeItem(at: folderURL(for: item.id))
        }

        items.removeAll { ids.contains($0.id) }
        persist()
        reconcileDownloadsDirectory()

        ToastManager.shared.show(
            title: "Manga",
            message: "Deleted \(targets.count) chapter\(targets.count == 1 ? "" : "s")",
            icon: "trash.fill",
            iconColor: .accentColor
        )
        processQueue()
    }

    // MARK: - Directory reconcile (orphan sweep)

    private func reconcileDownloadsDirectory() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadDir, includingPropertiesForKeys: nil) else { return }
        let names = contents.map { $0.lastPathComponent }
        let orphans = MangaDownloadPlanning.orphanFolderNames(names, validIDs: Set(items.map { $0.id }))
        for name in orphans {
            try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(name))
            Logger.shared.log("[MangaDownloads] Reclaimed orphaned folder: \(name)", type: "Download")
        }
    }

    // MARK: - Queue

    func processQueue() {
        // Wi-Fi-only (v2.13): never START a chapter over cellular.
        if downloadOverWiFiOnly, NetworkMonitor.shared.isOnCellular { return }
        let active = chapterTasks.count
        guard active < maxConcurrentChapters else { return }
        let pending = items.filter { $0.state == .pending }
        for item in pending.prefix(maxConcurrentChapters - active) {
            startChapter(item.id)
        }
    }

    private func startChapter(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .downloading
        persist()
        let referer = MangaDownloadPlanning.refererOrigin(forMangaHref: items[idx].mangaHref)
        let chapterHref = items[idx].chapterHref
        let folder = folderURL(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await JSEngine.shared.mangaImages(url: chapterHref)
                guard !urls.isEmpty else { throw NSError(domain: "MangaDownloadManager", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No pages found"]) }
                let pageFiles = try await self.downloadPages(id: id, urls: urls, referer: referer, folder: folder)
                await self.finishChapter(id: id, pageFiles: pageFiles)
            } catch {
                await self.failChapter(id: id, error: error)
            }
            self.chapterTasks.removeValue(forKey: id)
            self.processQueue()
            self.refreshKeepAlive()
        }
        chapterTasks[id] = task
        refreshKeepAlive()
    }

    /// Sliding-window page downloader (≤ maxPagesInFlight concurrent). Writes each
    /// page to <folder>/<paddedIndex>.<ext> and reports progress on the main actor.
    /// Returns the ordered page filenames on success.
    private func downloadPages(id: UUID, urls: [String], referer: String, folder: URL) async throws -> [String] {
        // Validate every page URL up front (v2.13). Previously a malformed
        // URL was silently skipped by enqueue's guard — the chapter then
        // "completed" with pages missing from the reader, only discoverable
        // by flipping through it. Fail the chapter honestly instead, and
        // drop the force-unwrap in the completion loop with it.
        let parsed: [URL] = try urls.map { raw in
            guard let url = URL(string: raw), !raw.isEmpty else {
                throw NSError(domain: "MangaDownloadManager", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Chapter returned an invalid page URL"])
            }
            return url
        }

        let total = parsed.count
        var names = [String?](repeating: nil, count: total)
        var done = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func enqueue(_ i: Int) {
                group.addTask { (i, try await Self.fetchPage(url: parsed[i], referer: referer)) }
            }
            while next < min(maxPagesInFlight, total) { enqueue(next); next += 1 }

            while let (i, data) = try await group.next() {
                let name = MangaDownloadPlanning.pageFileName(index: i, total: total, url: parsed[i])
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                names[i] = name
                done += 1
                let progress = Double(done) / Double(total)
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].progress = progress
                    items[idx].totalPages = total
                    objectWillChange.send()
                }
                if next < total { enqueue(next); next += 1 }
            }
        }
        return names.compactMap { $0 }
    }

    /// Off-actor image fetch with the reader's exact header policy (source-origin
    /// Referer + Cloudflare cookie/UA). Rejects non-2xx and empty bodies.
    private static func fetchPage(url: URL, referer: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        let cookie = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        KingfisherImageCache.headers(for: url, cookieHeader: cookie, bypassUserAgent: bypassUA, refererOverride: referer)
            .forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            throw NSError(domain: "MangaDownloadManager", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Page fetch failed (HTTP \(status))"])
        }
        return data
    }

    private func finishChapter(id: UUID, pageFiles: [String]) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .completed
        items[idx].progress = 1
        items[idx].pageFiles = pageFiles
        items[idx].totalPages = pageFiles.count
        items[idx].completedAt = Date()
        items[idx].error = nil
        persist()
        ToastManager.shared.show(
            title: "Manga",
            message: "Finished: \(items[idx].mangaTitle) - \(items[idx].chapterName)",
            icon: "checkmark.circle.fill",
            iconColor: .green
        )
    }

    private func failChapter(id: UUID, error: Error) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // Cancellation is deliberate (Wi-Fi pause or removal) — the canceller
        // already set the right state. Extended beyond CancellationError to
        // URLError.cancelled, which is how URLSession surfaces cancellation
        // of the page fetches (v2.13).
        if Self.isCancellationError(error) { return }
        items[idx].state = .failed
        items[idx].error = error.localizedDescription
        persist()
        ToastManager.shared.show(
            title: "Manga",
            message: "Failed: \(items[idx].mangaTitle) - \(items[idx].chapterName)",
            icon: "exclamationmark.circle.fill",
            iconColor: .red
        )
    }

    /// True when the error represents a deliberate task cancellation.
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    // MARK: - Background keep-alive

    private static let keepAliveReason = "manga-downloads"

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeepAlive(backgrounded: true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeepAlive(backgrounded: false); self?.processQueue() }
        }
    }

    private var isBackgrounded = false
    private func refreshKeepAlive(backgrounded: Bool? = nil) {
        if let backgrounded { isBackgrounded = backgrounded }
        if isBackgrounded && !chapterTasks.isEmpty {
            BackgroundKeepAlive.shared.acquire(Self.keepAliveReason)
        } else {
            BackgroundKeepAlive.shared.release(Self.keepAliveReason)
        }
    }

    // MARK: - Persistence

    func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            Logger.shared.log("[MangaDownloads] Failed to persist manifest: \(error.localizedDescription)", type: "Error")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([MangaDownloadItem].self, from: data) else { return }
        items = MangaDownloadPlanning.reconcileLoaded(decoded, folderComplete: folderComplete)
    }
}
#endif
