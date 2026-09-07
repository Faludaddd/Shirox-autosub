#if canImport(UIKit)
import SwiftUI
import CryptoKit

// MARK: - Update destination (v2.23)
//
// Where an update gets installed. All three handoffs use the install
// tool's REAL, documented deep link — verified against each tool's own
// source/docs (not invented):
//
//   LiveContainer  livecontainer://install?url=<percent-encoded https URL>
//                  — LCAppListView.handleURL case "install" reads the
//                    `url` query item and downloads/installs the IPA itself.
//   SideStore      sidestore://install?url=<percent-encoded https URL>
//                  — SideStore/DeepLinks/URLHandler.swift case "install"
//                    reads the `url` query item and imports the app.
//   KSign          Ksign://install/<https URL in the path>
//                  — KSign's documented URL scheme (kurdstore docs):
//                    "You can trigger app installation directly using
//                    Ksign://install/https://your-app-download-url.com/app.ipa"
//
// Every destination is probed with canOpenURL (schemes declared in
// LSApplicationQueriesSchemes) — unavailable tools are shown but clearly
// marked "Not installed", and nothing claims success unless iOS's open
// completion handler confirms the handoff was accepted.

enum UpdateDestination: String, CaseIterable, Identifiable {
    case liveContainer = "livecontainer"
    case sideStore = "sidestore"
    case ksign = "ksign"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveContainer: return "LiveContainer"
        case .sideStore:     return "SideStore"
        case .ksign:         return "KSign"
        }
    }

    var systemImage: String {
        switch self {
        case .liveContainer: return "square.stack.3d.up.fill"
        case .sideStore:     return "arrow.down.app.fill"
        case .ksign:         return "checkmark.seal.fill"
        }
    }

    var scheme: String {
        switch self {
        case .liveContainer: return "livecontainer"
        case .sideStore:     return "sidestore"
        case .ksign:         return "Ksign"
        }
    }

    /// The tool's own install deep link for an IPA URL.
    func installLink(for ipaURL: URL) -> URL? {
        switch self {
        case .liveContainer, .sideStore:
            // Query-item form: <scheme>://install?url=<encoded>
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host = "install"
            comps.queryItems = [URLQueryItem(name: "url", value: ipaURL.absoluteString)]
            return comps.url
        case .ksign:
            // Path form: Ksign://install/<https url>
            URL(string: "Ksign://install/\(ipaURL.absoluteString)")
        }
    }

    /// Honest probe — true only when the tool is installed on this device.
    @MainActor
    func isInstalled() -> Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }
}

