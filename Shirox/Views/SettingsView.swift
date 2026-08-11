import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled = true
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage("preferredVideoQuality") private var preferredVideoQuality = "auto"
    @AppStorage("autoPauseOnInterruption") private var autoPauseOnInterruption = true
    @AppStorage("holdSpeedEnabled") private var holdSpeedEnabled = true
    @AppStorage("holdSpeedSensitivity") private var holdSpeedSensitivity: Double = 0.5
    @AppStorage("holdSpeedMultiplier") private var holdSpeedMultiplier: Double = 2.0
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("episodeReminders") private var episodeReminders = false
    @AppStorage("airingNotifications") private var airingNotifications = false
    @AppStorage("dualSync") private var dualSync = false
    @AppStorage("rateOnFinish") private var rateOnFinish = true
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue
    @State private var showClearLocalLibrary = false
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showResetCWConfirmation = false
    @State private var showResetHistoryConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = 0
    @State private var websiteDataSize = 0
    @State private var tempFilesSize = 0
    @State private var continueWatchingSize = 0
    @State private var watchHistorySize = 0
    @State private var searchAliasSize = 0
    @State private var idMappingSize = 0
    @State private var episodeSortSize = 0
    @State private var totalUsage = 0
    @State private var isClearing = false
    #endif

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                // Appearance
                Section("Appearance") {
                    NavigationLink {
                        AppearanceSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "paintbrush.fill", title: "Appearance", subtitle: "Theme, accent color, motion")
                    }
                }

                // Playback
                Section("Playback") {
                    NavigationLink {
                        PlaybackSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "play.circle.fill", title: "Playback", subtitle: "Player, quality, skip, speed")
                    }
                    NavigationLink {
                        SubtitleSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "captions.bubble.fill", title: "Subtitles", subtitle: "Style, color, presets, live preview")
                    }
                }

                // Library & Tracking
                Section("Library & Tracking") {
                    NavigationLink {
                        LibrarySettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "books.vertical.fill", title: "Library", subtitle: "Tracking, sync, scores")
                    }
                    NavigationLink {
                        TrackersSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "antenna.radiowaves.left.and.right", title: "Trackers", subtitle: "AniList, MAL, sync settings")
                    }
                }

                // Sources & Modules
                Section("Sources & Modules") {
                    NavigationLink {
                        SourcesSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "person.crop.circle.badge.checkmark", title: "Sources", subtitle: "AniList, MyAnimeList, accounts")
                    }
                    NavigationLink {
                        ModulesSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "puzzlepiece.extension.fill", title: "Modules", subtitle: "Streaming sources, store")
                    }
                }

                // Schedule & Notifications
                Section("Schedule & Notifications") {
                    NavigationLink {
                        ScheduleSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "calendar", title: "Schedule", subtitle: "Airing schedules, timing")
                    }
                    NavigationLink {
                        NotificationsSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "bell.fill", title: "Notifications", subtitle: "Reminders, airing alerts")
                    }
                }

                // Data & Performance
                Section("Data & Performance") {
                    NavigationLink {
                        PerformanceModeSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "gauge.medium", title: "Performance Mode", subtitle: "Speed optimizations")
                    }
                    NavigationLink {
                        AdvancedSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "gearshape.2.fill", title: "Advanced", subtitle: "Cache, reset, storage")
                    }
                    NavigationLink {
                        BackupRestoreSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "externaldrive.badge.timemachine", title: "Backup & Restore", subtitle: "Export/import preferences")
                    }
                    NavigationLink {
                        LoggerSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "terminal", title: "Logger", subtitle: "App logs, debug info")
                    }
                }

                // About
                Section("About") {
                    NavigationLink {
                        AboutSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "info.circle.fill", title: "About", subtitle: "Version, licenses")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Reset Continue Watching?", isPresented: $showResetCWConfirmation) {
                Button("Reset", role: .destructive) {
                    CacheManager.shared.clearContinueWatching()
                    #if os(iOS)
                    updateCacheSizes()
                    #endif
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all in-progress playback cards from the Home screen.")
            }
            .alert("Reset Watch History?", isPresented: $showResetHistoryConfirmation) {
                Button("Reset", role: .destructive) {
                    CacheManager.shared.clearWatchHistory()
                    #if os(iOS)
                    updateCacheSizes()
                    #endif
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all 'Watched' checkmarks from episode lists.")
            }
            .onAppear {
                #if os(iOS)
                PlayerPresenter.shared.resetToAppOrientation()
                updateCacheSizes()
                #endif
            }
        }
    }

    @ViewBuilder
    private var fullSettingsList: some View {
                // Appearance — theme + accent color
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .tint(.appAccent)

                    Picker("Accent Color", selection: $accentColorHex) {
                        Text("Default").tag("")
                        Text("Red").tag("#FF453A")
                        Text("Orange").tag("#FF9F0A")
                        Text("Yellow").tag("#FFD60A")
                        Text("Green").tag("#30D158")
                        Text("Mint").tag("#63E6E2")
                        Text("Blue").tag("#0A84FF")
                        Text("Indigo").tag("#5E5CE6")
                        Text("Purple").tag("#BF5AF2")
                        Text("Pink").tag("#FF375F")
                    }
                    .tint(Color.gray)

                    Toggle("Reduce Motion", isOn: $reduceMotion)
                        .tint(Color.gray)
                }

                Section("Modules") {
                    NavigationLink {
                        ModuleListView()
                    } label: {
                        HStack(spacing: 12) {
                            // Icon
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
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName ?? "AniList")
                                    .font(.headline)
                                Text("Manage your modules")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Use Default Extension", isOn: $useDefaultExtension)
                        .tint(Color.gray)
                        .disabled(moduleManager.activeModule == nil)
                    Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
                        .tint(Color.gray)
                    Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream)
                        .tint(Color.gray)
                }

                ProvidersSettingsSection()

                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                        .tint(Color.gray)
                        #if os(iOS)
                        .onChangeOf(forceLandscape) {
                            PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                        }
                        #endif
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Toggle("Liquid Glass Controls", isOn: $playerLiquidGlass)
                            .tint(Color.gray)
                        Text("Frosted glass buttons in the video player. Turn off for solid controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    Toggle("Auto Next Episode", isOn: $autoNextEpisode)
                        .tint(Color.gray)
                    Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                        .tint(Color.gray)
                    Text("Automatically skip intros, recaps, credits, and previews")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Preferred Video Quality", selection: $preferredVideoQuality) {
                        Text("Auto").tag("auto")
                        Text("360p").tag("360p")
                        Text("480p").tag("480p")
                        Text("720p").tag("720p")
                        Text("1080p").tag("1080p")
                        Text("Highest Available").tag("highest")
                    }
                    .tint(Color.gray)
                    Toggle("Auto-Pause on Interruption", isOn: $autoPauseOnInterruption)
                        .tint(Color.gray)
                    Text("Pauses playback when Control Center or Notification Center is opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Hold-to-Speed", isOn: $holdSpeedEnabled)
                        .tint(Color.gray)
                    if holdSpeedEnabled {
                        VStack(alignment: .leading) {
                            Text("Movement Sensitivity")
                            Slider(value: $holdSpeedSensitivity, in: 0.1...1.0, step: 0.1)
                                .tint(.appAccent)
                        }
                        Picker("Speed Multiplier", selection: $holdSpeedMultiplier) {
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                            Text("2.5×").tag(2.5)
                            Text("3×").tag(3.0)
                        }
                        .tint(Color.gray)
                    }
                    Toggle("Reverse Episode List by Default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                        .tint(Color.gray)
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

                #if os(iOS)
                if #available(iOS 26.0, *) {
                    Section("Reader") {
                        Toggle("Liquid Glass Controls", isOn: $readerLiquidGlass)
                            .tint(Color.gray)
                        Text("Frosted glass buttons in the manga reader. Turn off for solid controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                if aniListAuth.isLoggedIn || malAuth.isLoggedIn {
                    Section("Tracking") {
                        if aniListAuth.isLoggedIn {
                            Toggle("Track on AniList", isOn: $aniListTrackingEnabled)
                                .tint(Color.gray)
                        }
                        if malAuth.isLoggedIn {
                            Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled)
                                .tint(Color.gray)
                        }
                        if aniListAuth.isLoggedIn && malAuth.isLoggedIn {
                            Toggle("Sync edits to both services", isOn: $dualSync)
                                .tint(Color.gray)
                        }
                        Toggle("Never reduce progress", isOn: $skipReWatchTracking)
                            .tint(Color.gray)
                        Toggle("Prompt to rate after finishing", isOn: $rateOnFinish)
                            .tint(Color.gray)
                        Text("Automatically update your watch progress as you watch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Library") {
                    NavigationLink {
                        LibrarySettingsView()
                    } label: {
                        Label("List Order & Custom Lists", systemImage: "list.bullet.indent")
                    }
                }

                Section {
                    Toggle("Auto-track what you watch", isOn: $localAutoTrackEnabled)
                        .tint(Color.gray)
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

                Section("Downloads") {
                    Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled)
                        .tint(Color.gray)
                }

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

                #if os(iOS)
                Section("Storage & Cache") {
                    Button(role: .destructive) {
                        guard !isClearing else { return }
                        isClearing = true
                        Task {
                            await CacheManager.shared.clearEverything()
                            imageCacheSize = 0
                            websiteDataSize = 0
                            tempFilesSize = 0
                            continueWatchingSize = 0
                            watchHistorySize = 0
                            searchAliasSize = 0
                            idMappingSize = 0
                            episodeSortSize = 0
                            totalUsage = 0
                            isClearing = false
                        }
                    } label: {
                        LabeledContent("Clear Everything") {
                            if isClearing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text(Self.formattedBytes(totalUsage))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.red)
                    .disabled(isClearing)

                    DisclosureGroup("Individual Resets") {
                        Button {
                            CacheManager.shared.clearImageCache()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Image Cache") {
                                Text(Self.formattedBytes(imageCacheSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            guard !isClearing else { return }
                            isClearing = true
                            Task {
                                await CacheManager.shared.clearWebsiteData()
                                totalUsage -= websiteDataSize
                                websiteDataSize = 0
                                isClearing = false
                            }
                        } label: {
                            LabeledContent("Reset Website Data") {
                                Text(Self.formattedBytes(websiteDataSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            CacheManager.shared.clearTempFiles()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Clear Temporary Files") {
                                Text(Self.formattedBytes(tempFilesSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            CacheManager.shared.clearSearchAliases()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Search Aliases") {
                                Text(Self.formattedBytes(searchAliasSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            CacheManager.shared.clearIDMappingCache()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset ID Mapping Cache") {
                                Text(Self.formattedBytes(idMappingSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            CacheManager.shared.clearEpisodeSortPreferences()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Episode Sort Preferences") {
                                Text(Self.formattedBytes(episodeSortSize))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            showResetCWConfirmation = true
                        } label: {
                            LabeledContent("Reset Continue Watching") {
                                Text(Self.formattedBytes(continueWatchingSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.red)

                        Button {
                            showResetHistoryConfirmation = true
                        } label: {
                            LabeledContent("Reset Watch History") {
                                Text(Self.formattedBytes(watchHistorySize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.red)
                    }
                    .font(.subheadline)
                    .disabled(isClearing)

                    Text("Website Data includes cookies and local storage from module scrapers. Watch Data includes continue watching and history. Search Aliases store remembered search results and stream picks per module.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    NavigationLink {
                        SettingsViewLogger()
                    } label: {
                        Label("App Logs", systemImage: "terminal")
                    }
                }
                #endif

                Section("Notifications") {
                    Toggle("Episode Reminders", isOn: $episodeReminders)
                        .tint(Color.gray)
                    Text("Get notified before a new episode airs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Airing Notifications", isOn: $airingNotifications)
                        .tint(Color.gray)
                    Text("Get notified when an anime you track starts airing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach([LegalPage.imprint, .privacy, .contributors, .licenses], id: \.title) { page in
                        NavigationLink {
                            LegalWebView(page: page)
                        } label: {
                            Text(page.title)
                        }
                    }

                    LabeledContent("Version") {
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                        Text("\(version) (\(build))")
                            .foregroundStyle(.secondary)
                    }
                }
        }

    @ViewBuilder
    private var filteredSettingsList: some View {
        Section("Search Results") {
            if searchText.isEmpty {
                Text("Start typing to search settings…")
                    .foregroundStyle(.secondary)
            } else {
                let matches = settingsSearchResults
                if matches.isEmpty {
                    Text("No settings found for \"\(searchText)\"")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches, id: \.self) { match in
                        Text(match)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    /// Simple text-matching search across setting labels. Returns labels that contain
    /// the search text (case-insensitive).
    private var settingsSearchResults: [String] {
        let q = searchText.lowercased()
        var results: [String] = []
        // Appearance
        if "theme".contains(q) || "appearance".contains(q) || "dark".contains(q) || "light".contains(q) { results.append("Theme (Appearance)") }
        if "accent".contains(q) || "color".contains(q) { results.append("Accent Color (Appearance)") }
        if "motion".contains(q) || "animation".contains(q) { results.append("Reduce Motion (Appearance)") }
        // Player
        if "landscape".contains(q) { results.append("Force Landscape Mode (Player)") }
        if "skip".contains(q) { results.append("Skip Duration (Player)") }
        if "quality".contains(q) || "resolution".contains(q) || "video".contains(q) { results.append("Preferred Video Quality (Player)") }
        if "pause".contains(q) || "interruption".contains(q) { results.append("Auto-Pause on Interruption (Player)") }
        if "hold".contains(q) || "speed".contains(q) { results.append("Hold-to-Speed (Player)") }
        if "auto next".contains(q) || "autoplay".contains(q) { results.append("Auto Next Episode (Player)") }
        if "segment".contains(q) || "intro".contains(q) || "outro".contains(q) { results.append("Auto-Skip Segments (Player)") }
        if "playback speed".contains(q) { results.append("Playback Speed (Player)") }
        // Streaming
                if "stream".contains(q) || "module".contains(q) { results.append("Auto-pick Last Stream (Streaming)") }
        // Library
        if "tracking".contains(q) || "anilist".contains(q) || "mal".contains(q) { results.append("Track on AniList/MAL (Library)") }
        if "score".contains(q) || "rating".contains(q) { results.append("Score Format (Library)") }
        // Downloads
        if "download".contains(q) || "concurrent".contains(q) { results.append("Concurrent Downloads (Downloads)") }
        if "background".contains(q) { results.append("Background Downloads (Downloads)") }
        // Notifications
        if "notification".contains(q) || "reminder".contains(q) || "airing".contains(q) { results.append("Episode Reminders / Airing Notifications") }
        return results
    }

    // MARK: - Settings actions and computed properties

    #if os(iOS)
    private func updateCacheSizes() {
        websiteDataSize = CacheManager.shared.websiteDataSize
        tempFilesSize = CacheManager.shared.tempFilesSize
        continueWatchingSize = CacheManager.shared.continueWatchingSize
        watchHistorySize = CacheManager.shared.watchHistorySize
        searchAliasSize = CacheManager.shared.searchAliasSize
        idMappingSize = CacheManager.shared.idMappingSize
        episodeSortSize = CacheManager.shared.episodeSortSize
        // Image cache + total are computed asynchronously (Kingfisher disk size).
        Task {
            imageCacheSize = await CacheManager.shared.imageCacheSize
            totalUsage = await CacheManager.shared.totalDiskUsage
        }
    }
    #endif

    private static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
}

// MARK: - Library Settings

struct LibrarySettingsView: View {
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
        .navigationTitle("Library")
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

// MARK: - Logger Views & Utilities

private func logTypeColor(_ type: String) -> Color {
    switch type {
    case "Error":       return .red
    case "Debug":       return .blue
    case "Stream":      return .green
    case "Download":    return .orange
    case "HTMLStrings": return .purple
    default:            return .secondary
    }
}

private func logTypeIcon(_ type: String) -> String {
    switch type {
    case "Error":       return "exclamationmark.triangle.fill"
    case "Debug":       return "ladybug.fill"
    case "Stream":      return "play.circle.fill"
    case "Download":    return "arrow.down.circle.fill"
    case "HTMLStrings": return "text.alignleft"
    default:            return "gear"
    }
}

struct LogEntryRow: View {
    let entry: Logger.LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: logTypeIcon(entry.type))
                    .font(.caption)
                    .foregroundStyle(logTypeColor(entry.type))
                Text(entry.type.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(logTypeColor(entry.type))
                Spacer()
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(logTypeColor(entry.type).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(logTypeColor(entry.type).opacity(0.18), lineWidth: 1)
        )
    }
}

struct SettingsViewLogger: View {
    @State private var entries: [Logger.LogEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @StateObject private var filterViewModel = LogFilterViewModel.shared

    private var filteredEntries: [Logger.LogEntry] {
        let base = searchText.isEmpty ? entries : entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText)
        }
        return base.reversed()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading logs…")
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "No Logs" : "No Results",
                    systemImage: entries.isEmpty ? "doc.text" : "magnifyingglass",
                    description: Text(entries.isEmpty ? "Nothing has been logged yet." : "No logs match your search.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search logs")
        .navigationTitle("Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadEntries() }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button {
                        let text = entries.map { "[\($0.type)] \($0.message)" }.joined(separator: "\n")
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #endif
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task {
                            await Logger.shared.clearLogsAsync()
                            await MainActor.run { entries = [] }
                        }
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                NavigationLink(destination: SettingsViewLoggerFilter(viewModel: filterViewModel)) {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    private func loadEntries() {
        Task {
            let loaded = await Logger.shared.getLogEntriesAsync()
            await MainActor.run {
                self.entries = loaded
                self.isLoading = false
            }
        }
    }
}

struct SettingsViewLoggerFilter: View {
    @ObservedObject var viewModel = LogFilterViewModel.shared

    var body: some View {
        List {
            Section(header: Text("Log Types"), footer: Text("Choose which log categories to record. Debug and HTMLStrings can be very verbose.")) {
                ForEach($viewModel.filters) { $filter in
                    Toggle(isOn: $filter.isEnabled) {
                        Label {
                            Text(filter.type)
                        } icon: {
                            Image(systemName: logTypeIcon(filter.type))
                                .foregroundStyle(logTypeColor(filter.type))
                        }
                    }
                    .tint(logTypeColor(filter.type))
                }
            }
        }
        .navigationTitle("Log Filters")
    }
}

struct LogFilter: Identifiable, Hashable {
    let id = UUID()
    let type: String
    var isEnabled: Bool
    let description: String
}

class LogFilterViewModel: ObservableObject {
    nonisolated(unsafe) static let shared = LogFilterViewModel()
    
    @Published var filters: [LogFilter] = [] {
        didSet {
            saveFiltersToUserDefaults()
        }
    }
    
    private let userDefaultsKey = "LogFilterStates"
    private let hardcodedFilters: [(type: String, description: String, defaultState: Bool)] = [
        ("General", "General events and activities.", true),
        ("Stream", "Streaming and video playback.", true),
        ("Error", "Errors and critical issues.", true),
        ("Debug", "Debugging and troubleshooting.", false),
        ("Network", "Network requests and responses.", false),
        ("Download", "HLS video downloading.", true),
        ("HTMLStrings", "Raw HTML response strings.", false)
    ]
    
    private init() {
        loadFilters()
    }
    
    func loadFilters() {
        if let savedStates = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Bool] {
            filters = hardcodedFilters.map {
                LogFilter(
                    type: $0.type,
                    isEnabled: savedStates[$0.type] ?? $0.defaultState,
                    description: $0.description
                )
            }
        } else {
            filters = hardcodedFilters.map {
                LogFilter(type: $0.type, isEnabled: $0.defaultState, description: $0.description)
            }
        }
    }
    
    func toggleFilter(for type: String) {
        if let index = filters.firstIndex(where: { $0.type == type }) {
            filters[index].isEnabled.toggle()
        }
    }
    
    func isFilterEnabled(for type: String) -> Bool {
        return filters.first(where: { $0.type == type })?.isEnabled ?? true
    }
    
    private func saveFiltersToUserDefaults() {
        let states = filters.reduce(into: [String: Bool]()) { result, filter in
            result[filter.type] = filter.isEnabled
        }
        UserDefaults.standard.set(states, forKey: userDefaultsKey)
    }
}

class Logger: @unchecked Sendable {
    static let shared = Logger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let message: String
        let type: String
        let timestamp: Date
    }
    
    private let queue = DispatchQueue(label: "com.shirox.logger", attributes: .concurrent)
    private var logs: [LogEntry] = []
    private let logFileURL: URL
    private let logFilterViewModel = LogFilterViewModel.shared

    private let maxFileSize = 1024 * 512
    private let maxLogEntries = 1000 
    
    private init() {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = documentDirectory.appendingPathComponent("logs.txt")
    }
    
    func log(_ message: String, type: String = "General") {
        guard logFilterViewModel.isFilterEnabled(for: type) else { return }
        
        let entry = LogEntry(message: message, type: type, timestamp: Date())
        
        queue.async(flags: .barrier) {
            self.logs.append(entry)
            
            if self.logs.count > self.maxLogEntries {
                self.logs.removeFirst(self.logs.count - self.maxLogEntries)
            }
            
            self.saveLogToFile(entry)
            self.debugLog(entry)
        }
    }
    
    func getLogs() -> String {
        var result = ""
        queue.sync {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            result = logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
            .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
        }
        return result
    }
    
    func getLogsAsync() async -> String {
        return await withCheckedContinuation { continuation in
            queue.async {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                let result = self.logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
                .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
                continuation.resume(returning: result)
            }
        }
    }

    func getLogEntriesAsync() async -> [LogEntry] {
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.logs)
            }
        }
    }

    /// Synchronous accessor used by the Logger settings page.
    /// Pass `nil` (or omit) to return every entry; pass a category name to
    /// filter by `LogEntry.type` (case-insensitive).
    func getEntries(category: String? = nil) -> [LogEntry] {
        var result: [LogEntry] = []
        queue.sync {
            if let category {
                let lowered = category.lowercased()
                result = logs.filter { $0.type.lowercased() == lowered }
            } else {
                result = logs
            }
        }
        return result
    }

    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logs.removeAll()
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }
    
    func clearLogsAsync() async {
        await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) {
                self.logs.removeAll()
                try? FileManager.default.removeItem(at: self.logFileURL)
                continuation.resume()
            }
        }
    }
    
    private func saveLogToFile(_ log: LogEntry) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        let separator = String(repeating: "─", count: 20)
        let logString = "[\(dateFormatter.string(from: log.timestamp))] [\(log.type.uppercased())]\n\(log.message)\n\(separator)\n"
        
        guard let data = logString.data(using: .utf8) else {
            return
        }
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
                let fileSize = attributes[.size] as? UInt64 ?? 0
                
                if fileSize + UInt64(data.count) > maxFileSize {
                    self.truncateLogFile()
                }
                
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            try? data.write(to: logFileURL)
        }
    }
    
    private func truncateLogFile() {
        do {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8),
                  !content.isEmpty else {
                return
            }
            
            let separator = String(repeating: "─", count: 20)
            let entries = content.components(separatedBy: "\n\(separator)\n")
            guard entries.count > 10 else { return }
            
            let keepCount = entries.count / 2
            let truncatedEntries = Array(entries.suffix(keepCount))
            let truncatedContent = truncatedEntries.joined(separator: "\n\(separator)\n")
            
            if let truncatedData = truncatedContent.data(using: .utf8) {
                try truncatedData.write(to: logFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }
    
    private func debugLog(_ entry: LogEntry) {
#if DEBUG
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let formattedMessage = "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.type)] \(entry.message)"
        print(formattedMessage)
#endif
    }
}

// MARK: - Providers Settings Section

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
                        #if os(iOS)
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

    #if os(iOS)
    @ViewBuilder
    private func providerAuthButton(for type: ProviderType) -> some View {
        let isLoggedIn = type == .anilist ? aniListAuth.isLoggedIn : malAuth.isLoggedIn
        Button(isLoggedIn ? "Sign Out" : "Sign In") {
            if isLoggedIn {
                if type == .anilist { aniListAuth.logout() } else { malAuth.logout() }
            } else {
                if let window = presentationWindow {
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
        case .anilist: return AniListAuthManager.shared.isLoggedIn ? "Signed in" : "Not signed in"
        case .mal: return malAuth.isLoggedIn ? "Signed in" : "Not signed in"
        case .local: return "Not signed in"
        }
    }
}

// MARK: - Settings Category Row

struct SettingsCategoryRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Appearance Settings Page

struct AppearanceSettingsPage: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("glowEnabled") private var glowEnabled = true
    @AppStorage("glowIntensity") private var glowIntensity: Double = 0.5

    private struct AccentSwatch: Identifiable {
        let id: String
        let hex: String
        let title: String
    }

    private let accentSwatches: [AccentSwatch] = [
        .init(id: "default", hex: "",        title: "Default"),
        .init(id: "red",     hex: "#FF453A", title: "Red"),
        .init(id: "orange",  hex: "#FF9F0A", title: "Orange"),
        .init(id: "yellow",  hex: "#FFD60A", title: "Yellow"),
        .init(id: "green",   hex: "#30D158", title: "Green"),
        .init(id: "mint",    hex: "#63E6E2", title: "Mint"),
        .init(id: "blue",    hex: "#0A84FF", title: "Blue"),
        .init(id: "indigo",  hex: "#5E5CE6", title: "Indigo"),
        .init(id: "purple",  hex: "#BF5AF2", title: "Purple"),
        .init(id: "pink",    hex: "#FF375F", title: "Pink")
    ]

    private let swatchColumns = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .tint(.appAccent)
            }
            Section {
                LazyVGrid(columns: swatchColumns, spacing: 14) {
                    ForEach(accentSwatches) { swatch in
                        accentSwatchButton(swatch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Tap a circle to set the app's accent. Default follows the system label color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Motion") {
                Toggle("Reduce Motion", isOn: $reduceMotion)
                    .tint(Color.gray)
            }
            Section {
                Toggle("Enable Glow", isOn: $glowEnabled)
                    .tint(Color.gray)
                if glowEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Intensity")
                            Spacer()
                            Text(String(format: "%.1f", glowIntensity))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $glowIntensity, in: 0.0...1.0, step: 0.1)
                            .tint(Color.gray)
                    }
                }
            } header: {
                Text("Glow")
            } footer: {
                Text("Glow adds a soft halo around connected source icons on the Sources page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Default", role: .destructive) {
                    appearanceMode = "system"
                    accentColorHex = ""
                    reduceMotion = false
                    glowEnabled = true
                    glowIntensity = 0.5
                }
                .tint(.appAccent)
            }
        }
        .navigationTitle("Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func accentSwatchButton(_ swatch: AccentSwatch) -> some View {
        let isSelected = accentColorHex == swatch.hex
        Button {
            accentColorHex = swatch.hex
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.appAccent : Color.clear, lineWidth: 2.5)
                        .frame(width: 50, height: 50)
                    Circle()
                        .fill(swatchColor(swatch))
                        .frame(width: 40, height: 40)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 50, height: 50)

                Text(swatch.title)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchColor(_ swatch: AccentSwatch) -> Color {
        if swatch.hex.isEmpty {
            return Color.primary.opacity(0.85)
        }
        if let ui = UIColor(hex: swatch.hex) {
            return Color(ui)
        }
        return Color.secondary.opacity(0.4)
    }
}

// MARK: - Playback Settings Page (Hub)

struct PlaybackSettingsPage: View {
    var body: some View {
        Form {
            Section("Player") {
                NavigationLink {
                    PlayerGeneralSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "gearshape.fill", title: "General", subtitle: "Speed, controls, layout")
                }
                NavigationLink {
                    QualitySettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "sparkles.tv.fill", title: "Quality", subtitle: "Resolution, data saving")
                }
            }
            Section("Playback") {
                NavigationLink {
                    GesturesSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "hand.tap.fill", title: "Gestures", subtitle: "Touch, skip durations")
                }
                NavigationLink {
                    SkipSegmentsSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "forward.end.fill", title: "Skip Segments", subtitle: "AniSkip, IntroDB, auto-skip")
                }
                NavigationLink {
                    NextEpisodeSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "arrow.right.circle.fill", title: "Next Episode", subtitle: "Auto-play, appearance")
                }
                NavigationLink {
                    HoldSpeedSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "speedometer", title: "Hold-Speed", subtitle: "Sensitivity, multiplier")
                }
            }
            Section("Audio") {
                NavigationLink {
                    AudioSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "speaker.wave.2.fill", title: "Audio", subtitle: "Surround, comfort, frame rate")
                }
            }
            Section("Display") {
                NavigationLink {
                    PiPSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "pip.fill", title: "Picture-in-Picture", subtitle: "PiP, auto-pause")
                }
                NavigationLink {
                    StreamingSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "dot.radiowaves.left.and.right", title: "Streaming", subtitle: "Auto-pick, progress")
                }
            }
        }
        .navigationTitle("Playback")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Playback Card Helpers

private struct PlaybackSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}

private struct SettingsChip<T: Hashable>: View {
    let title: String
    let value: T
    @Binding var selection: T

    var body: some View {
        Button {
            selection = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selection == value ? Color.appAccent.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .foregroundStyle(selection == value ? Color.appAccent : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private func doubleLabel(_ value: Double) -> String {
    if value == value.rounded() {
        return "\(Int(value))x"
    }
    return "\(value)x"
}

// MARK: - 1. Player General Settings Page

struct PlayerGeneralSettingsPage: View {
    @AppStorage("playerPlaybackSpeed") private var playerPlaybackSpeed: Double = 1.0
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("showLockButton") private var showLockButton = true
    @AppStorage("showServicesButton") private var showServicesButton = true
    @AppStorage("preferDownloaded") private var preferDownloaded = false
    @AppStorage("showRemainingTime") private var showRemainingTime = false

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let speedColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Playback") {
                    Text("Default Playback Speed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: speedColumns, spacing: 8) {
                        ForEach(speedOptions, id: \.self) { speed in
                            SettingsChip(
                                title: doubleLabel(speed),
                                value: speed,
                                selection: $playerPlaybackSpeed
                            )
                        }
                    }
                }
                PlaybackSettingsCard(title: "Player Controls") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                        .tint(Color.gray)
                    Toggle("Show Lock Button", isOn: $showLockButton)
                        .tint(Color.gray)
                    Toggle("Show Services Button", isOn: $showServicesButton)
                        .tint(Color.gray)
                    Toggle("Prefer Downloaded", isOn: $preferDownloaded)
                        .tint(Color.gray)
                    Toggle("Show Remaining Time", isOn: $showRemainingTime)
                        .tint(Color.gray)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("General")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 2. Quality Settings Page

struct QualitySettingsPage: View {
    @AppStorage("preferredVideoQuality") private var preferredVideoQuality = "auto"
    @AppStorage("dataSavingEnabled") private var dataSavingEnabled = false

    private struct QualityOption: Identifiable, Hashable {
        let value: String
        let label: String
        let icon: String
        var id: String { value }
    }

    private let qualityOptions: [QualityOption] = [
        QualityOption(value: "auto", label: "Auto", icon: "gearshape"),
        QualityOption(value: "360p", label: "360p", icon: "speedometer"),
        QualityOption(value: "480p", label: "480p", icon: "speedometer"),
        QualityOption(value: "720p", label: "720p", icon: "speedometer"),
        QualityOption(value: "1080p", label: "1080p", icon: "speedometer"),
        QualityOption(value: "highest", label: "Highest", icon: "trophy.fill")
    ]
    private let qualityColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if dataSavingEnabled {
                    HStack(spacing: 12) {
                        Image(systemName: "leaf.fill")
                            .font(.title3)
                            .foregroundStyle(Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Data Saving is On")
                                .font(.subheadline.weight(.semibold))
                            Text("Streamed quality is capped at 480p to reduce mobile data usage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }
                PlaybackSettingsCard(title: "Streaming Quality") {
                    Text("Preferred Video Quality")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: qualityColumns, spacing: 10) {
                        ForEach(qualityOptions) { option in
                            Button {
                                preferredVideoQuality = option.value
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: option.icon)
                                        .font(.title3)
                                    Text(option.label)
                                        .font(.body.weight(.semibold))
                                    Spacer()
                                    if preferredVideoQuality == option.value {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.appAccent)
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity)
                                .background(
                                    (preferredVideoQuality == option.value ? Color.appAccent.opacity(0.16) : Color.secondary.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .foregroundStyle(preferredVideoQuality == option.value ? Color.appAccent : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    Toggle("Data Saving", isOn: $dataSavingEnabled)
                        .tint(Color.gray)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Quality")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 3. Gestures Settings Page

struct GesturesSettingsPage: View {
    @AppStorage("playerBrightnessGesture") private var brightnessGesture = true
    @AppStorage("playerVolumeGesture") private var volumeGesture = true
    @AppStorage("playerTwoFingerGesture") private var twoFingerGesture = true
    @AppStorage("playerCenterTapGesture") private var centerTapGesture = true
    @AppStorage("playerDoubleTapGesture") private var doubleTapGesture = true
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Touch Gestures") {
                    Toggle("Brightness Gesture", isOn: $brightnessGesture)
                        .tint(Color.gray)
                    Toggle("Volume Gesture", isOn: $volumeGesture)
                        .tint(Color.gray)
                    Toggle("Two-Finger Seek", isOn: $twoFingerGesture)
                        .tint(Color.gray)
                    Toggle("Center-Tap to Toggle UI", isOn: $centerTapGesture)
                        .tint(Color.gray)
                    Toggle("Double-Tap to Seek", isOn: $doubleTapGesture)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Skip Durations") {
                    Picker("Skip Duration", selection: $skipShort) {
                        ForEach(shortOptions, id: \.self) { Text("\($0)s").tag($0) }
                    }
                    .tint(Color.gray)
                    Picker("Long Skip Duration", selection: $skipLong) {
                        ForEach(longOptions, id: \.self) { Text("\($0)s").tag($0) }
                    }
                    .tint(Color.gray)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Gestures")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 4. Skip Segments Settings Page

struct SkipSegmentsSettingsPage: View {
    @AppStorage("useAniSkip") private var useAniSkip = true
    @AppStorage("useTheIntroDB") private var useTheIntroDB = false
    @AppStorage("useIntroDB") private var useIntroDB = false
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("alwaysShowSkipSegments") private var alwaysShowSkipSegments = false
    @AppStorage("fallback85s") private var fallback85s = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Sources") {
                    Toggle("AniSkip", isOn: $useAniSkip)
                        .tint(Color.gray)
                    Toggle("TheIntroDB", isOn: $useTheIntroDB)
                        .tint(Color.gray)
                    Toggle("IntroDB", isOn: $useIntroDB)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Auto-Skip") {
                    Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                        .tint(Color.gray)
                    Toggle("Always Show Skip Button", isOn: $alwaysShowSkipSegments)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Skip 85s") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text("When AniSkip has no data for an episode, fall back to skipping the first 85 seconds as the intro.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("85s Fallback", isOn: $fallback85s)
                        .tint(Color.gray)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Skip Segments")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 5. Next Episode Settings Page

struct NextEpisodeSettingsPage: View {
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("showNextEpisodeButton") private var showNextEpisodeButton = true
    @AppStorage("showNextEpisodeBrowserButton") private var showNextEpisodeBrowserButton = false
    @AppStorage("usePosterForNextEpisode") private var usePosterForNextEpisode = true
    @AppStorage("skipFillerEpisodes") private var skipFillerEpisodes = false
    @AppStorage("nextEpisodeAppearanceThreshold") private var appearanceThreshold: Double = 90.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Auto-Play") {
                    Toggle("Auto Next Episode", isOn: $autoNextEpisode)
                        .tint(Color.gray)
                    Toggle("Show Next Episode Button", isOn: $showNextEpisodeButton)
                        .tint(Color.gray)
                    Toggle("Show Episode Browser Button", isOn: $showNextEpisodeBrowserButton)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Options") {
                    Toggle("Use Poster Art", isOn: $usePosterForNextEpisode)
                        .tint(Color.gray)
                    Toggle("Skip Filler Episodes", isOn: $skipFillerEpisodes)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Threshold") {
                    HStack {
                        Text("Appearance Threshold")
                        Spacer()
                        Text("\(Int(appearanceThreshold))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appearanceThreshold, in: 50...100, step: 5)
                        .tint(Color.gray)
                    Text("The next-episode card appears once playback reaches this percentage of the current episode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Next Episode")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 6. Hold Speed Settings Page

struct HoldSpeedSettingsPage: View {
    @AppStorage("holdSpeedEnabled") private var holdSpeedEnabled = true
    @AppStorage("holdSpeedSensitivity") private var holdSpeedSensitivity: Double = 0.5
    @AppStorage("holdSpeedMultiplier") private var holdSpeedMultiplier: Double = 2.0

    private let multipliers: [Double] = [1.5, 2.0, 2.5, 3.0]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Hold-to-Speed") {
                    Toggle("Enable", isOn: $holdSpeedEnabled)
                        .tint(Color.gray)
                    if holdSpeedEnabled {
                        Divider()
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text("\(Int(holdSpeedSensitivity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $holdSpeedSensitivity, in: 0.1...1.0, step: 0.1)
                            .tint(Color.gray)
                        Picker("Speed Multiplier", selection: $holdSpeedMultiplier) {
                            ForEach(multipliers, id: \.self) { mult in
                                Text(doubleLabel(mult)).tag(mult)
                            }
                        }
                        .tint(Color.gray)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Hold-Speed")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 7. Audio Settings Page

struct AudioSettingsPage: View {
    @AppStorage("surroundSound") private var surroundSound = false
    @AppStorage("comfortAudio") private var comfortAudio = "off"
    @AppStorage("inlineFrameRate") private var inlineFrameRate: Int = 60

    private let frameRateOptions: [Int] = [24, 30, 60, 120]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Surround Sound") {
                    Toggle("Surround Sound", isOn: $surroundSound)
                        .tint(Color.gray)
                    Text("Outputs multi-channel audio when supported by the stream and device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PlaybackSettingsCard(title: "Comfort Audio") {
                    Picker("Comfort Audio", selection: $comfortAudio) {
                        Text("Off").tag("off")
                        Text("Medium").tag("medium")
                        Text("Strong").tag("strong")
                    }
                    .tint(Color.gray)
                    Text("Compresses the dynamic range so quiet sounds are louder and loud sounds are quieter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PlaybackSettingsCard(title: "Frame Rate") {
                    Picker("Inline Frame Rate", selection: $inlineFrameRate) {
                        ForEach(frameRateOptions, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    .tint(Color.gray)
                    Text("Target frame rate for inline (in-feed) playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Audio")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 8. Picture-in-Picture Settings Page

struct PiPSettingsPage: View {
    @AppStorage("pipWhenLeavingApp") private var pipWhenLeavingApp = true
    @AppStorage("autoPauseOnInterruption") private var autoPauseOnInterruption = true
    @AppStorage("autoPauseOnControlCenter") private var autoPauseOnControlCenter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Picture-in-Picture") {
                    Toggle("PiP When Leaving App", isOn: $pipWhenLeavingApp)
                        .tint(Color.gray)
                    Text("Automatically enter Picture-in-Picture when leaving Shirox during playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PlaybackSettingsCard(title: "Auto-Pause") {
                    Toggle("Auto-Pause on Interruption", isOn: $autoPauseOnInterruption)
                        .tint(Color.gray)
                    Toggle("Auto-Pause on Control Center", isOn: $autoPauseOnControlCenter)
                        .tint(Color.gray)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Picture-in-Picture")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 9. Streaming Settings Page

struct StreamingSettingsPage: View {
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false
    @AppStorage("watchedPercentage") private var watchedPercentage: Double = 90.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlaybackSettingsCard(title: "Auto-Pick") {
                    Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream)
                        .tint(Color.gray)
                    Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
                        .tint(Color.gray)
                }
                PlaybackSettingsCard(title: "Progress Tracking") {
                    HStack {
                        Text("Progress Threshold")
                        Spacer()
                        Text("\(Int(watchedPercentage))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $watchedPercentage, in: 50...100, step: 5)
                        .tint(Color.gray)
                    Text("Episodes are marked as watched once playback passes this percentage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Streaming")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library Settings Page

struct LibrarySettingsPage: View {
    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("dualSync") private var dualSync = false
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("rateOnFinish") private var rateOnFinish = true
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                trackingCard
                localLibraryCard
                titleLanguageCard
            }
            .padding()
        }
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Card Header

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - Tracking Card

    private var trackingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Tracking", systemImage: "arrow.triangle.2.circlepath")
            VStack(spacing: 0) {
                toggleRow("Track on AniList", isOn: $aniListTrackingEnabled)
                rowDivider
                toggleRow("Track on MyAnimeList", isOn: $malTrackingEnabled)
                rowDivider
                toggleRow("Sync edits to both services", isOn: $dualSync)
                rowDivider
                toggleRow("Never reduce progress", isOn: $skipReWatchTracking)
                rowDivider
                toggleRow("Prompt to rate after finishing", isOn: $rateOnFinish)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Local Library Card

    private var localLibraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Local Library", systemImage: "internaldrive")
            toggleRow("Auto-track what you watch", isOn: $localAutoTrackEnabled)
            Text("Adds titles you start watching to your local library automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Title Language Card

    private var titleLanguageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Title Language Priority", systemImage: "text.alignleft")

            HStack(spacing: 6) {
                ForEach(Array(orderedLanguages.enumerated()), id: \.offset) { idx, lang in
                    HStack(spacing: 6) {
                        Text("\(idx + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.appAccent, in: Circle())
                        Text(lang.capitalized)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1), in: Capsule())

                    if idx < orderedLanguages.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Higher-priority titles are shown first across the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Divider().opacity(0.4).padding(.leading, 0)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(Color.gray)
            .padding(.vertical, 6)
    }
}

// MARK: - Downloads Settings Page

struct DownloadsSettingsPage: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled = true

    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3); Text("4").tag(4); Text("5").tag(5)
                }.tint(Color.gray)
                Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled).tint(Color.gray)
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Notifications Settings Page

struct NotificationsSettingsPage: View {
    @AppStorage("episodeReminders") private var episodeReminders = false
    @AppStorage("airingNotifications") private var airingNotifications = false
    @AppStorage("episodeNotificationLeadTime") private var leadTimeRaw =
        EpisodeNotificationManager.LeadTime.atAirtime.rawValue

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingCount: Int = 0
    @State private var isRefreshing = false

    private var leadTime: EpisodeNotificationManager.LeadTime {
        EpisodeNotificationManager.LeadTime(rawValue: leadTimeRaw) ?? .atAirtime
    }

    private var anyEnabled: Bool { episodeReminders || airingNotifications }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                togglesCard
                timingCard
                manageCard
            }
            .padding()
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refreshStatus() }
    }

    // MARK: - Status

    private var authStateText: String {
        switch authStatus {
        case .authorized:    return "Authorized"
        case .denied:        return "Denied — enable in Settings"
        case .notDetermined: return "Not requested yet"
        case .provisional:   return "Provisional"
        case .ephemeral:     return "Ephemeral"
        @unknown default:    return "Unknown"
        }
    }

    private var authStateColor: Color {
        switch authStatus {
        case .authorized, .provisional: return .green
        case .denied:                   return .red
        default:                        return .secondary
        }
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "bell.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.appAccent)
            }

            VStack(spacing: 4) {
                Text("Notification Status")
                    .font(.headline)
                Text(authStateText)
                    .font(.subheadline)
                    .foregroundStyle(authStateColor)
            }

            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text("\(pendingCount)")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Color.appAccent)
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 2) {
                    Text(anyEnabled ? "On" : "Off")
                        .font(.title2.bold())
                        .foregroundStyle(anyEnabled ? .green : .secondary)
                    Text("Enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Toggles

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Types", systemImage: "checkmark.circle.fill")
            Toggle("Episode Reminders", isOn: $episodeReminders)
                .tint(Color.gray)
            Toggle("Airing Notifications", isOn: $airingNotifications)
                .tint(Color.gray)
            Text("Reminders fire before an episode airs. Requires an AniList account and a connected schedule.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Timing

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Timing", systemImage: "clock.fill")
            Picker("Lead Time", selection: $leadTimeRaw) {
                ForEach(EpisodeNotificationManager.LeadTime.allCases, id: \.rawValue) { lt in
                    Text(lt.displayName).tag(lt.rawValue)
                }
            }
            .tint(.appAccent)

            Picker("Preview", selection: .constant(0)) {
                Text(leadTime.displayName).tag(0)
            }
            .tint(.appAccent)
            .disabled(true)

            Text("How far before airtime the notification fires.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Manage

    private var manageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Manage", systemImage: "slider.horizontal.3")

            Button {
                Task { await refreshStatus() }
            } label: {
                HStack {
                    if isRefreshing {
                        ProgressView().tint(.appAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh Status")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.appAccent)
            .disabled(isRefreshing)

            Button(role: .destructive) {
                Task {
                    await EpisodeNotificationManager.shared.removeAll()
                    await refreshStatus()
                }
            } label: {
                Label("Remove All Pending", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(pendingCount == 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private func refreshStatus() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authStatus = settings.authorizationStatus
        pendingCount = await EpisodeNotificationManager.shared.pendingCount()
    }
}

// MARK: - Search Settings Page

struct SearchSettingsPage: View {
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @EnvironmentObject private var moduleManager: ModuleManager

    var body: some View {
        Form {
            Section("Search") {
                Toggle("Use Default Extension Only", isOn: $useDefaultExtension)
                    .tint(Color.gray)
                    .disabled(moduleManager.activeModule == nil)
            }
            Section {
                Text("Live search is always enabled. Results appear as you type with a 500ms delay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Filters are available via the filter button in the Search toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Sources Settings Page (metadata/account providers)

struct SourcesSettingsPage: View {
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        Form {
            Section {
                Text("Sources are metadata and account providers for tracking, library sync, and progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Section {
                sourceRow(
                    provider: .anilist,
                    isLoggedIn: anilistAuth.isLoggedIn,
                    primaryName: "AniList",
                    subText: anilistAuth.isLoggedIn
                        ? (anilistAuth.username.map { "Connected as \($0)" } ?? "Connected")
                        : "Not connected"
                ) {
                    #if os(iOS)
                    if anilistAuth.isLoggedIn {
                        anilistAuth.logout()
                    } else if let window = presentationWindow {
                        anilistAuth.login(presentationAnchor: window)
                    }
                    #endif
                }
                sourceRow(
                    provider: .mal,
                    isLoggedIn: malAuth.isLoggedIn,
                    primaryName: "MyAnimeList",
                    subText: malAuth.isLoggedIn
                        ? (malAuth.username.map { "Connected as \($0)" } ?? "Connected")
                        : "Not connected"
                ) {
                    #if os(iOS)
                    if malAuth.isLoggedIn {
                        malAuth.logout()
                    } else if let window = presentationWindow {
                        malAuth.login(presentationAnchor: window)
                    }
                    #endif
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Connect an account to sync your library, progress, and ratings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Default Provider") {
                HStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.appAccent)
                    Text("Active")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(providerManager.primary?.displayName ?? "AniList")
                        .font(.body.weight(.semibold))
                }
            }
        }
        .navigationTitle("Sources")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    // MARK: - Source Row (reusable)

    @ViewBuilder
    private func sourceRow(
        provider: ProviderType,
        isLoggedIn: Bool,
        primaryName: String,
        subText: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconView(provider: provider, isLoggedIn: isLoggedIn)

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLoggedIn ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(subText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            Button(isLoggedIn ? "Disconnect" : "Connect", action: action)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(isLoggedIn ? .red : .appAccent)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Icon View (with glow border)

    @ViewBuilder
    private func iconView(provider: ProviderType, isLoggedIn: Bool) -> some View {
        let glowColor: Color = isLoggedIn ? .green : .red
        // When `Color.glowEnabled` is off the glow is fully suppressed (opacity
        // 0 + radius 0). When on, the intensity (0.0–1.0) drives BOTH the
        // shadow radius (`6 * intensity`) and its opacity (`intensity * 0.6`)
        // so the slider visibly grows and brightens the halo around the icon.
        let glowOpacity: Double = Color.glowEnabled ? Color.glowIntensity * 0.6 : 0
        let glowRadius: CGFloat = Color.glowEnabled ? CGFloat(6 * Color.glowIntensity) : 0

        CachedAsyncImage(urlString: provider.iconURL)
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(glowColor.opacity(Color.glowEnabled ? 0.85 : 0.25), lineWidth: 1.5)
            )
            .shadow(color: glowColor.opacity(glowOpacity),
                    radius: glowRadius, x: 0, y: 0)
    }
}

// MARK: - Modules Settings Page (content/streaming sources)

struct ModulesSettingsPage: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showAddModule = false
    @State private var showModuleStore = false
    @State private var moduleURL = ""
    @State private var isAddingModule = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        Form {
            Section("Installed Modules") {
                if moduleManager.modules.isEmpty {
                    Text("No modules installed. Add one below or browse the store.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(moduleManager.modules) { module in
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: module.iconUrl ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFill() }
                                else { Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary) }
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(module.sourceName).font(.body.weight(.medium))
                                if let lang = module.language {
                                    Text(lang.uppercased()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if moduleManager.activeModule?.id == module.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { moduleManager.selectModule(module) }
                    }
                    .onDelete { indices in
                        for i in indices { moduleManager.removeModule(moduleManager.modules[i]) }
                    }
                }
            }
            Section("Add Module") {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("Module JSON URL", text: $moduleURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .focused($isTextFieldFocused)
                        .disabled(isAddingModule)
                    #if os(iOS)
                    if !isAddingModule {
                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty { moduleURL = trimmed }
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard").font(.body).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !moduleURL.isEmpty && !isAddingModule {
                        Button { moduleURL = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                    Button {
                        addModuleInline()
                    } label: {
                        if isAddingModule {
                            ProgressView().scaleEffect(0.8).frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(moduleURL.isEmpty ? Color.secondary : Color.appAccent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(moduleURL.isEmpty || isAddingModule)
                }
            }
            Section {
                Button {
                    showModuleStore = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.1))
                                .frame(width: 36, height: 36)
                            Image(systemName: "bag.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.appAccent)
                        }
                        Text("Browse Modules")
                            .font(.body.weight(.medium))
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("About Modules")
                        .font(.caption.weight(.semibold))
                    Text("Modules are content sources for streaming and downloading anime. Providers (AniList, MAL) handle metadata and tracking.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Modules")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
        .background {
            NavigationLink(destination: ModuleStorePage().environmentObject(moduleManager), isActive: $showModuleStore) {
                EmptyView()
            }
            .opacity(0)
        }
    }

    private func addModuleInline() {
        guard let url = URL(string: moduleURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        isAddingModule = true
        Task {
            do {
                try await moduleManager.addModule(from: url)
                await MainActor.run {
                    moduleURL = ""
                    isAddingModule = false
                    isTextFieldFocused = false
                }
            } catch {
                await MainActor.run { isAddingModule = false }
            }
        }
    }
}

// MARK: - Module Store Page

struct ModuleStorePage: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var storeModules: [StoreModuleItem] = []
    @State private var isLoading = false
    @State private var storeError: String?
    @State private var searchText = ""
    @State private var moduleURL = ""
    @State private var isInstalling = false

    private let storeURL = "https://modulesbypaul.dev"
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Capsule-shaped search pill at the top
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Search modules…", text: $searchText)
                        .font(.subheadline)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .padding(.horizontal, 14)
                .padding(.top, 12)

                if isLoading {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in
                            StoreModuleSkeletonTile()
                        }
                    }
                    .padding(.horizontal, 14)
                } else if let error = storeError {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await loadStore() } }
                            .buttonStyle(.bordered)
                            .tint(.appAccent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .padding(.horizontal, 14)
                } else if storeModules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No modules available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if filteredModules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text("No matches for \"\(searchText)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredModules) { mod in
                            StoreModuleTile(mod: mod, isInstalled: isModuleInstalled(mod), isInstalling: isInstalling) {
                                installModule(mod)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color.secondary.opacity(0.04))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Module Store")
        .task { await loadStore() }
        .refreshable { await loadStore() }
    }

    private var filteredModules: [StoreModuleItem] {
        if searchText.isEmpty { return storeModules }
        return storeModules.filter { $0.name.lowercased().contains(searchText.lowercased()) }
    }

    private func isModuleInstalled(_ mod: StoreModuleItem) -> Bool {
        moduleManager.modules.contains { $0.sourceName == mod.name }
    }

    private func installModule(_ mod: StoreModuleItem) {
        guard let url = URL(string: mod.manifestUrl) else { return }
        isInstalling = true
        Task {
            do {
                try await moduleManager.addModule(from: url)
                await MainActor.run { isInstalling = false }
            } catch {
                await MainActor.run { isInstalling = false }
            }
        }
    }

    /// Fetches the modulesbypaul.dev HTML page and extracts module data from the
    /// embedded JSON. The page contains escaped JSON with jsonUrl, sourceName,
    /// and iconUrl fields for each module.
    private func loadStore() async {
        isLoading = true; storeError = nil
        do {
            let url = URL(string: storeURL)!
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            storeModules = parseModulesFromHTML(html)
            if storeModules.isEmpty {
                storeError = "No modules found. The repository may have changed."
            }
        } catch {
            storeError = "Could not load store. Check your connection and try again."
        }
        isLoading = false
    }

    /// Parses module data from the HTML page by extracting jsonUrl, sourceName,
    /// and iconUrl from the embedded escaped JSON.
    private func parseModulesFromHTML(_ html: String) -> [StoreModuleItem] {
        // The HTML contains literal backslash-quoted JSON:
        // \"jsonUrl\":\"https://...\",\"sourceName\":\"AnimePahe\",\"iconUrl\":\"https://...\"
        // We extract these triplets using simple string scanning.

        var results: [StoreModuleItem] = []
        var seen = Set<String>()

        // Find all occurrences of \"jsonUrl\":\" and extract the URL
        let searchKey = "\\\"jsonUrl\\\":\\\""
        var searchRange = html.startIndex..<html.endIndex

        while let jsonUrlRange = html.range(of: searchKey, options: .literal, range: searchRange) {
            // URL starts right after the search key
            let urlStart = jsonUrlRange.upperBound
            // URL ends at the next \"
            guard let urlEnd = html.range(of: "\\\"", options: .literal, range: urlStart..<html.endIndex) else { break }
            let jsonUrl = String(html[urlStart..<urlEnd.lowerBound])

            // Find sourceName after this jsonUrl
            let nameKey = "\\\"sourceName\\\":\\\""
            let nameSearchRange = urlEnd.upperBound..<html.endIndex
            guard let nameKeyRange = html.range(of: nameKey, options: .literal, range: nameSearchRange) else {
                searchRange = urlEnd.upperBound..<html.endIndex
                continue
            }
            let nameStart = nameKeyRange.upperBound
            guard let nameEnd = html.range(of: "\\\"", options: .literal, range: nameStart..<html.endIndex) else {
                searchRange = nameStart..<html.endIndex
                continue
            }
            let name = String(html[nameStart..<nameEnd.lowerBound])

            // Find iconUrl after sourceName
            let iconKey = "\\\"iconUrl\\\":\\\""
            let iconSearchRange = nameEnd.upperBound..<html.endIndex
            var iconUrl: String? = nil
            if let iconKeyRange = html.range(of: iconKey, options: .literal, range: iconSearchRange) {
                let iconStart = iconKeyRange.upperBound
                if let iconEnd = html.range(of: "\\\"", options: .literal, range: iconStart..<html.endIndex) {
                    iconUrl = String(html[iconStart..<iconEnd.lowerBound])
                }
            }

            // Deduplicate by URL
            if !seen.contains(jsonUrl) {
                seen.insert(jsonUrl)
                results.append(StoreModuleItem(
                    id: jsonUrl,
                    name: name,
                    description: nil,
                    version: nil,
                    manifestUrl: jsonUrl,
                    iconUrl: iconUrl?.isEmpty == true ? nil : iconUrl,
                    author: "modulesbypaul.dev"
                ))
            }

            // Continue searching after this match
            searchRange = nameEnd.upperBound..<html.endIndex
        }

        return results.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

struct StoreModuleWrapper: Codable { let modules: [StoreModuleItem] }

struct StoreModuleItem: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let version: String?
    let manifestUrl: String
    let iconUrl: String?
    let author: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version
        case manifestUrl = "manifest_url"
        case iconUrl = "icon_url"
        case author
    }

    init(id: String, name: String, description: String?, version: String?, manifestUrl: String, iconUrl: String?, author: String?) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.manifestUrl = manifestUrl
        self.iconUrl = iconUrl
        self.author = author
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        manifestUrl = try c.decodeIfPresent(String.self, forKey: .manifestUrl) ?? ""
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl)
        author = try c.decodeIfPresent(String.self, forKey: .author)
    }
}

private struct StoreModuleTile: View {
    let mod: StoreModuleItem
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Icon at top, centered, 56x56
            Group {
                if let iconUrl = mod.iconUrl, let url = URL(string: iconUrl) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFill() }
                        else { fallbackIcon }
                    }
                } else { fallbackIcon }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 2)

            // Name below, bold, 2-line limit, centered
            Text(mod.name)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)

            // Author caption
            if let author = mod.author, !author.isEmpty {
                Text(author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Install button at bottom
            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else if isInstalling {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                Button(action: onInstall) {
                    Text("Install")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.appAccent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .top)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    private var fallbackIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 56)
    }
}

private struct StoreModuleSkeletonTile: View {
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .padding(.top, 2)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 70, height: 10)
            Spacer(minLength: 4)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 26)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .top)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .redacted(reason: .placeholder)
    }
}

// MARK: - Advanced Settings Page

struct AdvancedSettingsPage: View {
    @State private var showResetCW = false
    @State private var showResetHistory = false
    @State private var showClearImage = false
    @State private var showClearAll = false

    @State private var imageCacheSize: Int = 0
    @State private var websiteDataSize: Int = 0
    @State private var tempFilesSize: Int = 0
    @State private var searchAliasSize: Int = 0
    @State private var idMappingSize: Int = 0
    @State private var episodeSortSize: Int = 0
    @State private var libraryCacheSize: Int = 0
    @State private var profileCacheSize: Int = 0
    @State private var cwSize: Int = 0
    @State private var historySize: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cacheManagementCard
                watchDataCard
                clearAllCard
            }
            .padding()
        }
        .navigationTitle("Advanced")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await updateSizes() }
        .alert("Clear Image Cache?", isPresented: $showClearImage) {
            Button("Clear", role: .destructive) {
                CacheManager.shared.clearImageCache()
                Task { await updateSizes() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reset Continue Watching?", isPresented: $showResetCW) {
            Button("Reset", role: .destructive) {
                CacheManager.shared.clearContinueWatching()
                Task { await updateSizes() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reset Watch History?", isPresented: $showResetHistory) {
            Button("Reset", role: .destructive) {
                CacheManager.shared.clearWatchHistory()
                Task { await updateSizes() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Clear All Cache?", isPresented: $showClearAll) {
            Button("Clear All", role: .destructive) {
                Task {
                    await CacheManager.shared.clearEverything()
                    await updateSizes()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all cache, continue watching, watch history, and search aliases. This cannot be undone.")
        }
    }

    // MARK: - Cache Management Card

    private var cacheManagementCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Cache Management", systemImage: "internaldrive")
            VStack(spacing: 0) {
                cacheRow(label: "Image Cache", size: imageCacheSize) {
                    showClearImage = true
                }
                rowDivider
                cacheRow(label: "Website Data", size: websiteDataSize) {
                    Task { await CacheManager.shared.clearWebsiteData(); await updateSizes() }
                }
                rowDivider
                cacheRow(label: "Temp Files", size: tempFilesSize) {
                    CacheManager.shared.clearTempFiles()
                    Task { await updateSizes() }
                }
                rowDivider
                cacheRow(label: "Search Aliases", size: searchAliasSize) {
                    CacheManager.shared.clearSearchAliases()
                    Task { await updateSizes() }
                }
                rowDivider
                cacheRow(label: "ID Mapping Cache", size: idMappingSize) {
                    CacheManager.shared.clearIDMappingCache()
                    Task { await updateSizes() }
                }
                rowDivider
                cacheRow(label: "Episode Sort Prefs", size: episodeSortSize) {
                    CacheManager.shared.clearEpisodeSortPreferences()
                    Task { await updateSizes() }
                }
                rowDivider
                cacheRow(label: "Library Cache", size: libraryCacheSize) {
                    CacheManager.shared.clearLibraryCache()
                    Task { await updateSizes() }
                }
                rowDivider
                cacheRow(label: "Profile Cache", size: profileCacheSize) {
                    CacheManager.shared.clearProfileCache()
                    Task { await updateSizes() }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Watch Data Card

    private var watchDataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Watch Data", systemImage: "eye.fill")
            VStack(spacing: 0) {
                cacheRow(label: "Continue Watching", size: cwSize) { showResetCW = true }
                rowDivider
                cacheRow(label: "Watch History", size: historySize) { showResetHistory = true }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Clear All Card

    private var clearAllCard: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                showClearAll = true
            } label: {
                Label("Clear All Cache", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            Text("Removes every cache above plus continue watching and watch history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private var rowDivider: some View {
        Divider().opacity(0.4)
    }

    private func cacheRow(label: String, size: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatSize(size))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 KB" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    @MainActor
    private func updateSizes() async {
        let cache = CacheManager.shared
        imageCacheSize   = await cache.imageCacheSize
        websiteDataSize  = cache.websiteDataSize
        tempFilesSize    = cache.tempFilesSize
        cwSize           = cache.continueWatchingSize
        historySize      = cache.watchHistorySize
        searchAliasSize  = cache.searchAliasSize
        idMappingSize    = cache.idMappingSize
        episodeSortSize  = cache.episodeSortSize
        libraryCacheSize = cache.libraryCacheSize
        profileCacheSize = cache.profileCacheSize
    }
}

// MARK: - Subtitle Settings Page

struct SubtitleSettingsPage: View {
    @AppStorage("subtitleTextColor") private var subtitleTextColor: String = "white"
    @AppStorage("subtitleStrokeColor") private var subtitleStrokeColor: String = "black"
    @AppStorage("subtitleStrokeWidth") private var subtitleStrokeWidth: Double = 1.0
    @AppStorage("subtitleBackgroundEnabled") private var subtitleBackgroundEnabled: Bool = false
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 30
    @AppStorage("subtitleBoldText") private var subtitleBoldText: Bool = false
    @State private var previewImageURL: String?

    private let textColorOptions = ["white", "yellow", "black", "cyan", "pink", "green"]
    private let strokeColorOptions = ["none", "black", "white", "gray"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                quickPresetsCard
                livePreviewCard
                appearanceControlsCard
            }
            .padding()
        }
        .navigationTitle("Subtitles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            Task {
                let trending = try? await AniListService.shared.browse(category: .trending, page: 1)
                if let random = trending?.randomElement() {
                    previewImageURL = random.bannerImage ?? random.coverImage.extraLarge ?? random.coverImage.large
                }
            }
        }
    }

    // MARK: - Quick Presets Card

    private var quickPresetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Presets", systemImage: "wand.and.stars")
                .font(.headline)

            Text("Tap a preset to apply a full subtitle style instantly.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                presetButton(title: "Minimal") {
                    subtitleTextColor = "white"
                    subtitleStrokeColor = "none"
                    subtitleStrokeWidth = 0
                    subtitleBackgroundEnabled = false
                    subtitleFontSize = 24
                    subtitleBoldText = false
                }
                presetButton(title: "Bold") {
                    subtitleTextColor = "yellow"
                    subtitleStrokeColor = "black"
                    subtitleStrokeWidth = 1.5
                    subtitleBackgroundEnabled = true
                    subtitleFontSize = 34
                    subtitleBoldText = true
                }
                presetButton(title: "Classic") {
                    subtitleTextColor = "white"
                    subtitleStrokeColor = "black"
                    subtitleStrokeWidth = 1.0
                    subtitleBackgroundEnabled = false
                    subtitleFontSize = 30
                    subtitleBoldText = false
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func presetButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(.appAccent)
    }

    // MARK: - Live Preview Card

    private var livePreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Preview", systemImage: "eye")
                    .font(.headline)
                Spacer()
                if previewImageURL == nil {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            ZStack(alignment: .bottom) {
                Group {
                    if let url = previewImageURL {
                        CachedAsyncImage(urlString: url)
                            .frame(height: 180)
                            .clipped()
                        Color.black.opacity(0.4)
                            .frame(height: 180)
                    } else {
                        LinearGradient(colors: [Color.black, Color.gray.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 180)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                subtitlePreviewText
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitlePreviewText: some View {
        let resolvedStrokeWidth: Double = (subtitleStrokeColor == "none") ? 0 : subtitleStrokeWidth
        return Text("The journey of a thousand miles begins with a single step.")
            .font(.system(size: CGFloat(subtitleFontSize),
                          weight: subtitleBoldText ? .bold : .regular))
            .foregroundStyle(color(fromName: subtitleTextColor))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if subtitleBackgroundEnabled {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    } else {
                        Color.clear
                    }
                }
            )
            .applySubtitleStroke(color: color(fromName: subtitleStrokeColor),
                                 width: resolvedStrokeWidth)
    }

    // MARK: - Appearance Controls Card

    private var appearanceControlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Appearance", systemImage: "textformat")
                .font(.headline)

            Picker("Text Color", selection: $subtitleTextColor) {
                ForEach(textColorOptions, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .tint(.appAccent)

            Picker("Stroke Color", selection: $subtitleStrokeColor) {
                ForEach(strokeColorOptions, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .tint(.appAccent)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stroke Width")
                    Spacer()
                    Text(String(format: "%.1f", subtitleStrokeWidth))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleStrokeWidth, in: 0...4, step: 0.5)
                    .tint(.appAccent)
                    .disabled(subtitleStrokeColor == "none")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(subtitleFontSize))pt")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleFontSize, in: 12...48, step: 1)
                    .tint(.appAccent)
            }

            Toggle("Background", isOn: $subtitleBackgroundEnabled)
                .tint(.appAccent)
            Toggle("Bold Text", isOn: $subtitleBoldText)
                .tint(.appAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Color Helpers

    private func color(fromName name: String) -> Color {
        switch name.lowercased() {
        case "white":  return .white
        case "black":  return .black
        case "yellow": return .yellow
        case "cyan":   return .cyan
        case "pink":   return .pink
        case "green":  return .green
        case "gray":   return .gray
        case "none":   return .clear
        default:       return .white
        }
    }
}

private extension View {
    @ViewBuilder
    func applySubtitleStroke(color: Color, width: Double) -> some View {
        if width <= 0 || color == .clear {
            self
        } else {
            let w = CGFloat(width)
            self
                .shadow(color: color, radius: 0, x: -w, y:  0)
                .shadow(color: color, radius: 0, x:  w, y:  0)
                .shadow(color: color, radius: 0, x:  0, y: -w)
                .shadow(color: color, radius: 0, x:  0, y:  w)
                .shadow(color: color, radius: 0, x: -w, y: -w)
                .shadow(color: color, radius: 0, x:  w, y: -w)
                .shadow(color: color, radius: 0, x: -w, y:  w)
                .shadow(color: color, radius: 0, x:  w, y:  w)
        }
    }
}

// MARK: - About Settings Page

struct AboutSettingsPage: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                legalCard
            }
            .padding()
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.7), Color.appAccent.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.appAccent.opacity(0.3), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text("Shirox")
                    .font(.system(size: 28, weight: .bold))
                Text("Version \(version) (\(build))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label("Anime", systemImage: "sparkles")
                Label("Manga", systemImage: "book.fill")
                Label("Tracking", systemImage: "checkmark.seal.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Legal Card

    private var legalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.appAccent)
                Text("Legal")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)

            legalLink("Imprint", icon: "person.text.rectangle") { LegalWebView(page: .imprint) }
            Divider().opacity(0.4)
            legalLink("Data Privacy", icon: "hand.raised.fill") { LegalWebView(page: .privacy) }
            Divider().opacity(0.4)
            legalLink("Contributors", icon: "person.3.fill") { LegalWebView(page: .contributors) }
            Divider().opacity(0.4)
            legalLink("Licenses", icon: "scroll.fill") { LegalWebView(page: .licenses) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func legalLink<Destination: View>(
        _ title: String,
        icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(Color.appAccent)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trackers Settings Page

struct TrackersSettingsPage: View {
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @AppStorage("trackersEnableSync") private var enableSync = true
    @AppStorage("trackersAutoSyncRatings") private var autoSyncRatings = false
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                connectionCard(
                    providerType: .anilist,
                    isConnected: anilistAuth.isLoggedIn,
                    onToggle: {
                        #if os(iOS)
                        if anilistAuth.isLoggedIn {
                            anilistAuth.logout()
                        } else if let window = presentationWindow {
                            anilistAuth.login(presentationAnchor: window)
                        }
                        #endif
                    }
                )

                connectionCard(
                    providerType: .mal,
                    isConnected: malAuth.isLoggedIn,
                    onToggle: {
                        #if os(iOS)
                        if malAuth.isLoggedIn {
                            malAuth.logout()
                        } else if let window = presentationWindow {
                            malAuth.login(presentationAnchor: window)
                        }
                        #endif
                    }
                )

                // Sync toggles card
                VStack(alignment: .leading, spacing: 14) {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Toggle("Enable Sync", isOn: $enableSync)
                        .tint(Color.gray)
                    Toggle("Auto Sync Ratings", isOn: $autoSyncRatings)
                        .tint(Color.gray)
                    Text("When enabled, ratings are pushed automatically to your connected tracker after you finish an episode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Trackers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    private func connectionCard(
        providerType: ProviderType,
        isConnected: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            CachedAsyncImage(urlString: providerType.iconURL)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(providerType.displayName)
                        .font(.headline)
                }
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            #if os(iOS)
            Button(isConnected ? "Sign Out" : "Sign In", action: onToggle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isConnected ? Color.red : Color.appAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    (isConnected ? Color.red : Color.appAccent).opacity(0.12),
                    in: Capsule()
                )
                .buttonStyle(.plain)
            #else
            Text(isConnected ? "Signed In" : "Signed Out")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isConnected ? .green : .secondary)
            #endif
        }
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Performance Mode Settings Page

struct PerformanceModeSettingsPage: View {
    @AppStorage("performanceModeEnabled") private var performanceModeEnabled = false
    @AppStorage("skipAniListTraversal") private var skipAniListTraversal = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero card
                VStack(spacing: 16) {
                    Image(systemName: "gauge.medium")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.appAccent)

                    Text("Performance Mode")
                        .font(.title2.bold())

                    Toggle("Performance Mode", isOn: $performanceModeEnabled)
                        .tint(Color.gray)
                        .scaleEffect(1.2)
                        .frame(maxWidth: 220)

                    Text(performanceModeEnabled
                         ? "Enabled — app runs in fast mode"
                         : "Disabled — default behavior")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Skip AniList Traversal card
                VStack(alignment: .leading, spacing: 14) {
                    Label("Advanced", systemImage: "bolt.fill")
                        .font(.headline)
                    Toggle("Skip AniList Traversal", isOn: $skipAniListTraversal)
                        .tint(Color.gray)
                    Text("When enabled, the app skips redundant AniList media lookups when module data is sufficient. This can significantly speed up library and search load times.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Performance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Backup & Restore Settings Page

struct BackupRestoreSettingsPage: View {
    @State private var showShareSheet = false
    @State private var backupFileURL: URL?
    @State private var showImporter = false
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero card
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.appAccent)
                    Text("Backup & Restore")
                        .font(.title2.bold())
                    Text("Export your app preferences to a JSON file, or restore from a previous backup. Only String, Int, Double, and Bool values are included.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Export card
                VStack(alignment: .leading, spacing: 14) {
                    Label("Export", systemImage: "arrow.up.doc")
                        .font(.headline)
                    Text("Creates a JSON backup of all serializable preferences (String/Int/Double/Bool) from UserDefaults and opens the system share sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        exportBackup()
                    } label: {
                        Label("Export Backup", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.appAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Import card
                VStack(alignment: .leading, spacing: 14) {
                    Label("Import", systemImage: "arrow.down.doc")
                        .font(.headline)
                    Text("Restore preferences from a previously-exported JSON backup. Existing values for matching keys will be overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Backup", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.appAccent)
                    if let msg = statusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Backup & Restore")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = backupFileURL {
                ShareSheet(items: [url])
            }
        }
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                importBackup(from: url)
            case .failure:
                statusMessage = "Could not import backup file."
            }
        }
    }

    private func exportBackup() {
        let defaults = UserDefaults.standard
        var serializable: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            // Filter to serializable types only — Bool must be checked before
            // Int/Double because NSNumber booleans also bridge to those types.
            if let v = value as? Bool {
                serializable[key] = v
            } else if let v = value as? Int {
                serializable[key] = v
            } else if let v = value as? Double {
                serializable[key] = v
            } else if let v = value as? String {
                serializable[key] = v
            } else {
                continue
            }
        }

        guard JSONSerialization.isValidJSONObject(serializable) else {
            statusMessage = "Cannot serialize preferences."
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: serializable, options: [.prettyPrinted, .sortedKeys])
            let timestamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShiroxBackup-\(timestamp).json")
            try data.write(to: url)
            backupFileURL = url
            statusMessage = "Backup created — tap share to save it."
            #if os(iOS)
            showShareSheet = true
            #endif
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importBackup(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statusMessage = "Invalid backup file."
                return
            }
            let defaults = UserDefaults.standard
            var restored = 0
            for (key, value) in dict {
                // Same Bool-first ordering as export.
                if let v = value as? Bool {
                    defaults.set(v, forKey: key); restored += 1
                } else if let v = value as? Int {
                    defaults.set(v, forKey: key); restored += 1
                } else if let v = value as? Double {
                    defaults.set(v, forKey: key); restored += 1
                } else if let v = value as? String {
                    defaults.set(v, forKey: key); restored += 1
                }
            }
            statusMessage = "Restored \(restored) preference\(restored == 1 ? "" : "s")."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Logger Settings Page

struct LoggerSettingsPage: View {
    enum Category: String, CaseIterable, Identifiable {
        case all = "All"
        case error = "Error"
        case warning = "Warning"
        case debug = "Debug"
        case info = "Info"
        case stream = "Stream"
        var id: String { rawValue }
    }

    @State private var entries: [Logger.LogEntry] = []
    @State private var selectedCategory: Category = .all

    private var filteredEntries: [Logger.LogEntry] {
        let base: [Logger.LogEntry]
        if selectedCategory == .all {
            base = entries
        } else {
            base = entries.filter { $0.type.lowercased() == selectedCategory.rawValue.lowercased() }
        }
        return base.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Category.allCases) { cat in
                        Button {
                            selectedCategory = cat
                            reload()
                        } label: {
                            Text(cat.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    selectedCategory == cat
                                        ? Color.appAccent.opacity(0.15)
                                        : Color.secondary.opacity(0.1),
                                    in: Capsule()
                                )
                                .foregroundStyle(selectedCategory == cat ? Color.appAccent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "doc.text",
                    description: Text("No log entries match this filter.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Logger")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { reload() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    clear()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    private func logRow(_ entry: Logger.LogEntry) -> some View {
        let color = logTypeColor(entry.type)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.type.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color, in: Capsule())
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        )
    }

    private func reload() {
        entries = Logger.shared.getEntries(category: selectedCategory == .all ? nil : selectedCategory.rawValue)
    }

    private func clear() {
        Logger.shared.clearLogs()
        entries = []
    }
}

// MARK: - Share Sheet (UIActivityViewController wrapper)

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
