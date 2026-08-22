import SwiftUI

/// Update Log page — replaces the old "Updates" tab in Settings.
/// Shows a clean, organized log of everything that has been Added,
/// Fixed, Changed, and Improved in the app. Each entry is grouped by
/// version and category so users can easily find what changed.
struct UpdateLogPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(logEntries, id: \.version) { entry in
                    versionSection(entry)
                }
                Spacer().frame(height: 32)
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Update Log")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder
    private func versionSection(_ entry: UpdateLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Version header
            HStack(spacing: 8) {
                Text("v\(entry.version)")
                    .font(.title2.weight(.bold))
                Text(entry.date)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            // Categories
            if !entry.added.isEmpty {
                categorySection(title: "Added", icon: "plus.circle.fill", color: .green, items: entry.added)
            }
            if !entry.fixed.isEmpty {
                categorySection(title: "Fixed", icon: "checkmark.circle.fill", color: .blue, items: entry.fixed)
            }
            if !entry.changed.isEmpty {
                categorySection(title: "Changed", icon: "arrow.triangle.2.circlepath.circle.fill", color: .orange, items: entry.changed)
            }
            if !entry.improved.isEmpty {
                categorySection(title: "Improved", icon: "sparkles", color: .purple, items: entry.improved)
            }
        }
    }

    @ViewBuilder
    private func categorySection(title: String, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                }
            }
        }
    }
}

// MARK: - Log data

struct UpdateLogEntry {
    let version: String
    let date: String
    let added: [String]
    let fixed: [String]
    let changed: [String]
    let improved: [String]
}