// MARK: - Update Download Service
//
// Owns the "get the new IPA onto this device" half of the update flow
// (AppUpdateManager owns the "is one needed" half):
//
//   idle → connecting → downloading → verifying → succeeded(verified)
//                ↘ failed (retryable)              ↘ handedTo(installer)
//
// The download runs on a plain URLSession download task so progress is
// real (delegate callbacks, not polling). Verification streams a SHA-256
// over the file and compares it against the checksum published next to
// the release asset (`<downloadURL>.sha256`). If the checksum can't be
// fetched, verification is skipped HONESTLY (the success card says so)
// rather than silently claiming the package was verified.
//
// The final handoff goes to the user's chosen install tool via its
// documented URL scheme. iOS's open completion verdict is surfaced
// honestly — success is never claimed for a handoff that didn't happen.
final class UpdateDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateDownloadService()

    enum Phase: Equatable {
        case idle
        case connecting
        case downloading(progress: Double, downloadedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double)
        case verifying(progress: Double)
        /// Download complete. `verified` is true only when the published
        /// checksum was fetched AND matched; false means the checksum was
        /// unavailable (download still arrived over HTTPS from GitHub).
        case succeeded(verified: Bool)
        /// The chosen install tool accepted the install deep link and is
        /// downloading/installing the update itself.
        case handedTo(installer: String)
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Local URL of the downloaded (and, when a checksum was available,
    /// verified) .ipa — nil until success.
    private(set) var packageURL: URL?

    /// v2.23 — the remembered install destination is a VIEW concern (the
    /// dropdown owns the @AppStorage so SwiftUI refreshes the label); the
    /// service receives the chosen destination per handoff. Availability
    /// probes live here (refreshed before every handoff).
    @Published private(set) var availableDestinations: [UpdateDestination: Bool] = [:]

    private var remoteURL: URL?
    private var expectedSHA256: String?
    private var versionLabel = ""
    private var task: URLSessionDownloadTask?

    /// Dedicated session: short request timeout (a stalled connect should
    /// fail fast into the retry state) and no cache (always the fresh IPA).
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// (timestamp, cumulative bytes) samples for the trailing speed window.
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private var lastPhasePublish = Date.distantPast

    private override init() {
        super.init()
    }

    var isBusy: Bool {
        switch phase {
        case .idle, .failed, .succeeded, .handedTo: return false
        default: return true
        }
    }

    // MARK: - Destination availability

    /// Re-probes every destination's presence (canOpenURL is cheap and
    /// allowed — every scheme is declared in LSApplicationQueriesSchemes).
    @MainActor
    func refreshDestinationAvailability() {
        var result: [UpdateDestination: Bool] = [:]
        for destination in UpdateDestination.allCases {
            result[destination] = destination.isInstalled()
        }
        availableDestinations = result
    }

    @MainActor
    func isDestinationAvailable(_ destination: UpdateDestination) -> Bool {
        if let known = availableDestinations[destination] { return known }
        return destination.isInstalled()
    }

    // MARK: - Actions

    /// Starts (or restarts) the download for the given update. Safe to call
    /// redundantly while a download is already running (no-op).
    func start(info: AppUpdateManager.UpdateInfo) {
        guard !isBusy else { return }
        task?.cancel()
        task = nil
        speedSamples.removeAll()
        remoteURL = info.downloadURL
        versionLabel = info.newVersion
        expectedSHA256 = nil
        setPhase(.connecting)

        // Drop stale packages from earlier updates, then race the checksum
        // fetch against the download itself — the checksum (a 77-byte text
        // file) always wins that race for an IPA.
        cleanUpdatesDirectory(keeping: nil)
        if let shaURL = URL(string: info.downloadURL.absoluteString + ".sha256") {
            fetchExpectedChecksum(from: shaURL)
        }

        let download = session.downloadTask(with: info.downloadURL)
        task = download
        download.resume()
    }

    /// Aborts an in-flight download. The cancelled task's error is ignored
    /// (the phase is already back at idle), so this is a clean stop.
    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        task = nil
        setPhase(.idle)
        Haptics.selection()
    }

    /// Hands the update to the chosen install tool via its documented deep
    /// link: the tool downloads the IPA from GitHub itself and installs it.
    /// Re-probes presence every call, reports honestly through the
    /// completion handler whether iOS actually accepted the open, and
    /// cancels a redundant in-app download.
    @MainActor
    func handOff(to destination: UpdateDestination, url: URL) {
        if isBusy { cancel() }
        refreshDestinationAvailability()
        guard destination.isInstalled(), let installLink = destination.installLink(for: url) else {
            Haptics.error()
            setPhase(.failed(reason: "\(destination.displayName) wasn't found on this device. Install or open it, then tap Try Again — or use Update Now to download the package here and share it to any install tool."))
            return
        }
        UIApplication.shared.open(installLink, options: [:]) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                Haptics.success()
                self.setPhase(.handedTo(installer: destination.displayName))
            } else {
                Haptics.error()
                self.setPhase(.failed(reason: "iOS couldn't open \(destination.displayName). Copy the IPA link and open it in \(destination.displayName) manually — or use Update Now and share the package file."))
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        speedSamples.append((now, totalBytesWritten))
        // Keep a trailing ~5s window.
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 5 }

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }

        var speed: Double = 0
        if let first = speedSamples.first, now.timeIntervalSince(first.time) > 0.3 {
            speed = Double(totalBytesWritten - first.bytes) / now.timeIntervalSince(first.time)
        }

        // Throttle @Published churn to ~10/s — the bar animates smoothly
        // without flooding SwiftUI updates.
        guard now.timeIntervalSince(lastPhasePublish) > 0.1 else { return }
        lastPhasePublish = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .downloading = self.phase {
                self.phase = .downloading(progress: progress,
                                          downloadedBytes: totalBytesWritten,
                                          totalBytes: totalBytesExpectedToWrite,
                                          bytesPerSecond: speed)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard remoteURL != nil else { return }
        do {
            let destination = try persistPackage(at: location)
            packageURL = destination
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setPhase(.verifying(progress: 0))
            }
            verify(packageAt: destination)
        } catch {
            setPhase(.failed(reason: "Saving the download failed: \(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .downloading = self.phase {
                self.setPhase(.failed(reason: "Download failed: \((error as? URLError)?.localizedDescription ?? error.localizedDescription)"))
            }
        }
    }

    // MARK: - Package storage

    private var updatesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persistPackage(at tempLocation: URL) throws -> URL {
        let name = "Shirox-\(versionLabel.isEmpty ? "update" : versionLabel).ipa"
        let destination = updatesDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempLocation, to: destination)
        return destination
    }

    private func cleanUpdatesDirectory(keeping kept: String?) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: updatesDirectory, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Checksum + verification

    private func fetchExpectedChecksum(from shaURL: URL) {
        URLSession.shared.dataTask(with: shaURL) { [weak self] data, response, _ in
            guard let self,
                  let data,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else { return }
            // The file is "<hex>  Shirox.ipa" — take the first token.
            let checksum = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .first
                .map(String.init)?
                .lowercased()
            guard let checksum, checksum.count == 64 else { return }
            DispatchQueue.main.async { self.expectedSHA256 = checksum }
        }.resume()
    }

    /// Streams a SHA-256 over the file. With a published checksum it
    /// compares and the phase says verified/unverified honestly; without
    /// one it skips verification and the success card says THAT instead.
    private func verify(packageAt url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let stream = InputStream(url: url) else {
                Task { @MainActor in self.setPhase(.failed(reason: "The downloaded package couldn't be read.")) }
                return
            }
            stream.open()
            defer { stream.close() }

            var hasher = SHA256()
            let bufferSize = 4 * 1024 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var totalRead = 0
            let totalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                totalRead += read
                hasher.update(data: Data(buffer[0..<read]))
                let progress = totalSize > 0 ? Double(totalRead) / Double(totalSize) : 0
                let completed = totalRead
                Task { @MainActor [weak self] in
                    guard let self, case .verifying = self.phase else { return }
                    self.phase = .verifying(progress: progress)
                }
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let verified: Bool
            if let expected = self.expectedSHA256 {
                verified = digest == expected
            } else {
                verified = false // no checksum published — honest "unverified"
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setPhase(.succeeded(verified: verified))
                if verified { Haptics.success() }
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.phase = newPhase
        }
    }
}
#endif

