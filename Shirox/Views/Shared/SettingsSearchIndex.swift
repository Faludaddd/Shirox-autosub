import SwiftUI

// MARK: - SettingsSearchIndex (#125)
//
// A static catalog of every searchable setting in the app, used by the
// Settings search bar to jump directly to a specific feature — even when
// it's buried deep inside a sub-page.
//
// Each entry carries:
//   • `label`       — the user-facing name of the setting (e.g. "Auto-Pause on Control Center")
//   • `aliases`     — alternative phrasings the user might type (e.g. "control centre",
//                     "pause when swiping", "CC pause"). Matched fuzzily.
//   • `category`    — the Settings page name (for the result row subtitle)
//   • `page`        — which settings page to push
//   • `anchor`      — a stable id the destination page uses with ScrollViewReader
//                     to scroll the matching row into view. Pages that don't yet
//                     implement scroll-to-anchor still push to the right page;
//                     the user lands on the correct screen and can scroll manually.
//   • `icon`        — SF Symbol for the result row
//
// Fuzzy matching: case-insensitive, ignores punctuation, matches on label OR
// any alias. A tokenized score (label match > alias match > category match)
// ranks the most relevant results first.

enum SettingsPage: Hashable {
    case appearance
    case playback
    case subtitles
    case library
    case trackers
    case sources
    case modules
    case schedule
    case notifications
    case advanced
    case backup
    case logger
    case about
    case pip
    case quality
    case gestures
    case skipSegments
    case nextEpisode
    case holdSpeed
    case audio
    case streaming
    case downloads
    case search
}

struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let label: String
    let aliases: [String]
    let category: String
    let page: SettingsPage
    let anchor: String
    let icon: String

    init(_ label: String, aliases: [String] = [], category: String, page: SettingsPage, anchor: String? = nil, icon: String = "gearshape") {
        self.id = "\(page).\(anchor ?? label)"
        self.label = label
        self.aliases = aliases
        self.category = category
        self.page = page
        self.anchor = anchor ?? label
        self.icon = icon
    }
}

