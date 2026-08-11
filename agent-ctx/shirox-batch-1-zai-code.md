# Work Record — Shirox 4-change batch (issues #92/109, #89, #110, #111)

Task ID: shirox-batch-1
Agent: Z.ai Code (single-agent execution; no subagents spawned)
Date: 2026 (current session)
Scope: 4 file-level changes against the existing Shirox Swift/iOS app.

---

## Summary of changes

### 1. `Shirox/Views/Shared/AnimatedSplashView.swift` (issues #92 / #109)
Rebuilt as a polished loading screen.
- Layout: centered `app-logo` icon → `Text("Shirox")` wordmark (44pt heavy rounded) → `Text("Anime · Manga · Tracker")` subtitle → `ProgressView().progressViewStyle(.circular)` spinner.
- Icon resolves via `bundledAppLogo` (`UIImage(named: "app-logo")` with a `Bundle.main.url(forResource:withExtension:)` fallback), then an SF Symbol `play.tv.fill` with a blue/purple gradient background for platforms without the asset.
- Icon is wrapped in a 120×120 `RoundedRectangle` clip with a top-down white gradient stroke and a soft white shadow; `scaledToFit()` preserves the full logo.
- Pulsing: `@State isPulsing` toggles `.scaleEffect(1.0 ↔ 1.05)` via `withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true))` on appear.
- Background: clean `LinearGradient` from `(0.02, 0.02, 0.03)` (near-black) to `(0.10, 0.10, 0.12)` (dark gray), `ignoresSafeArea()`.
- Whole VStack fades in via `@State isVisible` + `withAnimation(.easeOut(duration: 0.6))`.
- Timer is unchanged — still driven by `ShiroxApp.swift` (`Task.sleep(3.5s)` → `showSplash = false`).
- Removed the now-unused `extension UIApplication { var icon: UIImage? }` helper that previously supplied the alternate-icon fallback; nothing in the codebase references it any more (verified with a project-wide grep for `UIApplication.shared.icon` / `extension UIApplication`).