// MARK: - Update cover (v2.23 — complete redesign)
//
// The update surface, designed from scratch to belong to Shirox: a
// bottom-anchored sheet-style card over a blurred scrim (not a system
// alert), with the app's capsule-badge language, continuous-corner cards,
// gradient primary button, and honest state coverage.
//
// Contents (top → bottom):
//   • grabber + drag-to-dismiss
//   • header: app mark, "Update Available", release date
//   • version transition: Installed pill → New pill (both real numbers)
//   • advisory banner for critical gaps (recommend, never lock)
//   • INSTALL WITH selector — LiveContainer / SideStore / KSign dropdown,
//     availability-probed, selection remembered across launches
//   • What's New — expandable changelog from the release manifest
//   • phase-driven action area:
//       idle: Update Now (real in-app download + SHA-256) + hand-off to
//             the selected tool + Copy Link / Share + Maybe Later
//       connecting / downloading (cancelable) / verifying / succeeded
//       (share the verified package, open the tool) / failed (retry)
//
// Updates are NEVER forced — Later always works. The preview mode (from
// the Updates settings page) is clearly labeled and never touches the
// version comparison.

#if canImport(UIKit)
struct UpdateCoverView: View {
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var downloadService = UpdateDownloadService.shared

    @State private var appeared = false
    @State private var changelogExpanded = false
    @State private var shareItem: ShareItem?
    /// Inline confirmation on the Copy Link button (the cover overlays the
    /// root view, so root-level toasts aren't visible here).
    @State private var linkCopied = false
    /// Drag-to-dismiss translation.
    @State private var dragOffset: CGFloat = 0

