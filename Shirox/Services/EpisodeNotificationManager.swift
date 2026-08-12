import Foundation
import UserNotifications
import Combine

// MARK: - Notification.Name

extension Notification.Name {
    /// Posted when the user taps an episode-airing notification.
    /// The `object` is the AniList `mediaId` (as `Int`) to open.
    static let openAnimeDetail = Notification.Name("OpenAnimeDetail")
}

// MARK: - EpisodeNotificationManager

/// Schedules local notifications for anime episode airings via `UNUserNotificationCenter`.
///
/// Notification identifiers follow the format `"airing-\(scheduleId)"` so the manager can
/// reliably distinguish its own requests from any other notifications the app (or system)
/// may schedule, and so they can be cancelled / replaced per-schedule.
final class EpisodeNotificationManager: NSObject, ObservableObject {

    // MARK: - Singleton

    nonisolated(unsafe) static let shared = EpisodeNotificationManager()

    // MARK: - Lead Time

    /// How far ahead of the actual airtime the notification should fire.
    enum LeadTime: String, CaseIterable, Sendable {
        case atAirtime        // fires exactly at airingAt
        case fifteenMinutes   // "15min"
        case oneHour          // "1hour"
        case oneDay           // "1day"

        /// Human-readable label shown in Settings.
        var displayName: String {
            switch self {
            case .atAirtime:      return "At airtime"
            case .fifteenMinutes: return "15 minutes before"
            case .oneHour:        return "1 hour before"
            case .oneDay:         return "1 day before"
            }
        }

        /// Lead time in seconds (subtracted from `airingAt` to compute the fire date).
        var seconds: Int {
            switch self {
            case .atAirtime:      return 0
            case .fifteenMinutes: return 15 * 60
            case .oneHour:        return 60 * 60
            case .oneDay:         return 24 * 60 * 60
            }
        }

        /// Reads the user's chosen lead time from `UserDefaults` (key:
        /// `episodeNotificationLeadTime`), falling back to `.atAirtime`.
        static var current: LeadTime {
            let raw = UserDefaults.standard.string(forKey: "episodeNotificationLeadTime") ?? LeadTime.atAirtime.rawValue
            return LeadTime(rawValue: raw) ?? .atAirtime
        }

        /// Persists a new lead time to `UserDefaults`.
        static func set(_ value: LeadTime) {
            UserDefaults.standard.set(value.rawValue, forKey: "episodeNotificationLeadTime")
        }
    }

    // MARK: - ID Helpers

    /// Prefix used for every notification identifier this manager creates.
    static let notificationIDPrefix = "airing-"

    /// Builds the notification identifier for a given schedule id.
    static func notificationID(for scheduleId: Int) -> String {
        "\(notificationIDPrefix)\(scheduleId)"
    }

    /// The current lead time (read fresh from `UserDefaults` so settings changes take effect immediately).
    var leadTime: LeadTime { LeadTime.current }

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    /// Requests notification authorization from the user. Returns `true` if authorized.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if !granted {
                Logger.shared.log("[EpisodeNotification] User declined notification authorization", type: "Debug")
            }
            return granted
        } catch {
            Logger.shared.log("[EpisodeNotification] Authorization request failed: \(error)", type: "Error")
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules a local notification for a single episode airing.
    ///
    /// - Parameters:
    ///   - scheduleId: The AniList airing-schedule id (used to build the notification id and to cancel later).
    ///   - mediaId:    The AniList media id; passed back via `Notification.Name.openAnimeDetail` on tap.
    ///   - title:      The show title shown as the notification title.
    ///   - episode:    The episode number.
    ///   - airingAt:   Unix timestamp (seconds) of the exact airing time.
    /// - Returns: `true` if the notification was scheduled, `false` if it was skipped (e.g. fire time
    ///   already in the past) or failed.
    @discardableResult
    enum ScheduleResult {
        case success
        case alreadyAired
        case phoneNotificationsDisabled
        case permissionDenied
        case failed(String)
    }

    func schedule(scheduleId: Int,
                  mediaId: Int,
                  title: String,
                  episode: Int,
                  airingAt: Int) async -> ScheduleResult {
        guard UserDefaults.standard.object(forKey: "phoneNotificationsEnabled") as? Bool ?? true else {
            return .phoneNotificationsDisabled
        }
        let lead = leadTime
        var fireTimestamp = TimeInterval(airingAt) - TimeInterval(lead.seconds)

        if fireTimestamp <= Date().timeIntervalSince1970 {
            fireTimestamp = TimeInterval(airingAt)
        }

        let fireDate = Date(timeIntervalSince1970: fireTimestamp)
        guard fireDate > Date() else {
            return .alreadyAired
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "Episode \(episode)"
        switch lead {
        case .atAirtime:
            content.body = "Is airing now"
        case .fifteenMinutes:
            content.body = "Airs in 15 minutes"
        case .oneHour:
            content.body = "Airs in 1 hour"
        case .oneDay:
            content.body = "Airs in 1 day"
        }
        content.sound = .default
        content.userInfo = [
            "scheduleId": scheduleId,
            "mediaId": mediaId,
            "episode": episode,
            "airingAt": airingAt
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: EpisodeNotificationManager.notificationID(for: scheduleId),
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Cancellation

    /// Cancels both the pending request and any already-delivered notification for the given schedule id.
    func cancel(scheduleId: Int) {
        let id = EpisodeNotificationManager.notificationID(for: scheduleId)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Returns the set of schedule ids (the numeric suffix of `"airing-<id>"`) currently pending.
    func scheduledScheduleIds() async -> Set<Int> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        var ids = Set<Int>()
        for request in requests {
            guard request.identifier.hasPrefix(EpisodeNotificationManager.notificationIDPrefix) else { continue }
            let suffix = request.identifier.dropFirst(EpisodeNotificationManager.notificationIDPrefix.count)
            if let id = Int(suffix) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Removes every notification this manager has scheduled (pending + delivered).
    func removeAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(EpisodeNotificationManager.notificationIDPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Number of episode-airing notifications currently pending.
    func pendingCount() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.filter { $0.identifier.hasPrefix(EpisodeNotificationManager.notificationIDPrefix) }.count
    }

    // MARK: - Delegate

    /// Sets this manager as the `UNUserNotificationCenter` delegate so foreground presentation
    /// and tap responses are handled here. Call once early in app launch (e.g. from `AppDelegate`).
    func registerDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Extracts the `mediaId` from a notification's `userInfo` payload.
    /// Returns `nil` if the payload doesn't carry one (or the value can't be coerced to `Int`).
    static func handleNotificationTap(userInfo: [AnyHashable: Any]) -> Int? {
        if let v = userInfo["mediaId"] as? Int { return v }
        if let v = userInfo["mediaId"] as? Int64 { return Int(v) }
        if let v = userInfo["mediaId"] as? NSNumber { return v.intValue }
        if let v = userInfo["mediaId"] as? String, let n = Int(v) { return n }
        return nil
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension EpisodeNotificationManager: UNUserNotificationCenterDelegate {

    /// Called when the user opens (taps) a notification. Posts `Notification.Name.openAnimeDetail`
    /// with the `mediaId` as the object so the UI can deep-link to the anime detail view.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let mediaId = EpisodeNotificationManager.handleNotificationTap(userInfo: userInfo) {
            NotificationCenter.default.post(name: .openAnimeDetail, object: mediaId)
        }
        completionHandler()
    }

    /// Foreground presentation: still show a banner + play the sound while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
