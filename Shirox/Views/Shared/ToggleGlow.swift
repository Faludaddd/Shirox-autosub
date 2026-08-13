import SwiftUI

/// ViewModifier that applies a glow shadow to a Toggle when it's ON.
/// Works with the native SwiftUI Toggle by observing the binding value.
struct ToggleGlow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isOn && Color.glowEnabled
                    ? Color.appAccent.opacity(Color.glowIntensity * 0.5)
                    : .clear,
                radius: isOn && Color.glowEnabled
                    ? CGFloat(12 * Color.glowIntensity)
                    : 0
            )
    }
}

extension View {
    /// Applies a glow shadow when `isOn` is true. Must be on `View` (not `Toggle`)
    /// because modifiers like `.tint()` return `some View`, not `Toggle` — so the
    /// call chain `Toggle(...).tint(...).glowEffect(...)` requires `glowEffect` to
    /// be available on `some View`.
    func glowEffect(isOn: Bool) -> some View {
        modifier(ToggleGlow(isOn: isOn))
    }
}
