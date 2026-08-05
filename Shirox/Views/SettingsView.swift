import SwiftUI
import Combine

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
    @AppStorage("autoPickSubDub") private var autoPickSubDub = "off"
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
                // Category-based navigation — each opens a dedicated page
                Section {
                    NavigationLink {
                        AppearanceSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "paintbrush.fill", title: "Appearance", subtitle: "Theme, accent color, motion")
                    }
                    NavigationLink {
                        PlaybackSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "play.circle.fill", title: "Playback", subtitle: "Player, quality, skip, speed")
                    }
                    NavigationLink {
                        LibrarySettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "books.vertical.fill", title: "Library", subtitle: "Tracking, sync, scores")
                    }
                    NavigationLink {
                        DownloadsSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "arrow.down.circle.fill", title: "Downloads", subtitle: "Concurrent, background")
                    }
                    NavigationLink {
                        NotificationsSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "bell.fill", title: "Notifications", subtitle: "Reminders, airing alerts")
                    }
                    NavigationLink {
                        SearchSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "magnifyingglass", title: "Search", subtitle: "Filters, history, live search")
                    }
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
                    NavigationLink {
                        AdvancedSettingsPage()
                    } label: {
                        SettingsCategoryRow(icon: "gearshape.2.fill", title: "Advanced", subtitle: "Cache, reset, storage")
                    }
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
                    .tint(.appAccent)

                    Toggle("Reduce Motion", isOn: $reduceMotion)
                        .tint(.appAccent)
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
                        .tint(.appAccent)
                        .disabled(moduleManager.activeModule == nil)
                    Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
                        .tint(.appAccent)
                    Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream)
                        .tint(.appAccent)
                    Picker("Auto-pick Sub/Dub", selection: $autoPickSubDub) {
                        Text("Off (ask each time)").tag("off")
                        Text("Sub").tag("sub")
                        Text("Dub").tag("dub")
                    }
                    .tint(.appAccent)
                }

                ProvidersSettingsSection()

                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                        .tint(.appAccent)
                        #if os(iOS)
                        .onChangeOf(forceLandscape) {
                            PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                        }
                        #endif
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Toggle("Liquid Glass Controls", isOn: $playerLiquidGlass)
                            .tint(.appAccent)
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
                        .tint(.appAccent)
                    Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                        .tint(.appAccent)
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
                    .tint(.appAccent)
                    Toggle("Auto-Pause on Interruption", isOn: $autoPauseOnInterruption)
                        .tint(.appAccent)
                    Text("Pauses playback when Control Center or Notification Center is opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Hold-to-Speed", isOn: $holdSpeedEnabled)
                        .tint(.appAccent)
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
                        .tint(.appAccent)
                    }
                    Toggle("Reverse Episode List by Default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                        .tint(.appAccent)
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
                            .tint(.appAccent)
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
                                .tint(.appAccent)
                        }
                        if malAuth.isLoggedIn {
                            Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled)
                                .tint(.appAccent)
                        }
                        if aniListAuth.isLoggedIn && malAuth.isLoggedIn {
                            Toggle("Sync edits to both services", isOn: $dualSync)
                                .tint(.appAccent)
                        }
                        Toggle("Never reduce progress", isOn: $skipReWatchTracking)
                            .tint(.appAccent)
                        Toggle("Prompt to rate after finishing", isOn: $rateOnFinish)
                            .tint(.appAccent)
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
                        .tint(.appAccent)
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
                        .tint(.appAccent)
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
                        .foregroundStyle(.primary)

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
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearTempFiles()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Clear Temporary Files") {
                                Text(Self.formattedBytes(tempFilesSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearSearchAliases()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Search Aliases") {
                                Text(Self.formattedBytes(searchAliasSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearIDMappingCache()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset ID Mapping Cache") {
                                Text(Self.formattedBytes(idMappingSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearEpisodeSortPreferences()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Episode Sort Preferences") {
                                Text(Self.formattedBytes(episodeSortSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

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
                        .tint(.appAccent)
                    Text("Get notified before a new episode airs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Airing Notifications", isOn: $airingNotifications)
                        .tint(.appAccent)
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
        if "sub".contains(q) || "dub".contains(q) { results.append("Auto-pick Sub/Dub (Streaming)") }
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
                .foregroundStyle(.primary)
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.appAccent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Appearance Settings Page

struct AppearanceSettingsPage: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage("reduceMotion") private var reduceMotion = false

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
            Section("Accent Color") {
                Picker("Color", selection: $accentColorHex) {
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
                .tint(.appAccent)
            }
            Section("Motion") {
                Toggle("Reduce Motion", isOn: $reduceMotion)
                    .tint(.appAccent)
            }
            Section {
                Button("Reset to Default", role: .destructive) {
                    appearanceMode = "system"
                    accentColorHex = ""
                    reduceMotion = false
                }
                .tint(.appAccent)
            }
        }
        .navigationTitle("Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Playback Settings Page

struct PlaybackSettingsPage: View {
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("preferredVideoQuality") private var preferredVideoQuality = "auto"
    @AppStorage("autoPauseOnInterruption") private var autoPauseOnInterruption = true
    @AppStorage("holdSpeedEnabled") private var holdSpeedEnabled = true
    @AppStorage("holdSpeedSensitivity") private var holdSpeedSensitivity: Double = 0.5
    @AppStorage("holdSpeedMultiplier") private var holdSpeedMultiplier: Double = 2.0
    @AppStorage("playerPlaybackSpeed") private var playerPlaybackSpeed: Double = 1.0
    @AppStorage("watchedPercentage") private var watchedPercentage: Double = 90.0
    @AppStorage("autoPickSubDub") private var autoPickSubDub = "off"
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        Form {
            Section("Player") {
                Toggle("Force Landscape Mode", isOn: $forceLandscape).tint(.appAccent)
                Picker("Skip Duration", selection: $skipShort) {
                    ForEach(shortOptions, id: \.self) { Text("\($0)s").tag($0) }
                }.tint(.appAccent)
                Picker("Long Skip Duration", selection: $skipLong) {
                    ForEach(longOptions, id: \.self) { Text("\($0)s").tag($0) }
                }.tint(.appAccent)
                Picker("Playback Speed", selection: $playerPlaybackSpeed) {
                    Text("0.5x").tag(0.5); Text("0.75x").tag(0.75); Text("1x").tag(1.0)
                    Text("1.25x").tag(1.25); Text("1.5x").tag(1.5); Text("1.75x").tag(1.75); Text("2x").tag(2.0)
                }.tint(.appAccent)
            }
            Section("Quality") {
                Picker("Preferred Video Quality", selection: $preferredVideoQuality) {
                    Text("Auto").tag("auto"); Text("360p").tag("360p"); Text("480p").tag("480p")
                    Text("720p").tag("720p"); Text("1080p").tag("1080p"); Text("Highest").tag("highest")
                }.tint(.appAccent)
            }
            Section("Auto-play & Skip") {
                Toggle("Auto Next Episode", isOn: $autoNextEpisode).tint(.appAccent)
                Toggle("Auto-Skip Segments", isOn: $autoSkipSegments).tint(.appAccent)
                Toggle("Auto-Pause on Interruption", isOn: $autoPauseOnInterruption).tint(.appAccent)
            }
            Section("Hold-to-Speed") {
                Toggle("Enable", isOn: $holdSpeedEnabled).tint(.appAccent)
                if holdSpeedEnabled {
                    Slider(value: $holdSpeedSensitivity, in: 0.1...1.0, step: 0.1).tint(.appAccent)
                    Picker("Speed Multiplier", selection: $holdSpeedMultiplier) {
                        Text("1.5x").tag(1.5); Text("2x").tag(2.0); Text("2.5x").tag(2.5); Text("3x").tag(3.0)
                    }.tint(.appAccent)
                }
            }
            Section("Streaming") {
                Picker("Auto-pick Sub/Dub", selection: $autoPickSubDub) {
                    Text("Off").tag("off"); Text("Sub").tag("sub"); Text("Dub").tag("dub")
                }.tint(.appAccent)
                Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream).tint(.appAccent)
                Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult).tint(.appAccent)
            }
            Section("Progress") {
                VStack(alignment: .leading) {
                    Text("Episode Progress Threshold: \(Int(watchedPercentage))%")
                    Slider(value: $watchedPercentage, in: 50...100, step: 5).tint(.appAccent)
                }
            }
        }
        .navigationTitle("Playback")
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

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Track on AniList", isOn: $aniListTrackingEnabled).tint(.appAccent)
                Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled).tint(.appAccent)
                Toggle("Sync edits to both services", isOn: $dualSync).tint(.appAccent)
                Toggle("Never reduce progress", isOn: $skipReWatchTracking).tint(.appAccent)
                Toggle("Prompt to rate after finishing", isOn: $rateOnFinish).tint(.appAccent)
            }
            Section("Local Library") {
                Toggle("Auto-track what you watch", isOn: $localAutoTrackEnabled).tint(.appAccent)
            }
            Section("Title Language Priority") {
                Text("Current: \(titlePriority)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                }.tint(.appAccent)
                Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled).tint(.appAccent)
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

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Episode Reminders", isOn: $episodeReminders).tint(.appAccent)
                Toggle("Airing Notifications", isOn: $airingNotifications).tint(.appAccent)
            }
            Section {
                Text("Notifications require an AniList account and will appear as local notifications on your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Search Settings Page

struct SearchSettingsPage: View {
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false

    var body: some View {
        Form {
            Section("Search") {
                Toggle("Use Default Extension Only", isOn: $useDefaultExtension).tint(.appAccent)
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

    var body: some View {
        Form {
            Section {
                Text("Sources are metadata and account providers for tracking, library sync, and progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AniList") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(anilistAuth.isLoggedIn ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text("AniList").font(.subheadline.weight(.medium))
                        Text(anilistAuth.isLoggedIn ? "Connected" : "Not connected")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if anilistAuth.isLoggedIn {
                    Button("Disconnect", role: .destructive) { anilistAuth.logout() }
                }
            }
            Section("MyAnimeList") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(malAuth.isLoggedIn ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text("MyAnimeList").font(.subheadline.weight(.medium))
                        Text(malAuth.isLoggedIn ? "Connected" : "Not connected")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if malAuth.isLoggedIn {
                    Button("Disconnect", role: .destructive) { malAuth.logout() }
                }
            }
            Section("Default Provider") {
                Text("Active: \(providerManager.primary?.displayName ?? "AniList")")
                    .font(.subheadline)
            }
        }
        .navigationTitle("Sources")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Modules Settings Page (content/streaming sources)

struct ModulesSettingsPage: View {
    @EnvironmentObject private var moduleManager: ModuleManager

    var body: some View {
        Form {
            Section {
                Text("Modules are content sources for streaming and downloading anime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Installed") {
                if moduleManager.modules.isEmpty {
                    Text("No modules installed")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(moduleManager.modules) { module in
                        HStack(spacing: 10) {
                            AsyncImage(url: URL(string: module.iconUrl ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFill() }
                                else { Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary) }
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(module.sourceName).font(.subheadline.weight(.medium))
                                Text(module.id).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if moduleManager.activeModule?.id == module.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.appAccent)
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
            Section {
                NavigationLink("Manage Modules") { ModuleListView() }
            }
        }
        .navigationTitle("Modules")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Advanced Settings Page

struct AdvancedSettingsPage: View {
    @State private var showResetCW = false
    @State private var showResetHistory = false

    var body: some View {
        Form {
            Section("Cache") {
                Text("Image cache: 500 MB (auto-evicted after 7 days)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reset") {
                Button("Reset Continue Watching", role: .destructive) { showResetCW = true }
                Button("Reset Watch History", role: .destructive) { showResetHistory = true }
            }
        }
        .navigationTitle("Advanced")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Reset Continue Watching?", isPresented: $showResetCW) {
            Button("Reset", role: .destructive) { CacheManager.shared.clearContinueWatching() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reset Watch History?", isPresented: $showResetHistory) {
            Button("Reset", role: .destructive) { CacheManager.shared.clearWatchHistory() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - About Settings Page

struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
                    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
                    Text("\(v) (\(b))").foregroundStyle(.secondary)
                }
                LabeledContent("App Name") { Text("Shirox").foregroundStyle(.secondary) }
            }
            Section("Legal") {
                NavigationLink("Imprint") { LegalWebView(page: .imprint) }
                NavigationLink("Data Privacy") { LegalWebView(page: .privacy) }
                NavigationLink("Contributors") { LegalWebView(page: .contributors) }
                NavigationLink("Licenses") { LegalWebView(page: .licenses) }
            }
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
