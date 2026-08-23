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
        version: "1.90",
        date: "2026-08-23",
        added: [
            "Up Next smart auto-play — when an episode is within 30 seconds of ending, a clean 'Up Next' card appears showing the next episode number, anime title, a 10-second countdown, a Play Now button, and a dismiss button. If Auto Next is enabled, the next episode plays automatically when the countdown reaches zero.",
            "Auto-Download New Episodes (Settings → Downloads) — when enabled, monitors anime you're currently watching and automatically queues new episodes for download when they air. Never downloads an episode that's already downloaded.",
            "Download Over WiFi Only (Settings → Downloads) — prevents downloads from starting over cellular data when enabled.",
            "Watch Time Statistics (Profile → Stats) — new 'Shirox Watch Stats' section showing episodes watched, unique anime, total watch time, average per episode, weekly/monthly activity, current streak, and top 5 anime by watch time. Computed from the app's own Continue Watching data.",
            "Continue Watching countdown — when you've watched the latest available episode, a subtle countdown to the next episode's airing time appears on the Continue Watching card (e.g., 'EP 13 in 2h 15m'). Updates automatically every 60 seconds.",
            "Show Next Episode Countdown toggle (Settings → Streaming) — lets you enable/disable the Continue Watching countdown. ON by default.",
            "Auto-Fallback toggle (Settings → Streaming → Advanced) — when enabled, if your selected module fails to provide a stream, the app tries another eligible anime module. Only activates after a failure — does not auto-select a module. Disabled by default.",
            "Auto Pick Module toggle (Settings → Streaming → Advanced) — testing only, disabled by default. Automatically selects a module and stream without manual input. Does not affect the normal manual workflow unless explicitly enabled."
        ],
        changed: [],
        fixed: [],
        improved: [],
        removed: [],
        other: [
            "The normal Anime flow remains: Episode → Choose Module → Choose Stream → Watch. Auto Pick and Auto-Fallback are separate, isolated toggles that do not interfere with the manual workflow unless explicitly enabled.",
            "Crunchyroll-style simulcast = airing countdown + availability notification experience only. No Crunchyroll provider/module was added."
        ]
    ),
    UpdateLogEntry(
        version: "1.89",
        date: "2026-08-23",
        added: [
            "Storage Management page (Settings → Storage) — shows the total disk space used by Anime downloads, Manga downloads, and image cache, each with an item count and formatted size. Includes bulk-delete buttons for Anime downloads, Manga downloads, and image cache, plus pull-to-refresh to recalculate sizes.",
            "Per-Show Playback Settings — the player now remembers your playback speed for each anime individually. If you watch one anime at 1.5× and another at 1.0×, the app restores the correct speed automatically when you switch. No setup needed — just change the speed in the player and it saves automatically. Settings → Streaming has a new 'Per-Show Playback' card with clear instructions explaining what it does, how many shows have saved preferences, and a Clear All button.",
            "Module Health Indicators — each module in Settings → Modules now shows a colored status dot: green (working), yellow (some failures), red (repeated failures), or orange (Cloudflare blocked). The dot appears only after the module has been used at least once. Health is tracked automatically when the module loads or fails.",
            "Episode Release Notifications UI polish — the Episode Reminders and Airing Notifications toggles now have descriptive subtitles explaining what each one does. 'Episode Reminders' sends a phone notification when a new episode of a tracked anime airs. 'Airing Notifications' shows in-app alerts for upcoming episodes in the Schedule tab."
        ],
        fixed: [],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.88",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Glow leaks — 4 episode/chapter row badge shadows (EpisodeRowView, ThumbnailEpisodeRow, MangaDetailView, AniListMangaDetailView) were not gated by the Glow setting. Now when Glow is OFF, no glow is visible on these badges. When ON, the glow appears only on the number circle (not on text).",
            "Duplicate AniList API request — CharactersSection was re-fetching the full anime detail from AniList just to read the MAL ID (for Jikan character lookup). Now accepts the MAL ID from the parent view, eliminating the duplicate request. Falls back to IDMappingService cache, then to a detail fetch only as a last resort."
        ],
        changed: [],
        improved: [],
        removed: [
            "CustomActionSheet.swift — 185 lines of dead code. Was created in v1.84 for the custom Long Action UI but became unused after the v1.85 revert. Zero references in the codebase.",
            "DownloadModulePickerView.swift dead code — ~420 lines of unused DownloadVMStore, DownloadModuleRow, DownloadModuleRowViewModel, SearchResultCard, and SearchResultsPickerSheet. The file now delegates to ModuleStreamPickerView (since v1.87) and no longer needs these old implementations."
        ],
        other: [
            "Download retry backoff — failed downloads now wait with exponential backoff (2s, 4s, 8s, 16s, 32s) before retrying instead of retrying immediately. Prevents hammering a flaky server during transient outages. Up to 5 retries still allowed."
        ]
    ),
    UpdateLogEntry(
        version: "1.87",
        date: "2026-08-23",
        added: [
            "Manual number input in Download Range — the From and To fields now accept typed numbers. Tap the field and type (e.g. 50 → 53) using the numeric keyboard. Validates the range and prevents invalid input like 53 → 50."
        ],
        fixed: [
            "Download → Change Stream UI — clicking Download now opens the new custom Change Stream UI (the same one used by the Watch / Change Stream flow). Previously opened the old default iOS List picker. The custom picker handles module selection, stream selection, and single-stream auto-selection — no Auto Pick Module.",
            "Collection icon color — the Add to Collection (bookmark) icon was rendering white in some toolbar contexts. Now uses Color.appAccent explicitly when saved, and .primary when unsaved, so it's always visible and follows the user's chosen accent color."
        ],
        changed: [
            "Episode labels now show 'EP N' instead of 'Episode N' everywhere (episode rows, download rows, player subtitles, stream picker, cast overlay). Manga chapter labels are unchanged — they continue using 'Chapter N'."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.86",
        date: "2026-08-23",
        added: [
            "Download Range feature for Anime — a new button in the Episodes header (next to Sort and Reset) opens a custom range picker. Pick a starting episode and ending episode (e.g. 50 → 53), and the app downloads episodes 50, 51, 52, 53. The range is inclusive and validated. Already-downloaded episodes are automatically skipped and counted in the summary. Quick presets include First 5, First 10, Last 5, Last 10, and Entire Series.",
            "Download Range feature for Manga — the same custom range picker is now available on the Manga chapters page. Opens from a new button in the Chapters header. Pick a starting chapter and ending chapter (e.g. 50 → 53), and the app downloads chapters 50, 51, 52, 53. Already-downloaded chapters are skipped. Manga uses the same underlying range-download logic as Anime."
        ],
        fixed: [],
        changed: [],
        improved: [],
        removed: [],
        other: [
            "The custom range UI uses the app's existing design language — card-based layout with rounded corners, accent-colored buttons, and custom number selectors with +/- buttons and sliders. No Apple default pickers or action sheets are used.",
            "Anime and Manga range selection are completely separate — the UI automatically adapts its wording (Episode vs Chapter) and data source based on the content type. Anime episodes and Manga chapters never mix."
        ]
    ),
    UpdateLogEntry(
        version: "1.85",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Staff section — actual staff data now loads. Root cause: the section was fetching from Jikan's rate-limited API, which often returns 504 errors. Now fetches staff directly from AniList's GraphQL API as part of the main detail query — no separate network call, no Jikan rate-limiting. Each staff member shows their name, image, and role (Director, Animation, Original Creator, etc.). Jikan is kept as a fallback only if AniList returns no staff data.",
            "Glow toggle — when Glow is OFF, absolutely no glow is visible anywhere. Was previously leaking through on the Continue Watching progress bar (had a hard-coded shadow not gated by the Glow setting). Now every glow effect checks Color.glowEnabled before rendering.",
            "Glow updates immediately — changing the Glow toggle in Settings now updates the entire app instantly without requiring a restart. Added @AppStorage('glowEnabled') to the app root so the view tree re-renders when the toggle changes."
        ],
        changed: [
            "Long Action UI reverted to the previous version's design — restored the standard context menu that was used before the custom action sheet was introduced. All functionality (Add to Planning, Add to Watching, Mark as Completed) remains intact.",
            "Player UI reverted to the previous version's design — restored the original player bottom bar with all controls in a single row (Source, Quality, Audio, Subtitles, Fullscreen, Playback Speed, Next Episode). The collapsible Player Settings section has been removed. The title font size is also restored to the previous size."
        ],
        improved: [],
        removed: [
            "Custom Long Action UI (from v1.84) — reverted. The custom action sheet is no longer used; the standard context menu is restored.",
            "Custom Player UI collapsible settings (from v1.84) — reverted. The slider toggle and advanced-controls capsule are removed; all controls are back in the single bottom bar."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "1.84",
        date: "2026-08-23",
        added: [
            "Custom Long Action UI — long-pressing an anime poster now opens a custom action sheet instead of Apple's default context menu. Shows the anime's poster, title, score, and year at the top, then custom action cards for Add to Planning, Add to Watching, and Mark as Completed. Each card has an icon, title, and subtitle. Matches the Change Stream UI's design language. Smooth open/close animations with a dimmed backdrop.",
            "Collapsible Player Settings — advanced playback controls (Source, Quality, Audio, Subtitles, Playback Speed) are now hidden behind a single 'Player Settings' toggle button. Tapping the slider icon expands/collapses them inline. The main player controls (Skip, Fullscreen, Next Episode) remain always visible. Keeps the player clean while making advanced controls easy to access."
        ],
        fixed: [
            "Player portrait title too small — the anime title in the player's top bar was using a tiny 14pt font in portrait mode on iPhone. Increased to 20pt (.title3.weight) so it's clearly readable. Long titles still scale down via minimumScaleFactor(0.5) so they don't truncate."
        ],
        changed: [
            "Blue is now the default theme — the app's default accent colour is now blue (0A84FF) instead of red. Applied consistently across Color.appAccent, the AccentColor asset, ShiroxApp's accentColor resolver, and the schedule selected pill. The AltStore tintColor in apps.json is also blue. Existing users with a custom accent selected keep their choice; only fresh installs / resets get blue.",
            "Random Anime (Surprise Me) now uses genres — was previously fetching trending + popular + top rated (3 fixed categories, ~60 titles). Now picks 4 random genres from a curated list of 16 (Action, Comedy, Drama, Fantasy, etc.) and fetches up to 50 titles per genre, giving a pool of ~150-200 titles. Much harder to exhaust. Pool is cached for 10 minutes. When exhausted, automatically picks new genres on the next tap.",
            "Player bottom bar restructured — main controls (Fullscreen, Next Episode) are in a primary capsule. Advanced controls (Source, Quality, Audio, Subtitles, Playback Speed) are in a secondary capsule that appears when the Player Settings toggle is expanded. Both capsules use the same glassChrome styling."
        ],
        improved: [],
        removed: [
            "Duplicate Apply Filter bar in Search — removed the bottom 'Apply Filters' bar from the Search filter sheet. Was creating two Apply buttons (toolbar + bottom bar). The toolbar Apply button remains as the single intended button."
        ],
        other: [
            "AOT / duplicate seasons in Search — investigated and confirmed this is expected AniList behavior. When you search 'Attack on Titan', AniList returns each season (S1, S2, S3, Final Season) as a separate Media entry. These are not duplicates — they're individual entries with unique IDs. No code changes needed; the search deduplication by uniqueId already prevents true duplicates."
        ]
    ),
    UpdateLogEntry(
        version: "1.83",
        date: "2026-08-23",
        added: [
            "Module Settings icon — added a gear-shaped settings button to the top-right of the Change Stream UI's Modules header. Tapping it opens the existing Module Settings page (where you install/remove/reorder modules). Uses the same custom card design language as the rest of the Change Stream UI — 36×36 ultraThinMaterial circle with a subtle border."
        ],
        fixed: [
            "Module expand/collapse bug — once a module was expanded in the Change Stream UI, tapping it again wouldn't collapse it. Root cause: the code always set selectedModuleId to the module's ID, never toggled it. Now tapping a selected module collapses it; tapping a different module switches to it. Multiple modules maintain independent states.",
            "Staff section disappearing — the Staff section between Characters and Recommendations on the anime detail page would vanish entirely when staff data was empty (e.g. Jikan returned no results). Root cause: the section only rendered when staff was non-empty, so a failed/empty fetch made it look like Staff had been removed. Now the Staff header always renders; if staff data is empty after loading, a clean 'No staff data available' message appears inside the expanded section.",
            "Collection icon floating — the bookmark/collection icon was a floating overlay on the bottom-right of the anime detail page, which overlapped the episode sort/invert arrow button when scrolled. Moved to a fixed toolbar position at the top of the screen alongside the Modules and Edit Entry buttons. Consistent positioning across Anime detail pages."
        ],
        changed: [
            "Character Details UI upgraded — Description and 'Appears In' (animeography) sections now use collapsible cards matching the Change Stream UI's design language (rounded corners, subtle shadow, accent border, chevron toggle). Description defaults to collapsed since character bios can be very long. Each card has an icon, title, count badge, and expand/collapse chevron."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.82",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Long-press on Anime posters — when long-pressing a poster below the Continue Watching section, the action menu no longer randomly switches to a Continue Watching poster. Each poster now has its own isolated long-press gesture attached inside the card's view, with stable IDs and clipped hit-testing. The wrong-card menu bug is gone.",
            "Surprise Me stops working after ~4 uses — root cause: every tap fired 3 fresh AniList API calls (trending + popular + top rated), which burned through the AniList rate limit. Now caches the combined pool for 10 minutes. Repeated taps within that window pick a random item from the cached pool with zero network requests. After 10 minutes the cache refreshes automatically. Surprise Me now works repeatedly without saying 'No anime found'.",
            "Schedule details title — the title used to appear as a black bar overlay floating on top of the screen. Now displays the title inside the custom details UI itself as the first item below the hero poster, matching the rest of the app's layout.",
            "Schedule tab — removed the navigation title bar (the bar at the top that said 'Schedule' or 'Releases'). The Schedule tab now has a clean look with just the date selector and anime cards — no extra bar at the top."
        ],
        changed: [
            "Schedule poster titles are now ~20% larger — went from 14pt to 17pt. Longer titles still wrap correctly to 2 lines.",
            "Schedule tab's navigation bar is now transparent/hidden instead of showing the dark release-title bar.",
            "Surprise Me now uses a 10-minute static cache keyed by media type (anime vs manga) so switching modes doesn't mix pools. Even when the API fails, the cache prevents further API spam until the 10-minute window expires."
        ],
        improved: [],
        removed: [
            "Blue Appearance preset — completely removed from Settings → Appearance. The Default preset (system label colour, the existing app default) is now the only 'no colour' option. If you previously had Blue selected, your accent is automatically reset to Default on first launch."
        ],
        other: []
    ),
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
