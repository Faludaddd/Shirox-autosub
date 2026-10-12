import SwiftUI
import UserNotifications
import Kingfisher

// MARK: - Asset loading (conditional)

/// Loads only what onboarding genuinely needs: a handful of real trending
/// titles (and their poster artwork) so the notification demonstration shows
/// realistic content. Everything reuses the app's existing systems — the
/// unified discovery chain for the data, Kingfisher for caching — and the
/// loading screen only ever appears when there is real work to do.
enum OnboardingAssetLoader {
    /// How many posters the demo wants at most.
    private static let posterCount = 6

    /// The quick decision: is there genuine work (a fetch or missing cached
    /// artwork), or can the flow skip the loading screen entirely?
    ///
    /// Fresh installs have no shelf snapshot → real work. Returning users
    /// have a snapshot and cached posters → straight to the tour.
    static func decide() async -> (needsLoad: Bool, media: [Media]) {
        guard let snapshot = SnapshotStore.loadHomeShelves(ignoreTTL: true),
              let trending = snapshot.trending, !trending.isEmpty else {
            return (true, [])
        }
        let candidates = Array(trending.prefix(posterCount))
        let urls = candidates.compactMap { $0.coverImage.best }
        // Everything already on disk? Then there is nothing to show a
        // loading screen for. (Disk reads stay off the main thread.)
        let cachedCount = await Task.detached(priority: .userInitiated) {
            urls.filter { CachedAsyncImage.cachedImageData(for: $0) != nil }.count
        }.value
        let needed = min(3, urls.count)
        return (cachedCount < needed, candidates)
    }

