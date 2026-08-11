import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AnimatedSplashView: View {
    @State private var isVisible = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
            VStack(spacing: 16) {
                // #92 — App logo. Prefers the bundled `app-logo.png` resource
                // (added to the Xcode project as a Resources file reference so
                // `UIImage(named: "app-logo")` resolves at runtime). Falls back
                // to the alternate / primary app icon from the asset catalog,
                // then to an SF Symbol on platforms where neither is available
                // (e.g. macOS without UIKit).
                Group {
                    #if canImport(UIKit)
                    if let logo = Self.bundledAppLogo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else if let uiIcon = UIApplication.shared.icon {
                        Image(uiImage: uiIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 86, height: 86)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        splashSymbol
                    }
                    #else
                    splashSymbol
                    #endif
                }
                .frame(width: 140, height: 140)
                .background(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.black, location: 0.0),
                                    .init(color: Color(red: 0.10, green: 0.22, blue: 0.55), location: 0.5),
                                    .init(color: Color(red: 0.32, green: 0.10, blue: 0.55), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            // Inner highlight rim — gives the tile a glassy app-icon sheen.
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.0)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                        .shadow(color: Color(red: 0.18, green: 0.22, blue: 0.65).opacity(0.45),
                                radius: 24, y: 10)
                )
                // Subtle pulse — oscillates between 1.0 and 1.05.
                .scaleEffect(isPulsing ? 1.05 : 1.0)

                Text("Shirox")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))

                Text("Anime · Manga · Tracker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .opacity(isVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) { isVisible = true }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    /// SF Symbol fallback used when no bundled app icon is available
    /// (e.g. on macOS where `UIApplication.shared.icon` is unavailable).
    private var splashSymbol: some View {
        Image(systemName: "play.tv.fill")
            .font(.system(size: 78, weight: .bold))
            .foregroundStyle(.white)
    }

    #if canImport(UIKit)
    /// #92 — Resolves the bundled `app-logo.png` (located at
    /// `Shirox/Resources/app-logo.png` and registered as a resource in the
    /// Xcode project). `UIImage(named:)` checks both the asset catalog and
    /// the bundle's `.resources` directory, so this picks up the loose PNG
    /// once it's added to a Resources build phase. Returns `nil` on
    /// platforms without UIKit (handled at the call site).
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

#if canImport(UIKit)
extension UIApplication {
    /// Returns the app's alternate icon if one is set, otherwise the primary
    /// app icon bundled in the asset catalog (or `nil` if neither is available).
    /// Useful for showing the real icon in places like the splash screen and
    /// the About page — `Image("AppIcon")` does not work for the brand-assets
    /// icon set used by this project.
    var icon: UIImage? {
        if let alternate = alternateIconName,
           let img = UIImage(named: alternate) {
            return img
        }
        // Look for the primary icon in the bundle's .appiconset / asset catalog.
        // The exact key depends on the asset layout, so try the common names.
        for name in ["AppIcon", "AppIcon60x60", "shirox-icon"] {
            if let img = UIImage(named: name) { return img }
        }
        return nil
    }
}
#endif
