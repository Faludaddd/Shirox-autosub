import SwiftUI

// MARK: - Flow phase

/// Where the onboarding experience currently is. Owned by
/// `OnboardingFlowController`; every surface involved (the cover, the tour
/// overlay, the Notifications card) observes it so the flow has ONE source
/// of truth and can be paused and resumed at any point.
enum OnboardingPhase: String {
    /// Nothing onboarding-related is showing.
    case inactive
    /// Preparing demo artwork (only when there is genuine work — see
    /// `OnboardingAssetLoader`).
    case loading
    /// The spotlight tour over the real app interface.
    case tour
    /// The full-screen setup experience (notification demo, theme demo,
    /// setup cards).
    case setup
}

// MARK: - Flow controller

/// Drives the whole onboarding experience across its two presentations:
///
///   • the TOUR is an overlay ON TOP of the real app (RootTabView) so the
///     spotlights land on the actual interface, not a replica;
///   • the SETUP phase is the full-screen cover (`OnboardingView`).
///
/// Progress persists (`onboarding.saved*` keys) so an interrupted session —
/// app backgrounded, phone call, force quit — resumes where it left off, and
/// so the Notifications tab's "Get Started" card can continue the same run.
///
/// Tutorial-only state (demo badge counts, simulated banners) never lives
/// here — it stays local to the demo views, so it can't leak into the real
/// notification counts.
@MainActor
final class OnboardingFlowController: ObservableObject {
    static let shared = OnboardingFlowController()

    @Published private(set) var phase: OnboardingPhase = .inactive
    @Published private(set) var tourStep = 0
    @Published private(set) var setupPage = 0
    /// Live frames of the real views that tagged themselves with
    /// `.tourAnchor(_:)`, in global (window) coordinates.
    @Published internal var anchorRects: [String: CGRect] = [:]
    /// Real trending titles + artwork for the notification demonstration
    /// (empty when nothing could be loaded — the demo degrades to neutral
    /// placeholder content instead of blocking).
    @Published private(set) var demoMedia: [Media] = []
    /// `nil` = indeterminate. Only meaningful during `.loading`.
    @Published private(set) var loadProgress: Double?
    @Published private(set) var loadStatus = ""

    /// RootTabView hands this in so tour steps can select the real tab the
    /// step is describing.
    var selectTab: ((Int) -> Void)?

    private enum Keys {
        static let phase = "onboarding.savedPhase"
        static let tourStep = "onboarding.savedTourStep"
        static let setupPage = "onboarding.savedSetupPage"
        static let themeChosen = "onboardingThemeChosen"
    }

    private init() {}

    // MARK: Entry

    /// Starts (or resumes) the flow. Called after the splash hands over on a
    /// first run, from the Notifications "Get Started" card, and from
    /// Settings' "Getting Started" row.
    func begin() {
        guard phase == .inactive else { return }

        let savedPhaseRaw = UserDefaults.standard.string(forKey: Keys.phase)
            .flatMap(OnboardingPhase.init(rawValue:))
        let savedStep = min(max(UserDefaults.standard.integer(forKey: Keys.tourStep), 0),
                            max(TourStepCatalog.steps.count - 1, 0))
        let savedPage = min(max(UserDefaults.standard.integer(forKey: Keys.setupPage), 0), 2)

        Task { await run(savedPhase: savedPhaseRaw, savedStep: savedStep, savedPage: savedPage) }
    }

    private func run(savedPhase: OnboardingPhase?, savedStep: Int, savedPage: Int) async {
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

        // Resume exactly where the last run stopped (tour beats setup —
        // a resumed .loading phase restarts the decision above and falls
        // through to the tour it never reached).
        if let savedPhase {
            switch savedPhase {
            case .setup:
                setupPage = savedPage
                phase = .setup
                return
            case .tour:
                tourStep = savedStep
                phase = .tour
                enter(step: savedStep)
                return
            case .inactive, .loading:
                break
            }
        }

        tourStep = 0
        setupPage = 0
        phase = .tour
        enter(step: 0)
    }

    // MARK: Tour

    func nextTourStep() {
        let next = tourStep + 1
        guard next < TourStepCatalog.steps.count else { finishTour(); return }
        tourStep = next
        persist()
        enter(step: next)
    }

    func previousTourStep() {
        guard tourStep > 0 else { return }
        tourStep -= 1
        persist()
        enter(step: tourStep)
    }

    /// Applies a step's side effects: switching the real tab it describes so
    /// the live interface behind the spotlight matches the explanation.
    private func enter(step: Int) {
        guard let step = TourStepCatalog.steps[safe: step] else { return }
        if let tab = step.switchesToTab { selectTab?(tab) }
    }