enum SettingsSearchIndex {
    /// The full catalog. Add new entries here as settings are added. The
    /// `aliases` arrays are deliberately generous — they cover British
    /// spellings, common abbreviations, and natural-language phrasings a
    /// user might type when they don't remember the exact label.
    static let entries: [SettingsSearchEntry] = [
        // Appearance
        .init("Theme", aliases: ["dark mode", "light mode", "colour scheme", "color scheme"], category: "Appearance", page: .appearance, anchor: "theme", icon: "circle.lefthalf.filled"),
        .init("Accent Color", aliases: ["accent colour", "tint", "highlight color"], category: "Appearance", page: .appearance, anchor: "accent", icon: "paintpalette.fill"),
        .init("Glow", aliases: ["glow intensity", "halo", "neon"], category: "Appearance", page: .appearance, anchor: "glow", icon: "sparkles"),
        .init("Reduce Motion", aliases: ["animations", "no animation"], category: "Appearance", page: .appearance, anchor: "reduceMotion", icon: "tortoise"),
        .init("Show Browse Categories on Home", aliases: ["home categories", "browse tiles"], category: "Appearance", page: .appearance, anchor: "browseCategories", icon: "square.grid.2x2"),
        .init("Show Statistics", aliases: ["stats grid", "library stats"], category: "Appearance", page: .appearance, anchor: "statistics", icon: "chart.bar.fill"),

        // Playback — top-level
        .init("Player General", aliases: ["player behaviour", "default player"], category: "Playback", page: .playback, anchor: "general", icon: "play.circle.fill"),
        .init("Quality", aliases: ["video quality", "resolution", "480p", "720p", "1080p"], category: "Playback", page: .quality, anchor: "quality", icon: "speedometer"),
        .init("Data Saving", aliases: ["data saver", "mobile data", "cellular", "low data"], category: "Playback", page: .quality, anchor: "dataSaving", icon: "leaf.fill"),
        .init("Gestures", aliases: ["touch gestures", "swipe", "tap", "double tap"], category: "Playback", page: .gestures, anchor: "gestures", icon: "hand.draw.fill"),
        .init("Skip Segments", aliases: ["skip intro", "skip outro", "skip opening", "skip ending", "auto skip"], category: "Playback", page: .skipSegments, anchor: "skipSegments", icon: "forward.fill"),
        .init("Next Episode", aliases: ["auto play next", "auto advance", "continuous playback"], category: "Playback", page: .nextEpisode, anchor: "nextEpisode", icon: "arrow.right.circle.fill"),
        .init("Hold Speed", aliases: ["speed boost", "fast forward", "2x speed"], category: "Playback", page: .holdSpeed, anchor: "holdSpeed", icon: "gauge.with.dots.needle.67percent"),
        .init("Audio", aliases: ["sound", "volume", "audio language", "Japanese audio"], category: "Playback", page: .audio, anchor: "audio", icon: "speaker.wave.2.fill"),
        .init("Picture-in-Picture", aliases: ["pip", "floating video", "mini player"], category: "Playback", page: .pip, anchor: "pip", icon: "pip.fill"),
        .init("Auto-Pause on Interruption", aliases: ["pause on call", "pause on alarm", "audio interruption"], category: "Playback", page: .pip, anchor: "autoPauseInterruption", icon: "pause.circle.fill"),
        .init("Auto-Pause on Control Center", aliases: ["control centre", "control center", "pause on swipe", "cc pause"], category: "Playback", page: .pip, anchor: "autoPauseControlCenter", icon: "pause.circle.fill"),
        .init("Streaming", aliases: ["auto pick stream", "watched percentage", "stream picker"], category: "Playback", page: .streaming, anchor: "streaming", icon: "antenna.radiowaves.left.and.right"),

        // Subtitles
        .init("Subtitles", aliases: ["captions", "subs", "subtitle style"], category: "Subtitles", page: .subtitles, anchor: "subtitles", icon: "captions.bubble.fill"),
        .init("Subtitle Color", aliases: ["subtitle colour", "caption color", "text color"], category: "Subtitles", page: .subtitles, anchor: "subtitleColor", icon: "paintbrush.fill"),
        .init("Subtitle Font Size", aliases: ["caption size", "text size"], category: "Subtitles", page: .subtitles, anchor: "subtitleFontSize", icon: "textformat.size"),
        .init("Subtitle Position", aliases: ["subtitle vertical offset", "caption position", "subtitle location"], category: "Subtitles", page: .subtitles, anchor: "subtitlePosition", icon: "arrow.up.and.down"),
        .init("Subtitle Delay", aliases: ["subtitle sync", "caption offset", "subtitle timing"], category: "Subtitles", page: .subtitles, anchor: "subtitleDelay", icon: "clock"),
        .init("Landscape Subtitle Preview", aliases: ["true size preview", "fullscreen subtitle test"], category: "Subtitles", page: .subtitles, anchor: "landscapePreview", icon: "rectangle.landscape.rotate"),

        // Library & Trackers
        .init("Library", aliases: ["my library", "tracking list", "watch list", "reading list"], category: "Library", page: .library, anchor: "library", icon: "books.vertical.fill"),
        .init("Trackers", aliases: ["anilist", "myanimelist", "mal", "sync"], category: "Trackers", page: .trackers, anchor: "trackers", icon: "antenna.radiowaves.left.and.right"),
        .init("Enable Sync", aliases: ["auto sync", "push to anilist", "push to mal"], category: "Trackers", page: .trackers, anchor: "enableSync", icon: "arrow.triangle.2.circlepath"),
        .init("Auto Sync Ratings", aliases: ["rate after finishing", "auto rate", "rating prompt"], category: "Trackers", page: .trackers, anchor: "autoSyncRatings", icon: "star.fill"),

        // Sources & Modules
        .init("Sources", aliases: ["anilist account", "mal account", "provider"], category: "Sources", page: .sources, anchor: "sources", icon: "person.crop.circle.badge.checkmark"),
        .init("Modules", aliases: ["streaming modules", "module list", "installed modules"], category: "Modules", page: .modules, anchor: "modules", icon: "puzzlepiece.extension.fill"),
        .init("Module Store", aliases: ["browse modules", "install module", "cufiy", "sora modules"], category: "Modules", page: .modules, anchor: "moduleStore", icon: "bag.fill"),

        // Schedule & Notifications
        .init("Schedule", aliases: ["airing schedule", "calendar", "upcoming episodes"], category: "Schedule", page: .schedule, anchor: "schedule", icon: "calendar"),
        .init("Schedule Window Range", aliases: ["schedule days", "look ahead", "schedule range"], category: "Schedule", page: .schedule, anchor: "windowRange", icon: "calendar.badge.clock"),
        .init("Schedule Timezone", aliases: ["utc", "local time", "schedule timezone"], category: "Schedule", page: .schedule, anchor: "timezone", icon: "globe"),
        .init("Notifications", aliases: ["alerts", "airing alerts", "push notifications"], category: "Notifications", page: .notifications, anchor: "notifications", icon: "bell.fill"),

        // Advanced
        .init("Advanced", aliases: ["cache", "clear cache", "reset", "storage"], category: "Advanced", page: .advanced, anchor: "advanced", icon: "gearshape.2.fill"),
        .init("Clear Image Cache", aliases: ["delete images", "free space", "image cache"], category: "Advanced", page: .advanced, anchor: "clearImageCache", icon: "photo.stack"),
        .init("Reset Continue Watching", aliases: ["clear continue watching", "reset progress", "cw reset"], category: "Advanced", page: .advanced, anchor: "resetCW", icon: "arrow.counterclockwise"),
        .init("Backup & Restore", aliases: ["export settings", "import settings", "backup json"], category: "Backup & Restore", page: .backup, anchor: "backup", icon: "externaldrive.badge.timemachine"),
        .init("Logger", aliases: ["logs", "debug log", "app logs"], category: "Logger", page: .logger, anchor: "logger", icon: "terminal"),

        // About
        .init("About", aliases: ["version", "licenses", "credits", "legal"], category: "About", page: .about, anchor: "about", icon: "info.circle.fill"),
    ]

