import SwiftUI
import Combine

// MARK: - Settings Nav Row (original Shirox design)

/// The original app's settings row: a glass icon tile, a title, and an optional
/// trailing value — the four-folder settings layout's building block.
struct SettingsNavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    // Adapts to the appearance: white vanished against light mode's pale glass.
                    .foregroundStyle(.primary)
            }
            .frame(width: 28, height: 28)
            .glassChrome(
                RoundedRectangle(cornerRadius: 7, style: .continuous),
                enabled: true,
                tint: nil,
                off: .ultraThinMaterial
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )

            Text(title)
                .font(.body)

            Spacer()

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Root Settings View

#if !os(tvOS)
/// The window a sign-in sheet hangs from: the app's key window, or nil when there's none.
@MainActor
func keyPresentationAnchor() -> ASPresentationAnchor? {
    #if os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #else
    return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    #endif
}
#endif

/// A settings page's sections: grouped on a Mac, as System Settings is, where a List draws one
/// flat full-width column; a List everywhere else.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

/// v2.30 — the settings root restored to the ORIGINAL Shirox four-folder layout
/// (account card → content → data → system → about). The fork's previous
/// flat category menu — including its custom Data Sources tab — is gone:
/// source management is the original's, through Accounts (provider primary +
/// sign-in) and Modules (streaming sources).
struct SettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    #if !os(tvOS)
    @State private var totalUsage = 0
    #endif

    private var isAnyAccountSignedIn: Bool {
        aniListAuth.isLoggedIn || malAuth.isLoggedIn
    }

    private var accountDisplayName: String {
        if let username = aniListAuth.username, !username.isEmpty {
            return username
        }
        if let username = malAuth.username, !username.isEmpty {
            return username
        }
        if aniListAuth.isLoggedIn {
            return "AniList User"
        }
        if malAuth.isLoggedIn {
            return "MyAnimeList User"
        }
        return "Sign In"
    }

    private var accountSubtitle: String {
        let services = [
            aniListAuth.isLoggedIn ? "AniList" : nil,
            malAuth.isLoggedIn ? "MyAnimeList" : nil,
        ].compactMap { $0 }
        switch services.count {
        case 0:  return "Connect AniList or MyAnimeList"
        case 1:  return "\(services[0]) Account & Tracking"
        default: return services.joined(separator: ", ") + ", and Tracking"
        }
    }

    private var accountInitials: String {
        let name = accountDisplayName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            let first = parts[0].prefix(1)
            let second = parts[1].prefix(1)
            return "\(first)\(second)".uppercased()
        } else if name.count >= 2 {
            return String(name.prefix(2)).uppercased()
        } else if !name.isEmpty {
            return name.uppercased()
        }
        return "S"
    }

    private var accountAvatarURL: String? {
        if aniListAuth.isLoggedIn, let url = aniListAuth.avatarURL, !url.isEmpty {
            return url
        }
        if malAuth.isLoggedIn, let url = malAuth.avatarURL, !url.isEmpty {
            return url
        }
        return nil
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let url = accountAvatarURL {
            CachedAsyncImage(urlString: url)
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        } else if isAnyAccountSignedIn {
            ZStack {
                Circle()
                    .fill(Color(red: 0.35, green: 0.75, blue: 0.98))
                    .frame(width: 52, height: 52)
                Text(accountInitials)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        } else {
            ZStack {
                Circle()
                    .fill(Color(red: 0.35, green: 0.75, blue: 0.98))
                    .frame(width: 52, height: 52)
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private var modulesSubtitle: String? {
        moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName
    }

    #if !os(tvOS)
    private var storageSubtitle: String? {
        totalUsage > 0 ? Self.formattedBytes(totalUsage) : nil
    }
    #endif

    var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                // Grouped, as the Mac's own settings are; a List there draws one long flat column.
                Form { sections }
                    .formStyle(.grouped)
                #else
                List { sections }
                #endif
            }
            .softScrollEdges()
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                PlayerPresenter.shared.resetToAppOrientation()
                totalUsage = CacheManager.shared.totalDiskUsage
            }
            #elseif os(macOS)
            .onAppear {
                totalUsage = CacheManager.shared.totalDiskUsage
            }
            #endif
        }
    }

    @ViewBuilder
    private var sections: some View {
        // Folder 1 — the account.
        Section {
            NavigationLink {
                AccountsSettingsView()
            } label: {
                HStack(spacing: 14) {
                    accountAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountDisplayName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(accountSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }

        // Folder 2 — content & playback.
        Section {
            NavigationLink {
                AppearanceSettingsPage()
            } label: {
                SettingsNavRow(icon: "paintbrush.fill", title: "Appearance",
                               subtitle: "Theme, accent, UI mode")
            }

            NavigationLink {
                PlayerSettingsView()
            } label: {
                SettingsNavRow(icon: "play.tv", title: "Player")
            }

            NavigationLink {
                SubtitleSettingsPage()
            } label: {
                SettingsNavRow(icon: "captions.bubble", title: "Subtitles",
                               subtitle: "Style, presets, live preview")
            }

            #if !os(tvOS)
            NavigationLink {
                ReaderSettingsView()
            } label: {
                SettingsNavRow(icon: "book", title: "Reader")
            }
            #endif

            NavigationLink {
                ModulesSettingsPage()
            } label: {
                SettingsNavRow(icon: "puzzlepiece.extension", title: "Modules",
                               subtitle: modulesSubtitle)
            }
        }

        // Folder 3 — library & data.
        Section {
            NavigationLink {
                LibrarySettingsPage()
            } label: {
                SettingsNavRow(icon: "books.vertical", title: "Library",
                               subtitle: "Lists & Matching")
            }

            NavigationLink {
                DownloadsSettingsPage()
            } label: {
                SettingsNavRow(icon: "arrow.down.circle", title: "Downloads")
            }

            NavigationLink {
                ScheduleSettingsPage()
            } label: {
                SettingsNavRow(icon: "calendar", title: "Schedule",
                               subtitle: "Airing schedule, timing")
            }

            NavigationLink {
                NotificationsSettingsPage()
            } label: {
                SettingsNavRow(icon: "bell", title: "Notifications",
                               subtitle: "Reminders, airing alerts")
            }

            #if !os(tvOS)
            NavigationLink {
                StorageManagementPage()
            } label: {
                SettingsNavRow(icon: "internaldrive", title: "Storage & Cache",
                               subtitle: storageSubtitle)
            }
            #endif
        }

        // Folder 4 — system.
        Section {
            #if !os(tvOS)
            NavigationLink {
                BackupSettingsView()
            } label: {
                SettingsNavRow(icon: "arrow.up.arrow.down.circle", title: "Backup & Restore")
            }
            #endif

            NavigationLink {
                SettingsViewLogger()
            } label: {
                SettingsNavRow(icon: "terminal", title: "App Logs")
            }
        }

        // Folder 5 — about.
        Section {
            NavigationLink {
                UpdatesSettingsPage()
            } label: {
                SettingsNavRow(icon: "arrow.down.circle.fill", title: "Updates",
                               subtitle: "Version, check, install")
            }

            NavigationLink {
                UpdateLogPage()
            } label: {
                SettingsNavRow(icon: "list.bullet.clipboard.fill", title: "Change Log",
                               subtitle: "What's new, fixed, and changed")
            }

            NavigationLink {
                AboutSettingsPage()
            } label: {
                SettingsNavRow(icon: "info.circle.fill", title: "About",
                               subtitle: "Version, licenses")
            }

            LabeledContent("Version") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                Text("\(version) (\(build))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}

// MARK: - Accounts & Tracking Settings

/// The original's account page: the provider list (primary + sign-in) and the
/// tracking toggles. (The original also offers Simkl sign-in and library
/// sync/overwrite/mirror here — those arrive with the Simkl port.)
struct AccountsSettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared

    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("rateOnFinish") private var rateOnFinish = true
    @AppStorage("trackersEnableSync") private var trackersEnableSync = true
    @AppStorage("trackersAutoSyncRatings") private var trackersAutoSyncRatings = true

    var body: some View {
        SettingsList {
            ProvidersSettingsSection()

            if aniListAuth.isLoggedIn || malAuth.isLoggedIn {
                Section("Tracking") {
                    if aniListAuth.isLoggedIn {
                        Toggle("Track on AniList", isOn: $aniListTrackingEnabled)
                            .tint(.secondary)
                    }
                    if malAuth.isLoggedIn {
                        Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled)
                            .tint(.secondary)
                    }
                    Toggle("Sync Trackers", isOn: $trackersEnableSync)
                        .tint(.secondary)
                    Toggle("Auto-Sync Ratings", isOn: $trackersAutoSyncRatings)
                        .tint(.secondary)
                    Toggle("Never reduce progress", isOn: $skipReWatchTracking)
                        .tint(.secondary)
                    Toggle("Prompt to rate after finishing", isOn: $rateOnFinish)
                        .tint(.secondary)
                    Text("Automatically update your watch progress as you watch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Accounts & Tracking")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Providers Section (original)

/// The original's source management for trackers/metadata: drag to set which of
/// AniList / MyAnimeList is primary, with sign-in right on each row.
private struct ProvidersSettingsSection: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        Section {
            ForEach(manager.orderedProviders, id: \.providerType) { provider in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    CachedAsyncImage(urlString: provider.providerType.iconURL)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.providerType.displayName)
                            .font(.headline)
                        Text(providerStatus(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        } else if isSignedIn(provider.providerType) {
                            Button("Make Primary") {
                                manager.selectProvider(provider.providerType)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .buttonStyle(.plain)
                        }
                        #if !os(tvOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
                }
            }
            .onMove { from, to in
                manager.moveProvider(from: from, to: to)
            }
            Text("Drag to reorder. The first provider is primary; the second is used as fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Providers")
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder
    private func providerAuthButton(for type: ProviderType) -> some View {
        let isLoggedIn = type == .anilist ? aniListAuth.isLoggedIn : malAuth.isLoggedIn
        Button(isLoggedIn ? "Sign Out" : "Sign In") {
            if isLoggedIn {
                if type == .anilist { aniListAuth.logout() } else { malAuth.logout() }
            } else {
                #if os(iOS)
                let anchor = presentationWindow
                #else
                let anchor = keyPresentationAnchor()
                #endif
                if let window = anchor {
                    if type == .anilist {
                        aniListAuth.login(presentationAnchor: window)
                    } else {
                        malAuth.login(presentationAnchor: window)
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isLoggedIn ? .red : Color.accentColor)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((isLoggedIn ? Color.red : Color.accentColor).opacity(0.1), in: Capsule())
        .buttonStyle(.plain)
    }
    #endif

    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return aniListAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        case .local:   return false   // not a sign-in-able provider
        }
    }

    private func providerStatus(_ provider: any MediaProvider) -> String {
        switch provider.providerType {
        case .anilist:
            guard aniListAuth.isLoggedIn else { return "Not signed in" }
            // A token AniList has started refusing still has `isLoggedIn` true — the token is
            // kept on purpose, since a revoked one and a failing auth backend are
            // indistinguishable from here. Saying "Signed in" while every sync fails is the
            // part that left people with no idea what to do about it.
            return aniListAuth.needsReauthentication ? "Sign in again" : "Signed in"
        case .mal:   return malAuth.isLoggedIn ? "Signed in" : "Not signed in"
        case .local: return "Not signed in"
        }
    }
}

// MARK: - Player Settings (original page, fork-adapted)

/// The original's Player page. The engine picker (Native/MPV) and the
/// hold-action picker (save-frame) arrive with the MPV port; quality writes
/// this fork's `preferredVideoQuality` key, which the player reads.
struct PlayerSettingsView: View {
    fileprivate static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("preferredVideoQuality") private var preferredQuality: String = "auto"
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("autoPauseOnControlCenter") private var pauseForControlCenter = true
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        SettingsList {
            Section("Display & Style") {
                // A phone's: a Mac's player is a window.
                #if !os(macOS)
                Toggle("Force Landscape Mode", isOn: $forceLandscape)
                    .tint(.secondary)
                    #if os(iOS)
                    .onChangeOf(forceLandscape) {
                        PlayerPresenter.shared.resetToAppOrientation()
                    }
                    #endif
                #endif

                if #available(iOS 26.0, macOS 26.0, *) {
                    Toggle("Liquid Glass Controls", isOn: $playerLiquidGlass)
                        .tint(.secondary)
                    Text("Frosted glass buttons in the video player. Turn off for solid controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(Self.isMac ? "Playback Quality" : "Playback Quality & Gestures") {
                Picker("Preferred Quality", selection: $preferredQuality) {
                    Text("Auto").tag("auto")
                    Text("Highest").tag("highest")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("480p").tag("480")
                    Text("Lowest").tag("lowest")
                }
                Text("Which rendition to start on when a stream offers several. Auto lets the player adapt to your connection; a fixed choice falls back to the closest available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if os(iOS)
                Toggle("Pause for Control Center", isOn: $pauseForControlCenter)
                    .tint(.secondary)
                Text("Pauses while Control Center or Notification Center is open and picks up again when you close it. Leaving the app or locking the phone still plays in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("Skipping") {
                Picker("Skip Duration", selection: $skipShort) {
                    ForEach(shortOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                Picker("Long Skip Duration", selection: $skipLong) {
                    ForEach(longOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                    .tint(.secondary)
                Text("Automatically skip intros, recaps, credits, and previews")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Episodes & Progress") {
                Toggle("Auto Next Episode", isOn: $autoNextEpisode)
                    .tint(.secondary)

                Toggle("Reverse Episode List by Default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                    .tint(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Episode Progress Threshold")
                        Spacer()
                        Text("\(Int(watchedPercentage))%")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    #if !os(tvOS)
                    Slider(value: $watchedPercentage, in: 50...100, step: 1)
                    #endif
                }
            }

            // This fork's deeper player options, kept whole under the original page.
            Section("Advanced") {
                NavigationLink {
                    PlayerGeneralSettingsPage()
                } label: {
                    SettingsNavRow(icon: "gearshape.fill", title: "General",
                                   subtitle: "Speed, controls, layout")
                }
                NavigationLink {
                    QualitySettingsPage()
                } label: {
                    SettingsNavRow(icon: "sparkles.tv.fill", title: "Quality & Data Saver",
                                   subtitle: "Resolution, data saving")
                }
                NavigationLink {
                    GesturesSettingsPage()
                } label: {
                    SettingsNavRow(icon: "hand.tap.fill", title: "Gestures",
                                   subtitle: "Touch controls")
                }
                NavigationLink {
                    SkipSegmentsSettingsPage()
                } label: {
                    SettingsNavRow(icon: "forward.end.fill", title: "Skip Segments",
                                   subtitle: "AniSkip, IntroDB, auto-skip")
                }
                NavigationLink {
                    NextEpisodeSettingsPage()
                } label: {
                    SettingsNavRow(icon: "arrow.right.circle.fill", title: "Next Episode",
                                   subtitle: "Auto-play, appearance")
                }
                NavigationLink {
                    HoldSpeedSettingsPage()
                } label: {
                    SettingsNavRow(icon: "speedometer", title: "Hold-Speed",
                                   subtitle: "Sensitivity, multiplier")
                }
                NavigationLink {
                    AudioSettingsPage()
                } label: {
                    SettingsNavRow(icon: "speaker.wave.2.fill", title: "Audio",
                                   subtitle: "Surround, comfort")
                }
                NavigationLink {
                    PiPSettingsPage()
                } label: {
                    SettingsNavRow(icon: "pip.fill", title: "Picture-in-Picture",
                                   subtitle: "PiP, auto-pause")
                }
                NavigationLink {
                    StreamingSettingsPage()
                } label: {
                    SettingsNavRow(icon: "dot.radiowaves.left.and.right", title: "Streaming",
                                   subtitle: "Progress threshold")
                }
                NavigationLink {
                    AutoPickSettingsPage()
                } label: {
                    SettingsNavRow(icon: "wand.and.stars", title: "Auto Pick",
                                   subtitle: "Playback automation")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Player")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
        }
        #endif
    }
}

// MARK: - Reader Settings (original page, fork-adapted)

#if !os(tvOS)
/// The original's Reader page. The page-curl toggle arrives with the reader
/// rework; this fork's full reading options live in Reading Mode's settings.
struct ReaderSettingsView: View {
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true

    var body: some View {
        SettingsList {
            if #available(iOS 26.0, macOS 26.0, *) {
                Section {
                    Toggle("Liquid Glass Controls", isOn: $readerLiquidGlass)
                        .tint(.secondary)
                } header: {
                    Text("Style")
                } footer: {
                    Text("Frosted glass buttons in the manga reader. Turn off for solid controls.")
                }
            } else {
                Section {
                    Text("Liquid Glass reader controls need \(Self.systemName) 26.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    MangaSettingsView()
                } label: {
                    SettingsNavRow(icon: "book.fill", title: "Reading Settings",
                                   subtitle: "Reading Mode's full options")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Reader")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}
#endif

// MARK: - Modules Settings (original page)

/// The original's Modules page: manage installed modules (the app's streaming
/// and reading sources) and open the module store.
struct ModulesSettingsPage: View {
    enum ModuleMediaType { case manga }

    var mediaType: ModuleMediaType? = nil

    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    ModuleListView()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let active = moduleManager.activeModule {
                                CachedAsyncImage(urlString: active.iconUrl ?? "", base64String: active.iconData)
                            } else {
                                AsyncImage(url: URL(string: providerManager.primary?.providerType.iconURL ?? "")) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "list.bullet")
                                            .font(.title)
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName ?? "AniList")
                                .font(.headline)
                            Text("Manage Installed Modules")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                NavigationLink {
                    ModuleStorePage(mediaType: mediaType)
                } label: {
                    SettingsNavRow(icon: "square.grid.2x2.fill", title: "Module Store",
                                   subtitle: "Browse community modules")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Modules")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library Settings (original page, fork-adapted)

/// The original's Library page: list order, card behaviour, layout, matching
/// and the on-device library. (New-episode badges arrive with that system.)
struct LibrarySettingsPage: View {
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue
    @AppStorage(GooeyRefreshGeometry.settingKey) private var gooeyRefresh = true
    @AppStorage(CardTitleSetting.hiddenKey) private var hideCardTitles = false
    @AppStorage(DetailLayoutSetting.cinematicHomeKey) private var cinematicHomeLayout = true
    @State private var showClearLocalLibrary = false

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    LibraryListOrderView()
                } label: {
                    Label("List Order & Custom Lists", systemImage: "list.bullet.indent")
                }
            }

            Section {
                Toggle("Hide Titles on Cards", isOn: $hideCardTitles)
                    .tint(.secondary)
                Text("Posters from TVDB carry the show's name, so the title over them says it twice. Hold a card for its full title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cards")
            }

            if DetailLayoutSetting.isOffered {
                Section {
                    Toggle("Cinematic Home", isOn: $cinematicHomeLayout)
                        .tint(.secondary)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("The featured show's artwork fills the window on iPad, with the rows scrolling up over it. Turn off for the banner layout with the rows under it.")
                }
            }

            #if os(iOS)
            Section {
                Toggle("Gooey Pull to Refresh", isOn: $gooeyRefresh)
                    .tint(.secondary)
            } footer: {
                Text("Pulling to refresh stretches a drop out of the Dynamic Island that holds the spinner. Turn off for a frosted circle instead, as sheets always use.")
            }
            #endif

            Section("Matching") {
                ForEach(orderedLanguages, id: \.self) { lang in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(lang.capitalized)
                    }
                }
                .onMove { from, to in
                    var langs = orderedLanguages
                    langs.move(fromOffsets: from, toOffset: to)
                    titlePriority = langs.joined(separator: ",")
                }
                Text("Drag to reorder title priority for display and matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif

            Section {
                Toggle("Auto-track what you watch", isOn: $localAutoTrackEnabled)
                    .tint(.secondary)
                Picker("Score Format", selection: $localScoreFormatRaw) {
                    Text("100 Point").tag(ScoreFormat.point100.rawValue)
                    Text("10 Point (Decimal)").tag(ScoreFormat.point10Decimal.rawValue)
                    Text("10 Point").tag(ScoreFormat.point10.rawValue)
                    Text("5 Star").tag(ScoreFormat.point5.rawValue)
                    Text("3 Point").tag(ScoreFormat.point3.rawValue)
                }
                Button(role: .destructive) {
                    showClearLocalLibrary = true
                } label: {
                    Label("Clear Local Library", systemImage: "trash")
                }
            } header: {
                Text("Local Library")
            } footer: {
                Text("Your on-device library works without signing in. Auto-track keeps its Watching list in sync with what you watch.")
            }
            .alert("Clear Local Library", isPresented: $showClearLocalLibrary) {
                Button("Clear", role: .destructive) { LocalLibraryManager.shared.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all on-device entries and collections. AniList/MyAnimeList lists are not affected.")
            }
        }
        .softScrollEdges()
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library List Order View (original)

struct LibraryListOrderView: View {
    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    private var statuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private var customListNames: [String] {
        UserDefaults.standard.stringArray(forKey: "libraryCustomListNames") ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(statuses) { status in
                    Label(status.displayName, systemImage: icon(for: status))
                }
                .onMove { from, to in
                    var list = statuses
                    list.move(fromOffsets: from, toOffset: to)
                    statusOrderRaw = list.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("Drag to reorder status tabs")
            }

            if !customListNames.isEmpty {
                Section {
                    ForEach(customListNames, id: \.self) { name in
                        Label(name, systemImage: "list.star")
                    }
                } header: {
                    Text("Custom Lists")
                } footer: {
                    Text("Custom lists are managed on AniList.")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("List Order")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func icon(for status: MediaListStatus) -> String {
        switch status {
        case .current:   return "play.circle"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }
}

// MARK: - Downloads Settings (original page, fork-adapted)

/// The original's Downloads page shape, driving this fork's download manager
/// (concurrency, background, Wi-Fi-only). Delete-all lives in Storage & Cache.
struct DownloadsSettingsPage: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled: Bool = true
    @AppStorage("downloadOverWiFiOnly") private var downloadOverWiFiOnly: Bool = false

    var body: some View {
        SettingsList {
            Section("Downloads") {
                Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                #if os(iOS)
                Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled)
                    .tint(.secondary)
                #endif
                Toggle("Download Over Wi-Fi Only", isOn: $downloadOverWiFiOnly)
                    .tint(.secondary)
                Text("Background Downloads keeps unfinished transfers alive when you leave the app or lock the phone. Wi-Fi Only pauses every download on cellular and resumes by itself back on Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .softScrollEdges()
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
