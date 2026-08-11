import Foundation
import ActivityKit
import SwiftUI

// MARK: - EpisodeLiveActivity (#102)
//
// Live Activity for an upcoming anime episode airing. Shows a countdown to the
// next episode on the Lock Screen and in the Dynamic Island while the user is
// away from the app.
//
// ──────────────────────────────────────────────────────────────────────────
// ⚠️  THIS FILE REQUIRES XCODE CONFIGURATION TO FUNCTION AT RUNTIME  ⚠️
// ──────────────────────────────────────────────────────────────────────────
// Live Activities need:
//   1. The `NSSupportsLiveActivities` key set to `YES` in the app's Info.plist
//      (see the README in `Shirox/Widgets/`).
//   2. A Widget Extension target that bundles the `ActivityConfiguration` UI
//      (see `Shirox/Widgets/ShiroxWidgets.swift`).
//
// The code in this file compiles into the main app target on iOS 16.1+ so the
// app can start/end Live Activities. The UI rendering lives in the widget
// extension (which references these same `ActivityAttributes`), so when you
// add the widget extension target you must ALSO add this file to that target's
// Compile Sources phase so both sides see the same `Codable` shape.
// ──────────────────────────────────────────────────────────────────────────

#if os(iOS)
@available(iOS 16.2, *)

// MARK: - ActivityAttributes

/// Shared state for the "next episode airing" Live Activity.
///
/// `ActivityAttributes` carries the *static* identity of the activity (the
/// values that don't change while it's running — show title, media id, episode
/// number, total episodes, cover image). The `ContentState` nested type
/// carries the *dynamic* values that update over the activity's lifetime —
/// the air timestamp (which drives the visible countdown) and an optional
/// status message.
@available(iOS 16.1, *)
struct EpisodeLiveActivityAttributes: ActivityAttributes {
    /// Static, immutable identity of the activity.
    let mediaId: Int
    let title: String
    let episode: Int
    /// Total episode count for the show, when known (`nil` for ongoing series).
    let totalEpisodes: Int?
    /// Best-available cover image URL string. Loaded asynchronously by the
    /// widget's `ActivityConfiguration` view.
    let coverImageURL: String?

    public struct ContentState: Codable, Hashable {
        /// Unix timestamp (seconds) the episode airs at. Drives the countdown
        /// shown on the Lock Screen / Dynamic Island.
        let airingAt: Int
        /// Optional human-readable status (e.g. "Airing now", "Aired").
        let statusText: String?
    }
}

// MARK: - EpisodeLiveActivityManager

/// Singleton wrapper around `ActivityKit` that starts, updates, and ends the
/// "next episode airing" Live Activity.
///
/// Mirrors the lifecycle pattern of `EpisodeNotificationManager`: a single
/// `Activity<EpisodeLiveActivityAttributes>` token is held while the activity
/// is live; `start`/`update`/`end` operate on that token. The activity is
/// ended (rather than just dismissed) so it leaves the Lock Screen cleanly.
///
/// **Authorization:** `ActivityAuthorizationInfo().areActivitiesEnabled` must
/// return `true` before `start` is called. The caller is responsible for
/// gating UI on that (e.g. only showing a "Start Live Activity" button when
/// enabled). `requestAuthorization()` is *not* invoked here because, unlike
/// notifications, Live Activities don't have a separate authorization prompt
/// — the user enables them per-app in Settings.
@available(iOS 16.1, *)
final class EpisodeLiveActivityManager: ObservableObject {

    nonisolated(unsafe) static let shared = EpisodeLiveActivityManager()

    /// The currently-live activity, if any. `nil` when no activity is running.
    @Published private(set) var currentActivity: Activity<EpisodeLiveActivityAttributes>?

    private init() {}

    // MARK: - Authorization

    /// Whether Live Activities are available and enabled for this app on this
    /// device. `false` on the Simulator (Live Activities aren't supported
    /// there) and when the user has disabled them in Settings.
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Start

