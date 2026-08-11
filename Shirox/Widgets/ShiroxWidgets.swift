import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Shirox Widgets & Live Activity (#101, #102)
//
// ──────────────────────────────────────────────────────────────────────────
// ⚠️  THIS FILE IS NOT PART OF THE MAIN APP TARGET.  ⚠️
// ──────────────────────────────────────────────────────────────────────────
// `ShiroxWidgets.swift` must be added to a **Widget Extension** target, not
// the app target. It contains an `@main` `WidgetBundle` (which would clash
// with the app's `@main` if compiled into the app), an `ActivityConfiguration`
// for the Live Activity (#102), and three home-screen widgets (#101):
//
//   • `NextEpisodeWidget`       — shows the next airing episode + countdown.
//   • `ContinueWatchingWidget`  — shows the most recent in-progress title.
//   • `MiniScheduleWidget`      — shows today's airing list.
//
// Setup instructions live in `Shirox/Widgets/README.md` — read that before
// trying to build this file.
//
// The widget extension needs `EpisodeLiveActivity.swift` (from
// `Shirox/Views/Shared/`) added to its Compile Sources phase too, because the
// `ActivityConfiguration` below references `EpisodeLiveActivityAttributes`
// defined there.
// ──────────────────────────────────────────────────────────────────────────

// MARK: - Shared Config

/// Identifiers shared between the app, widget extension, and Live Activity.
/// Keep these in sync with the app's app-group / suite identifier configured
/// in the Xcode target's "Capabilities" tab.
enum ShiroxWidgetConfig {
    /// App Group identifier used to share `UserDefaults` between the app and
    /// the widget extension. Must match the App Group configured on both
    /// targets in Xcode → Signing & Capabilities.
    static let appGroup = "group.com.shirox.app"

    /// UserDefaults suite backed by the App Group. Returns `nil` if the App
    /// Group isn't configured (e.g. running standalone in the Simulator
    /// without entitlements) — callers fall back to a placeholder state.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// UserDefaults key the app writes its `[ContinueWatchingItem]` JSON to
    /// (see `ContinueWatchingManager.persist()`). For the widget to see live
    /// data, `ContinueWatchingManager` must be updated to write to the
    /// App Group suite in addition to `UserDefaults.standard`.
    static let continueWatchingKey = "continueWatchingItems"
}

// MARK: - NextEpisodeWidget (#101)

/// Home-screen widget showing the next episode that will air, with a live
/// countdown. Refreshes every 5 minutes via the timeline; the visible
/// countdown is derived from `airingAt` at render time so it stays smooth
/// without burning timeline reloads.
struct NextEpisodeWidget: Widget {
    let kind: String = "NextEpisodeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextEpisodeProvider()) { entry in
            NextEpisodeEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Next Episode")
        .description("Countdown to the next anime episode airing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextEpisodeEntry: TimelineEntry {
    let date: Date
    let title: String?
    let episode: Int?
    let airingAt: Date?
    let coverImageURL: URL?
    let isLoading: Bool
}

struct NextEpisodeProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEpisodeEntry {
        NextEpisodeEntry(
            date: Date(),
            title: "Frieren: Beyond Journey's End",
            episode: 18,
            airingAt: Date().addingTimeInterval(3 * 3600),
            coverImageURL: nil,
            isLoading: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEpisodeEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEpisodeEntry>) -> Void) {
        Task {
            let entry = await fetchNextEpisode() ?? NextEpisodeEntry(
                date: Date(),
                title: nil,
                episode: nil,
                airingAt: nil,
                coverImageURL: nil,
                isLoading: false
            )
            // Refresh every 5 minutes. The visible countdown is derived at
            // render time from `airingAt`, so we don't need per-second updates.
            let nextRefresh = Date().addingTimeInterval(5 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    /// Minimal direct AniList airing-schedule fetch. Independent of the main
    /// app's `AniListService` (which lives in the app target) so the widget
    /// extension is self-contained.
    private func fetchNextEpisode() async -> NextEpisodeEntry? {
        let endpoint = URL(string: "https://graphql.anilist.co")!
        let now = Int(Date().timeIntervalSince1970)
        let oneDayAhead = now + 86_400

        let query = """
        query ($airingGreater: Int, $airingLess: Int) {
          Page(page: 1, perPage: 1) {
            airingSchedules(airingAt_greater: $airingGreater, airingAt_lesser: $airingLess) {
              episode airingAt
              media {
                id
                title { romaji english native }
                coverImage { large extraLarge }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": ["airingGreater": now, "airingLess": oneDayAhead]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData
        request.timeoutInterval = 12

        struct Response: Decodable {
            let data: Data?
            struct Data: Decodable {
                let Page: Page?
                struct Page: Decodable {
                    let airingSchedules: [Schedule]?
                    struct Schedule: Decodable {
                        let episode: Int
                        let airingAt: Int
                        let media: Media
                        struct Media: Decodable {
                            let id: Int
                            let title: Title?
                            let coverImage: CoverImage?
                            struct Title: Decodable {
                                let romaji: String?
                                let english: String?
                                let native: String?
                                var displayTitle: String { english ?? romaji ?? native ?? "Unknown" }
                            }
                            struct CoverImage: Decodable {
                                let large: String?
                                let extraLarge: String?
                                var best: String? { extraLarge ?? large }
                            }
                        }
                    }
                }
            }
        }

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let schedule = decoded.data?.Page?.airingSchedules?.first
        else { return nil }

        let title = schedule.media.title?.displayTitle
        let coverURLString = schedule.media.coverImage?.best
        return NextEpisodeEntry(
            date: Date(),
            title: title,
            episode: schedule.episode,
            airingAt: Date(timeIntervalSince1970: TimeInterval(schedule.airingAt)),
            coverImageURL: coverURLString.flatMap(URL.init(string:)),
            isLoading: false
        )
    }
}

struct NextEpisodeEntryView: View {
    let entry: NextEpisodeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallLayout
        default:
            mediumLayout
        }
    }

    private var countdownText: String {
        guard let airingAt = entry.airingAt else { return "—" }
        let diff = airingAt.timeIntervalSinceNow
        if diff <= 0 { return "Aired" }
        let total = Int(diff)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(mins)m"
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Next Episode")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(entry.title ?? "Nothing airing soon")
                .font(.caption.weight(.semibold))
                .lineLimit(3)
                .foregroundStyle(.primary)
            if let ep = entry.episode {
                Text("EP \(ep)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(countdownText)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    private var mediumLayout: some View {
        HStack(spacing: 12) {
            if let url = entry.coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 70, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Next Episode")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.title ?? "Nothing airing soon")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                if let ep = entry.episode {
                    Text("Episode \(ep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(countdownText)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
    }
}

// MARK: - ContinueWatchingWidget (#101)

/// Home-screen widget showing the most recent in-progress title. Reads from
/// the shared App Group `UserDefaults` (key `continueWatchingItems`) so the
/// app must write there for the widget to show data.
struct ContinueWatchingWidget: Widget {
    let kind: String = "ContinueWatchingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Continue Watching")
        .description("Jump back into the last episode you were watching.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let title: String?
    let episode: Int?
    let progress: Double?      // 0…1
    let imageURL: URL?
    let deepLinkURL: URL?
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(
            date: Date(),
            title: "One Piece",
            episode: 1098,
            progress: 0.45,
            imageURL: nil,
            deepLinkURL: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        let entry = readMostRecentContinueWatching()
        // Refresh every 15 minutes — Continue Watching changes are infrequent,
        // and the app calls `WidgetCenter.shared.reloadAllTimelines()` after
        // every save when the App Group suite is wired up.
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    /// Reads the most recent Continue Watching item from the shared App Group
    /// `UserDefaults`. Returns a placeholder entry (no title) if no data is
    /// available — e.g. when the App Group isn't configured, or the user has
    /// nothing in progress.
    private func readMostRecentContinueWatching() -> ContinueWatchingEntry {
        guard
            let defaults = ShiroxWidgetConfig.sharedDefaults,
            let data = defaults.data(forKey: ShiroxWidgetConfig.continueWatchingKey)
        else {
            return ContinueWatchingEntry(
                date: Date(), title: nil, episode: nil,
                progress: nil, imageURL: nil, deepLinkURL: nil
            )
        }

        // The stored JSON is `[ContinueWatchingItem]` (see the app target).
        // We decode just the fields the widget needs so the widget extension
        // doesn't have to compile the whole `ContinueWatchingItem` model.
        struct SharedCWItem: Decodable {
            let mediaTitle: String
            let episodeNumber: Int
            let imageUrl: String
            let watchedSeconds: Double
            let totalSeconds: Double
            let aniListID: Int?
        }
        guard let items = try? JSONDecoder().decode([SharedCWItem].self, from: data),
              let mostRecent = items.first
        else {
            return ContinueWatchingEntry(
                date: Date(), title: nil, episode: nil,
                progress: nil, imageURL: nil, deepLinkURL: nil
            )
        }

        let progress = mostRecent.totalSeconds > 0
            ? min(max(mostRecent.watchedSeconds / mostRecent.totalSeconds, 0), 1)
            : nil
        let deepLink = mostRecent.aniListID
            .flatMap { URL(string: "shirox://anime/\($0)") }
        return ContinueWatchingEntry(
            date: Date(),
            title: mostRecent.mediaTitle,
            episode: mostRecent.episodeNumber,
            progress: progress,
            imageURL: URL(string: mostRecent.imageUrl),
            deepLinkURL: deepLink
        )
    }
}

struct ContinueWatchingEntryView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        HStack(spacing: 12) {
            if let url = entry.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary))
                    }
                }
                .frame(width: family == .systemSmall ? 60 : 80, height: family == .systemSmall ? 90 : 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: family == .systemSmall ? 60 : 80, height: family == .systemSmall ? 90 : 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Continue Watching")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.title ?? "Nothing in progress")
                    .font(family == .systemSmall ? .caption.weight(.semibold) : .subheadline.weight(.bold))
                    .lineLimit(2)
                if let ep = entry.episode {
                    Text("Episode \(ep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let progress = entry.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                    Text("\(Int(progress * 100))% watched")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .widgetURL(entry.deepLinkURL)
    }
}

// MARK: - MiniScheduleWidget (#101)

/// Home-screen widget showing today's airing list (up to 3 entries). Performs
/// its own minimal AniList fetch so it doesn't depend on the app's services.
struct MiniScheduleWidget: Widget {
    let kind: String = "MiniScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MiniScheduleProvider()) { entry in
            MiniScheduleEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Today's Schedule")
        .description("Episodes airing today, at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

struct MiniScheduleEntry: TimelineEntry {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let episode: Int
        let airingAt: Date
    }
    let date: Date
    let rows: [Row]
}

struct MiniScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> MiniScheduleEntry {
        MiniScheduleEntry(date: Date(), rows: [
            .init(id: 1, title: "Sample Show A", episode: 5, airingAt: Date().addingTimeInterval(1800)),
            .init(id: 2, title: "Sample Show B", episode: 12, airingAt: Date().addingTimeInterval(7200)),
            .init(id: 3, title: "Sample Show C", episode: 1, airingAt: Date().addingTimeInterval(14400)),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (MiniScheduleEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MiniScheduleEntry>) -> Void) {
        Task {
            let rows = await fetchTodaySchedule()
            let entry = MiniScheduleEntry(date: Date(), rows: rows)
            // Refresh every 15 minutes — the visible countdowns are derived
            // from `airingAt` at render time.
            let nextRefresh = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func fetchTodaySchedule() async -> [MiniScheduleEntry.Row] {
        let endpoint = URL(string: "https://graphql.anilist.co")!
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startTs = Int(startOfToday.timeIntervalSince1970)
        let endTs = startTs + 86_400

        let query = """
        query ($airingGreater: Int, $airingLess: Int) {
          Page(page: 1, perPage: 10) {
            airingSchedules(airingAt_greater: $airingGreater, airingAt_lesser: $airingLess) {
              id episode airingAt
              media { title { romaji english native } }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": ["airingGreater": startTs, "airingLess": endTs]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData
        request.timeoutInterval = 12

        struct Response: Decodable {
            let data: Data?
            struct Data: Decodable {
                let Page: Page?
                struct Page: Decodable {
                    let airingSchedules: [Schedule]?
                    struct Schedule: Decodable {
                        let id: Int
                        let episode: Int
                        let airingAt: Int
                        let media: Media
                        struct Media: Decodable {
                            let title: Title?
                            struct Title: Decodable {
                                let romaji: String?
                                let english: String?
                                let native: String?
                                var displayTitle: String { english ?? romaji ?? native ?? "Unknown" }
                            }
                        }
                    }
                }
            }
        }

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let schedules = decoded.data?.Page?.airingSchedules
        else { return [] }

        // Filter to entries that haven't aired yet (countdown is forward-
        // looking) and cap at 3 for the medium widget.
        let nowTs = Int(Date().timeIntervalSince1970)
        return schedules
            .filter { $0.airingAt >= nowTs }
            .prefix(3)
            .map { schedule in
                MiniScheduleEntry.Row(
                    id: schedule.id,
                    title: schedule.media.title?.displayTitle ?? "Unknown",
                    episode: schedule.episode,
                    airingAt: Date(timeIntervalSince1970: TimeInterval(schedule.airingAt))
                )
            }
    }
}

struct MiniScheduleEntryView: View {
    let entry: MiniScheduleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Airing Today")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if entry.rows.isEmpty {
                Spacer()
                Text("Nothing left to air today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.rows) { row in
                    HStack(spacing: 8) {
                        Text(timeText(for: row.airingAt))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 52, alignment: .leading)
                        Text(row.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("EP \(row.episode)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private func timeText(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - EpisodeLiveActivity (#102)
//
// The `ActivityConfiguration` below is auto-discovered by the system when this
// file is part of a Widget Extension bundle. It provides the UI for the Live
// Activity defined by `EpisodeLiveActivityAttributes` (in
// `Shirox/Views/Shared/EpisodeLiveActivity.swift`).
//
// Two presentations are required:
//   • `DynamicIsland` — the expanded/compact/minimal Dynamic Island UI.
//   • The Lock Screen `ContentView` — the full card shown on the Lock Screen
//     and in the Live Activities list.

@available(iOS 16.1, *)
struct EpisodeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EpisodeLiveActivityAttributes.self) { context in
            // ─────────────────────────────────────────────────────────────
            // Lock Screen presentation
            // ─────────────────────────────────────────────────────────────
            LockScreenLiveActivityView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(Color.black.opacity(0.4))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            // ─────────────────────────────────────────────────────────────
            // Dynamic Island presentation
            // ─────────────────────────────────────────────────────────────
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityCountdownLabel(state: context.state, font: .title3.weight(.bold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.attributes.totalEpisodes != nil {
                        Text("EP \(context.attributes.episode)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("EP \(context.attributes.episode)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.tv.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(context.state.countdownDisplay)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "play.tv.fill")
                    .foregroundStyle(Color.accentColor)
            } compactTrailing: {
                Text(context.state.countdownDisplay)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } minimal: {
                Image(systemName: "play.tv.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .keylineTint(Color.accentColor)
        }
    }
}

@available(iOS 16.1, *)
private struct LockScreenLiveActivityView: View {
    let attributes: EpisodeLiveActivityAttributes
    let state: EpisodeLiveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Cover image — falls back to a system symbol.
            AsyncImage(url: attributes.coverImageURL.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .overlay(Image(systemName: "play.tv.fill").foregroundStyle(.white))
                }
            }
            .frame(width: 64, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Next Episode")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Episode \(attributes.episode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: state.hasAired ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(state.hasAired ? .green : Color.accentColor)
                    Text(state.statusText ?? state.countdownDisplay)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.hasAired ? .green : Color.accentColor)
                }
                if isStale {
                    Text("Update unavailable — open Shirox to refresh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
            LiveActivityCountdownLabel(state: state, font: .title.weight(.bold))
                .frame(maxWidth: 80)
        }
        .padding(12)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityCountdownLabel: View {
    let state: EpisodeLiveActivityAttributes.ContentState
    let font: Font

    var body: some View {
        // `Text(timerInterval:)` renders a live-updating countdown without
        // needing timeline reloads — the system updates it every second while
        // the Live Activity is on screen.
        if state.hasAired {
            Text("Aired")
                .font(font)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        } else {
            let airDate = Date(timeIntervalSince1970: TimeInterval(state.airingAt))
            Text(timerInterval: Date()...airDate, countsDown: true)
                .font(font)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Widget Bundle

@main
struct ShiroxWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextEpisodeWidget()
        ContinueWatchingWidget()
        MiniScheduleWidget()
        if #available(iOS 16.1, *) {
            EpisodeLiveActivity()
        }
    }
}