    /// The real work: fetch one page of trending titles through the existing
    /// unified chain, then warm the poster cache. Reports honest progress —
    /// indeterminate while the list itself is fetching, exact percentage per
    /// poster. Any failure degrades gracefully (empty result → the demo uses
    /// neutral placeholder content).
    static func load(progress: @escaping @Sendable (Double?, String) -> Void) async throws -> [Media] {
        progress(nil, "Fetching example titles…")

        // One page of trending, with a timeout so a stalled network can
        // never block the flow indefinitely.
        let media: [Media] = await withTaskGroup(of: [Media]?.self) { group in
            group.addTask { try? await UnifiedProviderSystem.shared.trending() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        guard !media.isEmpty else { return [] }

        let candidates = Array(media.prefix(posterCount))
        let urls = candidates.compactMap { $0.coverImage.best }
        guard !urls.isEmpty else { return candidates }

        progress(0, "Caching artwork…")
        var loaded = 0
        let deadline = Date().addingTimeInterval(12)
        for url in urls {
            guard Date() < deadline else { break }
            let options: KingfisherOptionsInfo = [.downloadTimeout(6)]
            _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<KFCrossPlatformImage?, Error>) in
                guard let requestURL = URL(string: url) else {
                    cont.resume(returning: nil)
                    return
                }
                KingfisherManager.shared.retrieveImage(with: requestURL, options: options) { result in
                    switch result {
                    case .success(let value): cont.resume(returning: value.image)
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
            loaded += 1
            progress(Double(loaded) / Double(urls.count), "Caching artwork…")
        }
        return candidates
    }
}

// MARK: - Loading screen

/// Shown only while `OnboardingAssetLoader` has real work in flight. Real
/// progress when it can be measured (posters cached so far), clearly
/// indeterminate when it can't (the list fetch itself). Never appears on
/// ordinary launches — only onboarding runs that need it.
struct OnboardingLoadingScreen: View {
    @ObservedObject private var flow = OnboardingFlowController.shared

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.primary.opacity(0.001)
        #endif
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 40)

            Image("ShiroMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 88)
                .foregroundStyle(Color.appAccent)

            Text("Preparing the tour")
                .font(.title3.weight(.bold))

            VStack(spacing: 8) {
                if let progress = flow.loadProgress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                    Text("\(Int(min(max(progress, 0), 1) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.appAccent)
                }
            }
            .frame(maxWidth: 280)

            Text(flow.loadStatus.isEmpty ? "Getting things ready…" : flow.loadStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(platformBackground.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Simulated notification demonstration

/// One simulated banner's content. Demo-only — never delivered to the system,
/// never touching the real unread count.
struct DemoBannerContent: Identifiable {
    let id: Int
    let icon: String
    let tint: Color
    let title: String
    let message: String
}

/// The interactive notification demonstration: a bell whose badge climbs
/// 1…2…3…4…5 while simulated banners — styled like the app's real in-app
/// notification cards — slide down from the top of the demo area, hold, and
/// slide away. Everything is local state: the moment the view goes away, the
/// simulated badge and banners are gone, and the real Notifications badge is
/// untouched.
struct SimulatedNotificationDemo: View {
    let media: [Media]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex: Int?
    @State private var badgeCount = 0
    @State private var finishedPlaying = false

    private var banners: [DemoBannerContent] {
        let first = media.first?.title.displayTitle ?? "Example Series"
        let second = media.dropFirst().first?.title.displayTitle ?? "Another Series"
        let moduleName = ModuleManager.shared.modules.first?.name ?? "Your first module"
        return [
            DemoBannerContent(id: 0, icon: "tv.fill", tint: .accentColor,
                              title: "New Episode",
                              message: "\(first) — Episode 8 just aired"),
            DemoBannerContent(id: 1, icon: "clock.badge.fill", tint: .orange,
                              title: "Airing Soon",
                              message: "\(second) airs in 30 minutes"),
            DemoBannerContent(id: 2, icon: "checkmark.circle.fill", tint: .green,
                              title: "Module Installed",
                              message: "\(moduleName) was installed successfully"),
            DemoBannerContent(id: 3, icon: "arrow.down.circle.fill", tint: .blue,
                              title: "Download Complete",
                              message: "\(first) — Episode 3 is ready offline"),
            DemoBannerContent(id: 4, icon: "heart.fill", tint: .pink,
                              title: "Activity",
                              message: "Someone liked your activity post"),
        ]
    }

    var body: some View {
        VStack(spacing: 18) {
            demoHeader
            bannerStage
            if finishedPlaying {
                Label("That's how notifications look inside Shirox. The badge and banners you just saw were a demo — nothing was sent to your device.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .task { await play() }
    }

    // MARK: Header (bell + animated demo badge)

    private var demoHeader: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.appAccent.opacity(0.12)))

                ZStack {
                    Circle().fill(Color.red)
                    Text("\(badgeCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .modifier(BadgeNumberMorph(count: badgeCount))
                }
                .frame(width: 20, height: 20)
                .offset(x: 4, y: -2)
                .scaleEffect(badgeCount == 0 ? 0.01 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: badgeCount)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications, demonstrated")
                    .font(.subheadline.weight(.bold))
                Text("Watch the badge count each time a banner drops in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Text("DEMO")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().strokeBorder(Color.appAccent.opacity(0.6), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notification demonstration. Simulated badge count: \(badgeCount).")
    }

    // MARK: Banner stage

    private var bannerStage: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
                .frame(height: 300)

            VStack {
                if let index = currentIndex, let banner = banners[safe: index] {
                    demoBanner(banner)
                        .id(banner.id)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
        .frame(height: 300)
        .clipped()
    }

    private func demoBanner(_ banner: DemoBannerContent) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(banner.tint.opacity(0.18))
                Image(systemName: banner.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(banner.tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    // MARK: Timeline

    private func play() async {
        guard !finishedPlaying else { return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        for (index, _) in banners.enumerated() {
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.8)) {
                currentIndex = index
                badgeCount = index + 1
            }
            Haptics.light()
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                currentIndex = nil
            }
            try? await Task.sleep(nanoseconds: 380_000_000)
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.75)) {
            badgeCount = 0
            finishedPlaying = true
        }
    }
}

/// The badge number swap: a spring pop plus a numeric cross-fade on OS
/// versions that support it.
private struct BadgeNumberMorph: ViewModifier {
    var count: Int

    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            content.contentTransition(.numericText())
        } else {
            content
        }
    }
}

// MARK: - Theme demonstration

/// The interactive day/night scene. Dragging the sun/moon handle (or tapping
/// the scene) moves `dayNight` between 0 (day) and 1 (night) — pure
/// illustration, it writes nothing. The real choice happens through the
/// accompanying selector, which writes the app's actual `appearanceMode`
/// preference and persists normally.
struct ThemeDemoScene: View {
    @Binding var dayNight: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            scene
            handle
        }
    }

    // MARK: Scene

    private var scene: some View {
        GeometryReader { geo in
            let size = geo.size
            let stars = Self.starPositions(in: size)

            ZStack(alignment: .bottomLeading) {
                // Sky: the day gradient and the night gradient cross-faded.
                LinearGradient(
                    colors: [Color(red: 0.44, green: 0.71, blue: 0.96), Color(red: 0.78, green: 0.90, blue: 0.99)],
                    startPoint: .top, endPoint: .bottom)
                    .opacity(1 - dayNight)
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.05, blue: 0.13), Color(red: 0.11, green: 0.12, blue: 0.27)],
                    startPoint: .top, endPoint: .bottom)
                    .opacity(dayNight)

                // Stars, brightening as night falls.
                ForEach(0..<stars.count, id: \.self) { index in
                    let point = stars[index]
                    Circle()
                        .fill(.white)
                        .frame(width: index % 3 == 0 ? 2.5 : 1.8)
                        .position(point)
                        .opacity(dayNight * (index % 4 == 0 ? 1 : 0.7))
                }

                // Sun, sinking below the hills as night comes on.
                Circle()
                    .fill(Color(red: 1.0, green: 0.84, blue: 0.35))
                    .frame(width: 46, height: 46)
                    .shadow(color: Color(red: 1.0, green: 0.85, blue: 0.4).opacity(0.9), radius: 16)
                    .position(x: size.width * 0.72,
                              y: size.height * (0.30 + dayNight * 0.55))
                    .opacity(1 - min(dayNight * 1.35, 1))

                // Moon, rising as the sun sets.
                ZStack {
                    Circle().fill(Color(red: 0.93, green: 0.93, blue: 0.86))
                    Circle().fill(Color.black)
                        .offset(x: 13, y: -6)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: 34, height: 34)
                .shadow(color: .white.opacity(0.35), radius: 10)
                .position(x: size.width * 0.30,
                          y: size.height * (0.72 - dayNight * 0.48))
                .opacity(max(0, dayNight * 1.5 - 0.15))

                // Clouds, fading as the sky darkens.
                cloudGroup(width: 84, baseOpacity: 0.9)
                    .position(x: size.width * 0.24, y: size.height * 0.30)
                    .opacity((1 - dayNight) * 0.95)
                cloudGroup(width: 62, baseOpacity: 0.8)
                    .position(x: size.width * 0.78, y: size.height * 0.20)
                    .opacity((1 - dayNight) * 0.85)

                // Hills: two silhouettes that darken with the sky.
                Ellipse()
                    .fill(dayHillColor)
                    .frame(width: size.width * 1.35, height: size.height * 0.55)
                    .offset(x: -size.width * 0.12, y: size.height * 0.42)
                Ellipse()
                    .fill(dayHillColor2)
                    .frame(width: size.width * 1.2, height: size.height * 0.42)
                    .offset(x: size.width * 0.30, y: size.height * 0.50)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.85)) {
                dayNight = dayNight > 0.5 ? 0 : 1
            }
            Haptics.light()
        }
        .accessibilityLabel(dayNight > 0.5 ? "Night scene. Double tap to switch to day." : "Day scene. Double tap to switch to night.")
    }

    private var dayHillColor: Color {
        Color(red: 0.22 + dayNight * -0.15, green: 0.48 + dayNight * -0.38, blue: 0.30 + dayNight * -0.16)
    }
    private var dayHillColor2: Color {
        Color(red: 0.30 + dayNight * -0.23, green: 0.56 + dayNight * -0.44, blue: 0.36 + dayNight * -0.22)
    }

    private func cloudGroup(width: CGFloat, baseOpacity: Double) -> some View {
        HStack(spacing: -10) {
            Capsule().fill(.white).frame(width: width * 0.55, height: 22)
            Capsule().fill(.white).frame(width: width * 0.45, height: 17).padding(.top, 10)
        }
        .opacity(baseOpacity)
    }

    /// Deterministic star positions (seeded) — no shimmer, no timers, the
    /// same sky every time the step opens.
    private static func starPositions(in size: CGSize) -> [CGPoint] {
        var seed: UInt64 = 20261012
        var points: [CGPoint] = []
        for _ in 0..<24 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Double((seed >> 33) % 1000) / 1000
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = Double((seed >> 33) % 1000) / 1000
            points.append(CGPoint(x: 8 + x * max(size.width - 16, 0),
                                  y: 8 + y * max(size.height * 0.5, 0)))
        }
        return points
    }

    // MARK: Handle

    /// The sun/moon knob on a track — drag it to sweep the scene between day
    /// and night, release and it settles on the nearest side.
    private var handle: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width - 44
            let knobX = 22 + dayNight * trackWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 34)
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.84, blue: 0.35), Color(red: 0.35, green: 0.38, blue: 0.75)],
                    startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .frame(height: 34)
                    .opacity(0.35)

                Image(systemName: dayNight > 0.5 ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.appAccent))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(x: knobX, y: 17)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        dayNight = min(max(Double((value.location.x - 22) / max(trackWidth, 1)), 0), 1)
                    }
                    .onEnded { _ in
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.8)) {
                            dayNight = (dayNight > 0.5) ? 1 : 0
                        }
                        Haptics.light()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Day and night slider")
            .accessibilityValue(dayNight > 0.5 ? "Night" : "Day")
            .accessibilityHint("Swipe up or down to toggle")
            .accessibilityAdjustableAction { direction in
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85)) {
                    switch direction {
                    case .decrement: dayNight = 0
                    case .increment: dayNight = 1
                    @unknown default: break
                    }
                }
            }
        }
        .frame(height: 34)
    }
}