private let logEntries: [UpdateLogEntry] = [
    UpdateLogEntry(
        version: "1.46",
        date: "2026-08-22",
        added: [],
        fixed: [
            "Manga poster percentage badge now matches anime's size — uses Label with star.fill icon, .caption2.bold font, 8H/4V padding + 10pt outer inset (was plain Text, 9pt, 6H/3V + 4pt).",
            "Anime poster image source — switched from TVDBPosterImage (which could async-swap to a TVDB image that doesn't match AniList) to direct CachedAsyncImage with coverImage.extraLarge, matching manga's approach exactly.",
            "Library anime tap — no longer opens a blank page. Entries without a linked module now open AniListDetailView (which has its own data loading) instead of DetailView with an empty href (which caused blank because DetailViewModel.load() has guard !item.href.isEmpty).",
            "Library list — removed duplicate personal rating from the right-side info column. Personal score now shows only on the poster badge. Community average still shows on the right side.",
            "Notification section posters — all visual types (avatar, cover, plain icon) now share the same 84×112 outer frame so rows align in a single straight line. Posters are also modestly larger (80×80 avatar, 78×112 cover, was 72×72 / 72×108)."
        ],
        changed: [
            "Library list posters increased from 70pt to 80pt wide (modest increase)."
        ],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.43",
        date: "2026-08-22",
        added: [
            "Structured diagnostic logging — Logger.logStructured() provides feature, operation, provider, content ID, endpoint, HTTP status, error, and response snippet in every log entry. Deduplicates identical consecutive errors so rapid repeated failures don't spam the log.",
            "Manga downloads — in-progress and failed manga downloads are now tappable, opening the custom MangaDetailView with offline chapters."
        ],
        fixed: [
            "Manga downloads — completed manga now opens the custom manga detail page (MangaDetailView) with offline chapters loaded from disk. Previously some manga downloads were not tappable.",
            "Synopsis — increased line limit from 4 to 6 lines before 'Show more' appears. 'Show more' button now appears at 150 chars (was 200), so shorter synopses also get the expand option."
        ],
        changed: [],
        improved: [
            "AniList API requests now log the GraphQL operation name, variables, HTTP status, and response body on errors — so you can send the log back and I can identify the exact cause."
        ]
    ),
    UpdateLogEntry(
        version: "1.42",
        date: "2026-08-22",
        added: [
            "Manga batch download — selecting chapters and tapping the 'Download N' button now actually starts downloading the selected chapters via MangaDownloadManager. Previously the download icon entered selection mode but there was no way to initiate the download."
        ],
        fixed: [
            "Chapter/episode invert and reset buttons are now 46×46 — same size as all other action buttons. Previously they were 36×32 (manga) and 36×32 (anime), smaller than the rest."
        ],
        changed: [],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.41",
        date: "2026-08-22",
        added: [],
        fixed: [
            "Manga AniList page — duplicate/broken download button removed. The download button was in the chapters section header instead of the action-button row. Moved it to the action row (next to Continue + social icon) to match the anime page. Removed the dead-code duplicate 'else if' branch in readButton that did nothing.",
            "Manga edit button — wrong status ('Watching' instead of 'Reading') from the Library list's cross-provider edit sheet. The second LibraryEntryEditSheet call site was missing the progressUnit parameter, so it defaulted to 'episode' (anime). Added progressUnit: media.isManga ? 'chapter' : 'episode'.",
            "Manga edit button — stale status on fresh app launch. The onTogglePrivate callback now optimistically updates existingEntry.isPrivate immediately, so the toggle reflects instantly instead of waiting for the server round-trip.",
            "Manga reader — scrolling up quickly no longer teleports/jumps between pages. The onPreferenceChange callback was updating currentPage during active dragging/decelerating, which triggered onChangeOf(currentPage) → updateDisplayedChapter, causing geometry shifts. Now skips currentPage updates during active scroll and does a final pass after scrolling settles.",
            "Privacy sync for manga — the onTogglePrivate callback on the manga detail page now optimistically updates the local entry, so toggling private reflects immediately. The AniList fetch path already correctly populates isPrivate from the API response."
        ],
        changed: [
            "Removed dead 'openEntryDetail' function from LibraryView — was defined but never called.",
            "Manga chapters section header no longer has a download/selection-mode button — it's now in the action-button row above (matching anime)."
        ],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.40",
        date: "2026-08-22",
        added: [
            "People/social (Connections) button restored on individual manga AniList pages — opens the Connections section (relations + reading order), matching the anime page's button exactly."
        ],
        fixed: [
            "Poster size now consistent across anime and manga sections on the Home screen — both use the same responsive card width (155pt iPhone / 190pt iPad). Previously manga sections used a fixed 155pt while anime used responsive sizing.",
            "Continue Reading poster size now matches the posters in Trending Manga / All-Time Popular — all use the same responsive card width (was 130pt, now 155/190pt)."
        ],
        changed: [
            "Removed 'View on AniList' from the long-press context menu on Home and Library, for both anime and manga. The option remains in the Continue Watching / Continue Reading sections unchanged. Other context menu options (Add to Planning, Add to Watching/Reading, Mark as Completed) are unchanged."
        ],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.39",
        date: "2026-08-21",
        added: [],
        fixed: [
            "AniList 400 Bad Request — root cause: the anime and manga detail GraphQL queries requested 'alternativeSpoiler' on the voiceActors name field, but AniList's StaffName type does NOT have that field (only CharacterName does). This caused every detail page request to return 400, which is why Characters and Recommendations never appeared. Removed 'alternativeSpoiler' from both voiceActors name blocks (anime detail + manga detail). The character name block correctly retains it (CharacterName supports it).",
            "Characters and Recommendations not appearing — the 400 error from the invalid 'alternativeSpoiler' field caused the ENTIRE detail query to fail, so characters and recommendations data was never returned. Now that the query is valid, both sections load correctly.",
            "Notification custom UI 400 error — same root cause. AnimeNotificationDetailView calls AniListService.shared.detail(id:) which had the invalid field. Now that the query is fixed, the notification UI loads correctly."
        ],
        changed: [],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.38",
        date: "2026-08-20",
        added: [],
        fixed: [
            "Characters not appearing on Anime detail page — root cause: CharactersSection's self-fetch fallback only triggered when preloaded was nil, but the parent VM always passes preloaded: vm.characters (a non-optional array that starts as []). Swift promotes [] to Optional([]), which is NOT nil — so the self-fetch never ran. Fixed by checking preloaded?.isEmpty ?? true instead of preloaded == nil.",
            "Recommendations not appearing on Anime detail page — same root cause as Characters. Fixed the same way.",
            "Synopsis section looked misaligned — redesigned with a card-style background (RoundedRectangle with subtle fill + stroke), proper line spacing, and a centered 'Show more'/'Show less' button for long synopses. Now visually consistent with the rest of the detail page.",
            "Anime recommendations query was missing the 'type' field — added it so the anime/manga type filter works correctly when self-fetching recommendations."
        ],
        changed: [
            "Characters and Recommendations sections now show a loading spinner with 'Loading characters…' / 'Loading recommendations…' text while fetching, instead of being invisible until data arrives.",
            "Synopsis section — text now uses .primary opacity 0.85 (was .secondary) for better readability, with 3pt line spacing and proper multiline alignment."
        ],
        improved: [
            "Graceful empty state — if an anime genuinely has no character/recommendation data on AniList, the section renders nothing instead of a broken-looking empty section."
        ]
    ),
    UpdateLogEntry(
        version: "1.37",
        date: "2026-08-20",
        added: [],
        fixed: [
            "Toast close (X) button — completely reworked. The root cause was that ToastContainerView had .allowsHitTesting(false) on the parent, which disabled hit-testing for the ENTIRE view tree. SwiftUI's hit-testing is a one-way gate — child views CANNOT re-enable it. Removed the parent gate and used a GeometryReader + Spacer approach so empty space naturally passes taps through while toasts remain fully interactive. The X button now works every time.",
            "Surprise Me pool exhaustion — when the AniList API failed (empty results), the exclusion list (surpriseShownIds) was never reset, causing 'No anime found' to repeat after 2 uses. Now resets the exclusion list on API failure so the next attempt starts fresh.",
            "Manga posters — were smaller than anime posters because MangaPosterCard used .frame(height: 190) + text below, while AniListCardView made the image fill the entire 2:3 card. Rewrote MangaPosterCard to match AniListCardView exactly: image fills the entire 2:3 card, title overlaid on a gradient at the bottom, score badge at top-trailing. Manga posters are now the SAME size as anime posters.",
            "Library alignment — fixed double-padding issue. filterCapsuleRow and mediaTypeSegment had internal .padding(.horizontal, 16) that compounded with external padding, causing 32pt leading offset while LibrarySourceSwitcher sat at 16pt. Removed internal padding so all rows align at the same left edge.",
            "AniList HTTP 400 errors — added error logging that prints the actual GraphQL error response body so we can diagnose malformed queries instead of silently throwing."
        ],
        changed: [
            "Removed Auto Pick Module feature completely. This feature automatically switched to an anime module and searched for the title when opening anime from Library — it was causing long loading times and Cloudflare rejections from repeated module searches. Library now goes straight to DetailView; module selection happens via the Watch button's normal flow.",
            "Removed the Updates tab from Settings completely. The Update Log replaces it. No dead code left behind.",
            "Library grid toggle — moved to top-right toolbar, completely separate from the profile button. Each has its own independent ToolbarItem with its own click area.",
            "Manga section card width increased from 130pt to 155pt to match anime section width."
        ],
        improved: [
            "Surprise Me — no duplicate anime in the same session. Already-shown IDs are tracked and excluded. When the pool is exhausted, the exclusion list resets automatically.",
            "AniList detail request logging — 400 errors now log the response body for diagnosis instead of failing silently."
        ]
    ),
    UpdateLogEntry(
        version: "1.36",
        date: "2026-08-20",
        added: [],
        fixed: [
            "Toast close (X) button — reworked using ZStack with non-overlapping hit regions.",
            "Library filter alignment — all controls uniformly left-aligned.",
            "Episode 'Mixed' badge alignment — removed .fixedSize causing misalignment."
        ],
        changed: [
            "Grid/list toggle moved to top-right corner of Library."
        ],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.33",
        date: "2026-08-18",
        added: [],
        fixed: [
            "Anime detail pages now show Relations correctly even when the initial detail fetch fails. The Relations tab shows a 'Tap to retry' button instead of a dead-end 'No relations found' message."
        ],
        changed: [],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.32",
        date: "2026-08-18",
        added: [],
        fixed: [
            "Anime detail pages now load correctly from ALL categories (Trending, Popular, Top Rated, Browse, Search) — not just Recently Completed. List queries were missing episodes/status/format/season/studios fields, causing the Watch button to be disabled."
        ],
        changed: [],
        improved: [
            "Added popularity field to the detail query so the Statistics section shows the Popularity row for all anime."
        ]
    ),
    UpdateLogEntry(
        version: "1.31",
        date: "2026-08-17",
        added: [],
        fixed: [
            "Anime detail pages no longer return 400 Bad Request — removed a stray 'VO_EXPANDED' token from the GraphQL voiceActors field selection.",
            "MAL fallback now skips gracefully when the user isn't MAL-authenticated — no more 'token refresh failed: unauthenticated' log spam.",
            "Library filter controls scaled up (38pt → 44pt height) for better tap comfort.",
            "Sort control now displays as a text label ('Sort: Recently Updated') instead of an icon-only button.",
            "Continue Reading (manga) — tapping a poster now reliably opens the correct manga. Fixed a SwiftUI gesture conflict in LazyHStack.",
            "Toast close button gesture conflict fixed (first attempt)."
        ],
        changed: [
            "Removed MAL dual-source merge for Characters and Statistics — these now source from AniList exclusively."
        ],
        improved: [
            "Added in-flight request de-duplication for anime/manga detail pages to prevent cascade into rate-limit."
        ]
    ),
    UpdateLogEntry(
        version: "1.30",
        date: "2026-08-17",
        added: [],
        fixed: [
            "Library filter row — ALL controls (status filter, sort, grid/list toggle, Anime/Manga pills, source switcher pills) now share one unified capsule style.",
            "Tapping an anime in Library now always navigates to DetailView (the page with episodes) — no AniListDetailView fallback.",
            "Toast X button gesture conflict fixed (separated tap regions)."
        ],
        changed: [],
        improved: []
    ),
    UpdateLogEntry(
        version: "1.29",
        date: "2026-08-17",
        added: [],
        fixed: [
            "Invert chapter order index bug — tapping chapter 25 in inverted mode now correctly opens chapter 25 (was opening chapter 1).",
            "Chapter row circle restored with green-completed variant matching anime's EpisodeRowView.",
            "Section-header buttons resized to 36×36 with ultraThinMaterial background.",
            "Library filter row redesigned with shared libraryCapsuleStyle ViewModifier."
        ],
        changed: [],
        improved: [
            "Grid toggle moved from navigation toolbar into the filter row."
        ]
    )
]
