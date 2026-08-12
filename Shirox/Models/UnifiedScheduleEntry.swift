import Foundation

// MARK: - ScheduleSource

/// Where a schedule entry originated.
enum ScheduleSource: String, Codable, Hashable, Sendable {
    case anime
    case western
}

// MARK: - ScheduleMode

/// Top-level toggle for the schedule view.
///
/// #124 — Western and Combined were removed from the user-facing schedule; the
/// schedule now only ever shows Anime. The `.western` and `.combined` cases
/// are retained for backwards-compatible decoding of persisted `@AppStorage`
/// values, but are no longer presented in `ScheduleSettingsPage`. `ScheduleSettings`
/// always coerces any persisted non-anime value back to `.anime` on read.
enum ScheduleMode: String, Codable, Hashable, Sendable {
    case anime
    case western
    case combined

    /// The only mode selectable by the user post-#124. Used by
    /// `ScheduleSettingsPage` and the schedule view's load switch.
    static var allCases: [ScheduleMode] { [.anime] }

    var displayName: String {
        switch self {
        case .anime:     return "Anime"
        case .western:   return "Western"
        case .combined:  return "Combined"
        }
    }
}

// MARK: - UnifiedScheduleEntry

/// A single upcoming episode, normalized across anime (AniList) and Western TV (TVMaze) sources.
struct UnifiedScheduleEntry: Identifiable, Hashable, Sendable {

    /// Unique entry id (AniList airing-schedule id for anime; TVMaze episode id for Western).
    let id: Int
    /// Which source the entry came from.
    let source: ScheduleSource
    /// Native media id within its source (AniList media id, or TVMaze show id).
    let sourceMediaId: Int
    /// Cross-reference to the AniList media id when known (`nil` for Western entries).
    let aniListMediaId: Int?
    /// Display title.
    let title: String
    /// Unix timestamp (seconds) of the air/release time.
    let airingAt: Int
    /// Episode number.
    let episode: Int
    /// Season number, when known (`nil` for anime — AniList airing schedules don't carry one).
    let season: Int?
    /// Best-available cover image URL.
    let coverImage: String?
    /// Format label (e.g. "TV", "MOVIE", "OVA").
    let format: String?
    /// `true` for streaming-platform releases (Netflix drops, etc.); `false` otherwise.
    let isStreamingRelease: Bool
    /// Genre tags when known (`nil` for Western entries; populated from AniList for anime).
    /// Surfaced by `ScheduleDetailView` (#107) — kept optional so Western entries decode
    /// without it and older call sites don't need to supply a value.
    let genres: [String]?
    /// Popularity score used for ordering within a day. For AniList entries this is
    /// the media's `averageScore` (AniList doesn't expose `popularity` in our airing
    /// schedule query, so the average score serves as a popularity proxy). Western
    /// entries have no comparable metric from TVMaze, so they default to `0`.
    let popularity: Int

    // MARK: Init from AniList

    init(item: AniListAiringScheduleItem) {
        self.source = .anime
        self.id = item.id
        self.sourceMediaId = item.media.id
        self.aniListMediaId = item.media.id
        self.title = item.media.title.displayTitle
        self.airingAt = item.airingAt
        self.episode = item.episode
        self.season = nil
        self.coverImage = item.media.coverImage.best
        self.format = item.media.format
        self.isStreamingRelease = false
        self.genres = item.media.genres
        self.popularity = item.media.averageScore ?? 0
    }

    // MARK: Init from Western

    init(entry: WesternScheduleEntry) {
        self.source = .western
        self.id = entry.id
        self.sourceMediaId = entry.showId
        self.aniListMediaId = nil
        self.title = entry.showName
        self.airingAt = entry.airTimestamp ?? 0
        self.episode = entry.episode
        self.season = entry.season
        self.coverImage = entry.coverImage
        self.format = "TV"
        self.isStreamingRelease = entry.isStreamingRelease
        // TVMaze's schedule endpoint doesn't expose genres, so Western entries
        // carry `nil` here — `ScheduleDetailView` hides the genre row when empty.
        self.genres = nil
        // TVMaze doesn't expose a usable popularity/rating on the schedule endpoint,
        // so Western entries sort neutrally (popularity = 0).
        self.popularity = 0
    }

