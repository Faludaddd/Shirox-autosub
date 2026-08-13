import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Settings tab for app updates.
///
/// Replaces the old popup-based update flow (`UpdatePopupView`). Instead of a
/// one-shot modal that interrupts the user on launch, the update system now
/// lives as a dedicated settings page the user can visit on their own schedule.
/// The page surfaces the same `AppUpdateManager` state — current version, last
/// check, available update, changelog — but as a calm, scrollable card layout
/// rather than a system `Form`.
///
/// Layout: a `ScrollView` + `VStack` of five custom cards. Each card is built
/// inline with its own spacing, corner radius, and visual hierarchy — there is
/// deliberately NO shared "card" modifier. The Version Info hero card needs a
/// very different rhythm (large, centered, generous padding) than the compact
/// Auto-Update toggles card (tight rows, small radius), so the two are shaped
/// independently.
struct UpdateSettingsPage: View {
    @ObservedObject private var manager = AppUpdateManager.shared

    /// Whether the app should look for updates automatically on launch / in the
    /// background. Lives in its own `update.` UserDefaults namespace so it never
    /// collides with anime/manga settings.
    @AppStorage("update.autoCheck") private var autoCheck: Bool = true
    /// How often (in minutes) the auto-check should run. Stored in minutes
    /// because that's the unit the stepper operates in; `AppUpdateManager`'s
    /// own `checkIntervalSeconds` remains the canonical value used by the
    /// background check scheduler.
    @AppStorage("update.checkIntervalMinutes") private var checkIntervalMinutes: Int = 60

