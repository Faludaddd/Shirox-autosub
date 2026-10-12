import SwiftUI

// MARK: - Flow phase

/// Where the onboarding experience currently is. Owned by
/// `OnboardingFlowController`; every surface involved (the cover, the
/// Settings Getting Started card, the Notifications tab's Get Started
/// card, the Home header shortcut) observes it so the flow has ONE source
/// of truth and can be paused and resumed at any point.
///
/// v2.35 — the spotlight tour phase is retired. Onboarding is the
/// tab-based guide again (the familiar concept from the app's earlier
/// onboarding, substantially reworked — see OnboardingView.swift): the
/// flow is now just the conditional asset-loading screen, then the guide
/// itself.
enum OnboardingPhase: String {
    /// Nothing onboarding-related is showing.
    case inactive
    /// Preparing demo artwork (only when there is genuine work — see
    /// `OnboardingAssetLoader`).
    case loading
    /// The full-screen tab-based guide (welcome / discover / library /
    /// alerts / get started).
    case setup
}

// MARK: - Flow controller

/// Drives the onboarding experience: the full-screen cover
/// (`OnboardingView`) across its loading and guide phases.
///
/// Progress persists (`onboarding.saved*` keys) so an interrupted session —
/// app backgrounded, phone call, force quit — resumes where it left off,
/// and so every entry point (Settings' Getting Started card, the
/// Notifications tab's Get Started card, the Home header shortcut)
/// continues the same run through the same presentation.
///
/// Tutorial-only state (demo badge counts, simulated banners) never lives
/// here — it stays local to the demo views, so it can't leak into the real
/// notification counts.
@MainActor
final class OnboardingFlowController: ObservableObject {
    static let shared = OnboardingFlowController()

    @Published private(set) var phase: OnboardingPhase = .inactive
    /// The guide's selected tab (persisted; resumes here).
    @Published private(set) var setupPage = 0
    /// Real trending titles + artwork for the guide's Discover preview and
    /// the notification demonstration (empty when nothing could be loaded —
    /// the demo degrades to neutral placeholder content instead of
    /// blocking).
    @Published private(set) var demoMedia: [Media] = []
    /// `nil` = indeterminate. Only meaningful during `.loading`.
    @Published private(set) var loadProgress: Double?
    @Published private(set) var loadStatus = ""

    private enum Keys {
        static let phase = "onboarding.savedPhase"
        static let setupPage = "onboarding.savedSetupPage"
        static let themeChosen = "onboardingThemeChosen"
    }

    /// The guide's tab count — kept here so the controller's clamping and
    /// the view's tab bar can never drift apart.
    static let guideTabCount = 5

    private init() {}

    // MARK: Entry

    /// Starts (or resumes) the flow. Called after the splash hands over on
    /// a first run, from the Home header shortcut, the Notifications
    /// "Get Started" card, and Settings' Getting Started card.
    func begin() {
        guard phase == .inactive else { return }

        let savedPage = min(max(UserDefaults.standard.integer(forKey: Keys.setupPage), 0),
                            max(Self.guideTabCount - 1, 0))

        Task { await run(savedPage: savedPage) }
    }

    private func run(savedPage: Int) async {
        // Only load when there is genuine work: no cached shelf data, or
        // missing poster artwork. Otherwise the loading screen never appears.
        let decision = await OnboardingAssetLoader.decide()
        if decision.needsLoad {
            phase = .loading
            loadStatus = "Fetching example titles…"
            loadProgress = nil
            demoMedia = (try? await OnboardingAssetLoader.load { [weak self] progress, status in
                // The loader runs off the main actor; hop back for the
                // published state so SwiftUI always updates on main.
                Task { @MainActor [weak self] in
                    self?.loadProgress = progress
                    self?.loadStatus = status
                }
            }) ?? []
        } else {
            demoMedia = decision.media
        }

        // Resume exactly where the last run stopped (a resumed .loading
        // phase restarts the decision above and falls through to the guide).
        setupPage = savedPage
        phase = .setup
    }

    // MARK: Guide navigation

    /// Selects a guide tab directly (the tab bar) — clamped to the range.
    func goToSetupPage(_ index: Int) {
        setupPage = min(max(index, 0), Self.guideTabCount - 1)
        persist()
    }

    // MARK: Setup completion signals

    /// The theme setup card's completion signal — set only by an explicit
    /// choice in the theme step, never just by viewing the demonstration.
    var themeStepComplete: Bool {
        UserDefaults.standard.bool(forKey: Keys.themeChosen)
    }

    func markThemeChosen() {
        UserDefaults.standard.set(true, forKey: Keys.themeChosen)
        objectWillChange.send()
    }

    // MARK: Exit

    /// Finished for real — retires the Notifications card and the Home
    /// header shortcut.
    func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(false, forKey: "onboardingWasSkipped")
        clearSavedProgress()
        Haptics.success()
        phase = .inactive
    }

    /// Left for now — the Notifications tab and the Home header shortcut
    /// keep offering the guide, and the next run resumes where this one
    /// stopped.
    func skip() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(true, forKey: "onboardingWasSkipped")
        persist()
        phase = .inactive
    }

    // MARK: Persistence

    private func persist() {
        switch phase {
        case .setup:
            UserDefaults.standard.set(OnboardingPhase.setup.rawValue, forKey: Keys.phase)
            UserDefaults.standard.set(setupPage, forKey: Keys.setupPage)
        case .inactive, .loading:
            break
        }
    }

    private func clearSavedProgress() {
        UserDefaults.standard.removeObject(forKey: Keys.phase)
        UserDefaults.standard.removeObject(forKey: Keys.setupPage)
    }
}