    // MARK: Computed

    /// Human-readable countdown (e.g. "in 2d 5h", "in 3h 20m", "in 12m", "aired 2h ago").
    var countdownDisplay: String {
        let now = Int(Date().timeIntervalSince1970)
        let diff = airingAt - now
        if diff <= 0 {
            let ago = -diff
            let hours = ago / 3600
            if hours > 0 { return "aired \(hours)h ago" }
            let mins = ago / 60
            if mins > 0 { return "aired \(mins)m ago" }
            return "aired just now"
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(mins)m"
    }

    /// Full-granularity countdown including seconds (e.g. "in 3d 5h 12m 30s",
    /// "in 2h 14m 45s", "in 8m 3s", "aired 2h 14m 5s ago"). Used by
    /// `ScheduleDetailView` (#107 extension) where a 1-second `TimelineView`
    /// keeps the display live. Past-tense variants include seconds too so the
    /// detail view's big timer is always consistent in granularity.
    var countdownDisplayWithSeconds: String {
        let now = Int(Date().timeIntervalSince1970)
        let diff = airingAt - now
        if diff <= 0 {
            let ago = -diff
            let days = ago / 86400
            let hours = (ago % 86400) / 3600
            let mins = (ago % 3600) / 60
            let secs = ago % 60
            if days > 0 { return "aired \(days)d \(hours)h \(mins)m \(secs)s ago" }
            if hours > 0 { return "aired \(hours)h \(mins)m \(secs)s ago" }
            if mins > 0 { return "aired \(mins)m \(secs)s ago" }
            return "aired \(secs)s ago"
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        let secs = diff % 60
        if days > 0 { return "in \(days)d \(hours)h \(mins)m \(secs)s" }
        if hours > 0 { return "in \(hours)h \(mins)m \(secs)s" }
        if mins > 0 { return "in \(mins)m \(secs)s" }
        return "in \(secs)s"
    }

    /// Absolute air date (e.g. "Apr 15, 2025 3:00 PM").
    var airDateDisplay: String {
        let date = Date(timeIntervalSince1970: TimeInterval(airingAt))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Compact episode badge text (e.g. "EP 12" or "S2 EP 4").
    var episodeBadge: String {
        if let season = season, season > 0 {
            return "S\(season) EP \(episode)"
        }
        return "EP \(episode)"
    }
}

// MARK: - ScheduleDayBucket

/// A day-grouped bucket of unified schedule entries, used to render the schedule as sections.
struct ScheduleDayBucket: Identifiable, Hashable, Sendable {
    /// Start-of-day date for this bucket (timezone-aware).
    let date: Date
    /// Entries airing on this day, sorted by popularity (desc) then air time (asc).
    let entries: [UnifiedScheduleEntry]

    var id: TimeInterval { date.timeIntervalSince1970 }

    /// Full title (e.g. "Monday, April 15, 2025").
    var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }

    /// Short title with relative hints (e.g. "Today", "Tomorrow", "Tue, Apr 16").
    var shortTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    /// Buckets the supplied entries by their local air day, sorted by date ascending.
    static func build(from entries: [UnifiedScheduleEntry]) -> [ScheduleDayBucket] {
        let calendar = Calendar.current
        var grouped: [Date: [UnifiedScheduleEntry]] = [:]

        for entry in entries {
            let airDate = Date(timeIntervalSince1970: TimeInterval(entry.airingAt))
            let dayStart = calendar.startOfDay(for: airDate)
            grouped[dayStart, default: []].append(entry)
        }

        return grouped.keys.sorted().map { day in
            let dayEntries = grouped[day] ?? []
            let sorted = dayEntries.sorted {
                if $0.popularity != $1.popularity {
                    return $0.popularity > $1.popularity
                }
                return $0.airingAt < $1.airingAt
            }
            return ScheduleDayBucket(date: day, entries: sorted)
        }
    }
}
