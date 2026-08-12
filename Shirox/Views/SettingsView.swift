import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
import AVKit
#endif

// MARK: - Inline nav bar helper
//
// Consolidates the `#if os(iOS) .navigationBarTitleDisplayMode(.inline) #endif`
// pattern that was duplicated ~28× across the settings pages. The macOS / tvOS
// branch is a no-op so call sites stay single-line and platform-agnostic.
extension View {
    @ViewBuilder
    func inlineNavBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

struct SettingsView: View {
    // The top-level settings screen is a category menu — each row pushes a
    // dedicated settings page that owns its own `@AppStorage` bindings. The
    // per-category `@AppStorage` / cache-size state and the inline storage UI
    // that previously lived here were migrated to those sub-pages (Appearance,
    // Playback, Advanced, …), so this view now holds no state of its own.
    //
    // #125 — A search bar at the top lets the user type a feature name and
    // jump directly to the setting (even deep inside a sub-page). When the
    // search text is non-empty, the category list is replaced by a results
    // list; tapping a result pushes the containing page.

    @State private var searchText: String = ""
    @State private var searchResults: [SettingsSearchEntry] = []
    /// #125 — Drives a hidden NavigationLink for the iOS 15-compatible push
    /// (the app's NavigationStack shim doesn't reliably honor
    /// `navigationDestination(item:)`). Set when the user taps a search result.
    @State private var pushedPage: SettingsPage? = nil

    var body: some View {
        // Issue #5 — SettingsView no longer wraps in its own NavigationStack.
        // When pushed from HomeView's toolbar (the only entry point on iOS
        // since Settings is not a bottom tab), the parent NavigationStack
        // provides the navigation context. The previous nested NavigationStack
        // caused duplicate back arrows and a black bar at the top.
        Group {
            if searchText.isEmpty {
                categoryList
            } else {
                searchResultsList
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Settings")
        .inlineNavBar()
        .searchable(text: $searchText, prompt: "Search settings…")
        .onChangeOf(searchText) { query in
            searchResults = SettingsSearchIndex.search(query)
        }
        // #125 — Hidden NavigationLink that pushes the selected settings
        // page. The binding flips to non-nil when a search result is tapped,
        // and back to nil on pop. Works on iOS 15+ where
        // `navigationDestination(item:)` isn't available.
        .background(
            NavigationLink(
                destination: Group {
                    if let page = pushedPage {
                        settingsPageView(for: page)
                    }
                },
                isActive: Binding(
                    get: { pushedPage != nil },
                    set: { active in if !active { pushedPage = nil } }
                )
            ) { EmptyView() }
        )
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            #endif
        }
    }

    // MARK: - Category List (default, no search)
    //
    // Issue #11 — Settings items were too spread out because each category
    // was in its own Section (insetGrouped adds ~35pt between sections).
    // Now consolidated into two cohesive sections so related items sit
    // close together and the list feels tight and structured.

    private var categoryList: some View {
        List {
            // Section 1: Content & Playback (Appearance, Playback, Subtitles)
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
                    SubtitleSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "captions.bubble.fill", title: "Subtitles", subtitle: "Style, color, presets, live preview")
                }
            }

