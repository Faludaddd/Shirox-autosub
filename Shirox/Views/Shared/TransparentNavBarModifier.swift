import SwiftUI
#if os(iOS)
import UIKit

// MARK: - TransparentNavBarModifier

/// Makes the navigation bar transparent so content can scroll underneath it.
///
/// - On iOS 16+ uses the native `.toolbarBackground(.hidden, for: .navigationBar)` modifier.
/// - On iOS 15 falls back to configuring `UINavigationBar.appearance()` via a hidden
///   `NavBarAppearanceConfigurator` view inserted into the hierarchy.
struct TransparentNavBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content.background(NavBarAppearanceConfigurator())
        }
    }
}

// MARK: - NavBarAppearanceConfigurator (iOS 15 fallback)

/// A no-op `UIView` whose sole job is to (re)apply a transparent navigation-bar appearance
/// whenever SwiftUI inserts or updates it. Used as a `.background(...)` so it participates in
/// the view lifecycle while remaining invisible.
struct NavBarAppearanceConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        Self.applyTransparentAppearance()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Self.applyTransparentAppearance()
    }

    /// Configures the standard, scroll-edge, and compact navigation-bar appearances with a
    /// transparent background so the bar stays see-through in every scroll state.
    private static func applyTransparentAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.shadowColor = nil

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = nil
    }
}

// MARK: - View Extension

extension View {
    /// Makes the navigation bar transparent (iOS 16+ native, iOS 15 appearance fallback).
    func transparentNavBar() -> some View {
        modifier(TransparentNavBarModifier())
    }
}

#endif
