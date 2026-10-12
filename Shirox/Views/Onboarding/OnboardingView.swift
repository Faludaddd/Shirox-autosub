import SwiftUI
import AuthenticationServices

/// The onboarding experience (v2.34 — the interactive rebuild).
///
/// The flow has two presentations, both driven by `OnboardingFlowController`:
///
///   • the TOUR — a spotlight overlay over the REAL app (see GuidedTour.swift),
///     showing the actual tabs, charts and controls in place;
///   • this view, the SETUP phase — a full-screen cover holding, in order:
///     the simulated notification demonstration, the interactive day/night
///     theme demonstration (with the real theme selector), and the setup
///     checklist (module, tracking, notifications, theme).
///
/// The old generic introductory slides are gone — the tour replaces them
/// with the actual interface, so there is nothing left to explain in the
/// abstract. The rules the flow honors:
///
///   • Next / Back / Skip / Finish — nothing is required to finish (the app
///     genuinely works without an account or notifications);
///   • completion persists (`hasCompletedOnboarding`); skipping flags
///     `onboardingWasSkipped` so the Notifications tab keeps offering the
///     guide through its "Get Started" card, and the next run resumes where
///     this one stopped;
///   • setup states are honest: a card only shows as complete when its real
///     requirement actually holds (modules installed, tracker signed in,
///     notification permission granted, an explicit theme choice made);
///   • demo state is tutorial-only — the simulated banner/badge counts live
///     in the demo view and can never touch the real notification counts;
///   • reopening the guide later never touches saved settings or account
///     state beyond the four setup actions the user takes themselves.
struct OnboardingView: View {
    @ObservedObject private var flow = OnboardingFlowController.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// The REAL appearance preference — the same key Settings › Appearance
    /// writes, so a choice made here persists exactly like one made there.
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    // MARK: Setup steps state
    @State private var showSources = false
    /// The manual paste-URL page pushed inside the sources sheet.
    @State private var showManualAdd = false
    @State private var showPermissionSheet = false
    @State private var notificationState: NotificationAuthState = .notDetermined
    /// The theme demo's illustration value — 0 day, 1 night. Pure demo
    /// state; the real preference is written only by the explicit selector.
    @State private var dayNight: Double = 0
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    private var hasSource: Bool { !moduleManager.modules.isEmpty }
    private var hasTracker: Bool { aniListAuth.isLoggedIn || malAuth.isLoggedIn }
    private var notificationsOn: Bool { notificationState == .authorized }
    private var hasTheme: Bool { flow.themeStepComplete }