    /// The tour's end hands over to the setup phase.
    func finishTour() {
        setupPage = 0
        phase = .setup
        persist()
    }

    // MARK: Setup

    func goToSetupPage(_ index: Int) {
        setupPage = min(max(index, 0), 2)
        persist()
    }

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

    /// Finished for real — retires the Notifications card.
    func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(false, forKey: "onboardingWasSkipped")
        clearSavedProgress()
        Haptics.success()
        phase = .inactive
    }

    /// Left for now — the Notifications tab keeps offering the guide, and
    /// the next run resumes where this one stopped.
    func skip() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(true, forKey: "onboardingWasSkipped")
        persist()
        phase = .inactive
    }

    // MARK: Persistence

    private func persist() {
        switch phase {
        case .tour:
            UserDefaults.standard.set(OnboardingPhase.tour.rawValue, forKey: Keys.phase)
            UserDefaults.standard.set(tourStep, forKey: Keys.tourStep)
        case .setup:
            UserDefaults.standard.set(OnboardingPhase.setup.rawValue, forKey: Keys.phase)
            UserDefaults.standard.set(setupPage, forKey: Keys.setupPage)
        case .inactive, .loading:
            break
        }
    }

    private func clearSavedProgress() {
        UserDefaults.standard.removeObject(forKey: Keys.phase)
        UserDefaults.standard.removeObject(forKey: Keys.tourStep)
        UserDefaults.standard.removeObject(forKey: Keys.setupPage)
    }
}

// MARK: - Tour anchors

/// Live frames of REAL interface elements, reported up the view tree so the
/// tour overlay (an ancestor) can spotlight the actual views — never a
/// hardcoded screenshot rectangle.
struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Tags this view as a tour spotlight target. The frame is only reported
    /// while the tour is actually running, so normal scrolling never pays
    /// the preference cost.
    func tourAnchor(_ id: String) -> some View {
        modifier(TourAnchorModifier(id: id))
    }
}

private struct TourAnchorModifier: ViewModifier {
    let id: String
    @ObservedObject private var flow = OnboardingFlowController.shared

    func body(content: Content) -> some View {
        content.background(
            Group {
                if flow.phase == .tour {
                    GeometryReader { geo in
                        Color.clear.preference(key: TourAnchorKey.self,
                                               value: [id: geo.frame(in: .global)])
                    }
                }
            }
        )
    }
}

// MARK: - Tour steps

/// What a step's spotlight points at.
enum TourTarget: Equatable {
    /// A bottom-bar tab item (exact slot geometry on iPhone; the top tab-bar
    /// region on iPad; a card everywhere tabs aren't in a bar).
    case tab(Int)
    /// A live-anchored real view (`tourAnchor`).
    case anchor(String)
    /// Home's trailing toolbar cluster (bell + gear) — toolbar items live in
    /// a UIKit bar outside the SwiftUI preference tree, so this one is
    /// computed from the window geometry.
    case toolbarTrailing
    /// A centered card with no spotlight (intro / platforms without bars).
    case none
}

struct TourStep: Identifiable {
    let id: String
    let target: TourTarget
    /// The real tab to switch to while this step shows, so the live content
    /// behind the dim matches what the tooltip describes.
    var switchesToTab: Int? = nil
    let icon: String
    let title: String
    let message: String
}

/// The tour, step by step. Every step references things that genuinely exist
/// in the app — the five real tabs, the real chart shelf, the real toolbar.
enum TourStepCatalog {
    /// iOS/tvOS tab indices as RootTabView defines them:
    /// 0 Home · 1 Library · 2 Downloads · 3 Search · 4 Schedule.
    static let steps: [TourStep] = [
        TourStep(
            id: "intro", target: .none,
            icon: "sparkles",
            title: "Welcome to Shirox",
            message: "A quick tour of the app itself — this is the real interface you'll use every day, not a mockup. It takes under a minute."),
        TourStep(
            id: "home", target: .tab(0), switchesToTab: 0,
            icon: "house.fill",
            title: "Home — discovery",
            message: "Top charts, trending titles, seasonal picks and fifteen genre charts, plus a featured carousel. Everything windowable by day, week, month, quarter or year."),
        TourStep(
            id: "charts", target: .anchor("home.charts"), switchesToTab: 0,
            icon: "chart.bar.fill",
            title: "Top Charts",
            message: "Every chart row carries a period picker — the arrow beside \"Top Anime\" opens Daily, Weekly, Monthly, Quarterly or Yearly, and the list genuinely re-ranks for the window you pick."),
        TourStep(
            id: "library", target: .tab(1), switchesToTab: 1,
            icon: "books.vertical.fill",
            title: "Library — your lists",
            message: "Plan, watch and read. Everything you save from any source lands here — progress, lists and scores synced to your trackers, or kept on-device."),
        TourStep(
            id: "search", target: .tab(3), switchesToTab: 3,
            icon: "magnifyingglass",
            title: "Search",
            message: "The whole AniList catalog — look up any series, manga or person, then open it straight into your installed sources."),
        TourStep(
            id: "downloads", target: .tab(2), switchesToTab: 2,
            icon: "arrow.down.circle.fill",
            title: "Downloads",
            message: "Take it with you — episodes and chapters downloaded from your sources, playable offline with progress remembered."),
        TourStep(
            id: "schedule", target: .tab(4), switchesToTab: 4,
            icon: "calendar",
            title: "Schedule",
            message: "The airing calendar — what's out today, this week and beyond, with per-episode reminders you can set from any show."),
        TourStep(
            id: "alerts", target: .toolbarTrailing, switchesToTab: 0,
            icon: "bell.badge.fill",
            title: "Alerts & Settings",
            message: "On Home, the bell opens Notifications — episode alerts and account activity — and the gear opens Settings: appearance, accounts, playback, sources and more."),
    ]
}