            // Section 2: Library & Tracking
            Section {
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

            // Section 3: Sources & Modules
            Section {
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

            // Section 4: Schedule & Notifications
            Section {
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

            // Section 5: Data, Performance & Advanced
            Section {
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

            // Section 6: About
            Section {
                NavigationLink {
                    AboutSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "info.circle.fill", title: "About", subtitle: "Version, licenses")
                }
            }
        }
    }

    // MARK: - Search Results List (#125)

    /// Replaces the category list when the user types in the search bar.
    /// Each row shows the setting's icon, label, and the page it lives on;
    /// tapping pushes the page (and the destination page can use the entry's
    /// `anchor` with a ScrollViewReader to scroll to the exact row).
    private var searchResultsList: some View {
        List {
            if searchResults.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No settings match \"\(searchText)\"")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Try a different name or check the category list above.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(searchResults) { entry in
                        Button {
                            pushedPage = entry.page
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.appAccent)
                                    .frame(width: 28, alignment: .center)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(entry.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
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
        .inlineNavBar()
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
    /// Issue #5 — Browse Categories layout toggle. OFF = carousels (default),
    /// ON = grid tiles.
    @AppStorage("browseCategoriesGridLayout") private var browseCategoriesGridLayout = false
    /// #122 — Whether to render the Statistics grid on detail pages.
    @AppStorage("showStatistics") private var showStatistics = true
    // #118 (revised) — `inlineSearchOnHome` AppStorage removed. Search is now
    // always triggered by the toolbar icon; there's no alternate mode to toggle.

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
            }
            // Issue #5 — Browse Categories layout toggle + statistics toggle.
            Section {
                Toggle("Browse Categories as Grid", isOn: $browseCategoriesGridLayout)
                Toggle("Show Statistics on Detail Pages", isOn: $showStatistics)
            } header: {
                Text("Layout")
            } footer: {
                Text("Browse Categories as Grid switches the Home browse section between horizontal carousels (default) and a 2-column tile grid. Show Statistics renders the compact metadata grid on detail pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Enable Glow", isOn: $glowEnabled)
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
                    showStatistics = true
                }
                .tint(.appAccent)
            }
        }
        .navigationTitle("Appearance")
        .inlineNavBar()
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
            // #121 — Section headers removed from Playback sub-tab (all
            // Settings sub-page headers are removed per the global header-
            // removal rule, except Schedule settings which is exempt).
            Section {
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
                NavigationLink {
                    AudioSettingsPage()
                } label: {
                    SettingsCategoryRow(icon: "speaker.wave.2.fill", title: "Audio", subtitle: "Surround, comfort, frame rate")
                }
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
        .inlineNavBar()
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
                    Toggle("Show Lock Button", isOn: $showLockButton)
                    Toggle("Show Services Button", isOn: $showServicesButton)
                    Toggle("Prefer Downloaded", isOn: $preferDownloaded)
                    Toggle("Show Remaining Time", isOn: $showRemainingTime)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("General")
        .inlineNavBar()
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
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("Streaming quality is capped at roughly 480p to reduce mobile data usage. Even if you pick a higher quality in the player, playback stays at this cap until Data Saving is turned off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .transition(.opacity)
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
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 0)
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
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("Caps streaming quality at roughly 480p to use less mobile data. The video player's quality picker is also locked to this cap while Data Saving is on. Downloads and local files are not affected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.2), value: dataSavingEnabled)
        }
        .navigationTitle("Quality")
        .inlineNavBar()
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
                    Toggle("Volume Gesture", isOn: $volumeGesture)
                    Toggle("Two-Finger Seek", isOn: $twoFingerGesture)
                    Toggle("Center-Tap to Toggle UI", isOn: $centerTapGesture)
                    Toggle("Double-Tap to Seek", isOn: $doubleTapGesture)
                }
                PlaybackSettingsCard(title: "Skip Durations") {
                    Picker("Skip Duration", selection: $skipShort) {
                        ForEach(shortOptions, id: \.self) { Text("\($0)s").tag($0) }
                    }
                    Picker("Long Skip Duration", selection: $skipLong) {
                        ForEach(longOptions, id: \.self) { Text("\($0)s").tag($0) }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Gestures")
        .inlineNavBar()
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
                    Toggle("TheIntroDB", isOn: $useTheIntroDB)
                    Toggle("IntroDB", isOn: $useIntroDB)
                }
                PlaybackSettingsCard(title: "Auto-Skip") {
                    Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                    Toggle("Always Show Skip Button", isOn: $alwaysShowSkipSegments)
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
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Skip Segments")
        .inlineNavBar()
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
                    Toggle("Show Next Episode Button", isOn: $showNextEpisodeButton)
                    Toggle("Show Episode Browser Button", isOn: $showNextEpisodeBrowserButton)
                }
                PlaybackSettingsCard(title: "Options") {
                    Toggle("Use Poster Art", isOn: $usePosterForNextEpisode)
                    Toggle("Skip Filler Episodes", isOn: $skipFillerEpisodes)
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
                    Text("The next-episode card appears once playback reaches this percentage of the current episode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Next Episode")
        .inlineNavBar()
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
                    if holdSpeedEnabled {
                        Group {
                            Divider()
                            HStack {
                                Text("Sensitivity")
                                Spacer()
                                Text("\(Int(holdSpeedSensitivity * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $holdSpeedSensitivity, in: 0.1...1.0, step: 0.1)
                            Picker("Speed Multiplier", selection: $holdSpeedMultiplier) {
                                ForEach(multipliers, id: \.self) { mult in
                                    Text(doubleLabel(mult)).tag(mult)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.2), value: holdSpeedEnabled)
        }
        .navigationTitle("Hold-Speed")
        .inlineNavBar()
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
                    Text("Target frame rate for inline (in-feed) playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Audio")
        .inlineNavBar()
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
                    Text("When you swipe out of Shirox during playback, the video shrinks into a small floating window so you can keep watching while using other apps. Turn this off if you'd rather the video just pause.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PlaybackSettingsCard(title: "Auto-Pause") {
                    Toggle("Auto-Pause on Interruption", isOn: $autoPauseOnInterruption)
                    Text("Pauses playback automatically when something else takes over audio — an incoming call, Siri, an alarm, or another media app starting. Playback resumes when the interruption ends if the system allows it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.4)
                    Toggle("Auto-Pause on Control Center", isOn: $autoPauseOnControlCenter)
                    Text("Pauses playback when you open Control Center or Notification Center by swiping down from the top-right or top of the screen. Playback doesn't auto-resume when you close it — tap play to continue. Opening the app switcher or going to the home screen is not affected (those use PiP instead).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Picture-in-Picture")
        .inlineNavBar()
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
                    Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
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
                    Text("Episodes are marked as watched once playback passes this percentage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Streaming")
        .inlineNavBar()
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
        .inlineNavBar()
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
                }
            }
        }
        .navigationTitle("Downloads")
        .inlineNavBar()
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
    @State private var isSendingTest = false

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
        .inlineNavBar()
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
            .shadow(
                color: (anyEnabled && Color.glowEnabled)
                    ? Color.green.opacity(Color.glowIntensity * 0.6) : .clear,
                radius: (anyEnabled && Color.glowEnabled)
                    ? CGFloat(14 * Color.glowIntensity) : 0
            )

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
            Toggle("Airing Notifications", isOn: $airingNotifications)
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
                    .shadow(
                        color: Color.glowEnabled
                            ? Color.red.opacity(Color.glowIntensity * 0.4) : .clear,
                        radius: Color.glowEnabled
                            ? CGFloat(8 * Color.glowIntensity) : 0
                    )
            }
            .buttonStyle(.bordered)
            .disabled(pendingCount == 0)

            Button {
                Task { await sendTestNotification() }
            } label: {
                HStack {
                    if isSendingTest {
                        ProgressView().tint(.appAccent)
                    } else {
                        Image(systemName: "bell.badge.fill")
                    }
                    Text("Send Test Notification")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.appAccent)
            .disabled(isSendingTest)
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

    /// Fires a test toast via `ToastManager` and schedules a local UN notification
    /// so the user can verify how episode-airing notifications will look and behave.
    private func sendTestNotification() async {
        isSendingTest = true
        defer { isSendingTest = false }

        // In-app toast preview — matches the styling used by real airing alerts.
        ToastManager.shared.show(
            title: "Test Notification",
            message: "This is how notifications will appear",
            icon: "bell.fill",
            iconColor: .accentColor,
            duration: 5.0
        )

        // Real local notification so the user can also see the system banner /
        // lock-screen presentation that fires when an episode airs.
        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "This is how episode airing notifications will appear"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)

        // Pending count now includes the scheduled test — refresh so the counter reflects it.
        await refreshStatus()
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
        .inlineNavBar()
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
        // shadow radius (`20 * intensity`) and its opacity (`intensity * 1.0`)
        // so the slider visibly grows and brightens the halo around the icon.
        let glowOpacity: Double = Color.glowEnabled ? Color.glowIntensity * 1.0 : 0
        let glowRadius: CGFloat = Color.glowEnabled ? CGFloat(28 * Color.glowIntensity) : 0

        CachedAsyncImage(urlString: provider.iconURL)
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(glowColor.opacity(Color.glowEnabled ? 0.85 : 0.5), lineWidth: 1.5)
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
                        .shadow(
                            color: (moduleManager.activeModule?.id == module.id && Color.glowEnabled)
                                ? Color.appAccent.opacity(Color.glowIntensity * 0.8)
                                : .clear,
                            radius: (moduleManager.activeModule?.id == module.id && Color.glowEnabled)
                                ? CGFloat(14 * Color.glowIntensity)
                                : 0
                        )
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
                    .contentShape(Rectangle())
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
    /// #130 — Layout toggle. Grid (default, 3-column) or list (1-column row).
    /// Persisted so the user's choice survives re-opening the store.
    @AppStorage("moduleStoreLayout") private var layout: ModuleStoreLayout = .grid

    /// #133 — cufiy.net Sora Module Library JSON endpoint. This is the
    /// authoritative, structured source for the full module listing — every
    /// module from `https://library.cufiy.net/library/` is available here as
    /// a clean JSON object (no HTML scraping required). The previous
    /// `modulesbypaul.dev` endpoint was a smaller, regex-parsed subset.
    private let storeURL = "https://library.cufiy.net/api/modules.json"
    private var columns: [GridItem] {
        // #130 — Grid is 3-column, list is a single column (the list-row tile
        // handles its own internal layout).
        switch layout {
        case .grid:
            return [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]
        case .list:
            return [GridItem(.flexible(), spacing: 10)]
        }
    }

    /// Modules shown in the "🔥 Popular Sources" section — anime-typed or
    /// English-language sources, which are the most commonly requested.
    private var popularSources: [StoreModuleItem] {
        filteredModules.filter { $0.isPopularSource }
    }

    /// Modules shown in the "✨ Community Sources" section — everything else
    /// (non-anime types and non-English languages).
    private var communitySources: [StoreModuleItem] {
        filteredModules.filter { !$0.isPopularSource }
    }

    /// Whether we have enough modules to justify splitting into two sections.
    /// With fewer than 4 total modules we just show a single "All Modules" list.
    private var shouldSplitIntoSections: Bool {
        filteredModules.count >= 4
    }

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
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<9, id: \.self) { _ in
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
                } else if shouldSplitIntoSections {
                    // 🔥 Popular Sources section (anime-typed or English-language)
                    if !popularSources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("🔥 Popular Sources")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(popularSources) { mod in
                                    StoreModuleTile(mod: mod, isInstalled: isModuleInstalled(mod), isInstalling: isInstalling, layout: layout) {
                                        installModule(mod)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    // ✨ Community Sources section (everything else)
                    if !communitySources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("✨ Community Sources")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14)
                                .padding(.top, 4)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(communitySources) { mod in
                                    StoreModuleTile(mod: mod, isInstalled: isModuleInstalled(mod), isInstalling: isInstalling, layout: layout) {
                                        installModule(mod)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 24)
                        }
                    }
                } else {
                    // All Modules (fewer than 4 modules total)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Modules")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredModules) { mod in
                                StoreModuleTile(mod: mod, isInstalled: isModuleInstalled(mod), isInstalling: isInstalling, layout: layout) {
                                    installModule(mod)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.04))
        .inlineNavBar()
        .navigationTitle("Module Store")
        .task { await loadStore() }
        .refreshable { await loadStore() }
        .toolbar {
            // #130 — Grid/list view toggle. Icon shows the layout the user
            // will switch TO (not the current one) so the tap reads as
            // "switch to list" / "switch to grid".
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        layout = (layout == .grid) ? .list : .grid
                    }
                    #if os(iOS)
                    Haptics.selection()
                    #endif
                } label: {
                    Image(systemName: layout.toggleIconName)
                        .font(.system(size: 14, weight: .medium))
                }
                .accessibilityLabel(layout == .grid ? "Switch to list view" : "Switch to grid view")
            }
        }
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

    /// #133 — Fetches the cufiy.net Sora Module Library JSON API
    /// (`https://library.cufiy.net/api/modules.json`), which is the
    /// authoritative source for the full module listing. The previous
    /// implementation scraped the `modulesbypaul.dev` HTML with regex over
    /// backslash-escaped JSON; the cufiy.net endpoint returns structured JSON
    /// directly, so we get clean field names, real install counts, and
    /// curation flags (featured / recommendation) for free.
    ///
    /// After fetching, modules are sorted by `popularityRank` (Miruro pinned
    /// first, then featured → recommendation → installCount → alphabetical)
    /// so the store opens with the most popular, best-regarded sources at
    /// the top. This integrates with the existing Popular/Community split
    /// (#79) — `isPopularSource` now reads the real curation flags instead
    /// of guessing from type/language.
    private func loadStore() async {
        isLoading = true; storeError = nil
        do {
            let url = URL(string: storeURL)!
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            // cufiy.net is a static JSON API; cache-bust every load so the
            // user always sees the freshest module list (new modules are
            // added frequently).
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            // The API returns a top-level JSON array of module objects.
            let modules = try JSONDecoder().decode([StoreModuleItem].self, from: data)
            // Deduplicate by manifestUrl (the API is already clean, but a
            // defensive dedupe keeps the listing stable if the API ever
            // returns duplicates).
            var seen = Set<String>()
            let deduped = modules.filter { mod in
                if mod.manifestUrl.isEmpty { return false }
                if seen.contains(mod.manifestUrl) { return false }
                seen.insert(mod.manifestUrl)
                return true
            }
            // #133 — Sort by real popularity: Miruro pinned first, then
            // featured → recommendation → installCount → alphabetical.
            storeModules = deduped.sorted { lhs, rhs in
                let lhsRank = lhs.popularityRank
                let rhsRank = rhs.popularityRank
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs.name.lowercased() < rhs.name.lowercased()
            }
            if storeModules.isEmpty {
                storeError = "No modules found. The library may have changed."
            }
        } catch {
            storeError = "Could not load the module library. Check your connection and try again."
        }
        isLoading = false
    }
}

struct StoreModuleWrapper: Codable { let modules: [StoreModuleItem] }

/// #130 — Layout preference for `ModuleStorePage`. Grid is the original
/// 3-column tile layout; List is a single-column row layout that shows more
/// metadata (type, language) at a glance and is easier to scan on phones.
enum ModuleStoreLayout: String, CaseIterable {
    case grid
    case list

