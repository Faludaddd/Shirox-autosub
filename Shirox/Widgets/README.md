# Shirox Widgets & Live Activities — Setup Guide

This directory contains the **reference implementation** for three Home Screen
widgets (#101) and the Episode Live Activity (#102). The Swift files here are
**not** part of the main app target — they belong in a separate **Widget
Extension** target that Xcode builds and embeds into the app bundle.

> ⚠️ These files compile cleanly once the widget extension target exists.
> Until then, Xcode will not build them, which is expected.

## Current state — why CI does not build the widget extension

The repository ships **no Widget Extension target** in `Shirox.xcodeproj`.
This is deliberate. The IPA build (`buildipa.sh`) runs in CI with
`CODE_SIGNING_ALLOWED=NO`, and a Widget Extension target would require:

  * a second `CODE_SIGN_ENTITLEMENTS` file (App Group) on both the app and
    the extension target,
  * embedding the extension's `.appex` into the host `.app`,
  * an extra `xcodebuild` target whose build settings must stay in sync
    across iOS/macOS/tvOS/Catalyst schemes,

…any one of which is enough to break the 100+ run green CI build. Instead,
the project follows the **CI-safe approach**:

  * `Shirox/Views/Shared/EpisodeLiveActivity.swift` (the
    `EpisodeLiveActivityAttributes` `Codable` shape +
    `EpisodeLiveActivityManager` that calls `ActivityKit`) **is** part of the
    main app target, guarded by `#if os(iOS)` and `@available(iOS 16.2, *)`.
    That is all the app needs to *start*, *update*, and *end* Live Activities.
  * `ShiroxWidgets.swift` (the `@main` `WidgetBundle` + the three widgets +
    the `ActivityConfiguration` UI) lives in this directory but is **not** in
    any target. It compiles only after the developer follows the steps below.
  * `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates`
    are already set in `Shirox/Info.plist`, so the runtime capability is
    advertised as soon as the app is installed.

The template files in this directory exist so that the manual Xcode steps
below are quick and unambiguous — they're not consumed by CI.

## Files

| File | Purpose | Target membership |
|------|---------|-------------------|
| `ShiroxWidgets.swift` | `@main` `WidgetBundle`, the 3 widgets, and the `ActivityConfiguration` for the Live Activity. | **Widget Extension only.** |
| `WidgetExtension-Info.plist` | Template `Info.plist` for the Widget Extension target (sets `NSExtensionPointIdentifier = com.apple.widgetkit-extension`). Point the new target's `INFOPLIST_FILE` build setting here. | **Widget Extension only** (template, not yet referenced by any target). |
| `Widget.entitlements` | Template entitlements for the Widget Extension target — declares the `group.com.shirox.app` App Group. Point the new target's `CODE_SIGN_ENTITLEMENTS` build setting here. | **Widget Extension only** (template, not yet referenced by any target). |
| `../Shirox.entitlements` | Template entitlements for the **main app** target — declares the same `group.com.shirox.app` App Group so the app and extension share `UserDefaults`. | **Main app only** (template, not yet referenced by any target). |
| `../Views/Shared/EpisodeLiveActivity.swift` | `EpisodeLiveActivityAttributes` + `EpisodeLiveActivityManager` (start/update/end Live Activities from the app). | **Both** the app target (so the app can start activities) **and** the Widget Extension (so the widget can render them). |
| `../Views/Shared/CustomRefreshControl.swift` | Custom pull-to-refresh overlay (#98). | App target only. (Unrelated to widgets, but tracked alongside this issue batch.) |

## Step 1 — Add a Widget Extension target

1. In Xcode, **File → New → Target…**
2. Pick the **Widget Extension** template (iOS → Application Extension).
3. Configure:
   - **Product name:** `ShiroxWidgets`
   - **Organization Identifier:** match the app (`com.shirox`)
   - **Bundle Identifier:** `com.shirox.app.widgets`
   - **Language:** Swift
   - **Include Configuration App Intent:** ✅ (recommended)
   - **Embed in Application:** `Shirox_iOS`
4. Finish. Xcode creates:
   - A new target `ShiroxWidgetsExtension`
   - A boilerplate `.swift` file (delete its contents)
   - A separate `Info.plist` for the extension
5. **(Optional, recommended) Use the template Info.plist.** In the new
   target's Build Settings, set `Info.plist File` (`INFOPLIST_FILE`) to
   `Shirox/Widgets/WidgetExtension-Info.plist` and delete the boilerplate
   `Info.plist` Xcode generated in the target's group. The template is
   pre-configured with the `com.apple.widgetkit-extension` extension point.
6. **(Optional, recommended) Use the template entitlements.** In the new
   target's Build Settings, set `Code Signing Entitlements`
   (`CODE_SIGN_ENTITLEMENTS`) to `Shirox/Widgets/Widget.entitlements`.
   This admits the extension to the `group.com.shirox.app` App Group so
   `ContinueWatchingWidget` can read shared `UserDefaults`.

## Step 2 — Replace the boilerplate with our widget code

1. **Delete** the auto-generated widget file Xcode just created (e.g.
   `ShiroxWidgets.swift` inside the new group).
2. **Add** the existing `Shirox/Shirox/Widgets/ShiroxWidgets.swift` to the
   Widget Extension target:
   - File Inspector → **Target Membership** → check `ShiroxWidgetsExtension`.
   - Make sure it is **NOT** checked for `Shirox_iOS` / `Shirox_macOS` /
     `Shirox_tvOS` — the `@main` `WidgetBundle` would clash with the app's
     `@main`.
3. **Add** `Shirox/Shirox/Views/Shared/EpisodeLiveActivity.swift` to **both**
   the Widget Extension target **and** the existing app target
   (`Shirox_iOS`). Both sides must see the same `EpisodeLiveActivityAttributes`
   `Codable` shape.

## Step 3 — Enable the Live Activity capability

Live Activities require `NSSupportsLiveActivities = YES` in the **app's**
`Info.plist` (not the widget's). This is **already set** in
`Shirox/Shirox/Info.plist` — no action needed. The relevant keys are:

```xml
<key>NSSupportsLiveActivities</key>
<true/>
<key>NSSupportsLiveActivitiesFrequentUpdates</key>
<true/>
```

If you're starting from a fork that doesn't have them, add both to
`Shirox/Shirox/Info.plist`.

## Step 4 — Configure an App Group (for Continue Watching widget)

`ContinueWatchingWidget` reads the most-recent in-progress item from a shared
`UserDefaults` suite so the widget extension (a separate process) can see
what the app wrote.

The App Group identifier is `group.com.shirox.app` and is already declared
in **both** template entitlements files:

  * `Shirox/Widgets/Widget.entitlements` — for the Widget Extension target.
  * `Shirox/Shirox.entitlements` — for the main app target.

To activate them:

1. In Xcode, select the **app target** → **Build Settings** → set
   `Code Signing Entitlements` to `Shirox/Shirox.entitlements`.
2. In Xcode, select the **app target** → **Signing & Capabilities** →
   **+ Capability** → **App Groups** → add `group.com.shirox.app`.
   (Xcode will keep the entry in `Shirox.entitlements` in sync.)
3. Repeat for the **Widget Extension** target using
   `Shirox/Widgets/Widget.entitlements` and the same App Group ID.
4. Update `ContinueWatchingManager.persist()` and `load()` in
   `Shirox/Services/ContinueWatchingManager.swift` to write to **both**
   `UserDefaults.standard` **and** the shared suite:

   ```swift
   private static let sharedSuite = UserDefaults(suiteName: "group.com.shirox.app")

   private func persist() {
       // ... existing encode ...
       UserDefaults.standard.set(data, forKey: Keys.storage)
       Self.sharedSuite?.set(data, forKey: Keys.storage)
       // also persist watchedKeys / watchedHrefKeys if the widget ever needs them
   }
   ```
5. After every save, ping WidgetKit so the widget refreshes immediately:

   ```swift
   import WidgetKit
   // ... at end of persist() ...
   WidgetCenter.shared.reloadAllTimelines()
   ```

Until this is wired up, `ContinueWatchingWidget` shows the placeholder "Nothing
in progress" state — `NextEpisodeWidget` and `MiniScheduleWidget` work without
an App Group because they fetch directly from AniList.

> ⚠️ **CI note.** `buildipa.sh` runs with `CODE_SIGNING_ALLOWED=NO`, so
> `Shirox/Shirox.entitlements` is **not** referenced by the iOS target in
> `Shirox.xcodeproj` today. Don't wire it into `buildipa.sh` without also
> switching the build to ad-hoc signing — otherwise the entitlement will be
> ignored (no functional harm) but CI will emit a warning.

## Step 5 — (Optional) Wire up Live Activity start triggers

The Live Activity is started by the app via `EpisodeLiveActivityManager`. Good
trigger points in the existing code:

- **Schedule page** — when the user taps the bell on an entry to enable
  notifications, also start a Live Activity for the *next* airing entry.
  In `HomeView.swift`'s `ScheduleView.toggleNotification(for:)`:
  ```swift
  if #available(iOS 16.1, *), EpisodeLiveActivityManager.shared.areActivitiesEnabled {
      _ = await EpisodeLiveActivityManager.shared.start(
          mediaId: entry.aniListMediaId ?? 0,
          title: entry.title,
          episode: entry.episode,
          totalEpisodes: nil,
          airingAt: entry.airingAt,
          coverImageURL: entry.coverImage
      )
  }
  ```
- **App launch** — call `EpisodeLiveActivityManager.shared.endAll()` on launch
  to clear any stale activities left over from a previous run.
- **Settings** — add a "Live Activities" toggle under Notifications settings;
  gate the start call on it.

The manager is already guarded by `#if os(iOS)` and `@available(iOS 16.1, *)`
so it compiles on the iOS 15 deployment target without warnings — calls to it
just need the same `if #available(iOS 16.1, *)` guard at the call site.

## Step 6 — Build & run

1. Select the **`Shirox_iOS`** scheme (the widget extension is embedded
   automatically).
2. Build to a real device or the Simulator.
3. Long-press the Home Screen → **+** → search "Shirox" → add any of the
   three widgets.
4. For Live Activities: trigger one from the Schedule page (after wiring up
   step 5), then lock the device to see the Lock Screen presentation. On
   iPhone 14 Pro+, swipe to the Dynamic Island to see the compact/expanded
   presentations.

## Known limitations

- **`NextEpisodeWidget` / `MiniScheduleWidget`** do their own minimal AniList
  GraphQL fetch because `AniListService` lives in the app target and can't be
  directly imported. If you'd rather share data through the App Group, mirror
  the schedule entries to the shared `UserDefaults` from `ScheduleView.load()`
  and have the widget read from there.
- **Live Activities on Simulator** — `ActivityKit.request` returns
  `.activityNotEnabled` on the Simulator for most OS versions; test on a
  physical device.
- **`ContinueWatchingItem` model** — the widget decodes a minimal subset of
  fields via a private `SharedCWItem` struct to avoid compiling the whole
  model (and its `StoredStream` / `SubtitleTrack` dependencies) into the
  widget extension. If you add fields to `ContinueWatchingItem` that the
  widget should display, extend `SharedCWItem` in `ShiroxWidgets.swift` to
  match.