// MARK: - Spotlight geometry

/// Pure geometry helpers: turning a step's target into a window-space
/// rectangle. No hardcoded screen coordinates — everything derives from the
/// live window size, safe areas, and reported anchors.
enum TourSpotlight {
    static let tabBarHeight: CGFloat = 49

    /// The spotlight rect for a target, in the overlay's coordinate space
    /// (window space — the overlay ignores safe areas).
    static func rect(for target: TourTarget,
                     step: TourStep,
                     size: CGSize,
                     safeTop: CGFloat, safeBottom: CGFloat,
                     isCompactWidth: Bool,
                     anchors: [String: CGRect],
                     supportsSpotlight: Bool) -> CGRect? {
        guard supportsSpotlight else { return nil }
        switch target {
        case .none:
            return nil

        case .tab(let index):
            if isCompactWidth {
                // The bottom bar: five equal slots above the home indicator.
                let slot = size.width / 5
                let barTop = size.height - safeBottom - tabBarHeight
                return CGRect(x: slot * CGFloat(index) + 5,
                              y: barTop + 5,
                              width: slot - 10,
                              height: tabBarHeight - 12)
            } else {
                // iPad: the tab bar sits at the top under the safe area.
                return CGRect(x: size.width * 0.22,
                              y: safeTop + 4,
                              width: size.width * 0.56,
                              height: 48)
            }

        case .anchor(let id):
            if let rect = anchors[id], rect.width > 8, rect.height > 8 {
                return rect.insetBy(dx: -6, dy: -6)
            }
            // Anchor not on screen (grid layout mode, or scrolled out): fall
            // back to the upper content area where the shelf lives.
            return CGRect(x: 16, y: safeTop + 130, width: size.width - 32, height: 110)

        case .toolbarTrailing:
            // Home's trailing toolbar cluster: four items (mode toggle, bell,
            // gear, provider menu) hugging the top-right corner.
            return CGRect(x: size.width - 200, y: safeTop + 2, width: 190, height: 44)
        }
    }

    /// Where the tooltip card sits relative to the spotlight: above it when
    /// the spotlight is low on the screen, below when it's high, centered
    /// when there is no spotlight.
    static func cardIsAbove(_ rect: CGRect?, in size: CGSize) -> Bool {
        guard let rect else { return true }
        return rect.midY > size.height * 0.55
    }
}

// MARK: - Spotlight mask