    var iconName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    var toggleIconName: String {
        // Icon shows the LAYOUT YOU'LL SWITCH TO when tapped, so the user
        // reads it as "tap to switch to list/grid".
        switch self {
        case .grid: return "list.bullet"        // currently grid → tap goes to list
        case .list: return "square.grid.2x2"    // currently list → tap goes to grid
        }
    }
}

struct StoreModuleItem: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let version: String?
    let manifestUrl: String
    let iconUrl: String?
    let author: String?
    let type: String?
    let language: String?

    // #133 — Popularity / curation fields sourced from the cufiy.net Sora
    // Module Library JSON API (`https://library.cufiy.net/api/modules.json`).
    // All optional so legacy `modulesbypaul.dev`-style parses (which don't
    // carry these fields) still decode without failing.
    let installCount: Int?
    let recommendation: Int?
    let featured: Int?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, type, language, note
        // cufiy.net uses `sourceName` for the display name and `manifestUrl`
        // for the install URL. The legacy `modulesbypaul.dev` scrape used
        // `sourceName` (parsed manually) and `jsonUrl`/`manifest_url` —
        // we accept either spelling so both sources decode cleanly.
        case sourceName
        case manifestUrl
        case manifest_url
        case jsonUrl
        case iconUrl
        case icon_url
        case author
        case installCount
        case recommendation
        case featured
    }

