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
    let removed: [String]
    let other: [String]
}

private let logEntries: [UpdateLogEntry] = [
    UpdateLogEntry(
        version: "1.81",
        date: "2026-08-23",
        added: [
            "Custom Change Stream UI — completely redesigned the screen you see when you tap Change Stream on an episode. Instead of the default iOS list, it now shows a card for each anime module with the module's icon, name, language, and quality badge. Tapping a card opens the streams as a list of cards with quality badges (1080p, 720p, 480p, HLS), soft-subtitle indicators, and selected-state checkmarks.",
            "Module filter bar — if you have 4+ anime modules installed, a filter field appears so you can quickly find the module you want.",
            "Loading skeletons, error states, and Cloudflare verify prompts now all appear inside the module card itself instead of replacing the whole screen.",
            "Episode header at the top of Change Stream shows the anime title and episode number so you always know what you're picking a stream for."
        ],
        fixed: [
            "Manga modules appearing in Anime Change Stream — root cause: the module list returned ALL installed modules instead of filtering by content type. Now the data source itself filters to anime-only (no manga, no novels, no Jellyfin/local-playback pseudo-modules). Manga modules can never reach the anime stream picker regardless of which code path renders them.",
            "Auto Pick Module regression — confirmed not brought back. The new custom UI still requires you to manually select a module, then manually select a stream. Single-stream modules still auto-select since there's only one choice, but multi-stream modules always open the manual picker."
        ],
        changed: [
            "Anime module filtering now happens at the data-source layer (`animeModules` computed property), not at the UI rendering layer. The UI just iterates the already-filtered list — no possibility of manga modules slipping through."
        ],
        improved: [
            "Streams now sorted by quality (HLS first, then 1080p → 720p → 480p → 360p, then alphabetically) so the best option is at the top.",
            "Selected stream is highlighted with an accent border and checkmark icon before playback starts, so you get visual confirmation of your choice."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.80",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Watching anime — tapping an episode now opens the manual module and stream picker. Previously the app automatically picked a module and tried to auto-play the best stream, which was hitting Cloudflare blocks and leaving you unable to watch. Now you choose the module, then choose the stream, then playback starts.",
            "Change Stream button — long-press an episode and tap Change Stream now opens the same manual picker so you can pick a different module and stream. Previously this button did nothing useful because the auto-pick flow had already committed to a stream."
        ],
        changed: [
            "Episode tap flow restored to the original manual workflow — Click Episode → Choose Module → Choose Stream → Watch. Long-press → Change Stream → Choose Module → Choose Stream → Watch. No automatic module or stream selection anywhere in the process."
        ],
        improved: [],
        removed: [
            "Auto Pick Module feature — completely removed. The app no longer automatically selects a module or auto-plays a stream when you tap an episode.",
            "Auto-pick Last Stream toggle — removed from Settings → Streaming.",
            "Auto-pick Last Search Result toggle — removed from Settings → Streaming.",
            "Use Default Extension Only toggle — removed from Settings → Search. The module picker now always shows every installed anime module so you can pick whichever one you want."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "1.79",
        date: "2026-08-23",
        added: [],
        fixed: [
            "App renamed to 'Shirox+' — the springboard icon label (CFBundleDisplayName), sidebar header, launch wordmark, About page, and AltStore listing now display 'Shirox+'. The bundle identifier (com.shirox.app) and AniList/MAL OAuth URL scheme (shirox) are unchanged so existing installs upgrade in place without re-authenticating.",
            "Characters / Staff / Recommendations — duplicate section titles (e.g. 'Characters Characters') removed. The anime detail page previously rendered a parent collapsible header AND the section's own internal header, producing two identical titles stacked on top of each other. The parent collapsibleHeader wrapper is gone; each section now renders its own single header with the chevron. Same cleanup applied to Staff and Videos.",
            "Characters / Staff / Recommendations — were opening expanded by default on the anime detail page. All four sections (Characters, Staff, Recommendations, Videos) are now collapsed by default; the user taps the chevron to expand. The collapsed state is visually clean and compact — just the title + chevron, no body.",
            "Staff section not loading — root cause: StaffSection required a non-nil malId, but the preloaded Media passed from the AniList list query often has no idMal (only the full detail query populates it). When malId was nil, StaffSection silently skipped the fetch and rendered nothing. Now resolves the MAL id through IDMappingService.shared.cachedMalId(forAnilistId:) as a fallback — works for any anime whose Arm mapping is cached. Same fallback added to VideosSection.loadVideos() so videos load too.",
            "Downloads — custom Anime Downloads page was not being opened. Tapping a downloaded anime opened the 'Offline Reading' page (DetailView with offlineSnapshot) which only shows the downloaded episodes — that is NOT the custom download page. The 4-tier fallback (snapshot → DetailView, aniListID → AniListDetailView, href → DetailView, else → DownloadDetailView) is replaced with a single destination: DownloadDetailView. The custom page (circular progress ring, ETA, speed, file info, Find File / Share File buttons, Retry / Cancel / Delete actions) now opens for every anime download tap. The existing DownloadItem data is passed straight through, so the episode title, file name, progress, and metadata are preserved. Manga downloads are unchanged — they already route to MangaDetailView with offlineChapters.",
            "Watch Episode button loading state — tapping an episode no longer flips the Watch Episode button into a 'Loading…' spinner. The button now always renders the play icon + 'Watch Ep N' / 'Continue Ep N' label immediately and stays interactive. The vm.isResolving flag (used internally to prevent duplicate resolve cycles) is no longer tied to the button UI. Stream resolution still kicks off when the user taps an episode or presses the Watch button, but the loading state happens off-screen — the user doesn't see a disabled button."
        ],
        changed: [
            "Glow effects — removed from regular text-heavy buttons. The 'Surprise Me' button (SearchView), 'Remove All Pending' button (Notifications settings), 'Export Backup' button (Backup & Restore), and the module-store 'Install' button no longer cast a glow shadow — their labels read cleanly without the halo. Intentional glow on Modules (active module tile + active module list row), Sources (connected provider icons), the MangaHome layout/direction selector cards, the HomePressStyle card-press feedback, the Notification status circle, and all Toggle-on glow effects is preserved unchanged."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.51",
        date: "2026-08-23",
        added: [
            "Collapsible sections — Characters, Staff, and Recommendations on the anime detail page each have their own expand/collapse arrow. Clicking the arrow toggles that section independently. State is remembered while the page is open."
        ],
        fixed: [
            "AniList HTTP 403 errors — root cause: AniListService.post() was NOT sending a User-Agent header. AniList's API requires one and returns 403 for requests without it. Added 'shirox/1.50 (iOS)' User-Agent to the URLSession configuration. This fixes the carousel, categories, manga loading, and all other AniList data that was failing.",
            "Manga not loading — same 403 root cause. All manga queries go through AniListService.post() which was 403'ing. Now that the User-Agent is set, manga loads normally.",
            "Carousel and Categories disappeared — same 403 root cause. The data arrays were empty because every AniList request was being rejected. Now that the 403 is fixed, data loads and the carousel + sections appear.",
            "Provider fallback spam — when MAL is not authenticated, the 'fallback not authenticated' log was firing on every single request. Added a 30-second cooldown so it only logs once every 30 seconds instead of spamming."
        ],
        changed: [],
        improved: [
            "Provider fallback log deduplication — identical 'fallback not authenticated' messages are throttled to once per 30 seconds."
        ],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.33",
        date: "2026-08-18",
        added: [],
        fixed: [
            "Anime detail pages now show Relations correctly even when the initial detail fetch fails. The Relations tab shows a 'Tap to retry' button instead of a dead-end 'No relations found' message."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
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
        improved: [],
        removed: [],
        other: []
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
        ],
        removed: [],
        other: []
    )
]