// MARK: - Notification permission bottom sheet

/// The "Enable Notifications" bottom sheet: the benefits first, then — only
/// after an explicit tap — the REAL system permission prompt. The result
/// drives the UI honestly: granted shows enabled, denied explains how to
/// turn notifications on later in system Settings (and never re-prompts;
/// iOS makes that impossible anyway, and the sheet doesn't try).
struct NotificationPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRequesting = false
    @State private var outcome: Outcome?
    @State private var startingState: NotificationAuthState = .notDetermined

    enum Outcome {
        case granted
        case denied
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .accessibilityHidden(true)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.appAccent)
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(Color.appAccentForeground)
                        }
                        .frame(width: 46, height: 46)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable Notifications")
                                .font(.headline)
                            Text("Straight from Shirox, right when it matters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        benefitRow(icon: "tv.fill", text: "Episode reminders — know the moment a show you follow airs")
                        benefitRow(icon: "arrow.down.circle.fill", text: "Download results — finished episodes, ready to watch offline")
                        benefitRow(icon: "checkmark.circle.fill", text: "Module installs and app updates, confirmed")
                        benefitRow(icon: "person.2.fill", text: "Account activity — replies, likes and follows")
                    }

                    switch outcome {
                    case .granted:
                        Label("Notifications are on. Reminders you set will arrive right on time.",
                              systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
                            .transition(.opacity)

                    case .denied:
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Notifications are off for Shirox", systemImage: "bell.slash.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("You can turn them on any time: open the Settings app, tap Shirox, then Notifications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            #if os(iOS)
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Open Settings", systemImage: "arrow.up.forward.app.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.springPress)
                            #endif
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.09)))
                        .transition(.opacity)

                    case nil:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            VStack(spacing: 10) {
                switch outcome {
                case .granted:
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .foregroundStyle(Color.appAccentForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.appAccent))
                    }
                    .buttonStyle(.springPress)

                default:
                    Button {
                        Task { await request() }
                    } label: {
                        HStack(spacing: 6) {
                            if isRequesting {
                                ProgressView().tint(Color.appAccentForeground)
                            }
                            Text(startingState == .denied ? "Review in Settings" : "Enable Notifications")
                                .font(.headline)
                        }
                        .foregroundStyle(Color.appAccentForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.appAccent))
                    }
                    .buttonStyle(.springPress)
                    .disabled(isRequesting)

                    Button {
                        dismiss()
                    } label: {
                        Text("Not Now")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .task {
            startingState = await NotificationAuthState.current()
            if startingState == .denied { outcome = .denied }
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.appAccent.opacity(0.12)))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The one real permission request — only ever triggered by this button.
    private func request() async {
        if startingState == .denied {
            // Already denied at the OS level: iOS will not show the prompt
            // again, so be honest and take the user to Settings instead.
            #if os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            #endif
            return
        }
        isRequesting = true
        let granted = await EpisodeNotificationManager.shared.requestAuthorization()
        isRequesting = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8)) {
            outcome = granted ? .granted : .denied
        }
        if granted { Haptics.success() } else { Haptics.warning() }
    }
}

// MARK: - Real authorization state

/// The REAL notification permission state, read from the system — the setup
/// card shows this, never an assumption.
enum NotificationAuthState {
    case notDetermined
    case authorized
    case denied

    static func current() async -> NotificationAuthState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}