    /// Whether this module qualifies as a "Popular Source" for the
    /// 🔥 Popular section. #133 — Now driven by real curation data from
    /// cufiy.net: featured > recommendation > installCount. Falls back to
    /// the older heuristic (anime-typed or English-language) when the
    /// curation fields are missing, so legacy parses still split sensibly.
    var isPopularSource: Bool {
        if let featured, featured > 0 { return true }
        if let recommendation, recommendation > 0 { return true }
        if let installCount, installCount >= 100 { return true }
        // Legacy fallback.
        let types = (type ?? "").lowercased()
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if types.contains("anime") { return true }
        return (language ?? "").lowercased() == "english"
    }

    /// #133 — Composite popularity rank for ordering the store listing.
    /// Higher = more popular. Components (in priority order):
    ///   1. Miruro pinned to the very top (explicit user request).
    ///   2. `featured` flag (cufiy.net editor's pick).
    ///   3. `recommendation` score.
    ///   4. `installCount` (clamped so a single viral hit doesn't dominate).
    ///   5. Alphabetical tiebreaker for stable ordering.
    var popularityRank: Int {
        // Miruro always wins.
        if name.lowercased() == "miruro" { return 1_000_000_000 }
        var rank = 0
        if let featured, featured > 0 { rank += 1_000_000 }
        if let recommendation { rank += recommendation * 10_000 }
        if let installCount { rank += min(installCount, 100_000) }
        return rank
    }

    init(id: String, name: String, description: String?, version: String?, manifestUrl: String, iconUrl: String?, author: String?, type: String? = nil, language: String? = nil, installCount: Int? = nil, recommendation: Int? = nil, featured: Int? = nil, note: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.manifestUrl = manifestUrl
        self.iconUrl = iconUrl
        self.author = author
        self.type = type
        self.language = language
        self.installCount = installCount
        self.recommendation = recommendation
        self.featured = featured
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // cufiy.net uses `id` (short hash); legacy scrape synthesised one from
        // the manifest URL. Accept either.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        // cufiy.net: `sourceName`. Legacy: `name`. Prefer sourceName, then name.
        if let sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName), !sourceName.isEmpty {
            name = sourceName
        } else {
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        }
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        // manifestUrl preferred; fall back to manifest_url / jsonUrl for the
        // legacy scrape shape.
        if let manifest = try c.decodeIfPresent(String.self, forKey: .manifestUrl), !manifest.isEmpty {
            manifestUrl = manifest
        } else if let manifest = try c.decodeIfPresent(String.self, forKey: .manifest_url), !manifest.isEmpty {
            manifestUrl = manifest
        } else if let jsonUrl = try c.decodeIfPresent(String.self, forKey: .jsonUrl), !jsonUrl.isEmpty {
            manifestUrl = jsonUrl
        } else {
            manifestUrl = ""
        }
        if let icon = try c.decodeIfPresent(String.self, forKey: .iconUrl) {
            iconUrl = icon
        } else {
            iconUrl = try c.decodeIfPresent(String.self, forKey: .icon_url)
        }
        // cufiy.net nests author under an `author` object with a `name` field.
        // Legacy scrape stored the author name directly as a string. Handle
        // both shapes.
        if let authorObj = try? c.decodeIfPresent(AuthorObject.self, forKey: .author) {
            author = authorObj.name
        } else {
            author = try? c.decodeIfPresent(String.self, forKey: .author)
        }
        type = try c.decodeIfPresent(String.self, forKey: .type)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        installCount = try c.decodeIfPresent(Int.self, forKey: .installCount)
        recommendation = try c.decodeIfPresent(Int.self, forKey: .recommendation)
        featured = try c.decodeIfPresent(Int.self, forKey: .featured)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Nested `author` object from cufiy.net (`{ "name": "50/50", "icon": "..." }`).
    private struct AuthorObject: Decodable {
        let name: String?
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .sourceName)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(manifestUrl, forKey: .manifestUrl)
        try c.encodeIfPresent(iconUrl, forKey: .iconUrl)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(installCount, forKey: .installCount)
        try c.encodeIfPresent(recommendation, forKey: .recommendation)
        try c.encodeIfPresent(featured, forKey: .featured)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

private struct StoreModuleTile: View {
    let mod: StoreModuleItem
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void
    /// #130 — Which layout to render. `.grid` is the original vertical tile
    /// (icon-top, name-below, install-button-bottom). `.list` is a horizontal
    /// row (icon-left, metadata-center, install-button-right) that surfaces
    /// type and language chips for at-a-glance scanning.
    var layout: ModuleStoreLayout = .grid

