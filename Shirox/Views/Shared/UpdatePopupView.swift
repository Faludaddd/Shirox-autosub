import SwiftUI

/// The update popup modal. Rendered as a `.sheet` from the app root when
/// `AppUpdateManager.shared.availableUpdate` is non-nil.
///
/// Visual style: Liquid Glass — a frosted `.ultraThinMaterial` background
/// with translucency and depth, matching the global toggle style. The popup
/// is non-dismissible via swipe-down when the update is critical (forced
/// update); optional updates can be dismissed with the "Later" button.
struct UpdatePopupView: View {
    let info: AppUpdateManager.UpdateInfo
    let onDismiss: () -> Void

    @ObservedObject private var manager = AppUpdateManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showKSignHint = false
    @State private var showWebView = false

    var body: some View {
        ZStack {
            // Liquid Glass backdrop — frosted, translucent, with depth.
            backdrop
                .ignoresSafeArea()

            // Card
            card
                .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(info.isCritical)
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [info.downloadURL.absoluteString])
        }
        .sheet(isPresented: $showWebView) {
            UpdateWebView(url: info.downloadURL)
        }
        #endif
        .alert("Sent to KSign", isPresented: $showKSignHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The download link has been copied and the share sheet will open. Select KSign (or your preferred sideloading app) from the share sheet to import the IPA.")
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.55),
                Color.black.opacity(0.75)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.2)
                .padding(.vertical, 14)
            versionInfo
            changelogBlock
            actionButtons
            if !info.isCritical {
                dismissButton
            } else {
                exitButton
            }
        }
        .padding(22)
        .background(
            // Liquid Glass: ultraThinMaterial + subtle border + soft shadow.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 10)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 64, height: 64)
                    .overlay(Circle().strokeBorder(Color.appAccent.opacity(0.4), lineWidth: 1))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            Text("New Update Available")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if info.isCritical {
                Text("CRITICAL UPDATE")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.2)))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Version Info

    private var versionInfo: some View {
        HStack(spacing: 12) {
            versionBlock(label: "Current", value: info.currentVersion)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            versionBlock(label: "New", value: info.newVersion, highlight: true)
            Spacer()
        }
    }

    private func versionBlock(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("v\(value)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(highlight ? Color.appAccent : .primary)
        }
    }

    // MARK: - Changelog

    @ViewBuilder
    private var changelogBlock: some View {
        if !info.changelog.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("What's New")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(info.changelog)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 1. Download Update
            primaryButton(title: "Download Update", icon: "arrow.down.to.line.compact") {
                manager.markDownloadStarted()
                #if os(iOS)
                showWebView = true
                #endif
            }

            // 2. Copy Download Link
            secondaryButton(title: "Copy Download Link", icon: "doc.on.doc") {
                #if os(iOS)
                UIPasteboard.general.string = info.downloadURL.absoluteString
                ToastManager.shared.show(
                    title: "Link Copied",
                    message: "Download URL copied to clipboard",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
                #endif
            }

            // 3. Send to KSign
            secondaryButton(title: "Send to KSign", icon: "arrow.up.forward.app") {
                #if os(iOS)
                // KSign registers a custom URL scheme; if it's not installed
                // the canOpenURL check fails and we fall back to the share
                // sheet so the user can pick any sideloading app.
                if let ksignURL = URL(string: "ksign://import?url=\(info.downloadURL.absoluteString)"),
                   UIApplication.shared.canOpenURL(ksignURL) {
                    UIApplication.shared.open(ksignURL)
                } else {
                    UIPasteboard.general.string = info.downloadURL.absoluteString
                    showKSignHint = true
                    showShareSheet = true
                }
                #endif
            }

            // 4. Open in Other Sideloading Apps (share sheet)
            secondaryButton(title: "Open in Other Sideloading Apps", icon: "square.and.arrow.up") {
                #if os(iOS)
                showShareSheet = true
                #endif
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Dismiss / Exit

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Text("Maybe Later")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var exitButton: some View {
        VStack(spacing: 6) {
            Text("This update is required to continue using the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button {
                #if os(iOS)
                exit(0)
                #endif
            } label: {
                Text("Exit App")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Button Styles

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appAccent)
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - In-App Web View (for Download Update)

#if os(iOS)
import WebKit

struct UpdateWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
