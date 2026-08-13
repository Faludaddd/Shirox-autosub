import SwiftUI
#if os(iOS)
import UIKit
import AVFoundation
#if canImport(GoogleCast)
import GoogleCast
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        configureURLSession()
        IDMappingService.shared.prefetchAllMappingsIfNeeded()
        #if os(iOS)
        DownloadManager.shared.reconnectPendingTasks()
        #endif
        application.shortcutItems = QuickAction.registeredItems
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            let action = QuickAction(shortcutItem)
            MainActor.assumeIsolated {
                QuickActionManager.shared.pending = action
            }
        }
        let config = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if !targetEnvironment(macCatalyst) || os(macOS) && canImport(GoogleCast)
        let bgTask = application.beginBackgroundTask { }
        Task { @MainActor in
            CastManager.shared.stopCasting()
            application.endBackgroundTask(bgTask)
        }
        // Small sleep to give the network request a chance to fire before the process is killed
        Thread.sleep(forTimeInterval: 0.5)
        #endif
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        #if os(iOS)
        DownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
        #endif
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .all
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return PlayerPresenter.shared.orientationLock
        #else
        return .all
        #endif
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Declare the category at launch (harmless — does NOT interrupt other
            // apps' audio). Activation is deferred to player open so system music
            // (Spotify/Apple Music) keeps playing while browsing the app.
            try audioSession.setCategory(.playback, mode: .moviePlayback)
        } catch {
            Logger.shared.log("Failed to configure audio session: \(error)", type: "Error")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Request background task to keep casting alive while screen is locked
        #if canImport(GoogleCast)
        let bgTask = application.beginBackgroundTask { }
        DispatchQueue.main.asyncAfter(deadline: .now() + 27) {
            application.endBackgroundTask(bgTask)
        }
        #endif
    }

    private func configureURLSession() {
        let config = URLSessionConfiguration.default
        // Allow network transfers in background
        config.waitsForConnectivity = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        // Create a default session with this config for general use
        _ = URLSession(configuration: config)
    }
}
#endif

// MARK: - Hex Color Extension

extension UIColor {
    /// Initializes a UIColor from a hex string (e.g. "#FF6B6B" or "FF6B6B").
    /// Returns nil for invalid input.
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension Color {
    /// Resolves the user's custom accent color from UserDefaults, falling back to
    /// UIColor.label (adapts: near-black in light mode, near-white in dark mode)
    /// for a clean monochrome default aesthetic.
    static var appAccent: Color {
        let hex = UserDefaults.standard.string(forKey: "accentColorHex") ?? ""
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let uiColor = UIColor(hex: trimmed) {
            #if canImport(UIKit)
            return Color(uiColor)
            #endif
        }
        #if canImport(UIKit)
        return Color(UIColor.label)
        #else
        return .primary
        #endif
    }

    static var scheduleSelectedPill: Color {
        Color.red
    }

    static var glowIntensity: Double {
        UserDefaults.standard.object(forKey: "glowIntensity") as? Double ?? 0.5
    }

    static var glowEnabled: Bool {
        return UserDefaults.standard.object(forKey: "glowEnabled") as? Bool ?? true
    }

    static var dataSavingMode: Bool {
        UserDefaults.standard.bool(forKey: "dataSavingEnabled")
            || UserDefaults.standard.bool(forKey: "dataSavingMode")
    }
}

// MARK: - Liquid Glass Toggle Style (#123 correction)
//
// #123 correction — The previous `GlowingToggleStyle` used a solid gray
// capsule fill. The user requested the alternate Liquid Glass treatment: a
// frosted translucent capsule (`.ultraThinMaterial`) that matches the app's
// glass material language (toast system, sheets, tab bar). The thumb is a
// white circle with a subtle shadow. When ON, the capsule tints with the
// accent color at low opacity so the glass effect is preserved but the state
// is clearly readable. Glow is gated by `Color.glowEnabled` /
// `Color.glowIntensity` as before.
struct GlowingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            DraggableGlassToggle(isOn: configuration.isOn) {
                configuration.isOn.toggle()
                Haptics.light()
            } onChange: { newValue in
                configuration.isOn = newValue
                Haptics.light()
            }
        }
    }
}

