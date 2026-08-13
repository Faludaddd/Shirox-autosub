import Foundation
import Combine
import SwiftUI

/// App-wide mode switch between Anime and Reading (manga). Persisted to
/// UserDefaults so the user's last mode is restored on launch. Observable
/// so any view can react to mode changes by observing `shared`.
///
/// The mode is the SINGLE source of truth for which experience the app is
/// showing. Home, Search, and the toolbar mode-toggle icon all read from
/// here. There is NO back button — the only way to switch is to tap the
/// mode icon, which flips this value.
@MainActor
final class AppModeManager: ObservableObject {
    static let shared = AppModeManager()

    enum Mode: String, CaseIterable {
        case anime
        case reading

        var label: String {
            switch self {
            case .anime:   return "Anime"
            case .reading: return "Reading"
            }
        }

        /// SF Symbol shown on the mode-toggle button. Shows the OPPOSITE
        /// mode's icon so the user knows what tapping will switch TO.
        var toggleIcon: String {
            switch self {
            case .anime:   return "book.fill"        // tap → go to Reading
            case .reading: return "play.tv.fill"     // tap → go to Anime
            }
        }

        var toggleAccessibilityLabel: String {
            switch self {
            case .anime:   return "Switch to Reading Mode"
            case .reading: return "Switch to Anime Mode"
            }
        }
    }

    private let key = "appMode"

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: key) }
    }

    private init() {
        // CRITICAL: Always start in Anime Mode on launch. The user's last
        // selected mode is NOT restored — the app ALWAYS launches into the
        // Anime experience. The user can freely switch to Reading Mode
        // after launch by tapping the mode-toggle icon.
        self.mode = .anime
    }

    func toggle() {
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.3)) {
            mode = (mode == .anime) ? .reading : .anime
        }
    }
}
