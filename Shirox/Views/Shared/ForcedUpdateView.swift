#if canImport(UIKit)
import SwiftUI
import CryptoKit

// MARK: - Update Download Service
//
// Owns the "get the new IPA onto this device" half of the update flow
// (AppUpdateManager owns the "is one needed" half):
//
//   idle → connecting → downloading → verifying → succeeded(verified)
//                ↘ failed (retryable)              ↘ handedToLiveContainer
//
// The download runs on a plain URLSession download task so progress is
// real (delegate callbacks, not polling). Verification streams a SHA-256
// over the file and compares it against the checksum published next to
// the release asset (`<downloadURL>.sha256`) — the same checksum the
// release pipeline regenerates on every build. If the checksum can't be
// fetched, verification is skipped HONESTLY (the success card says so)
// rather than silently claiming the package was verified.
//
// iOS cannot install an IPA from inside a sandboxed app, so the final
// handoff goes to LiveContainer — the user's container app — via its
// documented URL scheme `livecontainer://install?url=<encoded>`. The
// scheme is verified against LiveContainer's own source (its app list
// handles the `install` host by downloading and installing the given
// URL); the button is only shown when `canOpenURL` confirms LiveContainer
// is installed (LSApplicationQueriesSchemes in Info.plist). For setups
// without LiveContainer, the downloaded + verified package can be shared
// from the app's Files-visible Updates folder to any sideload tool, and
// the download link can always be copied or opened in Safari.
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
        /// LiveContainer was opened with the install link — it is
        /// downloading and installing the update itself.
        case handedToLiveContainer
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Probed on first render and re-probed before every handoff: true
    /// when LiveContainer is installed on this device. Drives button
    /// visibility only — never any pretend integration.
    @Published private(set) var liveContainerAvailable = false

    /// Local URL of the downloaded (and, when a checksum was available,
    /// verified) .ipa — nil until success.
    private(set) var packageURL: URL?

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

    private override init() { super.init() }

    var isBusy: Bool {
        switch phase {
        case .idle, .failed, .succeeded, .handedToLiveContainer: return false
        default: return true
        }
    }

    // MARK: - LiveContainer detection

    /// True when LiveContainer is installed (honest probe — the app
    /// declares the `livecontainer` scheme in LSApplicationQueriesSchemes
    /// so `canOpenURL` is allowed to answer). Refreshed before every
    /// handoff so installing LiveContainer mid-flow enables the button.
    @discardableResult
    func probeLiveContainer() -> Bool {
        guard let probe = URL(string: "livecontainer://") else {
            liveContainerAvailable = false
            return false
        }
        let available = UIApplication.shared.canOpenURL(probe)
        if liveContainerAvailable != available { liveContainerAvailable = available }
        return available
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
        // file) always wins that race for an 11 MB IPA.
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

    /// Hands the update straight to LiveContainer via its documented
    /// `install` URL action: LiveContainer downloads the IPA from GitHub
    /// itself and installs it into its container. Re-probes presence every
    /// call, reports honestly through the completion handler whether iOS
    /// actually accepted the open, and cancels a redundant in-app download.
    func openInLiveContainer(url: URL) {
        if isBusy { cancel() }
        guard probeLiveContainer() else {
            Haptics.error()
            setPhase(.failed(reason: "LiveContainer wasn't found on this device. Install or open LiveContainer, then tap Try Again — or use Update Now to download the package here and share it to any sideload tool."))
            return
        }
        var comps = URLComponents()
        comps.scheme = "livecontainer"
        comps.host = "install"
        comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let installURL = comps.url else { return }
        UIApplication.shared.open(installURL, options: [:]) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                Haptics.success()
                self.setPhase(.handedToLiveContainer)
            } else {
                Haptics.error()
                self.setPhase(.failed(reason: "iOS refused to open the LiveContainer link. Copy the download link instead and add it to LiveContainer manually (Add by URL)."))
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        // Phase swaps rebuild the action area (different card per state),
        // so animate them — cross-fade the terminal states; the download
        // progress values inside one card carry their own animation.
        if Thread.isMainThread {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = newPhase }
        } else {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.phase = newPhase }
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate (background queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        speedSamples.append((now, totalBytesWritten))
        while let first = speedSamples.first, now.timeIntervalSince(first.time) > 1.5 {
            speedSamples.removeFirst()
        }
        var bytesPerSecond: Double = 0
        if let first = speedSamples.first, let last = speedSamples.last, last.bytes > first.bytes {
            let window = max(0.15, last.time.timeIntervalSince(first.time))
            bytesPerSecond = Double(last.bytes - first.bytes) / window
        }
        let total = max(totalBytesExpectedToWrite, 0)
        let progress = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0

        // Throttle published churn to ~5 Hz — the bar animates linearly
        // between updates so it still reads as perfectly smooth.
        guard now.timeIntervalSince(lastPhasePublish) > 0.18 else { return }
        lastPhasePublish = now
        setPhase(.downloading(progress: progress, downloadedBytes: totalBytesWritten,
                              totalBytes: total, bytesPerSecond: bytesPerSecond))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this callback returns, so the
        // file must move NOW (on the delegate queue, before returning).
        let destination = Self.updatesDirectory
            .appendingPathComponent("Shirox-\(versionLabel.isEmpty ? "update" : versionLabel).ipa")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setPhase(.failed(reason: "Couldn't save the update package: \(error.localizedDescription)"))
            Haptics.error()
            return
        }
        packageURL = destination
        setPhase(.verifying(progress: 0))

        // Stream a SHA-256 over the file off the main thread, comparing
        // against the published checksum fetched earlier.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var hasher = SHA256()
            var reported: Double = 0
            var readFailed = false
            do {
                let handle = try FileHandle(forReadingFrom: destination)
                defer { try? handle.close() }
                let total = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
                var processed: Int64 = 0
                let chunkSize = 1 << 20
                while true {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    processed += Int64(chunk.count)
                    let p = total > 0 ? Double(processed) / Double(total) : 0
                    if p - reported > 0.1 {
                        reported = p
                        self.setPhase(.verifying(progress: p))
                    }
                }
            } catch {
                readFailed = true
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

            func complete(_ verified: Bool) {
                self.setPhase(.succeeded(verified: verified))
                Haptics.success()
            }

            if let expected = self.expectedSHA256, !readFailed {
                if digest.caseInsensitiveCompare(expected) == .orderedSame {
                    complete(true)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    self.packageURL = nil
                    self.setPhase(.failed(reason: "The download didn't match its published checksum — the package is corrupt or truncated. Retry downloads it fresh."))
                    Haptics.error()
                }
            } else {
                // No checksum was published/fetchable — the bytes still
                // arrived from GitHub over TLS; the UI labels this state
                // honestly instead of claiming verification.
                complete(false)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // success path handled above
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        setPhase(.failed(reason: "Download failed: \(ns.localizedDescription)"))
        Haptics.error()
    }

    // MARK: - Checksum + files

    private func fetchExpectedChecksum(from url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        session.dataTask(with: request) { [weak self] data, response, error in
            guard error == nil,
                  let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else { return }
            // Format: "<hex>  Shirox.ipa" (shasum output).
            let hex = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "*" })
                .first.map(String.init)?.lowercased()
            if let hex, hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) {
                self?.expectedSHA256 = hex
            }
        }.resume()
    }

    static var updatesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Updates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanUpdatesDirectory(keeping: URL?) {
        let dir = Self.updatesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "ipa" && file != keeping {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Share sheet

/// Something to hand to the system share sheet — either the remote IPA
/// URL (before a download) or the downloaded package FILE (after). The
/// sheet is the honest fallback: the user picks where it goes (AirDrop,
/// Save to Files, LiveContainer's share extension, or any sideload tool).
private struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]

    init(url: URL) { items = [url] }
    init(fileURL: URL) { items = [fileURL] }
}

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Update Cover View
//
// The update surface presented as a fullScreenCover from the root view
// the moment AppUpdateManager confirms a newer version exists. It renders
// ONE content set in TWO presentations:
//
//   • Prompt mode (everyday release, non-critical): a centered popup
//     card over a dimmed ambient background, with a close (X) header
//     button, a "Maybe Later" footer action, and the full action set —
//     Update Now (real in-app download with live progress + SHA-256
//     verification), Add to LiveContainer (its documented
//     livecontainer://install?url= handoff, only shown when
//     LiveContainer is actually installed), Copy Link, and Share.
//     Later dismisses the popup for this version; the About page keeps
//     offering the install, and the next version re-prompts.
//
//   • Forced mode (critical gap — ≥ 3 minor versions behind or a major
//     bump, see AppUpdateManager.isCriticalGap): the full-screen gate.
//     Same content and actions, no Later/X, a "required" notice, and the
//     orbit emblem hero. The cover clears only when a real version check
//     confirms the app is current again.
//
// Action honesty rules: every state is real (download progress comes
// from URLSession delegate callbacks; verification is an actual SHA-256
// over the file, and when no checksum is published the success card SAYS
// it wasn't verified instead of faking a seal); the LiveContainer button
// only ever appears after canOpenURL confirms the app, and iOS's own
// completion handler decides whether the handoff succeeded.
//
// Visual language mirrors the rest of Shirox+ exactly: Color.appAccent
// (user's chosen accent), .rounded typography with monospaced digits,
// secondary.opacity(0.08) cards in 22pt continuous corners, capsule pills
// with tint.opacity(0.12) fills, hairline .primary.opacity(0.06) strokes,
// spring(response: 0.3–0.5, dampingFraction: 0.8) motion, glow language
// from GlowToggleStyle (shadow radius scaled by glowIntensity), and
// Haptics on every meaningful interaction.
struct UpdateCoverView: View {
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var downloadService = UpdateDownloadService.shared

