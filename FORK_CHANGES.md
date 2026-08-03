# Fork Changes

Personal fork of [xibrox/Shirox](https://github.com/xibrox/Shirox) with auto sub/dub
stream selection. All modifications are licensed under the upstream PolyForm
Noncommercial License 1.0.0.

## Feature: Auto-pick Sub/Dub

### Problem
When an episode has multiple streams (e.g. `SUB`, `DUB`, `Softsub`, `Hardsub`),
Shirox shows a picker sheet every time, requiring a manual tap before playback starts.

### Solution
A new **Settings → Streaming → "Auto-pick Sub/Dub"** picker with three options:

| Value | Behavior |
|-------|----------|
| Off   | Always show the picker (original behavior) |
| Sub   | Auto-pick a subbed stream — prefer Softsub > generic Sub > Hardsub > first non-dub |
| Dub   | Auto-pick a dubbed stream |

Default: **Sub** — matches the original feature request.

The preference is applied uniformly across **all three** stream-selection code paths:

1. `ModuleStreamPickerView` — the module-based picker used by `AniListDetailView`
2. `DetailViewModel.loadStreams` — the legacy episode-stream picker used by `DetailView`
3. `DetailViewModel.loadDownloadStreams` — the download stream picker

If no stream matches the preference (e.g. preference is `dub` but only sub streams exist),
the picker is shown as a graceful fallback.

### Matching algorithm

`StreamPreferenceMatcher.preferredStream(in:preference:)` is a pure function:

- **Sub preference priority:**
  1. Title contains `softsub` (switchable subtitles — highest quality)
  2. Title contains `sub` but not `dub` (catches `SUB`, `Sub`, `Subbed`, `Hardsub`)
  3. Fallback: first stream whose title does not contain `dub` (handles quality-only
     titles like `1080p`)

- **Dub preference:** first stream whose title contains `dub`

- A title containing both `sub` and `dub` (e.g. `Subbed (English Dub)`) is never
  selected for the sub preference — the `dub` substring disqualifies it.

All matching is case-insensitive.

### Setting persistence

Stored in `UserDefaults` under the key `autoPickSubDub`. Reads default to `.sub` when
the key is unset or holds an invalid value.

## Files modified

| File | Change |
|------|--------|
| `Shirox/Models/StreamResult.swift` | Added `StreamSubDubPreference` enum and `StreamPreferenceMatcher` with pure, testable matching logic |
| `Shirox/Views/ModuleStreamPickerView.swift` | Hooked the matcher into the module stream-picker's `onChangeOf(readyStreams)` |
| `Shirox/ViewModels/DetailViewModel.swift` | Hooked the matcher into `loadStreams` and `loadDownloadStreams` |
| `Shirox/Views/SettingsView.swift` | Added `@AppStorage("autoPickSubDub")` + a `Picker` in the Streaming section |
| `ShiroxTests/AnimeModulePreferenceTests.swift` | Added `StreamPreferenceMatcherTests` with 19 test cases covering off/sub/dub, case-insensitivity, softsub/hardsub priority, edge cases, and persisted-preference reading |
| `.github/workflows/nightly.yaml` | Added SPM caching, a unit-test step that fail-fast blocks the build, SHA-256 checksums alongside the IPA, and test-result upload on failure |

No new files were added to the `Shirox` target or the `ShiroxTests` target — existing
files were extended. This avoids `project.pbxproj` edits, which are fragile to do by
hand and would risk breaking the Xcode project.

## Tests

19 new unit tests in `StreamPreferenceMatcherTests`:

- Off preference: always returns nil (3 tests)
- Sub preference: picks SUB over DUB, prefers Softsub over generic Sub and Hardsub,
  rejects dub-titled streams, falls back to first non-dub, handles quality-only titles,
  case-insensitive, handles all common title variants (8 tests)
- Dub preference: picks DUB over SUB, picks first dub variant, returns nil when only
  sub streams exist, case-insensitive (4 tests)
- Edge cases: empty list, default preference, persisted preference read/write,
  invalid-value fallback (4 tests)

## CI

The nightly workflow now:

1. Resolves and caches Swift Package Manager dependencies (keyed on `Package.resolved`
   + `project.pbxproj` hash)
2. Runs `xcodebuild test` on an iOS Simulator before building the IPA — a red test
   blocks the build and uploads `TestResults.xcresult` for debugging
3. Builds the unsigned IPA via the existing `buildipa.sh`
4. Generates a SHA-256 checksum
5. Uploads the IPA + checksum as both a workflow artifact and to the `beta` GitHub
   Release (so AltStore/SideStore/KSign can pull it via `apps.json`)

## Compatibility

- iOS 15+ (unchanged — no new API requirements)
- macOS Catalyst, tvOS targets unaffected (the new setting is iOS-agnostic and the
  matcher is pure Swift)
- Backward compatible: existing users without the `autoPickSubDub` key get `.sub` by
  default, which is the requested behavior

## License

All modifications are bound by the upstream PolyForm Noncommercial License 1.0.0.
Personal/non-commercial use only.