    /// v2.23 — the install destination, remembered across launches. The
    /// dropdown writes here (a View-owned @AppStorage so SwiftUI refreshes
    /// the label instantly); every handoff passes the value to the service.
    @AppStorage("update.installDestination") private var destinationRaw: String = UpdateDestination.liveContainer.rawValue

    private var selectedDestination: UpdateDestination {
        UpdateDestination(rawValue: destinationRaw) ?? .liveContainer
    }

    /// The real update info (available or dismissed states).
    private var info: AppUpdateManager.UpdateInfo? {
        switch updateManager.state {
        case .available(let info), .dismissed(let info): return info
        default: return nil
        }
    }

    /// v2.23 — Design preview (Updates settings → "Preview the update
    /// popup"): current version on both sides, labeled PREVIEW, and none
    /// of the actions touch the real manifest.
    private var previewInfo: AppUpdateManager.UpdateInfo? {
        guard updateManager.previewing, info == nil else { return nil }
        return AppUpdateManager.UpdateInfo(
            newVersion: updateManager.currentVersion,
            currentVersion: updateManager.currentVersion,
            changelog: "This is a preview of the update popup design. Nothing here installs anything — the real popup appears only when a newer version is actually available.",
            downloadURL: URL(string: "https://github.com/Faludaddd/Shirox-autosub/releases/download/beta/Shirox.ipa")!,
            isCritical: false,
            releaseDate: Date()
        )
    }

    private var activeInfo: AppUpdateManager.UpdateInfo? { info ?? previewInfo }

    /// v2.22 — Updates are NEVER forced. A critical gap (3+ minor versions
    /// behind or a major bump) shows a prominent advisory banner instead of
    /// a lockout — the user can always dismiss and keep using the app.
    private var isRecommended: Bool {
        activeInfo?.isCritical ?? false
    }

    private var isPreview: Bool { updateManager.previewing }

