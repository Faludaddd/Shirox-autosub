import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// #92 / #109 — Polished loading screen shown on app launch.
///
/// Layout: centered `app-logo` icon → "Shirox" wordmark (large bold) →
/// "Anime · Manga · Tracker" subtitle → circular `ProgressView` spinner.
/// The icon gets a subtle repeating pulse (scale 1.0 ↔ 1.05) so the screen
/// never feels frozen. The whole screen sits on a clean black → dark gray
/// gradient. Duration is driven externally by `ShiroxApp` (3.5s — see
/// `try? await Task.sleep(nanoseconds: 3_500_000_000)` in `ShiroxApp.swift`),
/// so this view only owns the visual, not the timer.
struct AnimatedSplashView: View {
    /// Fade-in for the whole stack on appear.
    @State private var isVisible = false
    /// Drives the icon's repeating scale pulse.
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Clean gradient background — black to dark gray, top → bottom.
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.03),
                    Color(red: 0.10, green: 0.10, blue: 0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                // ── Icon ────────────────────────────────────────────────
                // `app-logo` lives in the asset catalog (`Assets.xcassets/
                // app-logo.imageset`), so SwiftUI's bundled `Image(_:)`
                // initializer resolves it directly — no UIKit fallback needed
                // on iOS/tvOS. On macOS without an asset catalog contribution
                // we still try `Image("app-logo")` first (the resource is
                // also bundled as `Shirox/Resources/app-logo.png`), then fall
                // back to an SF Symbol so the splash always renders *something*.
                iconView
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.30),
                                        Color.white.opacity(0.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(
                        color: Color.white.opacity(0.10),
                        radius: 24, y: 10
                    )
                    // Subtle pulse — oscillates between 1.0 and 1.05 forever.
                    .scaleEffect(isPulsing ? 1.05 : 1.0)

                // ── Wordmark ───────────────────────────────────────────
                Text("Shirox+")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                // ── Subtitle ───────────────────────────────────────────
                Text("Anime · Manga · Tracker")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))

                // ── Loading indicator ──────────────────────────────────
                // Spacing cushion above the spinner so it reads as a separate
                // "loading" affordance rather than crowding the subtitle.
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.7))
                    .scaleEffect(0.9)
                    .padding(.top, 8)
            }
            .opacity(isVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        // #109 — Smooth dismissal transition applied directly on the splash
        // view itself. Combines a fade with a subtle scale-up (1.0 → 1.05) so
        // the splash appears to gently "lift" away rather than just blinking
        // out. Mirrors the matching `.transition(...)` on the
        // `AnimatedSplashView()` call site in `ShiroxApp` so the dismissal
        // animation is consistent regardless of which modifier wins the view
        // tree's transition resolution.
        .transition(.opacity.combined(with: .scale(scale: 1.05)))
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) { isVisible = true }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    /// Resolves the `app-logo` asset (preferred) and falls back to an SF Symbol
    /// on platforms where the bundled asset can't be resolved (e.g. macOS
    /// without the asset catalog contribution). Keeps the splash screen
    /// rendering *something* icon-shaped on every platform.
    @ViewBuilder
    private var iconView: some View {
        #if canImport(UIKit)
        // The asset catalog `app-logo` is the primary source on iOS/tvOS.
        // Fall back to the loose PNG in Resources/ then to an SF Symbol.
        if let uiImage = Self.bundledAppLogo {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            splashSymbol
        }
        #else
        // macOS: try the asset catalog name first, then a loose bundle
        // resource, then the SF Symbol fallback.
        splashSymbol
        #endif
    }

    /// SF Symbol fallback used when no bundled app icon is available
    /// (e.g. on macOS without UIKit / asset catalog contribution).
    private var splashSymbol: some View {
        Image(systemName: "play.tv.fill")
            .font(.system(size: 64, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.22, blue: 0.55),
                        Color(red: 0.32, green: 0.10, blue: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    #if canImport(UIKit)
    /// #92 — Resolves the bundled `app-logo` asset. `UIImage(named:)` checks
    /// both the asset catalog and the bundle's `.resources` directory, so this
    /// picks up the loose PNG at `Shirox/Resources/app-logo.png` once it's added
    /// to a Resources build phase. Returns `nil` on platforms without UIKit
    /// (handled at the call site).
    private static let bundledAppLogo: UIImage? = {
        // Try the SwiftUI-friendly name first.
        if let img = UIImage(named: "app-logo") { return img }
        // Some build configurations mangle loose-resource names; try a
        // filename-with-extension lookup against the main bundle as a
        // fallback before giving up.
        if let url = Bundle.main.url(forResource: "app-logo", withExtension: "png"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        return nil
    }()
    #endif
}