    private var accent: Color { .appAccent }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.primary.opacity(0.001)
        #endif
    }

    var body: some View {
        Group {
            switch flow.phase {
            case .loading:
                OnboardingLoadingScreen()
            case .setup:
                setupFlow
            case .inactive, .tour:
                // Defensive: the cover should only be up for loading/setup.
                Color.clear.onAppear { dismiss() }
            }
        }
        .environmentObject(moduleManager)
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    // MARK: - Setup flow (the three setup pages)

    private var setupFlow: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ZStack {
                setupPage
                    .id(flow.setupPage)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97))
                    )
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86), value: flow.setupPage)

            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .padding(.top, 6)
        }
        .background(platformBackground.ignoresSafeArea())
        .sheet(isPresented: $showSources) {
            // Lands DIRECTLY in the Module Store: the step says "install a
            // module", so that's where the user should be. The store's own
            // Install buttons do the work; "Paste URL" covers local files,
            // Jellyfin and URLs the store doesn't list. Whatever installs,
            // the checklist row behind this sheet ticks itself live.
            NavigationStack {
                ModuleStorePage(showsDone: true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showManualAdd = true
                            } label: {
                                Label("Paste URL", systemImage: "link")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                    }
                    .navigationDestinationCompat(isPresented: $showManualAdd) {
                        ModuleListView(showsDone: false)
                    }
            }
            .environmentObject(moduleManager)
        }
        .sheet(isPresented: $showPermissionSheet) {
            NotificationPermissionSheet()
                .adaptivePresentationDetents([.medium, .large])
        }
        .task { await refreshNotificationState() }
        .onAppear {
            // The theme demo opens matching the app's current real look.
            dayNight = (colorScheme == .dark) ? 1 : 0
        }
        .onChange(of: showPermissionSheet) { stillUp in
            if !stillUp { Task { await refreshNotificationState() } }
        }
    }

    private func refreshNotificationState() async {
        notificationState = await NotificationAuthState.current()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index == flow.setupPage ? accent : Color.secondary.opacity(0.3))
                        .frame(width: index == flow.setupPage ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: flow.setupPage)
                }
            }
            Spacer()
            Button {
                flow.skip()
            } label: {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip setup for now")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if flow.setupPage > 0 {
                Button {
                    flow.goToSetupPage(flow.setupPage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.springPress)
                .accessibilityLabel("Go back")
            }

            Button {
                if flow.setupPage == 2 {
                    flow.finish()
                } else {
                    flow.goToSetupPage(flow.setupPage + 1)
                }
            } label: {
                Text(flow.setupPage == 2
                     ? (hasSource ? "Start Watching" : "Finish")
                     : "Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    )
                    .foregroundStyle(Color.appAccentForeground)
            }
            .buttonStyle(.springPress)
            .accessibilityLabel(flow.setupPage == 2 ? "Finish setup" : "Next page")
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var setupPage: some View {
        switch flow.setupPage {
        case 0: notificationsPage
        case 2: themePage
        default: checklistPage
        }
    }

    /// Page 0 — the simulated notification demonstration.
    private var notificationsPage: some View {
        onboardingScroll {
            Text("See it before you set it up")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("A quick look at how Shirox keeps you posted — entirely simulated, nothing is being sent to your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 22)

            SimulatedNotificationDemo(media: flow.demoMedia)

            Text("Enable the real thing from the checklist — one step away.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        }
    }

    /// Page 2 — the interactive day/night theme demonstration with the real
    /// appearance selector.
    private var themePage: some View {
        onboardingScroll {
            Text("Choose your look")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Drag the sun and the moon, or tap the scene. Picking an option below applies it for real — and you can change it any time in Settings › Appearance.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 22)

            ThemeDemoScene(dayNight: $dayNight)

            themeSelector
                .padding(.top, 22)
        }
    }

    /// The REAL selector — writes the app's actual appearance preference
    /// (the same one Settings › Appearance uses), and only an explicit pick
    /// marks the theme step complete.
    private var themeSelector: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                themeOption("System", value: "system", icon: "circle.lefthalf.filled", dayNight: nil)
                themeOption("Light", value: "light", icon: "sun.max.fill", dayNight: 0)
                themeOption("Dark", value: "dark", icon: "moon.fill", dayNight: 1)
            }

            if hasTheme {
                Label("Applied — saved with your preferences.", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasTheme)
    }

    private func themeOption(_ title: String, value: String, icon: String, dayNight target: Double?) -> some View {
        let isSelected = appearanceMode == value && hasTheme
        return Button {
            appearanceMode = value
            flow.markThemeChosen()
            Haptics.selection()
            if let target {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.85)) {
                    dayNight = target
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.appAccentForeground : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSelected ? Color.appAccent : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.springPress)
        .accessibilityLabel("\(title) appearance")
    }

    /// Page 2 — the setup checklist: the four things that make Shirox
    /// yours, each with its real completion state and its real action.
    private var checklistPage: some View {
        onboardingScroll {
            Text("Set up Shirox")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Shirox doesn't host any content. Connect a source and it becomes your library — tracked, downloaded and played on this device. Everything here is optional except the first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 22)

            VStack(spacing: 10) {
                stepRow(
                    icon: "square.grid.2x2.fill",
                    title: "Add a Module",
                    detail: hasSource
                        ? "\(moduleManager.modules.count) module\(moduleManager.modules.count == 1 ? "" : "s") connected"
                        : "Pick one from the Module Store — or paste a URL, use Jellyfin, or play local files",
                    isDone: hasSource,
                    isRequired: true
                ) { showSources = true }

                stepRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Connect Tracking",
                    detail: trackerDetail,
                    isDone: hasTracker,
                    isRequired: false,
                    action: signInToAniList
                )

                stepRow(
                    icon: "bell.badge.fill",
                    title: "Enable Notifications",
                    detail: notificationDetail,
                    isDone: notificationsOn,
                    isRequired: false,
                    action: { showPermissionSheet = true }
                )

                stepRow(
                    icon: "circle.lefthalf.filled",
                    title: "Choose Your Theme",
                    detail: hasTheme ? "Chosen — change it any time in Settings" : "Try the day/night demo and pick a look",
                    isDone: hasTheme,
                    isRequired: false,
                    action: { flow.goToSetupPage(2) }
                )
            }

            Text("You can change any of this later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
        }
    }

    private var trackerDetail: String {
        if aniListAuth.isLoggedIn && malAuth.isLoggedIn { return "AniList and MyAnimeList" }
        if aniListAuth.isLoggedIn { return "AniList" }
        if malAuth.isLoggedIn { return "MyAnimeList" }
        return "Sync your progress to AniList or MyAnimeList"
    }

    private var notificationDetail: String {
        switch notificationState {
        case .authorized: return "On — episode reminders and alerts"
        case .denied: return "Blocked in iOS Settings — tap to see how to re-enable"
        case .notDetermined: return "Episode reminders, downloads and module results"
        }
    }

    // MARK: - Page scaffolding

    private func onboardingScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Steps (the checklist's live rows)

    @ViewBuilder
    private func stepRow(
        icon: String,
        title: String,
        detail: String,
        isDone: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isDone ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .background(Circle().fill(isDone ? accent : Color.clear))
                        .frame(width: 26, height: 26)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .modifier(BounceWhenDone(trigger: isDone))
                    } else {
                        Image(systemName: icon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !isRequired && !isDone {
                            Text("Optional")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.09))
            )
        }
        .buttonStyle(.springPress)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDone)
    }

    // MARK: - Actions

    private func signInToAniList() {
        #if os(iOS)
        guard let presentationWindow else { return }
        aniListAuth.login(presentationAnchor: presentationWindow)
        #endif
    }
}

/// A small springy acknowledgment when a setup item ticks to done (the
/// trigger is the completion state itself, so the bounce fires exactly when
/// the row flips to complete). SF Symbol effects respect Reduce Motion on
/// their own.
private struct BounceWhenDone: ViewModifier {
    var trigger: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            content.symbolEffect(.bounce, value: trigger)
        } else {
            content
        }
    }
}