    /// Drives the system share sheet (Copy / Send-to-KSign fallback / Share
    /// via…). The URL to share is captured into `shareItem` at tap time so the
    /// sheet always has a valid payload even if `availableUpdate` is cleared
    /// between the tap and the sheet's appearance.
    @State private var showShareSheet = false
    @State private var shareItem: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                versionInfoCard
                checkForUpdatesCard
                if manager.availableUpdate != nil {
                    downloadOptionsCard
                }
                autoUpdateCard
                aboutCard
            }
            .padding()
        }
        .navigationTitle("Updates")
        .inlineNavBar()
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            if let url = shareItem {
                UpdateSettingsShareSheet(items: [url.absoluteString])
            }
        }
        #endif
    }

    // MARK: - 1. Version Info Card
    //
    // The hero of the page: a large, centered app icon, the version + build
    // numbers in display weight, and a compact "last checked" pill. Built tall
    // and airy on purpose so it reads as the page's focal point.

    private var versionInfoCard: some View {
        VStack(spacing: 14) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)

            VStack(spacing: 4) {
                Text("Shirox")
                    .font(.system(size: 26, weight: .bold))
                HStack(spacing: 6) {
                    Text("v\(manager.currentVersion)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Build \(manager.currentBuild)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            lastCheckedPill
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    /// Compact capsule showing when the manifest was last fetched. Uses
    /// `RelativeDateTimeFormatter`-style output via `Text(date, style: .relative)`
    /// so it stays human-readable ("5 minutes ago") and auto-updates in-place.
    @ViewBuilder
    private var lastCheckedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Last checked")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let date = manager.lastCheckAt {
                Text(date, style: .relative)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            } else {
                Text("Never")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    // MARK: - 2. Check for Updates Card
    //
    // A header row + a single full-width primary button. While checking, the
    // button swaps its icon for a spinner and disables itself. Below the
    // button, the card conditionally reveals either an "update available"
    // block (new version, critical badge, changelog) or an "up to date" block
    // — never both.

    private var checkForUpdatesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                Text("Check for Updates")
                    .font(.headline)
                Spacer()
            }

            checkButton

            if let info = manager.availableUpdate {
                updateAvailableBlock(info)
            } else if let last = manager.lastCheckAt, !manager.isChecking {
                upToDateBlock(last)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var checkButton: some View {
        Button {
            Haptics.light()
            Task { await manager.checkForUpdates(force: true) }
        } label: {
            HStack(spacing: 8) {
                if manager.isChecking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(manager.isChecking ? "Checking…" : "Check Now")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.appAccent)
            )
        }
        .buttonStyle(.plain)
        .disabled(manager.isChecking)
    }

    /// Accent-tinted sub-block shown when `AppUpdateManager.availableUpdate`
    /// is non-nil. Surfaces the version transition, a critical badge (when the
    /// gap is large), and the changelog.
    private func updateAvailableBlock(_ info: AppUpdateManager.UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color.appAccent)
                Text("Update Available")
                    .font(.subheadline.weight(.bold))
                if info.isCritical {
                    Text("CRITICAL")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.2)))
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("v\(info.currentVersion)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("v\(info.newVersion)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.appAccent)
            }

            if !info.changelog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(info.changelog)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.appAccent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 0.8)
        )
    }

    /// Green-tinted sub-block shown after a check finds no newer version.
    private func upToDateBlock(_ date: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're up to date")
                    .font(.subheadline.weight(.medium))
                Text("Checked \(date, style: .relative).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.green.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - 3. Download Options Card
    //
    // Only rendered when an update is available. The first button (Download)
    // is the primary action — solid accent fill — and opens the release URL in
    // the system browser. The remaining three are secondary rows (Copy Link,
    // Send to KSign, Share via…) laid out as a vertical stack of compact,
    // chevroned list rows.

    private var downloadOptionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.fill")
                    .foregroundStyle(Color.appAccent)
                Text("Download Options")
                    .font(.headline)
                Spacer()
            }

            if let info = manager.availableUpdate {
                downloadPrimaryButton(info)
                downloadSecondaryRow("Copy Download Link", icon: "doc.on.doc") {
                    copyLink(info)
                }
                downloadSecondaryRow("Send to KSign", icon: "arrow.up.forward.app") {
                    sendToKSign(info)
                }
                downloadSecondaryRow("Share via…", icon: "square.and.arrow.up") {
                    Haptics.light()
                    shareItem = info.downloadURL
                    showShareSheet = true
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func downloadPrimaryButton(_ info: AppUpdateManager.UpdateInfo) -> some View {
        Button {
            Haptics.light()
            openInBrowser(info.downloadURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 16, weight: .bold))
                Text("Download Update")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.appAccent)
            )
        }
        .buttonStyle(.plain)
    }

    /// Compact list-style row used for the three secondary download actions.
    /// Visually distinct from the primary button (no fill, accent-colored icon,
    /// trailing chevron) so the hierarchy reads at a glance.
    private func downloadSecondaryRow(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Download Actions

    /// Opens the release URL in the system browser via `UIApplication.shared.open`.
    private func openInBrowser(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        _ = url
        #endif
    }

    /// Copies the download URL to the system clipboard and confirms with a toast.
    private func copyLink(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.light()
        #if os(iOS)
        UIPasteboard.general.string = info.downloadURL.absoluteString
        ToastManager.shared.show(
            title: "Link Copied",
            message: "Download URL copied to clipboard",
            icon: "checkmark.circle.fill",
            iconColor: .green
        )
        #else
        _ = info
        #endif
    }

    /// Tries to hand the download URL to KSign via its `ksign://import?url=…`
    /// custom URL scheme. If KSign isn't installed (canOpenURL fails) the link
    /// is copied to the clipboard and the system share sheet is presented so
    /// the user can pick any other sideloading app.
    private func sendToKSign(_ info: AppUpdateManager.UpdateInfo) {
        Haptics.light()
        #if os(iOS)
        let urlString = info.downloadURL.absoluteString
        if let ksignURL = URL(string: "ksign://import?url=\(urlString)"),
           UIApplication.shared.canOpenURL(ksignURL) {
            UIApplication.shared.open(ksignURL)
            ToastManager.shared.show(
                title: "Sent to KSign",
                message: "Opening KSign to import the IPA…",
                icon: "arrow.up.forward.app",
                iconColor: Color.appAccent
            )
        } else {
            // KSign isn't installed — copy the link so the user can paste it
            // into whichever sideloading app they pick from the share sheet.
            UIPasteboard.general.string = urlString
            ToastManager.shared.show(
                title: "KSign Not Found",
                message: "Link copied — pick a sideloading app from the share sheet.",
                icon: "exclamationmark.bubble.fill",
                iconColor: .orange
            )
            shareItem = info.downloadURL
            showShareSheet = true
        }
        #else
        _ = info
        #endif
    }

    // MARK: - 4. Auto-Update Settings Card
    //
    // Two controls: a master Toggle (Auto-check for updates) and a Stepper for
    // the check interval in minutes. The stepper is disabled (and dimmed) when
    // auto-check is off, so the dependency between the two is visually obvious.
    // Both controls fire `Haptics.selection()` on change for tactile feedback.

    private var autoUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gear.badge")
                    .foregroundStyle(Color.appAccent)
                Text("Auto-Update")
                    .font(.headline)
                Spacer()
            }

            Toggle(isOn: $autoCheck) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-check for updates")
                        .font(.subheadline)
                    Text("Periodically look for new versions in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)
            .onChangeOf(autoCheck) { _ in Haptics.selection() }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Check interval")
                        .font(.subheadline)
                    Spacer()
                    Text("\(checkIntervalMinutes) min")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Stepper(
                    value: $checkIntervalMinutes,
                    in: 15...720,
                    step: 15
                ) {
                    Text("Every \(checkIntervalMinutes) minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!autoCheck)
                .onChangeOf(checkIntervalMinutes) { _ in Haptics.selection() }
            }
            .opacity(autoCheck ? 1.0 : 0.5)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    // MARK: - 5. About Card
    //
    // A short, plain-language explanation of how the update system works. Kept
    // compact (small radius, tight padding) so it reads as a footnote rather
    // than another interactive surface.

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.appAccent)
                Text("About Updates")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text("Shirox checks a public version manifest for new releases. When a newer version is found, it appears here with the changelog and download options. You can install updates via KSign or any sideloading app — Shirox itself never modifies its own bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

// MARK: - Share Sheet (iOS)

#if os(iOS)
/// `UIActivityViewController` bridge used by the Download Options card's
/// "Share via…" and "Send to KSign" fallback paths. Deliberately a separate
/// type from `UpdateShareSheet` (defined in `UpdatePopupView.swift`) so this
/// page stays self-contained even if the legacy popup is removed.
struct UpdateSettingsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