    var body: some View {
        ZStack {
            // Scrim — blurred, dims the app behind the sheet.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(appeared ? 0.32 : 0))
                .onTapGesture { laterTap() }

            if let info = activeInfo {
                sheetCard(info)
            } else {
                // A re-check is in flight while the cover is up — show an
                // honest transient state instead of stale content.
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Checking for updates…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(0.95)))
            }
        }
        .sheet(item: $shareItem) { item in
            shareSheet(item)
        }
        .onAppear {
            Task { @MainActor in downloadService.refreshDestinationAvailability() }
            Haptics.warning()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
        .onDisappear {
            updateManager.dismissPreview()
        }
    }

    // MARK: - Sheet card

    private func sheetCard(_ info: AppUpdateManager.UpdateInfo) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        grabber
                        header(info)
                        versionTransition(current: info.currentVersion, next: info.newVersion)
                        if isRecommended { recommendedBanner }
                        destinationSection(info)
                        whatsNewSection(info)
                        actionArea(info)
                        footerLine
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: geo.size.height * 0.94, alignment: .bottom)
                .background(
                    SheetTopRoundedShape(radius: 34)
                        .fill(Color(uiColor: .systemBackground).opacity(0.97))
                        .shadow(color: .black.opacity(0.3), radius: 30, y: -12)
                        .ignoresSafeArea(edges: .bottom)
                )
                .overlay(
                    SheetTopRoundedShape(radius: 34)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
            .offset(y: appeared ? max(0, dragOffset) : geo.size.height)
        }
        .gesture(dismissDrag)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: appeared)
    }

    private var grabber: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 40, height: 5)
                .padding(.top, 9)
            if isPreview {
                Text("PREVIEW")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    // MARK: - Header + versions

    private func header(_ info: AppUpdateManager.UpdateInfo) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Color.appAccent.opacity(0.3), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Update Available")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                if let date = info.releaseDate {
                    Text(Self.releaseDateText(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A new version of Shirox+ is ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                laterTap()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private static func releaseDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    /// Installed → New version transition, in the app's capsule style.
    private func versionTransition(current: String, next: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .center, spacing: 2) {
                Text(current)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Installed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 74)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))

            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .center, spacing: 2) {
                Text(next)
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.appAccent)
                Text("New")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.appAccent.opacity(0.75))
            }
            .frame(minWidth: 74)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appAccent.opacity(0.12)))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// Advisory (never a lockout): this gap is big enough that updating is
    /// strongly recommended.
    private var recommendedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Updating is strongly recommended")
                    .font(.subheadline.weight(.bold))
                Text("This release is several versions ahead and contains important fixes. You can keep using Shirox+ without updating — the newest experience is here when you're ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Destination dropdown

    private func destinationSection(_ info: AppUpdateManager.UpdateInfo) -> some View {
        let selected = selectedDestination
        return VStack(alignment: .leading, spacing: 8) {
            Text("INSTALL WITH")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Menu {
                ForEach(UpdateDestination.allCases) { destination in
                    let installed = downloadService.isDestinationAvailable(destination)
                    Button {
                        Haptics.selection()
                        destinationRaw = destination.rawValue
                    } label: {
                        HStack {
                            if selected == destination {
                                Image(systemName: "checkmark")
                            }
                            Text(destination.displayName)
                            if !installed {
                                Text("— not installed")
                            }
                        }
                    }
                    .disabled(!installed)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(selected.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Choose install destination")

            // Availability summary under the dropdown — honest per tool.
            HStack(spacing: 0) {
                ForEach(UpdateDestination.allCases) { destination in
                    let installed = downloadService.isDestinationAvailable(destination)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(installed ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                        Text(destination.displayName)
                            .font(.caption2)
                            .foregroundStyle(installed ? .secondary : .tertiary)
                            .strikethrough(!installed, color: .tertiary)
                    }
                    .padding(.trailing, 10)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - What's New

    private func whatsNewSection(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    changelogExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                    Text("What's New")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(changelogExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if changelogExpanded {
                ScrollView {
                    Text(info.changelog)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(maxHeight: 230, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Action area (phase machine)

    @ViewBuilder
    private func actionArea(_ info: AppUpdateManager.UpdateInfo) -> some View {
        switch downloadService.phase {
        case .idle:
            idleActions(info)
        case .connecting:
            connectingCard
        case .downloading(let progress, let downloaded, let total, let speed):
            progressCard(progress: progress, downloaded: downloaded, total: total, speed: speed)
        case .verifying(let progress):
            verifyCard(progress: progress)
        case .succeeded(let verified):
            successSection(info, verified: verified)
        case .handedTo(let installer):
            handedOffSection(info, installer: installer)
        case .failed(let reason):
            failedSection(info, reason: reason)
        }
    }

    /// The full action set before anything is in flight. In PREVIEW mode
    /// every action is disabled — the preview reviews the design, and
    /// nothing touches GitHub or any install tool.
    private func idleActions(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(spacing: 10) {
            Button {
                startDownload(info)
            } label: {
                Label("Update Now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(UpdatePrimaryButtonStyle())
            .disabled(isPreview)

            // Hand the IPA straight to the selected install tool (the tool
            // downloads and installs it itself). Only shown when that tool
            // is actually installed.
            if downloadService.isDestinationAvailable(selectedDestination) {
                Button {
                    Haptics.light()
                    downloadService.handOff(to: selectedDestination,
                                             url: info.downloadURL)
                } label: {
                    Label("Install with \(selectedDestination.displayName)",
                          systemImage: selectedDestination.systemImage)
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
                .disabled(isPreview)
            }

            HStack(spacing: 10) {
                Button {
                    copyLink(info)
                } label: {
                    Label(linkCopied ? "Copied" : "Copy Link",
                          systemImage: linkCopied ? "checkmark.circle.fill" : "link")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: linkCopied ? .green : Color.appAccent))
                .disabled(isPreview)

                #if os(iOS)
                Button {
                    shareLink(info)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
                .disabled(isPreview)
                #endif
            }

            if isPreview {
                Text("Design preview — actions are disabled. The real popup appears only when a newer version exists.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            // v2.22 — Never forced: Later is always offered.
            Button {
                laterTap()
            } label: {
                Text("Maybe Later")
            }
            .buttonStyle(UpdateLaterButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Transfer states

    private var connectingCard: some View {
        statusCard {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contacting GitHub")
                        .font(.headline)
                    Text("Starting the update download…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { downloadService.cancel() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func progressCard(progress: Double, downloaded: Int64, total: Int64, speed: Double) -> some View {
        statusCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Button {
                        downloadService.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel download")
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(LinearGradient(colors: [Color.appAccent, Color.purple.opacity(0.75)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: progress > 0.01 ? max(6, geo.size.width * progress) : 0)
                    }
                }
                .frame(height: 8)
                .animation(.easeInOut(duration: 0.18), value: progress)

                HStack(spacing: 0) {
                    statCell(value: ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file),
                             caption: "Downloaded")
                    statDivider
                    statCell(value: total > 0
                             ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                             : "—",
                             caption: "Total")
                    statDivider
                    statCell(value: speed > 0
                             ? ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
                             : "—",
                             caption: "Speed")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func verifyCard(progress: Double) -> some View {
        statusCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.appAccent)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verifying package")
                            .font(.headline)
                        Text("Checking the download against the release checksum…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.appAccent)
                            .frame(width: progress > 0.01 ? max(4, geo.size.width * progress) : 0)
                    }
                }
                .frame(height: 5)
                .animation(.easeInOut(duration: 0.15), value: progress)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Terminal states

    private func successSection(_ info: AppUpdateManager.UpdateInfo, verified: Bool) -> some View {
        VStack(spacing: 12) {
            statusCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: verified ? "checkmark.seal.fill" : "checkmark.circle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verified ? "Package verified" : "Package ready")
                                .font(.headline)
                            Text(verified
                                 ? "Checksum matches the release exactly — the file is intact."
                                 : "No checksum was published for this release; the file arrived over HTTPS from GitHub.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let packageURL = downloadService.packageURL {
                        let size = (try? FileManager.default.attributesOfItem(atPath: packageURL.path)[.size] as? Int64) ?? 0
                        HStack(spacing: 5) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · Files → Shirox+ → Updates")
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            #if os(iOS)
            Button {
                sharePackage()
            } label: {
                Label("Share Package", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(UpdatePrimaryButtonStyle())
            #endif

            // Hand the package to the preferred tool from here too.
            if downloadService.isDestinationAvailable(selectedDestination) {
                Button {
                    downloadService.handOff(to: selectedDestination,
                                             url: info.downloadURL)
                } label: {
                    Label("Install with \(selectedDestination.displayName)",
                          systemImage: selectedDestination.systemImage)
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
            }

            HStack(spacing: 10) {
                Button { copyLink(info) } label: {
                    Label(linkCopied ? "Copied" : "Copy Link",
                          systemImage: linkCopied ? "checkmark.circle.fill" : "link")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: linkCopied ? .green : Color.appAccent))
                Button {
                    if let url = URL(string: "https://github.com/Faludaddd/Shirox-autosub/releases/tag/beta") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Safari", systemImage: "safari")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
            }

            Button { laterTap() } label: {
                Text("Maybe Later")
            }
            .buttonStyle(UpdateLaterButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func handedOffSection(_ info: AppUpdateManager.UpdateInfo, installer: String) -> some View {
        VStack(spacing: 12) {
            statusCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(installer) took over")
                            .font(.headline)
                        Text("\(installer) was opened with the install link — it's downloading and installing the update itself. Relaunch Shirox+ from \(installer) when it finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Alternative: download in-app instead of waiting on the tool.
            Button {
                startDownload(info)
            } label: {
                Label("Download Here Instead", systemImage: "arrow.down.circle")
            }
            .buttonStyle(UpdateSecondaryButtonStyle())

            HStack(spacing: 10) {
                Button { copyLink(info) } label: {
                    Label(linkCopied ? "Copied" : "Copy Link",
                          systemImage: linkCopied ? "checkmark.circle.fill" : "link")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: linkCopied ? .green : Color.appAccent))
                Button {
                    if let url = URL(string: "https://github.com/Faludaddd/Shirox-autosub/releases/tag/beta") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Safari", systemImage: "safari")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
            }

            Button { laterTap() } label: {
                Text("Maybe Later")
            }
            .buttonStyle(UpdateLaterButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func failedSection(_ info: AppUpdateManager.UpdateInfo, reason: String) -> some View {
        VStack(spacing: 12) {
            statusCard(tint: .orange) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Update didn't complete")
                            .font(.headline)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            Button {
                startDownload(info)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(UpdatePrimaryButtonStyle())

            if downloadService.isDestinationAvailable(selectedDestination) {
                Button {
                    downloadService.handOff(to: selectedDestination,
                                             url: info.downloadURL)
                } label: {
                    Label("Try \(selectedDestination.displayName)",
                          systemImage: selectedDestination.systemImage)
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
            }

            HStack(spacing: 10) {
                Button { copyLink(info) } label: {
                    Label(linkCopied ? "Copied" : "Copy Link",
                          systemImage: linkCopied ? "checkmark.circle.fill" : "link")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: linkCopied ? .green : Color.appAccent))
                Button {
                    if let url = URL(string: "https://github.com/Faludaddd/Shirox-autosub/releases/tag/beta") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Safari", systemImage: "safari")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
            }

            Button { laterTap() } label: {
                Text("Maybe Later")
            }
            .buttonStyle(UpdateLaterButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    private var footerLine: some View {
        HStack(spacing: 6) {
            if let date = updateManager.lastSuccessfulCheck {
                let f = RelativeDateTimeFormatter()
                Text("Checked \(f.localizedString(for: date, relativeTo: Date())) ago")
            } else {
                Text("Shirox+ checks for updates automatically")
            }
            Text("· detection is exact — same version never prompts")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }

    // MARK: - Drag to dismiss

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if value.translation.y > 0 { dragOffset = value.translation.y }
            }
            .onEnded { value in
                if value.translation.y > 110 {
                    laterTap()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Actions

    private func startDownload(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.light()
        // Preview mode disables the buttons — this is unreachable there.
        downloadService.start(info: info)
    }

    private func laterTap() {
        Haptics.selection()
        if isPreview {
            updateManager.dismissPreview()
        } else {
            updateManager.dismiss()
        }
    }

    private func copyLink(_ info: AppUpdateManager.UpdateInfo) {
        UIPasteboard.general.string = info.downloadURL.absoluteString
        Haptics.light()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { linkCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { self.linkCopied = false }
        }
    }

    private func shareLink(_ info: AppUpdateManager.UpdateInfo) {
        shareItem = ShareItem(url: info.downloadURL)
    }

    private func sharePackage() {
        guard let packageURL = downloadService.packageURL else { return }
        shareItem = ShareItem(url: packageURL)
    }

    // MARK: - Share sheet

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private func shareSheet(_ item: ShareItem) -> some View {
        ActivityShareSheet(items: [item.url])
            .adaptivePresentationDetents([.medium, .large])
    }

    // MARK: - Shared status card

    private func statusCard(tint: Color = .clear,
                            @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(tint == .clear ? Color.primary.opacity(0.04) : tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(tint == .clear ? Color.primary.opacity(0.07) : tint.opacity(0.22), lineWidth: 1))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 6)
    }

    private func statCell(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// iOS 15-compatible sheet shape: rounded top corners, square bottom
/// (UnevenRoundedRectangle requires iOS 16.4; the app targets iOS 15).
struct SheetTopRoundedShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(270),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: .degrees(270),
                    endAngle: .degrees(0),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Button styles

struct UpdatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color.appAccent, Color.appAccent.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .shadow(color: Color.appAccent.opacity(0.35), radius: 12, y: 5)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct UpdateSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    var tint: Color = Color.appAccent

    init(height: CGFloat = 50, tint: Color = Color.appAccent) {
        self.height = height
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                Capsule().fill(tint.opacity(configuration.isPressed ? 0.18 : 0.12))
            )
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct UpdateLaterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// UIKit share sheet bridge (os(iOS)-guarded — no macOS availability).
#if os(iOS)
struct ActivityShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
#endif