/// Draggable Liquid Glass toggle. The thumb follows the finger during a
/// drag gesture and snaps to the nearest end on release. Tap toggles
/// instantly. Uses spring animation for smooth, physics-based movement.
private struct DraggableGlassToggle: View {
    let isOn: Bool
    let onTap: () -> Void
    let onChange: (Bool) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private let capsuleWidth: CGFloat = 60
    private let capsuleHeight: CGFloat = 34
    private let thumbSize: CGFloat = 28
    private let thumbTravel: CGFloat = 24 // distance between off and on positions

    private var thumbX: CGFloat {
        let base: CGFloat = isOn ? thumbTravel : -thumbTravel
        if isDragging {
            return base + dragOffset
        }
        return base
    }

    var body: some View {
        ZStack {
            // Liquid Glass capsule
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: capsuleWidth, height: capsuleHeight)
                .overlay(
                    Capsule()
                        .fill(isOn ? Color.appAccent.opacity(0.25) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isOn ? Color.appAccent.opacity(0.4) : Color.secondary.opacity(0.2),
                            lineWidth: 0.5
                        )
                )
                .shadow(
                    color: isOn && Color.glowEnabled
                        ? Color.appAccent.opacity(Color.glowIntensity * 0.6) : .clear,
                    radius: isOn && Color.glowEnabled
                        ? CGFloat(18 * Color.glowIntensity) : 0
                )

            // Thumb
            Circle()
                .fill(Color.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                .offset(x: isDragging ? thumbX : (isOn ? thumbTravel : -thumbTravel))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging ? false : isOn)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let base: CGFloat = isOn ? thumbTravel : -thumbTravel
                    let final = base + value.translation.width
                    // Snap to nearest end
                    let shouldTurnOn = final > 0
                    if shouldTurnOn != isOn {
                        onChange(shouldTurnOn)
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                        isDragging = false
                    }
                }
        )
        .onTapGesture {
            if !isDragging {
                onTap()
            }
        }
    }
}

