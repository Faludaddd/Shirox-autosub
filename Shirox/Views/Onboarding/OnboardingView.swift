import SwiftUI
import AuthenticationServices

/// First-run introduction (v2.33 — the rebuilt onboarding flow).
///
/// A short, themeable paged guide: Welcome, then one page per pillar
/// (Discover, Library, Downloads, Schedule & Notifications), ending on
/// the SET UP page — the original checklist of the two things that make
/// the app work (a source, an account), wired to the real flows.
///
/// Rules the flow honors:
///   • Next / Back / Skip / Finish — Skip is always allowed; nothing is
///     required to finish (the app genuinely works without an account).
///   • Completion persists (`hasCompletedOnboarding`); skipping marks
///     `onboardingWasSkipped` so the Notifications tab can offer the
///     guide again through its "Get Started" card.
///   • Reopening the guide later never touches saved settings or account
///     state — finishing only writes the two completion flags.
///   • The accent is the app's own (`Color.appAccent`), so the flow
///     follows the user's theme in light and dark.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// v2.33 — set when the user SKIPS; cleared when they finish. Drives
    /// the "Get Started with Shirox" card in Notifications.
    @AppStorage("onboardingWasSkipped") private var onboardingWasSkipped = false

    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex = 0
    @State private var showSources = false
    /// The manual paste-URL page pushed inside the sources sheet, for
    /// local files, Jellyfin, or a module URL the store doesn't list.
    @State private var showManualAdd = false
    /// The step the sources screen grows out of.
    @Namespace private var sourcesZoom
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    /// The one thing that has to be true before the app can show anything.
    private var hasSource: Bool { !moduleManager.modules.isEmpty }
    private var hasTracker: Bool { aniListAuth.isLoggedIn || malAuth.isLoggedIn }

    /// The flow's accent follows the app theme (not a private color).
    private var accent: Color { .appAccent }

    private let pageCount = 6
    private var isLastPage: Bool { pageIndex == pageCount - 1 }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.primary.opacity(0.001)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // The page itself, with a light scale+fade transition
            // (respects Reduce Motion; reads naturally in both
            // directions, unlike a directional slide).
            ZStack {
                pageView
                    .id(pageIndex)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97))
                    )
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86), value: pageIndex)

            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .padding(.top, 6)
        }
        .background(platformBackground.ignoresSafeArea())
        .sheet(isPresented: $showSources) {
            // The sheet lands DIRECTLY in the Module Store: the step says
            // "install a module", so that's where the user should be. The
            // store's own Install buttons do the work; a leading "Paste
            // URL" button opens the full sources screen (URL paste, local
            // files, Jellyfin) for the cases the store doesn't cover.
            // Whatever installs, the checklist row behind this sheet ticks
            // itself live; Done (or a back trip) returns to the exact step
            // the user left.
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
            .zoomingOut(of: "sources", in: sourcesZoom)
        }
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    // MARK: - Chrome

    /// Top bar: the progress dots on the leading side, Skip on the
    /// trailing side (hidden on the last page, where Finish is the way out).
    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == pageIndex ? accent : Color.secondary.opacity(0.3))
                        .frame(width: index == pageIndex ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pageIndex)
                }
            }
            Spacer()
            if !isLastPage {
                Button {
                    skip()
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip the introduction")
            }
        }
    }

    /// Bottom bar: Back (hidden on the first page) and Next / Finish.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if pageIndex > 0 {
                Button {
                    withAnimation { go(to: pageIndex - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(
                            Circle().fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go back")
            }

            Button {
                if isLastPage {
                    finish()
                } else {
                    withAnimation { go(to: pageIndex + 1) }
                }
            } label: {
                Text(isLastPage ? (hasSource ? "Start Watching" : "Finish") : "Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    )
                    .foregroundStyle(Color.appAccentForeground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLastPage ? "Finish setup" : "Next page")
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageView: some View {
        switch pageIndex {
        case 0: welcomePage
        case 1: featurePage(
            icon: "sparkles.tv",
            iconBack: "flame.fill",
            title: "Discover what's worth watching",
            body: "Home charts what's new and what's loved — Top Anime, Trending, Top Movies, Most Favorited and fifteen genre charts, each windowable by day, week, month, quarter or year. Search covers AniList's entire catalog.")
        case 2: featurePage(
            icon: "books.vertical.fill",
            iconBack: "checkmark.seal.fill",
            title: "A library that tracks you back",
            body: "Plan, watch and score every series. Progress, lists and ratings sync with AniList and MyAnimeList — or keep everything on-device. Signing in is optional; the app works either way.")
        case 3: featurePage(
            icon: "arrow.down.circle.fill",
            iconBack: "wifi.slash",
            title: "Take it with you",
            body: "Download episodes and chapters from your installed sources and watch or read offline. The player remembers exactly where you stopped, on every device this app runs on.")
        case 4: featurePage(
            icon: "calendar",
            iconBack: "bell.badge.fill",
            title: "Never miss a release",
            body: "The Schedule tab carries the airing calendar with per-episode reminders, and Notifications collects your alerts and activity in one place — new messages, likes, and every episode you asked to be told about.")
        default: setupPage
        }
    }

    /// Page 0 — the app's mark in the poster frame, the same emblem the
    /// setup screen has always carried.
    private var welcomePage: some View {
        onboardingScroll {
            frame
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            Text("Welcome to Shirox")
                .font(.system(size: 34, weight: .heavy))
                .multilineTextAlignment(.center)

            Text("Everything you watch and read, in one place. Bring your own sources, track your progress, download for offline, and never miss a release.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    /// Pages 1–4 — one pillar per page: a composed icon tile, a heading,
    /// a two-to-three sentence description.
    private func featurePage(icon: String, iconBack: String, title: String, body: String) -> some View {
        onboardingScroll {
            iconTile(icon: icon, back: iconBack)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)

            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    /// Page 5 — the setup checklist (the original onboarding's core):
    /// the two rows that make the app work, live-ticking, plus Finish.
    private var setupPage: some View {
        onboardingScroll {
            Text("Set up Shirox")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)

            Text("Shirox doesn't host any content. Connect a source and it becomes your library — tracked, downloaded and played on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)

            VStack(spacing: 10) {
                stepRow(
                    title: "Add a source",
                    detail: hasSource
                        ? "\(moduleManager.modules.count) connected"
                        : "Pick one from the Module Store — or paste a URL, use Jellyfin, or play local files",
                    isDone: hasSource,
                    isRequired: true
                ) { showSources = true }
                .zoomSource("sources", in: sourcesZoom, cornerRadius: 14)

                stepRow(
                    title: "Sign in to a tracker",
                    detail: trackerDetail,
                    isDone: hasTracker,
                    isRequired: false,
                    action: signInToAniList
                )
            }

            Text("You can change any of this later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
        }
    }

    // MARK: - Page scaffolding

    /// Every page scrolls when the screen is short, centers when it isn't.
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

    /// A poster-shaped outline holding the app's mark: empty and dashed
    /// until a source exists, filled once one does — the emblem the setup
    /// step has always carried.
    private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    hasSource ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 2, dash: hasSource ? [] : [7, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(hasSource ? accent.opacity(0.10) : Color.clear)
                )

            // The app's own mark, not the 白 typeface glyph — the logo has
            // squared terminals and its own angled top stroke, and a system
            // font can't stand in for it. Shipped as a template image so it
            // takes the same grey/accent treatment as the frame.
            Image("ShiroMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 86)
                .foregroundStyle(hasSource ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.35)))
        }
        .frame(width: 116, height: 174)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: hasSource)
        .accessibilityHidden(true)
    }

    /// The feature page's icon composition: the pillar's symbol on an
    /// accent-tinted tile, with its supporting symbol tucked behind.
    private func iconTile(icon: String, back: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: back)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(accent.opacity(0.45))
                .padding(10)
                .background(Circle().fill(Color.secondary.opacity(0.10)))
                .offset(x: 14, y: 12)

            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.appAccentForeground)
                .frame(width: 104, height: 104)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(accent)
                )
                .shadow(
                    color: Color.glowEnabled ? accent.opacity(Color.glowOpacity(0.4)) : .clear,
                    radius: Color.glowRadiusLarge
                )
        }
        .padding(.bottom, 16)
        .accessibilityHidden(true)
    }

    // MARK: - Steps (the setup page's live checklist)

    @ViewBuilder
    private func stepRow(
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
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDone)
    }

    private var trackerDetail: String {
        if aniListAuth.isLoggedIn && malAuth.isLoggedIn { return "AniList and MyAnimeList" }
        if aniListAuth.isLoggedIn { return "AniList" }
        if malAuth.isLoggedIn { return "MyAnimeList" }
        return "Sync your progress to AniList or MyAnimeList"
    }

    // MARK: - Actions

    private func go(to index: Int) {
        pageIndex = min(max(index, 0), pageCount - 1)
    }

    private func signInToAniList() {
        #if os(iOS)
        guard let presentationWindow else { return }
        aniListAuth.login(presentationAnchor: presentationWindow)
        #endif
    }

    /// Skip: the guide is done for now (it will not reappear on launch),
    /// but flagged as skipped so the Notifications tab keeps offering it.
    private func skip() {
        hasCompletedOnboarding = true
        onboardingWasSkipped = true
        dismiss()
    }

    /// Finish: completed for real — no skipped flag, so the Notifications
    /// card retires itself.
    private func finish() {
        hasCompletedOnboarding = true
        onboardingWasSkipped = false
        Haptics.success()
        dismiss()
    }
}