    /// Starts (or replaces) the "next episode airing" Live Activity.
    ///
    /// - Parameters:
    ///   - mediaId:        AniList media id; carried in the attributes for
    ///                     deep-linking from the activity's tap action.
    ///   - title:          Show title shown on the Lock Screen.
    ///   - episode:        Episode number that's about to air.
    ///   - totalEpisodes:  Optional total episode count (for "EP 5 of 12" display).
    ///   - airingAt:       Unix timestamp (seconds) of the air time.
    ///   - coverImageURL:  Optional cover image URL string.
    ///   - statusText:     Optional initial status (usually `nil`; the widget
    ///                     derives "Airs in X" from `airingAt`).
    @discardableResult
    func start(mediaId: Int,
               title: String,
               episode: Int,
               totalEpisodes: Int?,
               airingAt: Int,
               coverImageURL: String?,
               statusText: String? = nil) async -> Bool {
        guard areActivitiesEnabled else {
            Logger.shared.log("[EpisodeLiveActivity] Not enabled — skipping start", type: "Debug")
            return false
        }

        // End any existing activity first so we never have two running at once
        // (ActivityKit will otherwise throw `.activityAlreadyActive`).
        if let existing = currentActivity {
            await endActivity(existing)
        }

        let attributes = EpisodeLiveActivityAttributes(
            mediaId: mediaId,
            title: title,
            episode: episode,
            totalEpisodes: totalEpisodes,
            coverImageURL: coverImageURL
        )
        let state = EpisodeLiveActivityAttributes.ContentState(
            airingAt: airingAt,
            statusText: statusText
        )

        // Stale date — far enough in the future to keep the activity alive
        // until the next update/end. ActivityKit requires a non-nil
        // `staleDate`; we set it to a few hours past the air time so the
        // system can mark it stale if the app never updates it.
        let staleDate = Date(timeIntervalSince1970: TimeInterval(airingAt)).addingTimeInterval(6 * 3600)

        let content = ActivityContent(
            state: state,
            staleDate: staleDate
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            await MainActor.run { self.currentActivity = activity }
            Logger.shared.log(
                "[EpisodeLiveActivity] Started — \(title) EP\(episode) airs \(Date(timeIntervalSince1970: TimeInterval(airingAt)))",
                type: "Debug"
            )
            return true
        } catch {
            Logger.shared.log("[EpisodeLiveActivity] Failed to start: \(error)", type: "Error")
            return false
        }
    }

    // MARK: - Update

    /// Updates the dynamic state of the running activity (e.g. a corrected
    /// air time, or a new status message like "Airing now").
    func update(airingAt: Int, statusText: String? = nil) async {
        guard let activity = currentActivity else { return }
        let state = EpisodeLiveActivityAttributes.ContentState(
            airingAt: airingAt,
            statusText: statusText
        )
        let staleDate = Date(timeIntervalSince1970: TimeInterval(airingAt)).addingTimeInterval(6 * 3600)
        let content = ActivityContent(state: state, staleDate: staleDate)
        await activity.update(content)
        Logger.shared.log("[EpisodeLiveActivity] Updated — airingAt=\(airingAt)", type: "Debug")
    }

    // MARK: - End

    /// Ends the current activity, if any. Pass `dismissImmediately = true` to
    /// remove it from the Lock Screen right away; the default leaves it in the
    /// ended state for the system's usual dismissal window.
    func end(dismissImmediately: Bool = false) async {
        guard let activity = currentActivity else { return }
        await endActivity(activity, dismissImmediately: dismissImmediately)
        await MainActor.run { self.currentActivity = nil }
    }

    /// Ends ALL activities of this type that the app may have started
    /// (including ones orphaned by a previous launch). Useful on app launch
    /// to clean up stale activities before starting a fresh one.
    func endAll() async {
        for activity in Activity<EpisodeLiveActivityAttributes>.activities {
            await endActivity(activity, dismissImmediately: true)
        }
        await MainActor.run { self.currentActivity = nil }
    }

    // MARK: - Private

    private func endActivity(_ activity: Activity<EpisodeLiveActivityAttributes>,
                             dismissImmediately: Bool = false) async {
        let finalState = EpisodeLiveActivityAttributes.ContentState(
            airingAt: Int(Date().timeIntervalSince1970),
            statusText: "Aired"
        )
        let content = ActivityContent(
            state: finalState,
            staleDate: Date().addingTimeInterval(60 * 60)
        )
        await activity.end(content, dismissalPolicy: dismissImmediately ? .immediate : .default)
        Logger.shared.log("[EpisodeLiveActivity] Ended", type: "Debug")
    }
}

// MARK: - Convenience Countdown Helpers

@available(iOS 16.1, *)
extension EpisodeLiveActivityAttributes.ContentState {

    /// Human-readable countdown (e.g. "in 2d 5h", "in 3h 20m", "in 12m",
    /// "aired 2h ago"). Used by both the widget's `ActivityConfiguration`
    /// view and any in-app Live Activity preview.
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

    /// `true` when the air time has passed. Drives the widget's switch from
    /// "Airs in X" → "Aired" styling.
    var hasAired: Bool {
        airingAt <= Int(Date().timeIntervalSince1970)
    }
}

#endif