    @ViewBuilder
    var body: some View {
        switch layout {
        case .grid: gridBody
        case .list: listBody
        }
    }

    // MARK: - Grid layout (original)

    private var gridBody: some View {
        VStack(spacing: 6) {
            // Compact icon at top, centered, 40x40
            Group {
                if let iconUrl = mod.iconUrl, let url = URL(string: iconUrl) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFill() }
                        else { fallbackIcon }
                    }
                } else { fallbackIcon }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 2)

            // Name below, bold, 2-line limit, centered
            Text(mod.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)

            // Author caption
            if let author = mod.author, !author.isEmpty {
                Text(author)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            // Install button at bottom
            installButton
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .top)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        // Subtle accent glow on installed tiles — mirrors the active-module
        // glow used in `ModulesSettingsPage`. Gated by the global Glow
        // preference and scaled by its intensity slider.
        .shadow(
            color: isInstalled && Color.glowEnabled
                ? Color.appAccent.opacity(Color.glowIntensity * 0.5)
                : .clear,
            radius: isInstalled && Color.glowEnabled
                ? CGFloat(8 * Color.glowIntensity)
                : 0
        )
    }

    // MARK: - List layout (#130)

    private var listBody: some View {
        HStack(spacing: 12) {
            // Icon on the left, 44x44 (slightly larger than grid tile so the
            // row reads well at the wider single-column width).
            Group {
                if let iconUrl = mod.iconUrl, let url = URL(string: iconUrl) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFill() }
                        else { fallbackIcon }
                    }
                } else { fallbackIcon }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            // Center: name + author + type/language chips
            VStack(alignment: .leading, spacing: 4) {
                Text(mod.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let author = mod.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Type + language chips — only shown in list layout where
                // there's horizontal room for them. Helps the user scan a
                // long store listing for the source type they need.
                HStack(spacing: 6) {
                    if let type = mod.type, !type.isEmpty {
                        chipLabel(type, icon: "rectangle.stack")
                    }
                    if let language = mod.language, !language.isEmpty {
                        chipLabel(language, icon: "globe")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: install state / button
            installButton
                .frame(width: 84)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .shadow(
            color: isInstalled && Color.glowEnabled
                ? Color.appAccent.opacity(Color.glowIntensity * 0.5)
                : .clear,
            radius: isInstalled && Color.glowEnabled
                ? CGFloat(8 * Color.glowIntensity)
                : 0
        )
    }

    // MARK: - Shared install button

    @ViewBuilder
    private var installButton: some View {
        if isInstalled {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 3)
        } else if isInstalling {
            ProgressView()
                .scaleEffect(0.65)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 3)
        } else {
            Button(action: onInstall) {
                Text("Install")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlowingInstallButtonStyle())
        }
    }

    private func chipLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var fallbackIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
    }
}

/// Button style for the Store tile "Install" button. Mimics the system
/// `.bordered` look (tinted capsule background + tinted label) and adds an
/// accent glow while the button is pressed. The glow is gated by the global
/// `Color.glowEnabled` flag and scaled by `Color.glowIntensity`, matching the
/// pattern used elsewhere in the app (e.g. `ModulesSettingsPage`).
private struct GlowingInstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.appAccent)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.appAccent.opacity(configuration.isPressed ? 0.30 : 0.16))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .shadow(
                color: configuration.isPressed && Color.glowEnabled
                    ? Color.appAccent.opacity(Color.glowIntensity * 0.5)
                    : .clear,
                radius: configuration.isPressed && Color.glowEnabled
                    ? CGFloat(8 * Color.glowIntensity)
                    : 0
            )
    }
}

