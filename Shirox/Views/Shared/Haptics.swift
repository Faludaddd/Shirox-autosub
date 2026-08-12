import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Lightweight wrapper around UIKit's haptic feedback generators.
///
/// All calls are no-ops on non-iOS platforms (macOS / tvOS) so call sites can
/// invoke `Haptics.light()` etc. unconditionally without sprinkling `#if os(iOS)`
/// guards everywhere. Haptics are most useful on iPhone — iPad / Apple TV / Mac
/// don't have a Taptic Engine, so the system calls are simply skipped there.
struct Haptics {
    static func light() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func heavy() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }

    static func success() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func error() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    static func warning() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func selection() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