Note: searched `Shirox/Views/SettingsView.swift` for "Splash" / "splash" / "Loading Screen" per the brief — no matches found, so the Appearance-page rename was already done previously (per the brief's "if it was removed previously, skip this" clause). Skipped.

### 2. `Shirox/Views/Shared/ToastSystem.swift` (issue #89)
Replaced the always-rendered-but-opacity-toggled X button with a true conditional `if revealDismiss { Button { } }` branch that drives a `.scale.combined(with: .opacity)` transition. Followed the spec's exact pattern:

```swift
@State private var revealDismiss = false

// In the HStack, the X is conditionally inserted (only when isTop && revealDismiss):
if isTop && revealDismiss {
    Button {
        Haptics.light()
        ToastManager.shared.dismiss(toast.id)
    } label: {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.red)
    }
    .buttonStyle(.plain)
    .transition(.scale.combined(with: .opacity))
}
```

Gesture (the toast NEVER moves — only `revealDismiss` flips, which conditionally inserts/removes the X):
```swift
.gesture(
    DragGesture(minimumDistance: 15)
        .onChanged { value in
            guard isTop else { return }
            withAnimation(.spring(response: 0.3)) {
                revealDismiss = value.translation.width < -15
            }
        }
        .onEnded { value in
            guard isTop else { return }
            if value.translation.width < -100 {
                Haptics.light()
                ToastManager.shared.dismiss(toast.id)
            } else if value.translation.height > 50 {
                Haptics.light()
                ToastManager.shared.dismiss(toast.id)
            } else {
                withAnimation(.spring(response: 0.3)) {
                    revealDismiss = false
                }
            }
        }
)
```

Preserved the existing stacked-visual transforms (`.scaleEffect` / `.offset(y:)` / `.opacity` based on `stackIndex`/`total`) — these are layout-only and never move the toast in response to a drag. Also preserved the tap-to-dismiss behavior, but added a `guard !revealDismiss else { return }` so a tap on the X doesn't also fire the whole-card tap gesture.

Removed the now-unused `horizontalDismissThreshold` / `verticalDismissThreshold` / `dismissRevealThreshold` constants and the old `showDismiss` state.

### 3. `Shirox/Views/HomeView.swift` — FeaturedCard iPhone branch (issue #110)
Root cause: the iPhone branch of `FeaturedCard.body` was using `TVDBPosterImage(media: media)` (default `.poster` type — a portrait 2:3 image), but the iPhone carousel card is roughly square (height = `UIScreen.main.bounds.height * 0.55`, width = full screen width). A portrait image `.scaledToFill`-ing a square card gets cropped hard on the top/bottom, which read as "shortened".

Fix: switched the iPhone branch to `TVDBPosterImage(media: media, type: .fanart)` — landscape banner image, matching the existing iPad branch. The `CachedAsyncImage` infrastructure already applies `.scaledToFill().clipped()` (CachedAsyncImage.swift lines 71-89), so the image now fills the full card edge-to-edge with only the sides lightly cropped for the 100pt horizontal parallax buffer.

Verified:
- Card fills full carousel height — yes (`imageHeight = UIScreen.main.bounds.height * 0.55` is set on the parent `ZStack` via `.frame(height: imageHeight)`).
- Image uses `.scaledToFill()` not `.scaledToFit()` — yes (baked into `CachedAsyncImage`).
- No frame constraint cutting off the image — verified; the inner `.frame(width: geo.size.width + buffer, height: geo.size.height)` is the render size and the outer `.clipped()` clips to the card bounds.
- Image fills entire card area edge-to-edge — yes with `.fanart`.

The `.frame().offset().clipped()` chain inside the GeometryReader now matches the iPad branch's pattern (the iPad branch already had `.clipped()` after `.offset()`; the iPhone branch was missing it).

### 4. `Shirox/Views/HomeView.swift` — Continue Watching sign-in prompt (issue #111)
- Added `@ObservedObject private var anilistAuth = AniListAuthManager.shared` to `HomeView` so the body re-renders when login state changes.
- Replaced the existing `if !continueWatching.items.isEmpty { ContinueWatchingSection(...) }` block with an `if / else if`:
  - `if !continueWatching.items.isEmpty { ContinueWatchingSection(...) }` — unchanged behavior when items exist.
  - `else if !anilistAuth.isLoggedIn { ContinueWatchingSignInPrompt() }` — NEW: shows a sign-in prompt card when the user has no resume items AND is signed out.
- Added a new `private struct ContinueWatchingSignInPrompt: View` (wrapped in `#if os(iOS)` to match the call site, which is also iOS-only). It renders:
  - The same section header as `ContinueWatchingSection` ("Continue Watching" heavy title + 36pt accent rule) so the slot reads as the same section.
  - A single full-width card with:
    - `person.crop.circle.fill` SF Symbol in a tinted circle.
    - "Sign in to continue watching" title + "Connect AniList to sync your progress and pick up where you left off." subtitle.
    - An explicit "Sign in" capsule button.
    - The whole card is wrapped in `NavigationLink { SourcesSettingsPage() } label: { ... }` with `.buttonStyle(HomePressStyle())` so both the card body and the explicit capsule push the Sources settings page.

Behavior: once the user signs in via SourcesSettingsPage and watches something, `ContinueWatchingManager.shared.items` populates and the real `ContinueWatchingSection` replaces this prompt automatically (driven by the `@ObservedObject` bindings on both `anilistAuth` and `continueWatching`).

---

## Files modified
1. `/home/z/my-project/Shirox/Shirox/Views/Shared/AnimatedSplashView.swift` — full rewrite (160 lines)
2. `/home/z/my-project/Shirox/Shirox/Views/Shared/ToastSystem.swift` — `ToastView` body rewritten (276 lines total)
3. `/home/z/my-project/Shirox/Shirox/Views/HomeView.swift` — 3 edits:
   - Added `@ObservedObject anilistAuth` (line ~10)
   - Added `else if !anilistAuth.isLoggedIn { ContinueWatchingSignInPrompt() }` branch (line ~70)
   - iPhone FeaturedCard branch switched from `.poster` to `.fanart` (lines ~724-736)
   - Added new `ContinueWatchingSignInPrompt` struct at end of file (lines ~2593-2686)

## Files NOT modified (verified no action needed)
- `Shirox/Views/SettingsView.swift` — no "Splash" references found in a project-wide grep; the Appearance-page rename was already done previously.

## Verification
- Visual verification of all 4 modified files (read back after edits).
- Project-wide grep confirmed `extension UIApplication` and `UIApplication.shared.icon` are no longer referenced anywhere — safe to have removed from `AnimatedSplashView.swift`.
- Cannot run `xcodebuild` / `swiftc` in this Linux sandbox to do a compile check; relying on careful visual review of syntax + types.
- All references (`AniListAuthManager.shared.isLoggedIn`, `SourcesSettingsPage`, `Color.appAccent`, `HomePressStyle`, `TVDBPosterImage`, `CachedAsyncImage`, `Haptics.light`, `ToastManager.shared.dismiss`, `ContinueWatchingManager.shared`) resolve to existing declarations verified via grep.

## Subagents
None spawned — all 4 changes were small enough to execute inline. Single-agent execution.
