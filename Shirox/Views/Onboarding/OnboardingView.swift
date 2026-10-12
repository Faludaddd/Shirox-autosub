import SwiftUI
import AuthenticationServices

/// The onboarding experience (v2.35 — the interactive TAB-BASED rebuild).
///
/// The guide returns to the familiar tab-based concept the app's onboarding
/// always had (pages you move between, a clear sense of where you are),
/// rebuilt as one modern, genuinely interactive flow rather than a
/// sequence of static slides:
///
///   ┌──────────────────────────────────────────────┐
///   │  Welcome · Discover · Library · Alerts · Setup│  ← the tab bar
///   ├──────────────────────────────────────────────┤
///   │  the selected tab's live content              │
///   │  (real actions, real state, real demos)       │
///   ├──────────────────────────────────────────────┤
///   │   ◀ Back            Next / Finish       Skip  │
///   └──────────────────────────────────────────────┘
///
///   • Welcome — the mark, what Shirox is, and the one honest premise
///     (bring your own library);
///   • Discover — what the Home tab serves, previewed with REAL trending
///     artwork when the loader warmed it (honest placeholder otherwise);
///   • Library & Tracking — the tracker story + the real AniList sign-in
///     action, reflecting live account state;
///   • Alerts — the simulated notification demonstration (banners slide
///     down while the demo badge climbs; labelled DEMO, fully local);
///   • Get Started — the four setup cards (module, tracking,
///     notifications, theme) with real completion state and real actions,
///     the interactive day/night theme scene, and the REAL appearance
///     selector.
///
/// Rules the flow honors:
///   • Tabs are genuinely interactive: every tab is tappable with a clear
///     selected state, tabs can be visited in any order, and Next/Back
///     walk the same order; the selected tab animates with a spring.
///   • Nothing is required to finish — Skip is always available (and
///     remembered); finishing persists `hasCompletedOnboarding`, skipping
///     flags `onboardingWasSkipped` so the Notifications tab, the Home
///     header shortcut and Settings' Getting Started card keep a way back
///     in.
///   • Setup states are honest: a card only shows as complete when its
///     real requirement actually holds (modules installed, tracker signed
///     in, notification permission granted, an explicit theme choice).
///   • Demo state is tutorial-only — the simulated banner/badge counts
///     live in the demo view and can never touch the real counts.
///   • Reopening the guide later never touches saved settings or account
///     state beyond the four setup actions the user takes themselves.
///   • Reduce Motion swaps the transitions for plain fades.
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
    private var isLastTab: Bool { flow.setupPage == OnboardingFlowController.guideTabCount - 1 }

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
                guideFlow
            case .inactive:
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

    // MARK: - The tab-based guide

    private var guideFlow: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ZStack {
                guidePage
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

    // MARK: - Tab bar (the guide's sections, clearly selectable)

    /// One compact, scrollable row of section tabs — the structural spine
    /// the old onboarding had (its pages), made genuinely interactive:
    /// every tab is tappable, the selected tab carries the accent fill,
    /// and tabs that hold a setup step show a completion tick when that
    /// step is actually done. The tick is HONEST state, not decoration.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tabChip(index: 0, title: "Welcome", icon: "hand.wave.fill", done: nil)
                tabChip(index: 1, title: "Discover", icon: "sparkles.rectangle.stack.fill", done: nil)
                tabChip(index: 2, title: "Library", icon: "books.vertical.fill", done: hasTracker)
                tabChip(index: 3, title: "Alerts", icon: "bell.badge.fill", done: notificationsOn)
                tabChip(index: 4, title: "Setup", icon: "checklist", done: setupAllDone)
            }
            .padding(.vertical, 4)
        }
    }

    /// True when every optional setup card reads complete (the module card
    /// is the required one — the Setup tab's tick appears when all four
    /// are done).
    private var setupAllDone: Bool {
        hasSource && hasTracker && notificationsOn && hasTheme
    }

    private func tabChip(index: Int, title: String, icon: String, done: Bool?) -> some View {
        let isSelected = flow.setupPage == index
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)) {
                flow.goToSetupPage(index)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.bold))
                if done == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? Color.appAccentForeground : .green)
                }
            }
            .foregroundStyle(isSelected ? Color.appAccentForeground : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? accent : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tab\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Chrome

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
                if isLastTab {
                    flow.finish()
                } else {
                    flow.goToSetupPage(flow.setupPage + 1)
                }
            } label: {
                Text(isLastTab
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
            .accessibilityLabel(isLastTab ? "Finish setup" : "Next page")

            if !isLastTab {
                Button {
                    flow.skip()
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip setup for now")
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var guidePage: some View {
        switch flow.setupPage {
        case 0: welcomePage
        case 1: discoverPage
        case 2: libraryPage
        case 3: alertsPage
        default: setupPage
        }
    }

    /// Tab 1 — Welcome.
    private var welcomePage: some View {
        onboardingScroll {
            Image("ShiroMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 74, height: 74)
                .foregroundStyle(accent)
                .padding(.bottom, 6)

            Text("Welcome to Shirox")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Shirox doesn't host any content. Connect a source and it becomes your library — tracked, downloaded and played on this device. This short guide shows you where everything lives; setup takes two taps on the last tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(spacing: 10) {
                guideHighlight(icon: "square.grid.2x2.fill", text: "Anime and manga from the modules you choose")
                guideHighlight(icon: "person.crop.circle.badge.checkmark", text: "Progress synced to AniList or MyAnimeList")
                guideHighlight(icon: "arrow.down.circle.fill", text: "Offline downloads that play anywhere")
            }
            .padding(.top, 20)
        }
    }

    /// Tab 2 — Discover: what Home serves, with REAL trending artwork when
    /// the loader warmed it.
    private var discoverPage: some View {
        onboardingScroll {
            Text("Discover what's worth watching")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Trending and popular shelves, Top Charts with daily-to-yearly windows, genre rankings, hidden gems, and the full airing schedule — built from your connected sources.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 18)

            if !flow.demoMedia.isEmpty {
                // A real slice of the actual Home hero: live trending
                // artwork the loader warmed through the app's own caches.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(flow.demoMedia.prefix(8)) { media in
                            CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                                .aspectRatio(2/3, contentMode: .fill)
                                .frame(width: 96, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .softScrollEdges()
                .padding(.horizontal, -24)
                .padding(.bottom, 6)
            } else {
                // Honest placeholder — nothing warmed, nothing faked.
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 96, height: 144)
                    }
                }
                .padding(.bottom, 6)
            }

            VStack(spacing: 10) {
                guideHighlight(icon: "flame.fill", text: "Trending Now, All-Time Popular, Top Rated and Upcoming shelves")
                guideHighlight(icon: "chart.bar.fill", text: "Top Anime and genre charts with a Daily–Yearly window")
                guideHighlight(icon: "calendar", text: "The Schedule tab — every airing this week, day by day")
            }
            .padding(.top, 16)
        }
    }

    /// Tab 3 — Library & Tracking, with the real sign-in action.
    private var libraryPage: some View {
        onboardingScroll {
            Text("Your library, tracked")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("One library for anime and manga. Connect a tracker and your progress, scores and lists stay in sync everywhere — watching on this device updates AniList or MyAnimeList instantly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 18)

            VStack(spacing: 10) {
                guideHighlight(icon: "books.vertical.fill", text: "Planning, Watching, Completed — your statuses, sortable and filterable")
                guideHighlight(icon: "arrow.triangle.2.circlepath", text: "Two-way sync with AniList and MyAnimeList")
                guideHighlight(icon: "bell.badge.fill", text: "New-episode reminders for the shows you follow")
            }

            stepRow(
                icon: "person.crop.circle.badge.checkmark",
                title: hasTracker ? "Tracking connected" : "Connect Tracking",
                detail: trackerDetail,
                isDone: hasTracker,
                isRequired: false,
                action: signInToAniList
            )
            .padding(.top, 18)
        }
    }

    /// Tab 4 — Alerts: the simulated notification demonstration.
    private var alertsPage: some View {
        onboardingScroll {
            Text("Never miss an episode")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("See it before you set it up — a quick look at how Shirox keeps you posted. Entirely simulated; nothing is being sent to your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 22)

            SimulatedNotificationDemo(media: flow.demoMedia)

            Text("Enable the real thing on the Setup tab — one step away.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        }
    }

    /// Tab 5 — Setup: the four cards with real state and actions, plus the
    /// interactive theme scene and the REAL appearance selector.
    private var setupPage: some View {
        onboardingScroll {
            Text("Set up Shirox")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Everything here is optional except the first. Each card reflects its real state and does its real action.")
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
                    detail: hasTheme ? "Chosen — change it any time in Settings" : "Try the day/night scene and pick a look",
                    isDone: hasTheme,
                    isRequired: false,
                    action: {
                        // The scene opens matching the app's current real
                        // look — the selector right below writes the
                        // actual preference.
                        dayNight = (colorScheme == .dark) ? 1 : 0
                    }
                )
            }

            // The interactive day/night scene + the REAL selector — the
            // illustration is pure demo; the buttons below write the same
            // preference Settings › Appearance writes.
            ThemeDemoScene(dayNight: $dayNight)
                .padding(.top, 24)

            themeSelector
                .padding(.top, 14)
        }
    }

    /// The REAL selector — writes the app's actual appearance preference
    /// (the same one Settings › Appearance uses), and only an explicit
    /// pick marks the theme step complete.
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

    // MARK: - Shared page pieces

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

    /// A compact one-line highlight — the guide's content atom (no giant
    /// empty cards, no decorative filler).
    private func guideHighlight(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private func onboardingScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Setup cards (live rows with real actions)

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
