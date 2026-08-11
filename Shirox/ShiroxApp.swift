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

    static var glowIntensity: Double {
        UserDefaults.standard.object(forKey: "glowIntensity") as? Double ?? 0.5
    }

    static var glowEnabled: Bool {
        UserDefaults.standard.object(forKey: "glowEnabled") as? Bool ?? true
    }

    static var dataSavingMode: Bool {
        UserDefaults.standard.bool(forKey: "dataSavingMode")
    }
}

// MARK: - Glowing Toggle Style
//
// The global `.tint(Color.gray)` in `ShiroxApp` overrides the default green tint
// for `Toggle`, but it also strips the toggle of any glow halo. This custom
// `ToggleStyle` re-introduces a soft gray glow on the capsule when the toggle is
// ON, gated by `Color.glowEnabled` and scaled by `Color.glowIntensity` so the
// effect respects the user's Glow preference in Settings.

struct GlowingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.gray : Color.gray.opacity(0.3))
                    .frame(width: 51, height: 31)
                    .shadow(
                        color: configuration.isOn && Color.glowEnabled
                            ? Color.gray.opacity(Color.glowIntensity) : .clear,
                        radius: configuration.isOn && Color.glowEnabled ? CGFloat(21 * Color.glowIntensity) : 0
                    )
                Circle()
                    .fill(Color.white)
                    .frame(width: 27, height: 27)
                    .offset(x: configuration.isOn ? 10 : -10)
            }
            .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            .onTapGesture {
                configuration.isOn.toggle()
                Haptics.light()
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
    @State private var showSplash = true

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
                // #17 — Force the entire RootTabView subtree to re-render when
                // the user changes the accent color or appearance mode in
                // Settings. `@AppStorage` already re-evaluates `ShiroxApp.body`,
                // but cached `.tint` / `.preferredColorScheme` values inside
                // already-displayed subviews (especially `RootTabView`, which
                // is a separate struct and doesn't directly observe these
                // `@AppStorage` keys) don't always pick up the new values.
                // Bumping `.id(...)` discards the old view tree and rebuilds it
                // fresh with the new accent color / color scheme applied.
                .id("\(accentColorHex)-\(appearanceMode)")
                .overlay {
                    if showSplash {
                        AnimatedSplashView()
                            .transition(.opacity)
                    }
                }
                .overlay {
                    ToastContainerView()
                }
                .task {
                    // #93 — Preload Schedule + Notifications in the background
                    // during the splash. The fetches stay in `Task.detached`
                    // (a slow network never blocks app entry), but the splash
                    // window is now 3.5s so the preload has a much better
                    // chance of completing before the home tab appears. The
                    // schedule fetch uses the SAME window `ScheduleView` will
                    // request (start-of-today → +windowDays) so the result
                    // lands in `AniListService`'s in-memory cache and
                    // `ScheduleView.load()` can read it back without a second
                    // network call.
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
                    // #93 — Extended splash window (3.5s) gives the preload a
                    // head start so the Home tab is more likely to be
                    // populated when it appears.
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await PendingWriteQueue.shared.flush() } }
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
                    Tab(value: 3, role: .search) {
                        SearchView().transition(.opacity)
                    }
                    Tab("Settings", systemImage: "gearshape.fill", value: 4) {
                        SettingsView().transition(.opacity)
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
                    SearchView()
                        .transition(.opacity)
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(3)
                    SettingsView()
                        .transition(.opacity)
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                        .tag(4)
                }
                .tint(.appAccent)
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
