import SwiftUI

/// ViewModifier that applies a glow shadow to a Toggle when it's ON.
/// Works with the native SwiftUI Toggle by observing the binding value.
struct ToggleGlow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isOn && Color.glowEnabled
                    ? Color.appAccent.opacity(Color.glowOpacity(0.8))
                    : .clear,
                radius: isOn && Color.glowEnabled
                    ? Color.glowRadiusToggle
                    : 0
            )
    }
}

extension View {
    /// Applies a glow shadow when `isOn` is true. Defined on `View` (not `Toggle`)
    /// so it remains callable after modifiers like `.tint()` that return `some View`.
    func glowEffect(isOn: Bool) -> some View {
        modifier(ToggleGlow(isOn: isOn))
    }
}
