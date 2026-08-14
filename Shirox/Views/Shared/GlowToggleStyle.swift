import SwiftUI

// MARK: - GlowToggleStyle
//
// A reusable `ToggleStyle` that wraps the native iOS/macOS toggle and
// applies the app-wide glow effect when the toggle is ON. By setting this
// as the default toggle style (via `.toggleStyle(GlowToggleStyle())` on
// the root view, or by applying it to individual toggles), EVERY toggle
// in the app gets the glow automatically — no need to chain
// `.glowEffect(isOn:)` on each call site.
//
// The glow respects the global `Color.glowEnabled` setting and uses the
// shared `Color.glowOpacity(_:)` / `Color.glowRadiusToggle` tokens so it
// stays consistent with toggles that already use the old
// `.glowEffect(isOn:)` modifier.
//
// **Why a ToggleStyle and not a ViewModifier:** a ToggleStyle can read
// `configuration.isOn` directly, so it always knows the current state
// without the caller having to pass a binding. This means we can apply
// it once at the root and every Toggle inherits it.

struct GlowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The native toggle — same look and interaction as default.
        Toggle(configuration)
            .shadow(
                color: configuration.isOn && Color.glowEnabled
                    ? Color.appAccent.opacity(Color.glowOpacity(0.8))
                    : .clear,
                radius: configuration.isOn && Color.glowEnabled
                    ? Color.glowRadiusToggle
                    : 0
            )
            .onChange(of: configuration.isOn) { _ in
                // Light haptic on toggle flip, matching the rest of the app.
                if configuration.isOn { Haptics.selection() }
            }
    }
}

// MARK: - View extension for app-wide application

extension View {
    /// Applies `GlowToggleStyle` as the default toggle style for this view
    /// and all descendants. Apply once at the root of the app (or per-screen)
    /// so every Toggle gets the glow without per-call-site modifiers.
    func withGlowToggles() -> some View {
        self.toggleStyle(GlowToggleStyle())
    }
}