@main
struct ShiroxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
    @StateObject private var moduleManager = ModuleManager.shared
    @Environment(\.scenePhase) private var scenePhase

    // Appearance settings — applied globally via .preferredColorScheme and .tint
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = ""

    /// Resolves the appearance mode to a ColorScheme (nil = follow system).
    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    /// Resolves the user's custom accent color, falling back to the system default.
    private var accentColor: Color {
        let hex = accentColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hex.isEmpty, let uiColor = UIColor(hex: hex) {
            #if canImport(UIKit)
            return Color(uiColor)
            #else
            return Color(hex)
            #endif
        }
        return .primary
    }

    init() {
        KingfisherImageCache.configure()
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: nil
        )
        #if !os(tvOS) && !targetEnvironment(macCatalyst) || os(macOS)
            _ = CastManager.shared
        #endif
        ProviderManager.shared.setup(providers: [AniListProvider.shared, MALProvider.shared])
        PendingWriteQueue.shared.register(sink: LibraryWriteSink())
        LocalLibraryManager.shared.syncFromContinueWatching()
        HostBlocklist.shared.loadIfNeeded()
        EpisodeNotificationManager.shared.registerDelegate()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(moduleManager)
                .tint(accentColor)
                .toggleStyle(GlowingToggleStyle())
                .preferredColorScheme(colorScheme)
                // Requirement #2 — Appearance changes must NOT reset navigation
                // or rebuild the view tree. The previous `.id(...)` modifier
                // (which bumped on accentColor/appearanceMode change) is removed
                // so the user stays on the same screen/tab with scroll position
                // and UI state preserved. SwiftUI's `.tint` and
                // `.preferredColorScheme` propagate live to the existing view
                // tree without needing a full rebuild.
                .overlay {
                    ToastContainerView()
                }
                .task {
                    // Update check — fire on launch, then periodically while
                    // the app is active. Non-blocking (the popup only renders
                    // when an update is actually available).
                    await AppUpdateManager.shared.checkForUpdates()
                    Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                            await AppUpdateManager.shared.checkForUpdates()
                        }
                    }
                    // #93 — Preload Schedule + Notifications in the background
                    // on launch. The fetches stay in `Task.detached` so a slow
                    // network never blocks app entry. The schedule fetch uses
                    // the SAME window `ScheduleView` will request
                    // (start-of-today → +windowDays) so the result lands in
                    // `AniListService`'s in-memory cache and `ScheduleView.load()`
                    // can read it back without a second network call.
                    Task.detached(priority: .userInitiated) {
                        // Match ScheduleView's fetch window exactly so the
                        // cached entries cover every day the schedule tab will
                        // render. `windowDays` defaults to 7.
                        let windowDays = UserDefaults.standard.object(forKey: "scheduleWindowDays") as? Int ?? 7
                        let clamped = [7, 14, 21, 30].contains(windowDays) ? windowDays : 7
                        let cal = Calendar.current
                        let startOfToday = cal.startOfDay(for: Date())
                        let from = Int(startOfToday.timeIntervalSince1970)
                        let to = from + clamped * 86_400
                        async let schedule = try? AniListService.shared.airingSchedules(from: from, to: to)
                        async let notifications = try? AniListSocialService.shared.fetchNotifications()
                        _ = await (schedule, notifications)
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await PendingWriteQueue.shared.flush() }
                        // Re-check for updates whenever the app returns to the
                        // foreground, so an update published while the app was
                        // backgrounded is surfaced promptly.
                        Task { await AppUpdateManager.shared.checkForUpdates() }
                    }
                }
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    NotificationCenter.default.post(name: .openSettingsTab, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
enum SidebarTab: CaseIterable {
    case home, library, downloads, settings, search

    var label: String {
        switch self {
        case .home:      return "Home"
        case .library:   return "Library"
        case .downloads: return "Downloads"
        case .settings:  return "Settings"
        case .search:    return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .library:   return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings:  return "gearshape.fill"
        case .search:    return "magnifyingglass"
        }
    }
}

private struct MacSidebarRow: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20))
                    .frame(width: 24)
                Text(tab.label)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? .white : .secondary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.primary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacSidebarView: View {
    @Binding var selection: SidebarTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shirox")
                .font(.title2.bold())
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(SidebarTab.allCases, id: \.self) { tab in
                MacSidebarRow(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .navigationSplitViewColumnWidthIfAvailable(220)
    }
}
#endif

// MARK: - Root Tab View

private struct RootTabView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var cfManager = CloudflareBypassManager.shared
    #if os(iOS)
    @ObservedObject private var playerPresenter = PlayerPresenter.shared
    @ObservedObject private var quickActions = QuickActionManager.shared
    #endif
    @State private var selectedTab = 0
    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var sidebarTab: SidebarTab = .home
    #endif

    #if os(iOS)
    private func routePendingQuickAction() {
        guard let action = quickActions.pending else { return }
        switch action {
        case .library:   selectedTab = 1
        case .downloads: selectedTab = 2
        case .search:    selectedTab = 3
        }
        quickActions.pending = nil
    }
    #endif

    var body: some View {
        Group {
            if #available(iOS 18, macOS 15, *) {
                #if targetEnvironment(macCatalyst)
                NavigationSplitView {
                    MacSidebarView(selection: $sidebarTab)
                } detail: {
                    switch sidebarTab {
                    case .home:      HomeView()
                    case .library:   LibraryView()
                    case .downloads: DownloadsView()
                    case .settings:  SettingsView()
                    case .search:    SearchView()
                    }
                }
                #elseif os(macOS)
                    NavigationSplitView {
                        MacSidebarView(selection: $sidebarTab)
                    } detail: {
                        switch sidebarTab {
                        case .home:      HomeView()
                        case .library:   LibraryView()
                        case .settings:  SettingsView()
                        case .search:    SearchView()
                        default: EmptyView()
                        }
                    }
                #else
                TabView(selection: $selectedTab) {
                    Tab("Home", systemImage: "house.fill", value: 0) {
                        HomeView().transition(.opacity)
                    }
                    Tab("Library", systemImage: "books.vertical.fill", value: 1) {
                        LibraryView().transition(.opacity)
                    }
                    #if os(iOS)
                    Tab("Downloads", systemImage: "arrow.down.circle.fill", value: 2) {
                        DownloadsView().transition(.opacity)
                    }
                    #endif
                    // Requirement #3 — Bottom search bar is the ONLY search
                    // entry point. AniList-only.
                    Tab(value: 3, role: .search) {
                        SearchView().transition(.opacity)
                    }
                    // Requirement #6 — Schedule tab (where Settings used to sit
                    // in the bottom bar). Settings is now in the Home toolbar
                    // (right icon) per requirement #7.
                    Tab("Schedule", systemImage: "calendar", value: 4) {
                        ScheduleView().transition(.opacity)
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tint(.appAccent)
                .animation(.easeInOut(duration: 0.25), value: selectedTab)
                .glassTabBarBackground()
                #endif
            } else {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .transition(.opacity)
                        .tabItem { Label("Home", systemImage: "house.fill") }
                        .tag(0)
                    LibraryView()
                        .transition(.opacity)
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                        .tag(1)
                    #if os(iOS)
                    DownloadsView()
                        .transition(.opacity)
                        .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                        .tag(2)
                    #endif
                    // Requirement #3 — Bottom search bar (AniList-only).
                    SearchView()
                        .transition(.opacity)
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(3)
                    // Requirement #6 — Schedule tab (where Settings was).
                    ScheduleView()
                        .transition(.opacity)
                        .tabItem { Label("Schedule", systemImage: "calendar") }
                        .tag(4)
                }
                .tint(.appAccent)
                // #126 — Performance Mode skips the tab-switch fade so tab
                // changes are instant on older devices.
                .animation(.easeInOut(duration: 0.25), value: selectedTab)
                .glassTabBarBackground()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedTab)
        // #96 — Selection haptic whenever the user switches tabs.
        .onChange(of: selectedTab) { _ in Haptics.selection() }
        .onOpenURL { url in
            guard url.scheme == "shirox" else { return }
            AniListAuthManager.shared.handleCallback(url: url)
        }
        .task {
            await moduleManager.restoreActiveModule()
            await moduleManager.checkForUpdates()
            await AniListAuthManager.shared.fetchViewer()
            await ContinueWatchingManager.shared.syncWithAniList()
            await ContinueWatchingManager.shared.syncWithMAL()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
            #if targetEnvironment(macCatalyst)
            sidebarTab = .settings
            #else
            selectedTab = 4
            #endif
        }
        #if os(iOS)
        .onAppear { routePendingQuickAction() }
        .onChange(of: quickActions.pending) { _ in routePendingQuickAction() }
        #endif
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { playerPresenter.pendingRatingContext != nil },
            set: { if !$0 { playerPresenter.pendingRatingContext = nil } }
        )) {
            if let ctx = playerPresenter.pendingRatingContext {
                RatingPromptView(
                    title: ctx.mediaTitle,
                    imageUrl: ctx.imageUrl,
                    scoreFormat: AniListAuthManager.shared.scoreFormat,
                    onSave: { score in
                        PlayerPresenter.shared.submitRating(score, for: ctx)
                        playerPresenter.pendingRatingContext = nil
                    },
                    onSkip: {
                        playerPresenter.pendingRatingContext = nil
                    }
                )
                .adaptivePresentationDetents([.medium, .large])
            }
        }

        .onChange(of: cfManager.activeBypassWebView != nil) { presented in
            if presented {
                CloudflareBypassWindowController.shared.show()
            } else {
                CloudflareBypassWindowController.shared.hide()
            }
        }

        // Update popup removed — updates are now handled via Settings → Update
        // tab (UpdateSettingsPage). The popup was non-functional and replaced
        // with a dedicated settings page that has check/download/copy/share.
        #endif
        #if targetEnvironment(macCatalyst)
        .onAppear {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 1024, height: 700)
        }
        #endif
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
}
