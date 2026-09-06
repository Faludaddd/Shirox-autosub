#if canImport(UIKit)
import SwiftUI
import CryptoKit

// MARK: - Update Download Service
//
// Owns the "get the new IPA onto this device" half of the forced-update
// flow (AppUpdateManager owns the "is one needed" half):
//
//   connecting → downloading → verifying → succeeded → handedOff
//                                            ↘ failed (retryable)
//
// The download runs on a plain URLSession download task so progress is
// real (delegate callbacks, not polling). Verification streams a SHA-256
// over the file and compares it against the checksum published next to
// the release asset (`<downloadURL>.sha256`) — the same checksum the
// release pipeline regenerates on every build. If the checksum can't be
// fetched, verification is skipped (best-effort) rather than blocking
// the update.
//
// iOS cannot install an IPA from inside a sandboxed app — installation is
// AltStore's job, so the final step hands the REMOTE url to AltStore via
// its `altstore://install?url=…` scheme (LSApplicationQueriesSchemes in
// Info.plist lets us query it first). AltStore re-downloads and installs,
// iOS replaces the app in place, and the user relaunches into the new
// version — where the launch version check passes and the gate never
// shows again.
final class UpdateDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateDownloadService()

    enum Phase: Equatable {
        case idle
        case connecting
        case downloading(progress: Double, downloadedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double)
        case verifying(progress: Double)
        /// Downloaded + verified; the handoff to the installer is imminent.
        case succeeded
        /// AltStore was opened — it is installing the update now.
        case handedOff
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Set when an install handoff was attempted and AltStore isn't
    /// installed. The package is still on disk (see `packageURL`), so the
    /// UI offers sharing it instead of a pointless re-download.
    @Published private(set) var installerMissing = false

    /// Local URL of the downloaded + verified .ipa (nil until success).
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
        case .idle, .failed, .succeeded, .handedOff: return false
        default: return true
        }
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
        installerMissing = false
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

    /// Hands the update to the installer (AltStore). Re-checks presence
    /// every time so a user who installs AltStore mid-flow can retry.
    func openInstaller() {
        guard let remote = remoteURL else { return }
        guard let schemeProbe = URL(string: "altstore://"),
              UIApplication.shared.canOpenURL(schemeProbe) else {
            installerMissing = true
            Haptics.error()
            setPhase(.failed(reason: "AltStore wasn't found on this device. Install or open AltStore, then tap Try Again — or share the verified package and install it with any sideload tool."))
            return
        }
        var comps = URLComponents()
        comps.scheme = "altstore"
        comps.host = "install"
        comps.queryItems = [URLQueryItem(name: "url", value: remote.absoluteString)]
        guard let installURL = comps.url else { return }
        UIApplication.shared.open(installURL)
        Haptics.success()
        setPhase(.handedOff)
    }

    private func setPhase(_ newPhase: Phase) {
        if Thread.isMainThread { phase = newPhase }
        else { DispatchQueue.main.async { self.phase = newPhase } }
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

            func complete() {
                // Success (or best-effort when no checksum was fetched —
                // GitHub itself served the bytes over TLS either way).
                self.setPhase(.succeeded)
                Haptics.success()
                // Let the success animation land before bouncing to AltStore.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    self.openInstaller()
                }
            }

            if let expected = self.expectedSHA256, !readFailed {
                if digest.caseInsensitiveCompare(expected) == .orderedSame {
                    complete()
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    self.packageURL = nil
                    self.setPhase(.failed(reason: "The download didn't match its published checksum — the package is corrupt or truncated. Retry downloads it fresh."))
                    Haptics.error()
                }
            } else {
                complete()
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

// MARK: - Forced Update View
//
// The full-screen gate shown whenever AppUpdateManager confirms a newer
// version exists. It is presented as a fullScreenCover from RootTabView and
// deliberately offers NO dismissal — the cover clears only when a real
// version check confirms the app is current again (after AltStore installs
// the update and iOS relaunches the app).
//
// Visual language mirrors the rest of Shirox+ exactly: Color.appAccent
// (user's chosen accent), .rounded typography with monospaced digits,
// secondary.opacity(0.08) cards in 22pt continuous corners, capsule pills
// with tint.opacity(0.12) fills, hairline .primary.opacity(0.06) strokes,
// spring(response: 0.3–0.5, dampingFraction: 0.8) motion, glow language
// from GlowToggleStyle (shadow radius scaled by glowIntensity), and
// Haptics on every meaningful state change.
struct ForcedUpdateView: View {
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var installer = UpdateDownloadService.shared

    @State private var appeared = false
    @State private var changelogExpanded = false
    @State private var shareItem: ShareItem?
    @State private var orbitAngle: Double = 0
    @State private var breath = false
    @State private var bob: CGFloat = 0
    @State private var shakeOffset: CGFloat = 0

    private var phase: UpdateDownloadService.Phase { installer.phase }

    private var info: AppUpdateManager.UpdateInfo? {
        switch updateManager.state {
        case .available(let info), .dismissed(let info): return info
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            background
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
                    Color.clear.frame(height: 8)
                    identityMark
                        .modifier(Entrance(index: 0, appeared: appeared))
                    heroEmblem
                        .modifier(Entrance(index: 1, appeared: appeared, hero: true))
                        .offset(x: shakeOffset)
                    titleBlock
                        .modifier(Entrance(index: 2, appeared: appeared))
                    if let info {
                        versionTransition(current: info.currentVersion, next: info.newVersion)
                            .modifier(Entrance(index: 3, appeared: appeared))
                        stateContent
                            .modifier(Entrance(index: 4, appeared: appeared))
                        ctaArea(info: info)
                            .modifier(Entrance(index: 5, appeared: appeared))
                        footerBlock
                            .modifier(Entrance(index: 6, appeared: appeared))
                    } else {
                        ProgressView()
                            .padding(.top, 40)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .onAppear {
            Haptics.warning()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            // Ambient loops — orbit drift, blob breathing, icon float.
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { orbitAngle = 360 }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { breath = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { bob = 5 }
            // Auto-start: a forced update shouldn't wait for the user to
            // find the button. The Update Now button remains as the
            // guaranteed entry if the auto-start raced a state change.
            if let info {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if installer.phase == .idle { installer.start(info: info) }
                }
            }
        }
        .onChange(of: installer.phase) { newPhase in
            guard case .failed = newPhase else { return }
            // One-shot wiggle on failure — three quick keyframes.
            shakeOffset = 14
            withAnimation(.spring(response: 0.12, dampingFraction: 0.18)) { shakeOffset = -10 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(response: 0.12, dampingFraction: 0.18)) { shakeOffset = 7 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) { shakeOffset = 0 }
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Circle()
                .fill(RadialGradient(colors: [Color.appAccent.opacity(0.20), Color.appAccent.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 210))
                .frame(width: 360, height: 360)
                .offset(x: 150, y: -290)
                .scaleEffect(breath ? 1.12 : 0.9)
            Circle()
                .fill(RadialGradient(colors: [Color.purple.opacity(0.13), Color.purple.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 180))
                .frame(width: 300, height: 300)
                .offset(x: -160, y: 340)
                .scaleEffect(breath ? 0.92 : 1.1)
        }
        .ignoresSafeArea()
    }

    // MARK: - Identity

    private var identityMark: some View {
        VStack(spacing: 8) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.appAccent.opacity(0.35), radius: 10, y: 4)
            Text("SHIROX+")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hero

    private var heroEmblem: some View {
        ZStack {
            // Ambient glow behind the disc.
            Circle()
                .fill(Color.appAccent.opacity(0.16))
                .frame(width: 185, height: 185)
                .blur(radius: 36)
                .scaleEffect(breath ? 1.08 : 0.94)

            // Dashed orbit + three travelling sparkles. The whole container
            // rotates; each dot is pre-rotated 120° apart on the ring.
            ZStack {
                Circle()
                    .stroke(Color.appAccent.opacity(0.38),
                            style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 8]))
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == 0 ? Color.appAccent : Color.secondary.opacity(0.55))
                        .frame(width: i == 0 ? 6 : 4)
                        .offset(y: -106)
                        .rotationEffect(.degrees(Double(i) * 120))
                }
            }
            .frame(width: 212, height: 212)
            .rotationEffect(.degrees(orbitAngle))

            // Determinate progress ring (download only), just outside the disc.
            if case .downloading(let progress, _, _, _) = phase {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.003, progress))
                        .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 174, height: 174)
            }

            emblemDisc
        }
        .frame(width: 250, height: 250)
    }

    private var emblemDisc: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .stroke(LinearGradient(colors: [Color.appAccent.opacity(0.85), Color.purple.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5)
            Circle()
                .fill(Color.appAccent.opacity(0.07))
                .padding(12)

            switch phase {
            case .idle, .connecting:
                VStack(spacing: 7) {
                    Image(systemName: phase == .connecting ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [Color.appAccent, Color.purple.opacity(0.8)],
                                                         startPoint: .top, endPoint: .bottom))
                        .offset(y: bob)
                    if phase == .connecting {
                        Text("Starting")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)

            case .downloading(let progress, _, _, _):
                VStack(spacing: 1) {
                    Text("\(Int((progress * 100).rounded()))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("PERCENT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)

            case .verifying:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .scaleEffect(breath ? 1.04 : 0.96)
                    Text("Verifying")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)

            case .succeeded, .handedOff:
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 92, height: 92)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.green)
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))

            case .failed:
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.orange)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 150, height: 150)
        .shadow(color: Color.appAccent.opacity(Color.glowEnabled ? 0.35 : 0),
                radius: Color.glowEnabled ? Color.glowRadiusLarge * 0.45 : 0, y: 10)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: phase)
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text(titleText)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: titleText)
            Text(subtitleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var titleText: String {
        switch phase {
        case .idle, .connecting: return "Update Required"
        case .downloading: return "Downloading Update"
        case .verifying: return "Verifying Update"
        case .succeeded: return "Update Ready"
        case .handedOff: return "Installing Update"
        case .failed: return "Update Failed"
        }
    }

    private var subtitleText: String {
        switch phase {
        case .idle, .connecting:
            return "A required update is available for Shirox+."
        case .downloading:
            return "Fetching the new version — you can keep this screen open."
        case .verifying:
            return "Checking the package is authentic and complete."
        case .succeeded:
            return "The update is downloaded and verified."
        case .handedOff:
            return "AltStore is finishing the installation."
        case .failed:
            return "Something went wrong — retry below."
        }
    }

    // MARK: - Version transition

    private func versionTransition(current: String, next: String) -> some View {
        HStack(spacing: 10) {
            Text(current)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.8))

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .scaleEffect(x: appeared ? 1 : 0.1, y: 1)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.35), value: appeared)

            Text(next)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.7)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.appAccent.opacity(0.4), radius: 8, y: 3)
        }
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch phase {
        case .idle, .connecting:
            if let info { changelogCard(info) }
        case .failed:
            VStack(spacing: 14) {
                errorCard
                if let info { changelogCard(info) }
            }
        case .downloading(let progress, let downloaded, let total, let speed):
            progressBlock(progress: progress, downloaded: downloaded, total: total, speed: speed)
        case .verifying:
            verifyingBlock
        case .succeeded:
            successCard
        case .handedOff:
            handoffCard
        }
    }

    private var errorCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("The update couldn't complete")
                    .font(.subheadline.weight(.semibold))
                if case .failed(let reason) = phase {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1))
    }

    private func changelogCard(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func progressBlock(progress: Double, downloaded: Int64, total: Int64, speed: Double) -> some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.75)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, geo.size.width * progress))
                        .opacity(breath ? 1.0 : 0.85)
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.25), value: progress)

            HStack(spacing: 0) {
                statBlock("\(Int((progress * 100).rounded()))%", "Percent")
                statDivider
                statBlock("\(bytes(downloaded)) of \(bytes(total))", "Downloaded")
                statDivider
                statBlock("\(bytes(Int64(speed)))/s", "Speed")
            }

            Text("Downloading update package…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var verifyingBlock: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Verifying package integrity")
                    .font(.subheadline.weight(.semibold))
                Text("Matching the download against its published checksum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.appAccent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.appAccent.opacity(0.15), lineWidth: 1))
    }

    private var successCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update package verified")
                    .font(.subheadline.weight(.semibold))
                Text("Handing off to your installer…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.green.opacity(0.18), lineWidth: 1))
    }

    private var handoffCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text("AltStore is installing the update")
                    .font(.subheadline.weight(.semibold))
                Text("Shirox+ will close and restart once installation completes. If you land back here before that happens, tap Reopen AltStore to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.appAccent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.appAccent.opacity(0.16), lineWidth: 1))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 30)
    }

    private func statBlock(_ value: String, _ label: String) -> some View {
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

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    // MARK: - CTA

    @ViewBuilder
    private func ctaArea(info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(spacing: 12) {
            switch phase {
            case .idle, .connecting:
                Button {
                    Haptics.light()
                    installer.start(info: info)
                } label: {
                    Label("Update Now", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(UpdatePrimaryButtonStyle())

            case .failed:
                if installer.installerMissing {
                    Button {
                        Haptics.light()
                        installer.openInstaller()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(UpdatePrimaryButtonStyle())
                    if let package = installer.packageURL {
                        Button {
                            Haptics.light()
                            shareItem = ShareItem(url: package)
                        } label: {
                            Label("Share Package", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(UpdateSecondaryButtonStyle())
                    }
                } else {
                    Button {
                        Haptics.light()
                        installer.start(info: info)
                    } label: {
                        Label("Retry Download", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(UpdatePrimaryButtonStyle())
                }

            case .succeeded:
                Button {
                    Haptics.light()
                    installer.openInstaller()
                } label: {
                    Label("Install Now", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(UpdatePrimaryButtonStyle())

            case .handedOff:
                Button {
                    Haptics.light()
                    installer.openInstaller()
                } label: {
                    Label("Reopen AltStore", systemImage: "arrow.clockwise")
                }
                .buttonStyle(UpdateSecondaryButtonStyle())

            default:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: phase)
    }

    // MARK: - Footer

    private var footerBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("This update is required to keep using Shirox+.")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)

            if let last = updateManager.lastSuccessfulCheck {
                Text("Checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if updateManager.simulateOutdated {
                Button {
                    Haptics.selection()
                    updateManager.exitDemo()
                } label: {
                    Label("Exit demo mode", systemImage: "xmark.circle")
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

// MARK: - Entrance stagger

/// Fades + slides a section in when the gate first appears, staggered by
/// index so the screen composes itself top-to-bottom.
private struct Entrance: ViewModifier {
    let index: Int
    let appeared: Bool
    var hero = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : (hero ? 0.82 : 0.97))
            .offset(y: appeared ? 0 : 24)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.07 * Double(index)),
                       value: appeared)
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

/// The secondary CTA — the app's standard accent-on-accent-0.1 capsule
/// (same recipe as the About page's "Check for Updates" button).
private struct UpdateSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.appAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule().fill(Color.appAccent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Share sheet

/// Wrapper for presenting the verified .ipa via the system share sheet —
/// the fallback path when AltStore isn't installed (AirDrop to another
/// installer, save to Files, etc.).
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