    @State private var appeared = false
    @State private var changelogExpanded = false
    @State private var breath = false
    @State private var shareItem: ShareItem?
    /// Inline confirmation on the Copy Link button (the popup covers the
    /// root view, so root-level toasts wouldn't be visible here).
    @State private var linkCopied = false

    private var info: AppUpdateManager.UpdateInfo? {
        switch updateManager.state {
        case .available(let info), .dismissed(let info): return info
        default: return nil
        }
    }

    /// v2.22 — Updates are NEVER forced anymore. A critical gap (3+ minor
    /// versions behind or a major bump) shows a prominent "strongly
    /// recommended" banner instead of a lockout — the user can always
    /// close the popup and keep using the app.
    private var isRecommended: Bool {
        info?.isCritical ?? false
    }

    var body: some View {
        ZStack {
            background
            if let info {
                // The popup manages its own centered, scrollable card.
                promptLayout(info)
            } else {
                // A re-check is in flight while the cover is up — show
                // an honest transient state instead of stale content.
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Checking for updates…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            shareSheet(item)
        }
        .onAppear {
            downloadService.probeLiveContainer()
            Haptics.warning()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            // Ambient loop — blob breathing.
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { breath = true }
        }
    }

    // MARK: - Prompt (popup) presentation

    /// Centered card that scrolls when content outgrows the screen —
    /// responsive on every iPhone and iPad size.
    private func promptLayout(_ info: AppUpdateManager.UpdateInfo) -> some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(minHeight: 48)
                    popupCard(info)
                        .modifier(Entrance(index: 0, appeared: appeared, hero: true))
                    Color.clear.frame(minHeight: 48)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
        }
    }

    private func popupCard(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header — identity + close.
            HStack(alignment: .top, spacing: 12) {
                Image("app-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: Color.appAccent.opacity(0.3), radius: 7, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Available")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("A new version of Shirox+ is ready to install.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            versionTransition(current: info.currentVersion, next: info.newVersion)

            // v2.22 — Strong recommendation for critical gaps (3+ versions
            // behind / major bump). Advisory, never a lockout.
            if isRecommended {
                recommendedBanner
            }

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            whatsNewSection(info)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            actionArea(info)

            // Demo-only escape hatch (Updates page → 5 taps on the version
            // row) + last-checked line.
            if updateManager.simulateOutdated {
                demoChips
                    .frame(maxWidth: .infinity)
            } else {
                lastCheckedLine
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(uiColor: .systemBackground).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.28), radius: 32, y: 18)
    }

    /// v2.22 — The honest advisory banner shown instead of the old forced
    /// gate: this update contains important fixes, so updating is strongly
    /// recommended — but the app stays usable and the popup stays
    /// dismissable (Maybe Later / close button).
    private var recommendedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Updating is strongly recommended")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("You're several versions behind — this release contains important fixes and improvements. You can keep using Shirox+ without updating, but the newest experience is here when you're ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Shared: action area (phase machine)

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
        case .handedToLiveContainer:
            handedOffSection(info)
        case .failed(let reason):
            failedSection(info, reason: reason)
        }
    }

    /// The full action set before anything is in flight.
    private func idleActions(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(spacing: 10) {
            Button {
                startDownload(info)
            } label: {
                Label("Update Now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(UpdatePrimaryButtonStyle())

            if downloadService.liveContainerAvailable {
                Button {
                    Haptics.light()
                    downloadService.openInLiveContainer(url: info.downloadURL)
                } label: {
                    Label("Add to LiveContainer", systemImage: "arrow.down.app.fill")
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
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

                #if os(iOS)
                Button {
                    shareLink(info)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
                #endif
            }

            // v2.22 — Never forced: Later is always offered.
            Button {
                laterTap()
            } label: {
                Text("Maybe Later")
            }
            .buttonStyle(UpdateLaterButtonStyle())
        }
    }

    // MARK: - Shared: transfer states

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
    }

    private func verifyCard(progress: Double) -> some View {
        statusCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.appAccent)
                        .symbolRenderingMode(.hierarchical)
                        .scaleEffect(breath ? 1.06 : 0.96)
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
    }

    // MARK: - Shared: terminal states

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

            if downloadService.liveContainerAvailable {
                Button {
                    Haptics.light()
                    downloadService.openInLiveContainer(url: info.downloadURL)
                } label: {
                    Label("Add to LiveContainer", systemImage: "arrow.down.app.fill")
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
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

                Button {
                    openInSafari(info)
                } label: {
                    Label("Safari", systemImage: "safari.fill")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
            }

            // v2.22 — Never forced: Later is always offered.
            Button { laterTap() } label: { Text("Maybe Later") }
                .buttonStyle(UpdateLaterButtonStyle())
        }
    }

    private func handedOffSection(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(spacing: 12) {
            statusCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.appAccent.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: "arrow.down.app.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LiveContainer took over")
                                .font(.headline)
                            Text("LiveContainer is downloading and installing the update from GitHub. Launch Shirox+ from LiveContainer once it finishes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Button {
                startDownload(info)
            } label: {
                Label("Download in App Instead", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(UpdateSecondaryButtonStyle())
            // v2.22 — Never forced: Later is always offered.
            Button { laterTap() } label: { Text("Maybe Later") }
                .buttonStyle(UpdateLaterButtonStyle())
        }
    }

    private func failedSection(_ info: AppUpdateManager.UpdateInfo, reason: String) -> some View {
        VStack(spacing: 12) {
            statusCard(tint: .orange) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        .modifier(ErrorWiggler())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn't get the update")
                                .font(.headline)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            Button {
                startDownload(info)
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
            .buttonStyle(UpdatePrimaryButtonStyle())

            if downloadService.liveContainerAvailable {
                Button {
                    Haptics.light()
                    downloadService.openInLiveContainer(url: info.downloadURL)
                } label: {
                    Label("Add to LiveContainer", systemImage: "arrow.down.app.fill")
                }
                .buttonStyle(UpdateSecondaryButtonStyle())
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

                Button {
                    openInSafari(info)
                } label: {
                    Label("Safari", systemImage: "safari.fill")
                        .lineLimit(1)
                }
                .buttonStyle(UpdateSecondaryButtonStyle(height: 44, tint: Color.appAccent))
            }

            // v2.22 — Never forced: Later is always offered.
            Button { laterTap() } label: { Text("Maybe Later") }
                .buttonStyle(UpdateLaterButtonStyle())
        }
    }

    // MARK: - Actions

    private func startDownload(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.medium()
        updateManager.markDownloadStarted()
        downloadService.start(info: info)
    }

    private func laterTap() {
        Haptics.selection()
        updateManager.dismiss()
    }

    private func copyLink(_ info: AppUpdateManager.UpdateInfo) {
        UIPasteboard.general.string = info.downloadURL.absoluteString
        Haptics.light()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { linkCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.3)) { linkCopied = false }
        }
    }

    private func shareLink(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.light()
        shareItem = ShareItem(url: info.downloadURL)
    }

    private func sharePackage() {
        guard let packageURL = downloadService.packageURL else { return }
        Haptics.light()
        shareItem = ShareItem(fileURL: packageURL)
    }

    private func openInSafari(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.light()
        UIApplication.shared.open(info.downloadURL)
    }

    @ViewBuilder
    private func shareSheet(_ item: ShareItem) -> some View {
        #if os(iOS)
        ActivityShareSheet(items: item.items)
        #else
        // tvOS has no UIActivityViewController; the Share button is only
        // rendered on iOS so this branch never shows in practice.
        Text("Sharing isn't available here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }

    // MARK: - Shared sections

    /// Version comparison — the installed pill, an arrow, the new pill,
    /// each with a tiny caption so the numbers are unambiguous.
    private func versionTransition(current: String, next: String) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 5) {
                Text(current)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.8))
                Text("Installed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .scaleEffect(x: appeared ? 1 : 0.1, y: 1)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.35), value: appeared)
                .padding(.bottom, 14)

            VStack(spacing: 5) {
                Text(next)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.7)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                    .shadow(color: Color.appAccent.opacity(0.4), radius: 8, y: 3)
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "What's New" header + changelog — used bare inside the popup card.
    private func whatsNewSection(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("What's New")
                    .font(.headline)
                Spacer()
                if let date = info.releaseDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(info.changelog)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(changelogExpanded ? nil : 7)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: changelogExpanded)
            if info.changelog.count > 420 {
                Button(changelogExpanded ? "Show Less" : "Show All") {
                    Haptics.light()
                    changelogExpanded.toggle()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neutral container for a transfer/terminal state block.
    private func statusCard<Content: View>(tint: Color = Color.appAccent,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 1))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 14)
    }

    private func statCell(value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            // Prompt mode: ambient blobs dialed down, plus a scrim so
            // the card reads as a modal over the app world.
            Circle()
                .fill(RadialGradient(colors: [Color.appAccent.opacity(0.13), Color.appAccent.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 210))
                .frame(width: 360, height: 360)
                .offset(x: 150, y: -320)
                .scaleEffect(breath ? 1.08 : 0.94)
            Circle()
                .fill(RadialGradient(colors: [Color.purple.opacity(0.08), Color.purple.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 180))
                .frame(width: 300, height: 300)
                .offset(x: -170, y: 360)
                .scaleEffect(breath ? 0.94 : 1.06)
            Color.primary.opacity(0.04)
        }
        .ignoresSafeArea()
    }

    // MARK: - Footer

    private var lastCheckedLine: some View {
        Group {
            if let last = updateManager.lastSuccessfulCheck {
                Text("Checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Demo-only affordance (Updates page → 5 taps on the version row):
    /// exit the simulation. The forced-presentation preview was removed
    /// with the forced gate itself (v2.22).
    private var demoChips: some View {
        Group {
            if updateManager.simulateOutdated {
                HStack(spacing: 8) {
                    Button {
                        Haptics.selection()
                        updateManager.exitDemo()
                    } label: {
                        Label("Exit demo", systemImage: "xmark.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.appAccent.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Entrance stagger

/// Fades + slides a section in when the cover first appears, staggered by
/// index so the screen composes itself top-to-bottom.
private struct Entrance: ViewModifier {
    let index: Int
    let appeared: Bool
    var hero = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : (hero ? 0.86 : 0.97))
            .offset(y: appeared ? 0 : 24)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.07 * Double(index)),
                       value: appeared)
    }
}

/// One-shot attention shake for the error icon.
private struct ErrorWiggler: ViewModifier {
    @State private var wiggled = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(wiggled ? 0 : -9))
            .onAppear {
                withAnimation(.spring(response: 0.12, dampingFraction: 0.4).repeatCount(3)) {
                    wiggled = true
                }
            }
    }
}

// MARK: - Button styles

/// The prominent CTA — gradient capsule with the app's glow language
/// (shadow radius scaled by the global glow settings) and a press spring.
/// Matches the app's bold .rounded typography.
private struct UpdatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.72)],
                                                  startPoint: .top, endPoint: .bottom))
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                }
            )
            .shadow(color: Color.appAccent.opacity(Color.glowEnabled ? 0.45 : 0),
                    radius: Color.glowEnabled ? Color.glowRadiusLarge * 0.4 : 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary CTA — tinted capsule (LiveContainer, Safari, Copy, Share…)
/// using the app's pill language. Height is tunable so compact rows sit
/// alongside the primary without fighting it.
private struct UpdateSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    var tint: Color = Color.appAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// The quiet "Maybe Later" text action — deliberately low-weight so it
/// never competes with the primary CTA.
private struct UpdateLaterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
#endif