/// A rectangle mask with a rounded-rect hole — the dim layer's cutout. The
/// hole's position and size are animatable, so the spotlight travels between
/// elements with one continuous spring (that travel IS the zoom).
struct SpotlightMask: Shape {
    var holeX: CGFloat = 0
    var holeY: CGFloat = 0
    var holeW: CGFloat = 0
    var holeH: CGFloat = 0
    var radius: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(holeX, holeY),
                           AnimatablePair(holeW, holeH))
        }
        set {
            holeX = newValue.first.first
            holeY = newValue.first.second
            holeW = newValue.second.first
            holeH = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard holeW > 0, holeH > 0 else {
            path.addRect(rect)
            return path
        }
        path.addRect(CGRect(origin: .zero, size: rect.size))
        path.addRoundedRect(in: CGRect(x: holeX, y: holeY, width: holeW, height: holeH),
                            cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

// MARK: - Tour overlay

/// The tour itself, drawn over the REAL app: a dim layer with an animated
/// spotlight cutout on the element the step describes, a tooltip card, and
/// Next / Back / Skip. Rendered by RootTabView whenever the flow is in the
/// tour phase.
struct GuidedTourOverlay: View {
    @ObservedObject private var flow = OnboardingFlowController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Spotlight geometry is an iPhone/iPad affordance. Catalyst and macOS
    /// navigate through a sidebar, and tvOS through the focus engine — there
    /// the tour presents the same steps as plain cards (still describing the
    /// real interface).
    private var supportsSpotlight: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var step: TourStep? {
        TourStepCatalog.steps[safe: flow.tourStep]
    }

    private var isLastStep: Bool {
        flow.tourStep >= TourStepCatalog.steps.count - 1
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.45, dampingFraction: 0.85)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            let spotlight = TourSpotlight.rect(
                for: step?.target ?? .none,
                step: step ?? TourStep(id: "", target: .none, icon: "", title: "", message: ""),
                size: size, safeTop: safeTop, safeBottom: safeBottom,
                isCompactWidth: sizeClass == .compact,
                anchors: flow.anchorRects,
                supportsSpotlight: supportsSpotlight)

            ZStack(alignment: .topLeading) {
                // The dim with its cutout. The hole animates between steps,
                // which reads as the camera zooming between elements.
                Color.black.opacity(0.58)
                    .mask(SpotlightMask(
                        holeX: spotlight?.minX ?? 0,
                        holeY: spotlight?.minY ?? 0,
                        holeW: spotlight?.width ?? 0,
                        holeH: spotlight?.height ?? 0,
                        radius: 16)
                        .fill(style: FillStyle(eoFill: true)))
                    .animation(animation, value: flow.tourStep)
                    .animation(animation, value: flow.anchorRects)

                // A soft stroke exactly around the cutout, so the
                // highlighted element has a clear edge.
                if let spotlight {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.9), lineWidth: 2.5)
                        .frame(width: max(spotlight.width, 0), height: max(spotlight.height, 0))
                        .position(x: spotlight.midX, y: spotlight.midY)
                        .shadow(color: Color.appAccent.opacity(0.5), radius: 6)
                        .allowsHitTesting(false)
                        .animation(animation, value: flow.tourStep)
                        .animation(animation, value: flow.anchorRects)

                    // Tapping the highlighted element advances the tour (the
                    // tab the step describes is already selected underneath).
                    Button {
                        Haptics.light()
                        flow.nextTourStep()
                    } label: {
                        Color.clear.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .frame(width: max(spotlight.width, 0), height: max(spotlight.height, 0))
                    .position(x: spotlight.midX, y: spotlight.midY)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Continue tour")
                }

                tooltip(spotlight: spotlight, size: size)
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
        // The overlay itself blocks interaction with everything except the
        // spotlight tap target and the card.
        .accessibilityElement(children: .contain)
    }

    // MARK: Tooltip card

    @ViewBuilder
    private func tooltip(spotlight: CGRect?, size: CGSize) -> some View {
        if let step {
            let above = TourSpotlight.cardIsAbove(spotlight, in: size)
            VStack {
                if above { card(step: step) }
                Spacer(minLength: 0)
                if !above { card(step: step) }
            }
            .frame(width: min(size.width - 32, 420), alignment: .center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, spotlight == nil ? max(size.height * 0.2, 120) : 0)
            .padding(.bottom, spotlight == nil ? 120 : 0)
            .animation(animation, value: flow.tourStep)
        }
    }

    private func card(step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.appAccent)
                    Image(systemName: step.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.appAccentForeground)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Step \(flow.tourStep) of \(TourStepCatalog.steps.count - 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if step.target != .none && supportsSpotlight {
                Text("Tap the highlighted area to continue")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                if flow.tourStep > 0 {
                    Button {
                        flow.previousTourStep()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.springPress)
                    .accessibilityLabel("Previous step")
                }

                Button {
                    if isLastStep {
                        Haptics.success()
                        flow.finishTour()
                    } else {
                        flow.nextTourStep()
                    }
                } label: {
                    Text(flow.tourStep == 0 ? "Start Tour" : (isLastStep ? "Continue to Setup" : "Next"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.appAccentForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.appAccent)
                        )
                }
                .buttonStyle(.springPress)
                .accessibilityLabel(isLastStep ? "Continue to setup" : "Next step")

                Button {
                    flow.skip()
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip the tour")
            }

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<max(TourStepCatalog.steps.count - 1, 1), id: \.self) { index in
                    Capsule()
                        .fill(index == flow.tourStep - 1 ? Color.appAccent : Color.secondary.opacity(0.3))
                        .frame(width: index == flow.tourStep - 1 ? 20 : 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: flow.tourStep)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .id(flow.tourStep)
        .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96)),
                        removal: .opacity))
    }
}
// (The app's shared `[safe:]` array subscript lives in AnimationModifiers.swift.)