    // MARK: - Fuzzy search

    /// Normalizes a string for matching: lowercase, collapse whitespace,
    /// strip punctuation. "Control Centre" and "control-centre" both
    /// normalize to "control centre".
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .components(separatedBy: .punctuationCharacters).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when `query` (already normalized) appears as a substring of
    /// `candidate` (already normalized), OR when every token of `query`
    /// appears in `candidate` in order (token-prefix match). The tokenized
    /// branch lets "control centre" match "Auto-Pause on Control Center"
    /// even though the exact substring doesn't appear.
    private static func fuzzyMatch(_ query: String, _ candidate: String) -> Bool {
        if candidate.contains(query) { return true }
        let queryTokens = query.components(separatedBy: " ").filter { !$0.isEmpty }
        let candidateTokens = candidate.components(separatedBy: " ").filter { !$0.isEmpty }
        var ci = 0
        for qt in queryTokens {
            // Find the next candidate token that starts with this query token.
            while ci < candidateTokens.count {
                if candidateTokens[ci].hasPrefix(qt) {
                    ci += 1
                    break
                }
                ci += 1
            }
            if ci > candidateTokens.count { return false }
        }
        return true
    }

    /// Searches the index. Returns up to `limit` entries ranked by relevance:
    ///   1. Label starts with query (most relevant)
    ///   2. Label contains query
    ///   3. Any alias contains query
    ///   4. Category contains query (least relevant)
    /// Within a tier, shorter labels rank first (they're more likely the
    /// exact thing the user wanted).
    static func search(_ rawQuery: String, limit: Int = 20) -> [SettingsSearchEntry] {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        var tier1: [SettingsSearchEntry] = []  // label starts with query
        var tier2: [SettingsSearchEntry] = []  // label fuzzy-matches
        var tier3: [SettingsSearchEntry] = []  // alias fuzzy-matches
        var tier4: [SettingsSearchEntry] = []  // category fuzzy-matches
        for entry in entries {
            let label = normalize(entry.label)
            if label.hasPrefix(query) {
                tier1.append(entry); continue
            }
            if fuzzyMatch(query, label) {
                tier2.append(entry); continue
            }
            if entry.aliases.contains(where: { fuzzyMatch(query, normalize($0)) }) {
                tier3.append(entry); continue
            }
            if fuzzyMatch(query, normalize(entry.category)) {
                tier4.append(entry); continue
            }
        }
        let byLabelLength: (SettingsSearchEntry, SettingsSearchEntry) -> Bool = { $0.label.count < $1.label.count }
        return (tier1.sorted(by: byLabelLength)
                + tier2.sorted(by: byLabelLength)
                + tier3.sorted(by: byLabelLength)
                + tier4.sorted(by: byLabelLength))
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Settings Page Resolver
//
// Maps a `SettingsPage` enum value to the actual SwiftUI view to push.
// Kept separate from the index so the index has no SwiftUI dependencies
// (easier to test, and the resolver is the only place that needs to know
// about the concrete view types).

@ViewBuilder
func settingsPageView(for page: SettingsPage) -> some View {
    switch page {
    case .appearance:    AppearanceSettingsPage()
    case .playback:      PlaybackSettingsPage()
    case .subtitles:     SubtitleSettingsPage()
    case .library:       LibrarySettingsPage()
    case .trackers:      TrackersSettingsPage()
    case .sources:       SourcesSettingsPage()
    case .modules:       ModulesSettingsPage()
    case .schedule:      ScheduleSettingsPage()
    case .notifications: NotificationsSettingsPage()
    case .advanced:      AdvancedSettingsPage()
    case .backup:        BackupRestoreSettingsPage()
    case .logger:        LoggerSettingsPage()
    case .about:         AboutSettingsPage()
    // Sub-pages of Playback — reachable via search but not top-level.
    case .pip:           PiPSettingsPage()
    case .quality:       QualitySettingsPage()
    case .gestures:      GesturesSettingsPage()
    case .skipSegments:  SkipSegmentsSettingsPage()
    case .nextEpisode:   NextEpisodeSettingsPage()
    case .holdSpeed:     HoldSpeedSettingsPage()
    case .audio:         AudioSettingsPage()
    case .streaming:     StreamingSettingsPage()
    case .downloads:     DownloadsSettingsPage()
    case .search:        SearchSettingsPage()
    }
}