private struct StoreModuleSkeletonTile: View {
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 40)
                .padding(.top, 2)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 54, height: 9)
            Spacer(minLength: 2)
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 22)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .top)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .inlineNavBar()
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

    // #114 — Expanded subtitle customization. These are persisted alongside
    // the original keys so existing installs keep their settings; the new
    // keys default to no-op values (1.0x spacing, full opacity, no delay…)
    // so the visual result is unchanged until the user opts in.
    @AppStorage("subtitleFontDesign") private var subtitleFontDesign: String = "default"
    @AppStorage("subtitleTextOpacity") private var subtitleTextOpacity: Double = 1.0
    @AppStorage("subtitleLineSpacing") private var subtitleLineSpacing: Double = 1.0
    @AppStorage("subtitleMaxWidth") private var subtitleMaxWidth: Double = 90
    @AppStorage("subtitleDelaySeconds") private var subtitleDelaySeconds: Double = 0
    @AppStorage("subtitleShadowOffset") private var subtitleShadowOffset: Double = 2

    // #114 extension — Vertical position control. -100 = top of screen,
    // 100 = bottom of screen, 0 = default (near-bottom) subtitle position.
    // The live preview and LandscapeSubtitlePreview both read this key so the
    // user can drag the slider and see the caption move in real time.
    @AppStorage("subtitleVerticalOffset") private var subtitleVerticalOffset: Double = 0

    @State private var previewImageURL: String?
    @State private var showLandscapePreview = false

    private let textColorOptions = ["white", "yellow", "black", "cyan", "pink", "green"]
    private let strokeColorOptions = ["none", "black", "white", "gray"]
    private let fontDesignOptions: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Rounded", "rounded"),
        ("Serif", "serif"),
        ("Monospaced", "monospaced")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                quickPresetsCard
                livePreviewCard
                appearanceControlsCard
                positionCard
                typographyCard
                timingCard
                effectsCard
                testInLandscapeButton
            }
            .padding()
        }
        .navigationTitle("Subtitles")
        .inlineNavBar()
        .onAppear {
            Task {
                let trending = try? await AniListService.shared.browse(category: .trending, page: 1)
                if let random = trending?.randomElement() {
                    previewImageURL = random.bannerImage ?? random.coverImage.extraLarge ?? random.coverImage.large
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showLandscapePreview) {
            // #114 (bug) — Pass the fetched anime backdrop URL into the
            // landscape preview so the caption renders over a real anime
            // still (matching playback conditions), not just a flat gradient.
            LandscapeSubtitlePreview(backdropImageURL: previewImageURL)
        }
        #endif
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
                    // #114 extension — Apply the user's vertical offset so the
                    // preview caption moves in real time as the slider drags.
                    // The multiplier (0.5) scales the -100…100 range down to
                    // ±50pt so the caption stays inside the 180pt preview frame.
                    .offset(y: -subtitleVerticalOffset * 0.5)
            }
            .frame(maxWidth: .infinity)

            // Caption text in this preview is scaled down by 50% so the preview
            // fits inside the card without overflowing. The styling (color,
            // stroke, background, weight) is preserved — only the rendered size
            // is reduced. See the disclaimer below for why.
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("True caption size is only visible in fullscreen landscape mode during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitlePreviewText: some View {
        let resolvedStrokeWidth: Double = (subtitleStrokeColor == "none") ? 0 : subtitleStrokeWidth
        // Preview is rendered at 50% of the user-selected font size so the
        // caption fits inside the (180pt-tall) preview card. Stroke width is
        // scaled by the same factor to keep the visual ratio between glyph
        // and outline consistent with playback.
        let previewFontScale: Double = 0.5
        let previewFontSize = max(CGFloat(subtitleFontSize * previewFontScale), 8)
        let previewStrokeWidth = resolvedStrokeWidth * previewFontScale
        return Text("The journey of a thousand miles begins with a single step.")
            .font(.system(size: previewFontSize,
                          weight: subtitleBoldText ? .bold : .regular))
            .foregroundStyle(color(fromName: subtitleTextColor))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Group {
                    if subtitleBackgroundEnabled {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    } else {
                        Color.clear
                    }
                }
            )
            .applySubtitleStroke(color: color(fromName: subtitleStrokeColor),
                                 width: previewStrokeWidth)
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

    // MARK: - Typography Card (#114)

    private var typographyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Typography", systemImage: "textformat.size")
                .font(.headline)

            Picker("Font Design", selection: $subtitleFontDesign) {
                ForEach(fontDesignOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .tint(.appAccent)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Line Spacing")
                    Spacer()
                    Text(String(format: "%.2fx", subtitleLineSpacing))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleLineSpacing, in: 0.8...2.0, step: 0.05)
                    .tint(.appAccent)
                Text("Multiplier applied between caption lines. 1.0 = default, 2.0 = double-spaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Max Width")
                    Spacer()
                    Text("\(Int(subtitleMaxWidth))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleMaxWidth, in: 50...100, step: 1)
                    .tint(.appAccent)
                Text("Maximum width of the caption block, as a percentage of the screen width.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Timing Card (#114)

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Timing", systemImage: "clock")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Subtitle Delay")
                    Spacer()
                    Text(String(format: "%+.1fs", subtitleDelaySeconds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleDelaySeconds, in: -5...5, step: 0.1)
                    .tint(.appAccent)
                Text("Negative values show subtitles earlier, positive values later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        subtitleDelaySeconds = 0
                    }
                } label: {
                    Label("Reset to 0s", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.appAccent)
                .disabled(subtitleDelaySeconds == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Position & Background Card (#114 extension)

    /// #114 extension — Vertical position control. The slider runs -100…100
    /// (top…bottom) with 0 as the default (near-bottom) subtitle position so
    /// existing installs are unaffected until the user opts in.
    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Position & Background", systemImage: "arrow.up.and.down.text.horizontal")
                .font(.headline)

            Toggle("Background", isOn: $subtitleBackgroundEnabled)
                .tint(.appAccent)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Vertical Position")
                    Spacer()
                    Text(String(format: "%+.0f", subtitleVerticalOffset))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleVerticalOffset, in: -100...100, step: 1)
                    .tint(.appAccent)
                HStack {
                    Text("Top")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Bottom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Negative values lift the caption toward the top of the screen, positive values push it toward the bottom. 0 = default position near the bottom edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        subtitleVerticalOffset = 0
                    }
                } label: {
                    Label("Reset to 0", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.appAccent)
                .disabled(subtitleVerticalOffset == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Effects Card (#114)

    private var effectsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Effects", systemImage: "sparkles")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Text Opacity")
                    Spacer()
                    Text("\(Int((subtitleTextOpacity * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleTextOpacity, in: 0.5...1.0, step: 0.05)
                    .tint(.appAccent)
                Text("Dims the entire caption. Useful for non-intrusive subtitles over bright scenes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Shadow Offset")
                    Spacer()
                    Text(String(format: "%.1fpt", subtitleShadowOffset))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $subtitleShadowOffset, in: 0...10, step: 0.5)
                    .tint(.appAccent)
                Text("Drop-shadow distance behind the caption. 0 disables the shadow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Test in Landscape Button (#114)

    private var testInLandscapeButton: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showLandscapePreview = true
            } label: {
                Label("Test in Landscape", systemImage: "rectangle.landscape.rotate")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.appAccent)

            Text("Opens a fullscreen, landscape-only preview that renders the caption at its true playback size — no scaling.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        #else
        EmptyView()
        #endif
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

// MARK: - Landscape Subtitle Preview (#114)

#if os(iOS)
/// Fullscreen, landscape-only preview that renders the configured subtitle
/// style at its true playback size.
///
/// The inline "Live Preview" card in `SubtitleSettingsPage` scales the caption
/// down by 50% so it fits inside a 180pt-tall card — that's enough to check
/// color/stroke choices, but it hides the real on-screen proportions. This
/// view borrows `PlayerPresenter`'s orientation-lock machinery to rotate the
/// device into landscape exactly like real playback, then draws the caption
/// with no scaling so the user can judge readability at the genuine size.
///
/// #114 (bug fix) — Now renders the actual anime backdrop (banner/cover) URL
/// passed in from `SubtitleSettingsPage` behind the caption, instead of the
/// previous flat dark gradient. The backdrop is darkened with a 45% black
/// overlay so the caption stays readable regardless of the artwork's
/// brightness, matching real playback where subtitles overlay the video.
struct LandscapeSubtitlePreview: View {
    /// Optional anime artwork (banner or cover URL) shown behind the caption.
    /// Nil falls back to the dark gradient placeholder.
    var backdropImageURL: String? = nil

    @AppStorage("subtitleTextColor") private var subtitleTextColor: String = "white"
    @AppStorage("subtitleStrokeColor") private var subtitleStrokeColor: String = "black"
    @AppStorage("subtitleStrokeWidth") private var subtitleStrokeWidth: Double = 1.0
    @AppStorage("subtitleBackgroundEnabled") private var subtitleBackgroundEnabled: Bool = false
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 30
    @AppStorage("subtitleBoldText") private var subtitleBoldText: Bool = false
    @AppStorage("subtitleFontDesign") private var subtitleFontDesign: String = "default"
    @AppStorage("subtitleTextOpacity") private var subtitleTextOpacity: Double = 1.0
    @AppStorage("subtitleLineSpacing") private var subtitleLineSpacing: Double = 1.0
    @AppStorage("subtitleMaxWidth") private var subtitleMaxWidth: Double = 90
    @AppStorage("subtitleShadowOffset") private var subtitleShadowOffset: Double = 2
    // #114 extension — Mirror the vertical-offset key so the landscape preview
    // honors the same slider the user just dragged in the inline preview.
    @AppStorage("subtitleVerticalOffset") private var subtitleVerticalOffset: Double = 0

    @Environment(\.dismiss) private var dismiss
    @State private var hasAppliedLandscapeLock = false

    var body: some View {
        GeometryReader { proxy in
            // Issue #9 — Clamp caption width to 92% of screen width so text
            // never overflows off-screen in landscape, even if the user's
            // subtitleMaxWidth slider is set to 100%.
            let captionMaxWidth = min(proxy.size.width * (subtitleMaxWidth / 100.0), proxy.size.width * 0.92)
            let bottomInset = max(proxy.size.height * 0.08, 48)
            ZStack(alignment: .top) {
                // #114 (bug fix) — Real anime backdrop. The SubtitleSettingsPage
                // fetches a trending title on appear and passes its banner/cover
                // URL here. We render it aspect-fill across the whole frame so
                // the caption sits on top of actual anime art, just like real
                // playback. A 45% black overlay guarantees caption legibility
                // regardless of the artwork's brightness.
                backdropView

                VStack(spacing: 0) {
                    // Top bar with Done button — always reachable so the user
                    // is never trapped in the preview.
                    HStack {
                        Label("Landscape Preview", systemImage: "rectangle.landscape.rotate")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                    Spacer()

                    // Caption rendered at TRUE font size (no scaling). All of
                    // the user-selected style settings (color, stroke,
                    // background, weight, design, opacity, line spacing,
                    // shadow) are applied so the preview matches playback 1:1.
                    // #114 extension — Apply the user's vertical offset so the
                    // landscape preview matches the inline preview's caption
                    // position. Positive offset pushes down (closer to / past
                    // the default bottom inset), negative lifts toward the top.
                    captionText
                        .frame(maxWidth: captionMaxWidth)
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomInset)
                        .offset(y: -subtitleVerticalOffset * 0.8)
                }

                // Subtle helper text just above the caption so the user
                // understands what they're looking at.
                VStack {
                    Spacer()
                    Text("Caption shown at actual playback size")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, bottomInset + 76)
                }
            }
            .foregroundStyle(.white)
        }
        .statusBarHidden()
        .onAppear {
            // Borrow the player presenter's orientation-lock machinery so the
            // preview rotates into landscape exactly like real playback does.
            // The lock is also consulted by the AppDelegate's
            // `supportedInterfaceOrientationsFor:` so iOS will allow the
            // rotation.
            #if !targetEnvironment(macCatalyst)
            PlayerPresenter.shared.updateOrientationLock(.landscape, shouldRotate: true)
            hasAppliedLandscapeLock = true
            #endif
        }
        .onDisappear {
            // Always restore portrait on dismiss, even if onAppear failed —
            // leaving the app stuck in landscape after closing the preview
            // would be a regression.
            #if !targetEnvironment(macCatalyst)
            if hasAppliedLandscapeLock {
                PlayerPresenter.shared.updateOrientationLock(.portrait, shouldRotate: true)
            }
            #endif
        }
    }

    // MARK: - Backdrop

    /// The backdrop behind the caption. When `backdropImageURL` is present,
    /// renders the anime artwork aspect-fill across the whole frame with a
    /// 45% black overlay for caption legibility (matching real playback where
    /// subtitles overlay video). When absent (network failed / no trending
    /// title yet), falls back to the original dark gradient placeholder.
    @ViewBuilder
    private var backdropView: some View {
        if let urlString = backdropImageURL, !urlString.isEmpty, let url = URL(string: urlString) {
            ZStack {
                // Aspect-fill the artwork so the whole landscape frame is
                // covered, just like a real video frame. SwiftUI's built-in
                // AsyncImage is used (not CachedAsyncImage) because we need
                // the phase closure to fall back to the gradient placeholder
                // while the image loads or if it fails.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        // While loading or if the URL fails, show the gradient
                        // placeholder so the preview never shows a black void.
                        gradientPlaceholder
                    @unknown default:
                        gradientPlaceholder
                    }
                }
                // Darken the artwork so white captions stay readable.
                Color.black.opacity(0.45)
            }
            .ignoresSafeArea()
        } else {
            gradientPlaceholder
                .ignoresSafeArea()
        }
    }

    private var gradientPlaceholder: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.04, blue: 0.06),
                Color(red: 0.10, green: 0.09, blue: 0.13)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Caption

    private var captionText: some View {
        let resolvedStrokeWidth: Double = (subtitleStrokeColor == "none") ? 0 : subtitleStrokeWidth
        // SwiftUI's `Text.lineSpacing(_:)` adds extra *points* between lines,
        // not a multiplier. Convert the user-facing 1.0–2.0 multiplier to an
        // additive point value scaled by font size so 1.0 = default spacing
        // and 2.0 = roughly double.
        let lineSpacingPoints = CGFloat((subtitleLineSpacing - 1.0) * subtitleFontSize * 0.5)
        return Text("The journey of a thousand miles begins with a single step.")
            .font(.system(size: CGFloat(subtitleFontSize),
                          weight: subtitleBoldText ? .bold : .regular,
                          design: resolvedFontDesign))
            .foregroundStyle(resolvedTextColor.opacity(subtitleTextOpacity))
            .multilineTextAlignment(.center)
            .lineSpacing(lineSpacingPoints)
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
            .shadow(color: .black.opacity(subtitleShadowOffset > 0 ? 0.85 : 0),
                    radius: max(CGFloat(subtitleShadowOffset), 0),
                    x: 0,
                    y: max(CGFloat(subtitleShadowOffset) / 2.0, 0))
    }

    // MARK: - Resolved values

    private var resolvedFontDesign: Font.Design {
        switch subtitleFontDesign.lowercased() {
        case "rounded":    return .rounded
        case "serif":      return .serif
        case "monospaced": return .monospaced
        default:           return .default
        }
    }

    private var resolvedTextColor: Color {
        color(fromName: subtitleTextColor)
    }

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
#endif

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
        .inlineNavBar()
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: 14) {
            // #94 — Single clean app icon: just the bundled `app-logo` asset
            // in a rounded rect. No gradient background, no extra frame, no
            // SF-Symbol fallback wrapping — the image speaks for itself.
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))

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
                    Text("When on, your library changes (status, progress, score) are pushed to AniList and MyAnimeList automatically. Turn this off if you want to edit your library locally without affecting your online accounts. Both anime and manga entries are synced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.4)
                    Toggle("Auto Sync Ratings", isOn: $autoSyncRatings)
                    Text("After you finish an episode (or read the final chapter of a manga), prompts you to rate it and pushes that rating to your connected tracker. Disable if you'd rather rate things manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                .shadow(
                    color: isConnected && Color.glowEnabled
                        ? Color.green.opacity(Color.glowIntensity) : .clear,
                    radius: isConnected && Color.glowEnabled
                        ? CGFloat(21 * Color.glowIntensity) : 0
                )

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

                // #127 — Plain-language explanation of what Performance Mode
                // actually does. Listed as concrete bullet points so the user
                // can decide whether the trade-off is worth it for their device.
                VStack(alignment: .leading, spacing: 14) {
                    Label("What Performance Mode Does", systemImage: "info.circle.fill")
                        .font(.headline)
                    Text("When enabled, Shirox turns off decorative visual effects so the app feels snappier and uses less battery. This is most useful on older devices or when you're low on power.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        performanceBullet(
                            icon: "sparkles",
                            title: "Animated Background Off",
                            detail: "The drifting gradient backdrop on the Home tab is replaced with a flat static gradient."
                        )
                        performanceBullet(
                            icon: "wand.and.stars",
                            title: "Glow Halos Off",
                            detail: "The soft glow around toggles, source cards, and install buttons is removed."
                        )
                        performanceBullet(
                            icon: "rectangle.split.3x1",
                            title: "Instant Tab Switching",
                            detail: "The cross-fade animation when switching between Home, Library, Search, and Settings is skipped — tabs swap immediately."
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Skip AniList Traversal card
                VStack(alignment: .leading, spacing: 14) {
                    Label("Advanced", systemImage: "bolt.fill")
                        .font(.headline)
                    Toggle("Skip AniList Traversal", isOn: $skipAniListTraversal)
                    // #128 — Rewritten in plain language: what the setting
                    // actually does, when it helps, and when it might miss
                    // data — without jargon.
                    Text("When you open a manga or anime from a module, Shirox normally makes an extra request to AniList to fetch richer metadata (synopsis, genres, score, studio). Turning this on skips that extra lookup and uses only the data the module already provided.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pages load faster, especially on slow networks, but the detail screen may show less information (for example: no average score, no studio, no genres) for titles the module doesn't fully describe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Performance")
        .inlineNavBar()
    }

    // #127 — Helper for the bullet list. Each row pairs an icon, a bold
    // title, and a one-sentence explanation so the user can scan the list
    // and understand the full impact of Performance Mode at a glance.
    @ViewBuilder
    private func performanceBullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    .shadow(
                        color: Color.glowEnabled
                            ? Color.appAccent.opacity(Color.glowIntensity * 0.5) : .clear,
                        radius: Color.glowEnabled ? CGFloat(17 * Color.glowIntensity) : 0
                    )
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
                    // #100 — Frosted-glass backdrop so the sheet picks up the
                    // content underneath instead of sitting on a flat card.
                    .background(.ultraThinMaterial)
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
        .inlineNavBar()
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
