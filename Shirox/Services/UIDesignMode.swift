import Foundation
import SwiftUI
import Combine

// MARK: - UI Design Mode (Batch 27)
//
// The app-level presentation switch: SHIROX (the custom streaming-style
// design — the original home hero, custom cards/carousels, transparent
// full-bleed navbar) vs APPLE (the DEFAULT native iOS presentation —
// standard navigation bar with a title, native hero/sections/cards built
// from plain system components, zero custom chrome).
//
// The switch changes ONLY the presentation layer. Everything else is
// shared and never duplicated:
//   SHARED:  data models, providers, chains, networking, caching,
//            playback, user data, search, favorites, watch history,
//            detail data, schedule data, settings storage
//   SHIROX:  Home hero/sections/cards presentation, transparent navbar
//            treatment, the custom carousel + pill design language
//   APPLE:   the same Home content rendered with native components —
//            standard NavigationStack/NavigationBar with a large title,
//            a plain paged TabView hero, standard section headers,
//            simple poster cards, native pull-to-refresh
//
// Both modes expose the SAME features (every shelf, Continue Watching,
// See All routing, Surprise Me entry points, context menus, navigation
// destinations) — switching presentation never removes functionality.
@MainActor
final class UIDesignModeManager: ObservableObject {
    static let shared = UIDesignModeManager()

    enum Mode: String, CaseIterable, Identifiable {
        case shirox
        case apple

        var id: String { rawValue }

        var label: String {
            switch self {
            case .shirox: return "Shirox"
            case .apple:  return "Apple"
            }
        }

        var description: String {
            switch self {
            case .shirox:
                return "The custom Shirox streaming design — full-bleed hero, official title logos, capsule pills, transparent chrome."
            case .apple:
                return "The standard iOS design — native navigation bar, system cards and layout conventions. Same features, Apple presentation."
            }
        }

        var symbolName: String {
            switch self {
            case .shirox: return "sparkles.tv"
            case .apple:  return "iphone.gen3"
            }
        }
    }

    private let key = "uiDesignMode.v1"

    /// The current mode. Defaults to SHIROX (the app's signature design);
    /// the choice persists across launches.
    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: key)
            Haptics.selection()
            objectWillChange.send()
        }
    }

    var isShirox: Bool { mode == .shirox }
    var isApple: Bool { mode == .apple }

    private init() {
        let saved = UserDefaults.standard.string(forKey: key)
        self.mode = Mode(rawValue: saved ?? "") ?? .shirox
    }

    func toggle() {
        mode = (mode == .shirox) ? .apple : .shirox
    }
}
