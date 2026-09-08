import SwiftUI

/// Change Log page (v2.22 — renamed from "Update Log").
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
        .navigationTitle("Change Log")
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
            if !entry.removed.isEmpty {
                categorySection(title: "Removed", icon: "minus.circle.fill", color: .red, items: entry.removed)
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
        version: "2.26",
        date: "2026-09-08",
        added: [
            "Kitsu now serves as a live backup source for manga too (it previously only backed up anime). The Manga tab and the Reading-mode Releases page keep real, current lists even while MyAnimeList and AniList are both having outages — previously those two going down at the same time left the Manga tab with nothing to show. Kitsu appears in Settings → Data Sources under the manga chain, where you can reorder or disable it like every other source."
        ],
        fixed: [
            "TVDB — the top-priority source for anime search — failed on every single search with a data-reading error, so searches always fell through to slower backup sources (this is the 'The data couldn't be read because it isn't in the correct format' error in the logs). Its results now decode correctly and navigate to the right series pages.",
            "The Kitsu backup source's lists were sorted BACKWARDS: instead of the most popular anime and manga, they showed obscure zero-follower titles (self-published doujinshi, obscure shorts). Every Kitsu-served list — shelves, See All pages, and the new manga lists — now leads with genuinely popular series like One Piece and Attack on Titan.",
            "When every manga source is unreachable, the app used to re-run the whole request chain over and over — the log showed the same four shelves re-requested several times per second, and the Releases page reloading six times in half a minute. It now waits a short interval between failed attempts (retrying immediately is still one tap on Retry or a pull-to-refresh away), so the page settles on one clear message instead of churning."
        ],
        changed: [],
        improved: [
            "Manga search gained the same Kitsu backup, so it survives MyAnimeList and AniList outage windows as well."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.25",
        date: "2026-09-08",
        added: [
            "A subtitle style switch — choose between Apple's default subtitle look and Shirox's custom styling. Find it in the player's subtitle menu and in Settings → Subtitles; the choice sticks across restarts. Apple mode renders embedded subtitles with the system's native appearance and gives external subtitle files the same clean default look; Shirox mode is the full custom styler you already know, with every appearance setting applying as before.",
            "Manga Home now survives full outages the same way anime Home does: when every manga source is unreachable, the last successfully loaded shelves (kept up to 6 hours) come back with a clear note about their age instead of a blank error page. Pull to refresh retries the live sources.",
            "Each provider on the Data Sources page now shows a recognizable brand tile (TVDB, MyAnimeList, AniList, Kitsu, AniDB, MangaBaka, AniChart, AnimeSchedule) so the list reads at a glance instead of as a wall of text."
        ],
        fixed: [
            "The See All pages now show what their titles promise: 'Recently Completed' loads the previous season's finished shows and 'Upcoming' loads genuinely unreleased anime — both previously borrowed unrelated lists (all-time popular and trending), which is why the results felt random or off-topic. Every browse list is also now a Japanese-anime list: entries known to originate outside Japan are filtered out at every provider, so donghua no longer mixes into the shelves or See All grids.",
            "Continue Watching's 'caught up' count: the episode list from your actual streaming source is now the authority for how many episodes exist. AniList's stored total can be stale — the reported case said 8 of 8 while the source really served 9 — so counts now reconcile upward against the real list and never get lowered by a stale sync.",
            "Tapping an anime in Continue Watching (or long-pressing it and choosing 'View on AniList') no longer errors out when AniList is down: the page opens immediately with the title, poster, and episode info the card already carries, then fills in the rest from TVDB and the other sources. Previously it hit a hard error wall while Library taps worked fine.",
            "The Schedule's saved-data fallback quietly rotted: while a backup source (like MyAnimeList) was serving the page, the saved copy was never refreshed — so on the day that source ALSO went down, the fallback was empty or stale and the page still failed. Every successful live load now refreshes the saved copy, so the last good data is genuinely the last good data.",
            "The manga release schedule fired three identical requests at once (one per caller, all failing with the same timeout) — it now runs through the shared request system like every other feature, so there's exactly one deduplicated, paced, cached request no matter how many screens ask.",
            "Kitsu's browse requests returned HTTP 400 errors — a wrong sort field in the app's own request, not a Kitsu outage. It now uses the correct field, so Kitsu genuinely serves as a working fallback for browse and See All.",
            "The 'modules are installed but the app says no modules' confusion: the anime module list in Settings now only counts sources that can actually stream anime — the same list every watch flow uses. Novel, local-playback, and Jellyfin entries moved to their own clearly labeled section instead of inflating the anime count.",
            "The carousel no longer flickers or feels slow while swiping: the title text is gone entirely — the logo shows when artwork is available, and the slot simply stays empty when it isn't, so every slide uses one consistent rendering instead of switching between text and artwork mid-swipe."
        ],
        changed: [
            "Carousel genre pills (Action, Fantasy, …) are slightly larger and horizontally centered as a group — the same centered alignment as the Start Watching / Start Reading button below them — while still scrolling gracefully when a long genre list needs it.",
            "The Data Sources page was rebuilt row by row: the provider's name, API host, priority, and health status each get their own space with the brand tile, drag handle, enable toggle, and test/move buttons arranged so nothing can overlap or wrap unexpectedly — even at the largest accessibility text sizes.",
            "The Recently Completed and Upcoming shelves draw from the full provider chain (MyAnimeList, AniList, Kitsu) instead of AniList alone, so they stay filled through AniList outages — and they're part of the same saved-data fallback as the rest of Home."
        ],
        improved: [
            "The provider chain's decision log now tells the whole story: every provider attempt is visible with its outcome — who was skipped and why (cooling down, not configured, doesn't serve that data) and who actually served the request and how fast. TVDB is genuinely tried first for search and details; it simply has no trending-chart endpoints, and that's now recorded instead of silent.",
            "AnimeSchedule no longer wastes a spot in every schedule attempt when no API token is entered: it's skipped up front with a clear note, and it activates the moment you add your free token in Data Sources.",
            "The subtitle menu hides the custom appearance controls while Apple's default look is selected, so the settings you see always match the settings that apply."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.24",
        date: "2026-09-08",
        added: [
            "A new Data Sources page in Settings: the control room for every provider. Each provider shows its name, API host, live health (Online / Degraded / Rate Limited / Unavailable / Offline), its position in the chain (PRIMARY or FALLBACK #n), the last successful request, measured latency, and current cooldown. Toggle any provider on or off, run a REAL test (a lightweight request with measured response time — 'Online · 142 ms' or the honest failure reason), and clear the anime / manga / schedule caches with their exact on-disk sizes.",
            "Drag-and-drop priority ordering: press and hold a provider card's handle, drag it to a new position — the neighbors slide aside live with a haptic tick at every slot — and drop to commit. The order is saved instantly and every request the app makes follows it. 'Reset Order' restores the recommended chain (TVDB → MAL → AniList → Kitsu → AniDB). The arrow buttons remain for precise single-step moves.",
            "The whole provider chain is rebuilt around one system: TVDB (artwork, seasons, episodes, characters, staff, ratings — the app's own TVDB key, so it works out of the box), Kitsu, and AniDB join MAL and AniList for anime; MangaBaka is the new manga primary; AniChart and AnimeSchedule lead the schedule chain. Everything flows through one central manager with per-domain priority, field-level fallback (the next provider fills only the missing fields — it never replaces the whole record), shared caching, and in-flight deduplication.",
            "DOWNLOAD NOW: the update popup downloads the real package inside the app — live progress, transfer speed, total size — then verifies it byte-for-byte against the release's SHA-256 checksum. It never claims the download finished unless the file actually exists on disk. Afterward, DELETE FILE removes the package (with a small confirmation) and lets you re-download, and FIND FILE opens the Files interface at the app's Documents folder with the exact path spelled out — only shown when the location is actually known."
        ],
        fixed: [
            "Provider failure storms are gone at the root: one failing provider now gets an exponential cooldown (60s → 2 min → 4 min, capped at 10 minutes) that every screen respects, the identical request is deduplicated while in flight (two screens asking for the same shelf share ONE request), failures are negatively cached for 45 seconds, and a provider that returns a rate limit pauses for 90 seconds instead of being re-asked. No more request storms, duplicate API calls, or endless provider-switching loops.",
            "The Manga page can no longer go blank when its provider fails: MangaBaka → MAL → AniList chain with field-level fallback, and every state (loading / content / empty / error-with-retry) renders the page itself. The Schedule page is the same — AniChart → AnimeSchedule → MAL → AniList, cached timetable, and a proper 'Schedule Temporarily Unavailable' card only when everything is genuinely down.",
            "Update detection was hardened end-to-end: version comparison is fully semantic (2.2 and 2.2.0 are equal, 2.10 is newer than 2.9, prefixes and suffixes normalize), a failed version check never assumes an update exists, and stale cache can't produce a false popup. When you're already on the latest version, nothing appears."
        ],
        changed: [
            "Anime metadata is now TVDB-first: TVDB is the primary source for posters, covers, backdrops, logos, banners, episode and season artwork, synopsis, characters, staff, cast, genres, ratings, seasons, episodes, release info, and studios — with MAL, AniList, Kitsu, and AniDB filling in only what TVDB doesn't have, in that exact order. One chain, one health system, one cache — used by Home, Trending, Search, Details, Seasons, Episodes, Characters, Staff, Recommendations, and Schedule alike.",
            "The update popup's action is DOWNLOAD NOW, making clear that you download the new app file rather than the installed app updating itself — with the current version, the new version, the release date, the file size when known, and the download/downloading/downloaded/error states, each honest.",
            "Dead code and duplicate systems were consolidated: the old provider orchestration paths, the obsolete update plumbing, and every last trace of the Music feature's wiring — navigation, managers, models, caches, settings rows, and the VLCKit dependency — verified unreferenced and removed. The app returns to its lean size (roughly 12 MB, down from 55.9 MB)."
        ],
        improved: [
            "Provider health is now a first-class system: healthy providers stay in their user-configured priority, failing ones cool down and are skipped silently, and a controlled health check (or a successful Test Provider run) restores normal priority automatically — no API spam, no manual unstick.",
            "Every screen's request lifecycle is cancellable and timeout-bounded through the central system, so leaving a page mid-load actually stops the work instead of leaving orphaned requests competing for the same providers."
        ],
        removed: [
            "Music — removed completely. The AnimeThemes-based Music feature (tab, player, managers, providers, models, caches, and settings) is gone, and with it the VLCKit framework that accounted for ~44 MB of the previous build. Nothing else was touched: anime details, navigation, search, home, playback, and settings work exactly as before."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "2.23",
        date: "2026-09-08",
        added: [
            "Music, rebuilt on AnimeThemes.moe — the dedicated anime openings/endings database — through its official GraphQL API. Openings, endings, and insert songs with the real song titles, artists (including 'as' credits), episode ranges, versions, and anime artwork. A music-note icon now sits directly beside the manga toggle in the Home toolbar; tapping it opens the Music page with a Featured rail (the provider's own shuffle), this season's openings and endings, an artists rail, and search across anime, songs, and artists.",
            "Real in-app playback: tapping a theme plays its actual media (AnimeThemes theme → entry → video/audio) inside the app via VLCKit — the OP/ED video or its audio track, with a mini player bar that persists across every tab, an expanded player with seek bar, queue, and lock-screen controls. Music never opens AnimeThemes in Safari, and it has zero AniList dependency — it keeps working while AniList is down.",
            "A redesigned update popup (built from scratch, not a tweak): a bottom-sheet card in the app's design language with the version transition (Installed → New), the changelog, and an INSTALL WITH picker for LiveContainer, SideStore, and KSign — each verified against that tool's own documented install link, probed for availability, and remembered across launches.",
            "Provider circuit breakers and a 6-hour offline snapshot for the Home shelves, so the carousel keeps real data through full outages."
        ],
        fixed: [
            "The false update popup: an accidental five taps on the version row persisted a hidden 'demo mode' that made every check report the installed build as outdated — the popup could appear with the same version on both sides (2.2 → 2.2). The simulation is gone; the comparison is purely real, normalized (whitespace, v-prefixes, pre-release suffixes, missing patch numbers), and takes the newest manifest version semantically. 2.2 + 2.2 never prompts; 2.10 + 2.9 never prompts; a failed check never assumes an update.",
            "Schedule and Music 'not showing': six bottom tabs overflowed the bar into the system 'More' menu, hiding them. Music moved to the toolbar and the bar is exactly five tabs again — Schedule is always directly visible, and every page renders its loading / content / offline snapshot / empty / error states no matter which APIs are down.",
            "AniList 403 flooding: a disabled AniList response now trips a 5-minute circuit breaker checked before every request (every screen fails fast instead of re-403ing), and a failing Jikan gets a 45-second failure cache plus a shared outage cooldown — the duplicate, independent fallback requests that caused the 429 storms are gone (Home now routes through the one central provider path).",
            "Donghua in the trending carousel: when AniList is down the Jikan fallback fed a global top-airing list with no country data, so Chinese animation sailed through the carousel's Japan filter. The fallback now classifies each entry from the provider's own production metadata (Chinese production companies, JST broadcasts, kana in the Japanese title) and the AniList query itself filters to Japanese anime at the source.",
            "The Start Watching button hugging the left edge: it's centered in the carousel again, in its own centering container so it never shifts with title length, poster size, or screen size."
        ],
        changed: [
            "The carousel shows its richer information again: genre pills (up to six, with a +N overflow chip, never overflowing off-screen), a star rating, the year, format, and episode count — all in fixed-height rows so every slide still lays out in exactly the same spot (the v2.20 position-stability guarantee, preserved).",
            "Update destination handoffs are honest by construction: LiveContainer, SideStore, and KSign each get their own documented install link, availability is probed with canOpenURL, and success is only claimed when iOS confirms the open. The download + SHA-256 verification flow is unchanged and still runs in-app.",
            "The Updates settings page's hidden five-tap trigger is replaced by a clearly labeled 'Preview the update popup' row that can never affect the real version check."
        ],
        improved: [
            "Music request hygiene: every AnimeThemes query is deduplicated in flight, cached in memory and on disk, paced under the documented 90/minute limit, and failures are remembered for 45 seconds — several screens never re-request a dead endpoint.",
            "Manga and Schedule pages keep their honest state chain (provider → fallback → snapshot → error with retry) with the new circuit breakers, so temporary API failures degrade gracefully instead of emptying the page.",
            "The update popup's design preview is clearly labeled and disables every action — nothing in preview mode touches GitHub or any install tool."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.22",
        date: "2026-09-08",
        added: [
            "A dedicated Updates section in Settings — everything update-related now lives in one place: your current version and build, the available version, Check for Updates with the honest six-state status card (including 'Couldn't verify version' with Retry), the What's New changelog, one-tap access to the full update popup (in-app download with progress and verification, LiveContainer handoff, copy link, share), and the Change Log.",
            "A brand-new Music tab — a real dedicated section for anime openings and endings. Featured openers and endings rails with anime artwork, song titles, artists and episode ranges straight from the anime database, an All/Openings/Endings filter, and its own search across every anime's themes. Tap any track to jump straight to its anime. Themes are disk-cached, rate-limited, and parsed exactly as the database returns them — nothing is invented.",
            "A complete multi-source fallback architecture across the app: the Schedule now falls back from AniList to MyAnimeList's weekly airing list, then to a saved offline copy of your last good schedule; manga shelves fall back per-shelf; See All and search pages use the same provider fallback — and the fallback provider now works even without a linked MAL account, since discovery never needed one to begin with.",
            "Per-category storage clearing: the Storage page now lists anime episodes, manga chapters, image cache, website data, temp files, anime data, manga data, ID-mapping and profile metadata, music cache, schedule backup, search aliases, episode sort preferences, continue watching, and watch history — each with its own size, its own Clear button, and its own description of what clearing does."
        ],
        fixed: [
            "See All pages failing when AniList is unavailable: the provider fallback used to skip the backup source entirely whenever no MAL account was linked — even though browse, search, trending, and detail data never needed an account. It also skipped the fallback whenever AniList's API was 'disabled', which is precisely when a fallback matters. Both blocks are gone; every category page, search, and home shelf now gets its data from the next source automatically.",
            "Wrong-series data on fallback pages: opening a title that came from the backup source used to query AniList with a MyAnimeList id — which can resolve to a completely different series — mixing one title's info into another's page. Detail pages now resolve the real AniList id through the offline mapping service, verify the fetched title matches the one you tapped, and keep the correct data (skipping only AniList-only enrichment when no verified mapping exists).",
            "Manga shelves loading empty whenever AniList hiccuped: the Jikan fallback only triggered when AniList was officially 'disabled' or rate-limited, so plain outages and 5xx errors left the page blank. Every manga shelf now falls back individually, and backup entries carry proper manga typing (chapters, volumes, status, start year) instead of anime-shaped data.",
            "The Manga 'Latest' shelf had no backup source at all — it now falls back to the newest manga from MyAnimeList when AniList can't fill it."
        ],
        changed: [
            "Updates are never forced anymore. Every new version shows the custom update popup with the version numbers, what's new, and why updating may be recommended — and Maybe Later (or the close button) always works, for normal and critical updates alike. Falling several versions behind now shows a prominent 'updating is strongly recommended' banner instead of a lockout; the app stays fully usable either way.",
            "Update Log is now Change Log everywhere in the app (Settings, the manga settings page, and the page itself) — same clean release-by-release history, clearer name.",
            "Downloading is one clean interface now: the Download button on an episode or chapter row opens a unified sheet offering 'This Episode' (the exact existing source-and-stream flow, untouched) or 'Download Range' with From/To steppers, quick presets, and a live summary of exactly what will be downloaded (already-downloaded items are skipped and counted). The separate range button that used to sit in the Episodes header is gone — merged in.",
            "Advanced Cache Management is gone as a separate page — it merged into Storage, which separates offline content from re-downloadable caches at a glance and requires confirmation before anything important is removed. The single 'Clear All Cache' button was removed on purpose: every category clears on its own now."
        ],
        improved: [
            "The Schedule's offline safety net: every successful load refreshes a snapshot on disk, so when every source is unreachable the page still shows the last good schedule with an honest 'saved X ago' banner instead of a blank error screen. Backup-source entries show a NEW badge (their source carries no episode numbers) and resolve their AniList cross-references from the offline mapping cache so bells and library actions keep working where possible.",
            "Provider fallbacks no longer hammer dead APIs: the Jikan layer keeps its in-flight de-duplication, 2-minute cache, and request pacing across every screen that shares it; failed manifest and theme fetches are retried once, patiently, then reported honestly.",
            "The Music tab's search is debounced, cancellable, and cached per query; its featured rails refresh from a 30-minute disk cache, so repeat visits are instant and outages show a proper retry card rather than an empty page."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.21",
        date: "2026-09-07",
        added: [
            "Add to LiveContainer: the update popup now detects LiveContainer honestly (through the system's canOpenURL probe, with the scheme declared in the app's Info.plist) and, when it's actually installed, hands the update straight to it via LiveContainer's supported install link so LiveContainer downloads and installs the package itself. When LiveContainer isn't installed — or iOS refuses the open — the popup says exactly that and falls back to the useful basics: copy the IPA link, share it through the system share sheet, or open it in Safari. Nothing is ever faked: the handoff is real or the button isn't there.",
            "A real download flow behind the Update Now button: the IPA is fetched inside the app with a live progress bar, byte counts, and speed read from actual network callbacks — never a fake spinner — then verified against the release's published SHA-256 checksum. When no checksum is published, the success card says the package is unverified instead of pretending it passed; a mismatch deletes the corrupt file and says so. The verified package lands in Files (Shirox+ → Updates) and can be shared to any sideload tool.",
            "Copy Link (with inline 'Copied' confirmation) and Share actions are available in every state of the update popup — before, during, and after a download, and in every failure state."
        ],
        fixed: [
            "On iPad, the ambient fanart backdrop behind the carousel no longer keeps the previous slide's artwork on screen when you swipe — it resets together with the page, so the backdrop always matches the anime in front of it."
        ],
        changed: [
            "Dismissed updates no longer bounce the cover back up: the login-screen check now runs non-forced, so a version you chose to skip doesn't re-prompt on every visit to the sources page. A fresh re-offer stays one tap away in the About page."
        ],
        improved: [
            "The update popup is a full Shirox+ surface instead of a basic alert with one button: it shows the new version number and your installed version side by side in capsule pills, a clean expandable What's New section with the changelog and release date, custom gradient and tinted capsule buttons, staggered spring entrance, breathing ambient background, haptics, and a centered card that scales properly from the smallest iPhone to the largest iPad. Non-critical updates offer a Maybe Later action (and a close button in the header); updates that are actually required still gate the app when you fall several versions behind.",
            "Clear state coverage throughout: checking, connecting, downloading (with cancel), verifying, success, handed-off-to-LiveContainer, and failure each get their own honest card with the right actions — retry, copy link, open in Safari, or hand off to LiveContainer. The About page's Update and Install buttons now open this full popup instead of a raw Safari hop.",
            "The featured carousel is now visibly TVDB-first: while a slide's TVDB artwork is still resolving, the carousel holds its standard loading tint instead of painting the AniList image first — so TVDB's sharper posters (iPhone) and full 1920×1080 backgrounds (iPad) are what you actually see, and AniList's art appears only as the backup it was always meant to be, when TVDB has nothing for that title. Warm caches still paint instantly, and titles whose AniList id is unknown to the mapping service are now also resolved through their MAL id, so more slides get real TVDB artwork.",
            "The carousel's transparent title logo is about 40% larger, and every swipe now shows the title text first — readable for a moment — before the logo crossfades in to replace it. When a title has no TVDB logo at all, the text simply stays."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.20",
        date: "2026-09-07",
        added: [],
        fixed: [
            "The carousel's controls no longer move between slides. The logo, genre pills, and Start Watching button now live in reserved, constant-size rows: the transparent logo scales and centers inside its own fixed area regardless of the artwork's proportions, the pill row keeps its height even when a title has no genres, and the button's position is identical on every slide and every screen size, iPhone and iPad alike. Nothing about the carousel's design changed — same layout style, animations, swipe behavior, gradients, pagination, and logo placement.",
            "Carousel artwork now walks a complete fallback chain instead of ever going blank: TheTVDB remains the primary source for banners, posters, and the transparent logo (matched to the exact series and season through the ID-based mapping, so artwork from a similarly named anime can't slip in); the provider's own art is the first fallback; and a Jikan (MyAnimeList) lookup — cached, including failures — is the last resort when both earlier sources come up empty. Each failed request falls through to the next source automatically.",
            "The carousel no longer surfaces unrelated anime: Chinese animation and other non-Japanese entries that ride AniList's trending mix (\"Renegade Immortal\" and friends) are filtered out, the popularity floor that was supposed to keep obscure titles out is actually enforced now, and every slide must carry real title and artwork data before it can appear. The carousel still uses the same intended AniList trending selection — just cleaned."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.19",
        date: "2026-09-07",
        added: [
            "The home carousel now shows each title's official transparent logo. Where the plain title text used to sit, the banner's bottom-left corner — the spot official streaming platforms reserve for it — carries TheTVDB's clearlogo artwork for the exact series on screen: genuine official art with its transparency, proportions, and original look preserved, never cropped or stretched, and never boxed in by a border or background. Sizing is responsive, tuned to look right on both iPhone and iPad. The pick is equally deliberate: the English clearlogo when one exists, otherwise the best alternate — Japanese next, then any other language, each ranked by community score and resolution — and the familiar title text returns only when a title has no logo anywhere. Everything else about the carousel is untouched: banner art, swiping, parallax, gradient, and the TVDB poster system all behave exactly as before."
        ],
        fixed: [],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.18",
        date: "2026-09-06",
        added: [],
        fixed: [],
        changed: [
            "The required-update screen now offers exactly one action: Download from GitHub. Tapping it opens the new release's IPA download in Safari — the same hop the About page's Update button has always made. Nothing is downloaded inside the app, and no installer is probed, launched, or handed off to; however you sideload, your tool fetches the file from GitHub itself, so the single button serves every setup. The gate is unchanged where it matters: still impossible to dismiss, still re-checking whenever you return to the app, and still clearing the moment your installed version is current again. The About-page demo trigger (five taps on the version row) still previews the whole flow."
        ],
        improved: [],
        removed: [
            "In-app update download with live progress and SHA-256 verification, the AltStore install handoff (altstore://install?url=… plus the altstore entry in LSApplicationQueriesSchemes), and the share-package fallback — all replaced by the single GitHub download button."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "2.17",
        date: "2026-09-06",
        added: [
            "Forced updates, end to end. If the version you're running is behind the latest release, the app now locks itself behind a dedicated update screen the moment it launches — and re-checks whenever you open the login/sources page or return to the app. There's no dismissing it and no way past it until you're current: the update is downloaded inside the app (live percentage, megabytes, and speed), verified against the checksum published with the release, then handed to AltStore to install — and the app relaunches straight into the new version. The screen itself is a custom, animated experience that matches the app: an emblem with an orbiting sparkle ring that becomes your download progress, your version transitioning into the new one, the changelog of what's coming, springy state transitions, haptics on every state change, one-tap retry on failure, and a share-the-package fallback if AltStore isn't installed. You can preview the entire flow on demand: tap the version row on the About page five times to enter demo mode, and exit it from the screen itself."
        ],
        fixed: [],
        changed: [
            "The update check now drives a real gate instead of just a notification: a confirmed newer version raises it, only a confirmed-current version (or exiting demo mode) lowers it, and a failed network check never unlocks a known-outdated app."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.16",
        date: "2026-09-06",
        added: [
            "Tap any detail-page poster to open it full-screen — pinch to zoom, double-tap to zoom, drag down to dismiss. The lightbox enlarges the exact same image the page was showing (same TVDB/AniList source), so it never swaps to a different picture under your finger. Works on anime, module and manga detail pages.",
            "Long-press (or right-click on Mac) any detail-page title to copy it to the clipboard, with a confirmation toast so the copy isn't a silent no-feedback action.",
            "AniList activity notifications now name the user — \"GamerX liked your activity\" instead of a bare \"Activity liked your activity\" fragment — and forum notifications (thread comments, likes, mentions, replies) render as real sentences with the thread title and open the thread on AniList instead of showing a blank row.",
            "The in-player cast overlay now shows a reconnecting state, so a cast session recovering after a screen lock reads as \"reconnecting\" instead of dead controls."
        ],
        fixed: [
            "Streams that silently failed to load — the root cause is fixed. The player was watching the video item's status through a channel that drops the fast failure signal an expired CDN link produces, so it never learned the stream had died: no refetch, no error, just the loading overlay until a black frame replaced it. Every item now carries a proper observer (including items swapped in by quality/source switches, episode advances and recoveries), failures trigger an automatic fresh-URL refetch, and when recovery runs out of road you get a Retry button instead of a spinning wheel.",
            "Player launches could be silently dropped. UIKit refuses to present over a view controller that's still dismissing a sheet; the player now waits for the hierarchy to settle (up to ~2 seconds) instead of vanishing, and a double-tap on an episode row can no longer stack two players with competing audio.",
            "Chromecast and AirPlay dropping out mid-playback. The cast session survives screen locks (the SDK's suspend-on-background was the teardown trigger), commands route to whichever engine actually owns playback, quality switches re-issue to the TV instead of starting the new rendition on the phone, and auto-advance during a cast no longer plays episode 2 out of the handset.",
            "AirPlay to an Apple TV showing a black screen on header-protected streams: the receiver fetches the URL itself and auth headers don't travel with the handoff. Those streams now route through the phone's LAN proxy, which the TV's own fetch can authenticate against.",
            "Modules whose scripts hang could freeze the app — the stream picker spun forever and every later recovery was blocked. Both JavaScript bridges are now bounded (120s) and can only resume once; modules returning a raw value instead of a promise no longer hang batch download and sequel resolution.",
            "Pull-to-refresh on Browse appended the next page instead of reloading; refreshing a populated grid now starts over.",
            "A stale episode-range index could render an empty episode list with no way to recover (the range menu only appears above 100 episodes). Both detail pages clamp the range to what the show actually has.",
            "VTT subtitles that use a tab before the cue settings were silently dropped — the timestamp parser now splits on any whitespace.",
            "The Home tab crashed when trending emptied out (failed refresh, offline): the carousel indexed an empty array in exactly the branch that guards it. Same class of fix in the manga reader for empty chapter lists, plus it saves your page position when the app is swiped away mid-read.",
            "Failed social deletes and likes were silent or never rolled back — failures now show an error toast and restore the optimistic UI."
        ],
        changed: [
            "The home carousel now loads TVDB's high-resolution posters (typically 680×1000+) instead of AniList's smaller cover art, with a 100-point parallax buffer so swipes reveal image instead of hard edges — visibly sharper on every device.",
            "Exported logs no longer contain credentials. AniList access tokens, Jellyfin API keys, and Cloudflare session cookies are redacted before anything is written to logs.txt — safe to paste into bug reports.",
            "Control Center / lock screen transport controls now drive the same code paths as the on-screen buttons (correct cast routing, audio-session reactivation, playback speed preserved), and their registration is idempotent instead of stacking a duplicate set per playback rebuild."
        ],
        improved: [
            "Continue Watching's version wipe no longer leaves stale watched-markers behind, which silently marked episodes of a freshly cleared show as already seen.",
            "The player presents on the app's own window instead of whichever window happens to be first — presenting from the Cloudflare bypass window no longer buries the player.",
            "A player opened in portrait (Force Landscape off) now dismisses with the proper animation instead of skipping it and persisting a landscape orientation you never chose."
        ],
        removed: [],
        other: [
            "Synced with the upstream project's latest release (their 1.0.5 stream-fix batch, poster lightbox, cast/AirPlay rework, and notification improvements), merged on top of v2.15's subtitle/source/skip-intro work."
        ]
    ),
    UpdateLogEntry(
        version: "2.15",
        date: "2026-08-31",
        added: [
            "The Skip Intro button now auto-dismisses after 5 seconds, with a tiny live countdown (\"4s\", \"3s\"…) right on the button so you can see it's about to vanish. Re-entering a skip segment (or seeking back into one) brings it back with a fresh countdown.",
            "Embedded HLS subtitles are now routed through the app's own subtitle renderer. Streams whose manifests carry built-in subtitle tracks used to be rendered by the system player with default styling — silently ignoring your configured size, color and position. All subtitles now render through the custom overlay, no matter the source.",
            "Subtitles gained the full styling set in the player: bold text, outline color and width, font design (default / rounded / serif / monospaced), text opacity, line spacing, max caption width, drop-shadow distance, and a vertical nudge on top of the bottom padding.",
            "Source switching now survives dead servers: if the source you switch to fails to load (expired link, offline server), the player automatically falls back to the source you were watching instead of sitting on a black screen."
        ],
        fixed: [
            "Subtitle settings not applying in the player — root cause found and eliminated. The Settings → Subtitles page was writing to a completely separate set of stored keys that no player code ever read, while its preview rendered through its own drawing code. You could configure yellow bold subtitles and the player would keep showing its own defaults. The page now edits the exact same settings object the player renders from, and the landscape preview renders through the actual player overlay — what you preview is what plays. Any choices you'd already made on the old page are migrated over automatically.",
            "Switching sources from the in-player Source menu could look like a dead button. Providers that alias several source names onto the same video file hit an early return that skipped updating anything — the stream kept playing (correctly, same file) but the selection never moved, so it read as \"switching doesn't work\". Same-file switches now update the selection, subtitle tracks and title properly; genuinely different files switch as before.",
            "The Skip Intro button overlapped other player controls in portrait. It used to borrow the 85-second skip button's position via frame math that only worked in landscape — in portrait the wider label ran straight into the source / quality / audio buttons. It now sits in its own clear space at the bottom-right of the screen in both orientations (and the 85s button stays visible while a skip segment is active).",
            "The Skip Intro button appearing on episodes with no intro. Skip-timestamp data is now validated before use: segments must actually end after they start, \"from the beginning\" segments can't claim to end after 5 minutes (the shape bad episode-mappings produce), the segment must end before the video does, and the button needs at least 1.5 seconds of segment left to be worth showing.",
            "Deleting a source in Settings → Modules could delete a different source than the one you swiped. The installed list shows a filtered array (anime-only or manga-only per page), but the delete action was indexing the full unfiltered module list — with any manga module installed alongside anime modules, every delete removed the wrong row. Deletes now target the exact module from the row you tapped."
        ],
        changed: [
            "Settings → Subtitles was rebuilt around one shared subtitle engine. Presets, the color swatches, and every slider now write the live settings the player reads mid-playback, and the landscape test renders through the real player overlay at true size and position — the preview can no longer drift from reality."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.14",
        date: "2026-08-30",
        added: [
            "Live status header on the Downloads tab: an aggregate progress ring, total download speed, transfer size, and a Wi-Fi / Cellular / Offline network pill pinned above the list — one glance answers \"what is the app doing right now\". While the Wi-Fi-only gate is armed and you're on cellular it says so in orange instead of leaving a wall of \"Waiting…\" rows unexplained.",
            "All / Anime / Manga filter chips with live counts, shown once you have downloads of both types. They replace the old design's six stacked duplicate sections (Downloading, Downloading Manga, Failed, Failed Manga…) with one merged In Progress list and one merged Failed list — every row self-describes with its poster, episode or chapter, and progress.",
            "Completed downloads are grouped by series instead of by source module. Each show is a single row (poster, \"12 episodes · ModuleName\") that drills into a per-series page listing everything downloading, failed and downloaded for that title — with a header card (counts, source, size on disk) and a per-series Delete All that also cancels episodes still in flight. The old layout dumped every episode of every show into one alphabetized pile under a module header.",
            "Retry All button in the Failed section header (plus Retry All on the manager itself) — one tap re-queues every failed episode and chapter instead of tapping retry on each row.",
            "Per-series Delete All in the Downloads tab: swipe or context-menu a show row, confirm once, and every download for that title is removed in a single pass with one summary toast (new removeItems bulk API on both download managers)."
        ],
        fixed: [],
        changed: [
            "Both download detail pages (anime and manga) were rebuilt around one shared design: a hero card with the poster and a live progress-ring badge, a stats strip (speed / remaining / transferred — or pages for manga), a single grouped info card that now includes the source module, and state-aware actions. The old page showed the percentage three separate times (ring, stats, row) — the new one shows it once, properly.",
            "The redundant \"Done\" toolbar button on the download detail pages is gone — they're pushed pages with a back button, so \"Done\" just duplicated it."
        ],
        improved: [],
        removed: [
            "Dead code: DownloadRowView — the pre-v1.79 row component nothing referenced anymore."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "2.13",
        date: "2026-08-30",
        added: [
            "Wi-Fi-only downloads are real. The \"Download Over WiFi Only\" toggle had been sitting in the Downloads settings page for ages doing absolutely nothing — no download code ever read it (same placebo disease as the old Auto Pick settings). It now works end to end: while you're on cellular, new downloads stay queued as \"Waiting\" instead of starting, and anything already downloading pauses the moment the device drops to cellular — HLS downloads keep every segment already fetched (restart continues where they left off), MP4 downloads are cancelled with resume data so the restart picks up at the exact same byte, and manga chapters go back to the queue. Everything resumes automatically the instant Wi-Fi returns. The Downloads settings page now shows a live status line under the toggle (\"Downloads paused — you're on cellular\" / \"On Wi-Fi — downloads run normally\"), and adding a download while on cellular says \"waiting for Wi-Fi\" right in the toast instead of pretending it started.",
            "New NetworkMonitor service (NWPathMonitor) — one shared, always-current source of truth for whether the connection is metered (cellular, personal hotspot, expensive), feeding both download managers and the settings page. This closes a launch-time hole too: the first queue run after app start is delayed by a second so a cellular launch with Wi-Fi-only on can never slip past the gate before the monitor reports the network class.",
            "Background Downloads toggle added to the Downloads settings page. The setting already existed and was honored by the keep-alive logic (it controls whether downloads keep running when you switch apps) but there was no switch for it anywhere in the UI — a real setting with no way to turn it off."
        ],
        fixed: [
            "Backgrounding the app with HLS downloads in flight could mark them Failed. When iOS ends the ~30s background window (or background downloads are off), the app pauses HLS tasks and sets them back to Waiting — but the cancellation error then arrived asynchronously and overwrote the state to Failed with an error message, requiring a manual retry for something that was supposed to resume by itself. Cancellation errors are now recognized as deliberate in both download managers and no longer turn a pause into a failure.",
            "A manga chapter with one malformed page URL silently \"completed\" with pages missing. The page downloader skipped any URL that failed to parse — the chapter finished, looked fine in the list, and only revealed the holes when you read it. Page URLs are now all validated before downloading starts: one bad URL fails the chapter honestly with a clear error instead of shipping a chapter with gaps.",
            "The \"Auto-Download New Episodes\" toggle was removed — it was saved to storage and read by nothing (the second placebo found on that page). The Downloads settings now contain only settings that actually do something."
        ],
        changed: [
            "No Mac/Catalyst builds, per user decision: the build pipeline produces the iOS IPA only (the stale Mac artifact was already removed in v2.12 and the workflow never rebuilds it), and nothing Mac-related is referenced in the app."
        ],
        improved: [],
        removed: [
            "Auto-Download New Episodes toggle (placebo — never read by any code)."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "2.12",
        date: "2026-08-30",
        added: [
            "Clear Completed — the Downloads tab now has a toolbar action (top-right, only visible when something is completed) that removes every completed anime episode AND manga chapter in one pass, files included, with a confirmation dialog that tells you exactly how many entries will go. Downloads still in progress, waiting, or failed are untouched. Previously the only way to clean up after a 50-episode batch download was swiping rows one at a time."
        ],
        fixed: [
            "Crash hardening in the update checker: when a version you had previously dismissed appeared again in the update manifest, the code constructed the update info WITHOUT validating the manifest's download URL first — a malformed URL in apps.json would have crashed the app right at the update check. URL validation now guards every path that builds update info, and the URL parse can never crash: a bad manifest is reported as \"Couldn't verify version\", never as a crash.",
            "Crash hardening in the character sheet: the \"View on AniList\" link force-unwrapped the character's site URL from the API. A malformed or glitched URL from the AniList cache would have crashed the whole character page. The link now parses safely and simply hides if the URL is bad.",
            "Episode notifications told a small lie: if you picked a lead time (say \"15 minutes before\") for an episode airing sooner than that, the notification correctly fell back to firing at airtime — but its text still claimed \"Airs in 15 minutes\" when it fired. The body now describes when the notification actually fires: \"Is airing now\" when it fires at airtime, the lead-time text only when the lead time was genuinely honoured.",
            "Release page hygiene: the beta release carried a Mac (Catalyst) build from August 12 — missing every fix since v2.5, and never refreshed because the build workflow no longer produces it — and an IPA checksum file from August 4 that matched nothing (verifying a fresh download against it always failed). Both stale artifacts were removed, and the workflow now regenerates the checksum automatically on every build so it always matches the IPA it sits next to."
        ],
        changed: [
            "Bulk deletion in Downloads uses dedicated clearCompleted methods on both download managers instead of looping the per-item remove (which fires a toast per episode — clearing 50 episodes would have stacked 50 toasts); one summary toast reports the count."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.11",
        date: "2026-08-29",
        added: [
            "Manga downloads now have their own custom download page (MangaDownloadDetailView), mirroring the anime one: cover + chapter header with a status badge, a circular progress ring with page stats (pages on disk / total), an info list (chapter, page count, module, queued/completed dates, error details), and actions for every state — Read Chapter + Delete when completed (Read opens the reader directly on the downloaded pages, resuming your last-read position), Retry + Remove when failed, Cancel while downloading.",
            "Module Priority list in Auto Pick settings supports drag-to-reorder: long-press any module row and drop it where you want it — rows shift aside with a spring animation, haptics tick on each swap, and the new order is saved the moment you let go. A grip handle marks the affordance; the up/down arrows remain for one-step nudges."
        ],
        fixed: [
            "The app's home-screen icon label showed \"shirox\" instead of \"Shirox+\". Root cause: the v1.79 rename only set INFOPLIST_KEY_CFBundleDisplayName in the Xcode project file, but the iOS app target builds from a physical Info.plist (Shirox/Info.plist) — those INFOPLIST_KEY_ values are only applied when GENERATE_INFOPLIST_FILE is on, which this target doesn't use, so iOS fell back to CFBundleName (= PRODUCT_NAME = \"shirox\"). CFBundleDisplayName is now set directly in the Info.plist, so the springboard, App Switcher and Spotlight all show \"Shirox+\".",
            "Tapping a manga download in the Downloads tab opened the offline reading page (the manga detail view listing downloaded chapters) instead of the custom download UI — anime rows had been fixed in v1.79 but every manga row (downloading, completed, failed) still pushed the offline page. All manga rows now open the new custom MangaDownloadDetailView, and the completed-manga section lists each downloaded chapter as its own row (same per-episode layout the anime section already uses) so every individual download is one tap from its detail page.",
            "The Subtitles settings Live Preview card rendered a sample caption at 50% scale on the anime still — it could never show the true playback size (the card even carried a disclaimer admitting that) and it put text on the picture. The preview is now a clean anime still with zero text on it, and the \"Test in Landscape\" button sits on the picture itself instead of in its own section at the bottom of the page.",
            "The fullscreen landscape caption test carried extra chrome on the picture — a \"Landscape Preview\" title label and a \"Caption shown at actual playback size\" helper line. Both removed; the only remaining chrome is the Done button (top-right, needed to exit), so what you see is exactly the backdrop with your caption on it, the way it looks during playback."
        ],
        changed: [
            "Live Preview card layout: sample caption overlay, 40% black scrim and size disclaimer removed; the card is now the fetched anime backdrop at 200pt with a subtle bottom gradient for button legibility and the Test in Landscape capsule pinned to the bottom of the image."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.10",
        date: "2026-08-29",
        added: [
            "Auto Pick now shows live progress directly on the episode row you tapped: the play badge becomes a spinner and a status line (\"Trying HiAnime…\", \"Starting playback…\") appears under the episode title. No overlays, no popups — the row itself tells you what's happening.",
            "Auto Pick failure is now honest and recoverable: a toast names which modules failed and why (timed out, no results, episode not found…), and the normal manual stream picker opens automatically so a tap is never left dead.",
            "New Auto Pick Sub/Dub preference: streams are filtered by their SUB/DUB labels before quality scoring (with \"Any\" to disable the filter).",
            "The About page now shows when the version was last successfully verified (\"checked 3 minutes ago\"), and a dismissed update stays visible with an install button."
        ],
        fixed: [
            "The version check could show \"You're up to date\" with a green checkmark even when the check had never reached the server — every network failure was silently swallowed, making a dead check indistinguishable from a successful one. The checker now fetches the update manifest from three independent servers (raw.githubusercontent.com, the GitHub contents API, and the jsDelivr CDN mirror of the same file) and only fails when ALL three are unreachable; \"Couldn't verify version\" is now its own visible state with a Retry button instead of a fake all-clear.",
            "Auto Pick could permanently brick itself: a duplicate-trigger guard refused every new tap while any previous pick was still running, so one hung module blocked all future episodes until the app was restarted. Starting a new Auto Pick now cancels the in-flight run first — the newest tap always wins.",
            "Auto Pick had no timeout, so a single dead or hanging module stalled the entire module chain indefinitely. Every module now gets a hard 25-second budget (search + episodes + streams combined); when it expires the chain moves on to the next module and the failure is reported to module health.",
            "Auto Pick thrashed the app-wide active module, switching it before every attempt — including attempts that failed — which could leave you on the last-tried (broken) module after an Auto Pick failure. The global module is now switched exactly once: for the winner, right before playback starts.",
            "Auto Pick ranked stream quality by alphabetically sorting stream titles (a string comparison pretending to be quality analysis). Stream selection now parses the real resolution out of the title (2160/1440/1080/720/576/540/480/432/360/240), applies your Sub/Dub preference, breaks ties preferring HLS, and honours exact quality targets with nearest-above fallback (ask 1080p, get 1080p; if unavailable, the closest higher tier rather than an arbitrary entry).",
            "Auto Pick consulted the per-anime search alias of only the FIRST module in the priority list for every module it tried; each module now uses its own alias.",
            "Auto Pick started playback with an empty stream list, so in-player stream switching didn't work after an auto-picked episode. The player now receives the full stream list, matching the manual flow."
        ],
        changed: [
            "Auto Pick Module reworked from scratch into a dedicated AutoPickEngine — one run at a time with cancel-on-new-tap, per-module time budgets, a single global module switch for the winner, and request-ID logging with per-module durations for debugging.",
            "The Auto Pick settings page was rebuilt to contain only settings the engine actually reads: module priority order, preferred quality (Auto / 1080p / 720p / 480p / Highest / Lowest), the new Sub/Dub/Any audio preference, fallback on/off, and skip-unavailable-modules. Six placebo controls that were saved but never read by any code — audio language, subtitle language, preferred stream type, prefer-higher-quality, remember-per-anime, and a duplicate auto-fallback toggle — were removed.",
            "The update-check state is now an explicit state machine (not-checked / checking / up to date / available / dismissed / failed) that the About page renders distinctly, instead of a single optional value that conflated \"failed\" with \"current\"."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.9",
        date: "2026-08-29",
        added: [],
        fixed: [
            "Airing manga posters showed only \"Airing\" with no chapter count after it, while airing anime correctly showed \"Airing, N\". Root cause (verified live against the APIs): AniList, MyAnimeList/Jikan and Kitsu all leave the chapter field null while a manga is still releasing — they only fill in the total once a series finishes — so there was simply no in-house number to display for ongoing manga. The app now cross-references MangaUpdates (the one database that tracks the latest released chapter of ongoing series) by title with strict matching: an exact normalized-title hit with a compatible start year is accepted, anything less is treated as \"no data\" so a poster keeps an honest bare \"Airing\" instead of a wrong number. Counts are fetched in the background after the shelves render and patch in progressively (poster cards update in place as each count lands), cached on disk for 24 hours so repeat loads cost zero extra network calls. Airing manga posters now show \"Airing, N\" — N being the number of chapters currently available to read, not the eventual total — in the exact same format, size, font and position as the anime version, on the manga home shelves and in manga search results. Finished manga posters are unchanged.",
            "The notification bell icon was missing entirely from every row of the manga Releases section (the Reading Mode equivalent of the Schedule tab), while the anime Schedule section had it correctly on every row. The manga release card never carried a bell at all — it now renders the exact same bell as the anime Schedule card: same position (trailing edge of every row), same 32×32 size, same alignment, same constant \"bell.fill\" glyph with the yellow dot badge when a notification is on. Tapping it schedules or cancels the release notification through the same notification manager the anime schedule uses, and the on/off state is restored from the pending-notification list whenever the Releases tab loads, so bells stay in sync across app restarts. No existing buttons were removed or repositioned, and the calendar date selector is untouched."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.8",
        date: "2026-08-27",
        added: [],
        fixed: [
            "Schedule section cards rebuilt from scratch — the notification bell is now guaranteed to sit fully on-screen, and posters are guaranteed a perfectly straight leading edge. True root cause (finally identified): the badge row and the countdown row inside each schedule card used .fixedSize(), which made them refuse to compress; on content-heavy entries (Stream badge, longer date strings) and narrower devices the card's MINIMUM width exceeded the actual row width, so SwiftUI rendered the card wider than the screen and clipped the trailing bell off the right edge. This is also why every earlier fix (v2.4–v2.7) failed to fully correct it — those adjustments changed outer frames and symbol variants but never removed the incompressibility. New layout contract: only the poster (84×112) and the bell (32×32) have fixed widths; every badge, countdown, and date text is lineLimit(1) and fully compressible, truncating gracefully on tight rows instead of expanding the card — so the card can never exceed the row width on any device, the poster stays pinned to the leading edge on every row, and the bell stays pinned to the trailing edge, always fully visible. The manga release schedule cards received the same rework, and the calendar date selector at the top of the schedule is completely untouched."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.7",
        date: "2026-08-27",
        added: [],
        fixed: [
            "Anime and manga poster status text is inconsistent across posters — some airing titles showed a bare \"Airing\" while others showed an episode count. Replaced the old either/or logic (count if present, otherwise status word) with a single unified format: status and count ALWAYS shown together, separated by a comma — \"Airing, 8\", \"Finished, 12\" — same text size, font and bottom-left position on every anime and manga poster. For airing titles the count is the number of episodes/chapters released so far and currently available to watch/read (derived from AniList's nextAiringEpisode for anime — next episode number minus one — and from the live chapters count for manga), never the announced eventual total.",
            "Schedule section notification bell icon was still a tiny bit offset to the right across rows (barely noticeable residual after the v2.6 fix). Root cause: the bell's on/off states swapped between two SF Symbols — \"bell.fill\" and \"bell.badge.fill\" — whose bounding boxes have different widths; centered inside the same fixed 32×32 frame, the wider badged variant shifted its visible bell a couple of points left on rows with notifications enabled, so on/off rows never lined up in a perfectly straight line. The bell glyph now renders the constant \"bell.fill\" symbol on every row (identical x/y position always) with the on-state badge drawn as a small yellow dot overlaid at the bell's top-right shoulder — preserving both states' existing look while giving zero offset. Poster alignment/positioning in the Schedule section is completely untouched."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.6",
        date: "2026-08-26",
        added: [],
        fixed: [
            "Schedule section notification bell icon was being pushed off the right edge of the screen. Root cause: the v2.4 fix added an OUTER .frame(maxWidth: .infinity, alignment: .leading) modifier on the ScheduleCard body (after .padding/.background) which expanded the view's frame but allowed the inner HStack's natural width to grow unbounded — combined with the inner VStack's own .frame(maxWidth: .infinity), this caused the HStack to claim more horizontal space than the row actually had, pushing the bell past the right edge. Removed the redundant OUTER .frame modifier (kept the inner VStack's .frame(maxWidth: .infinity) which is sufficient to anchor the poster to the leading edge and let the bell sit at the trailing edge naturally). Also removed the redundant .frame(width: 32, height: 32) on the bell Button itself (the inner Image already has the same frame). MangaScheduleCard got the same cleanup."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.5",
        date: "2026-08-26",
        added: [],
        fixed: [
            "Schedule section posters were still appearing in different horizontal positions for certain entries (e.g. ONA-format shows). Root cause: the LazyVStack that renders the schedule cards defaulted to .center alignment, so any card whose NavigationLink wrapper didn't fully expand to fill the row width would get centered instead of leading-aligned — causing its poster to appear shifted right relative to cards that did fill the full width. Fixed by adding explicit alignment: .leading to both LazyVStacks (anime schedule + manga schedule) and .frame(maxWidth: .infinity, alignment: .leading) to each NavigationLink row so every card fills the full row width and anchors to the leading edge regardless of its content or format."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.4",
        date: "2026-08-26",
        added: [
            "Anime posters on Home now display the same small status text in the bottom-left corner that manga posters show — episode count (e.g. \"12 ep\") when episodes are populated, otherwise the status string (e.g. \"Airing\"). Matches the MangaPosterCard pattern exactly so anime and manga poster cards look consistent."
        ],
        fixed: [
            "Schedule section posters and notification bell icons are now perfectly aligned in a single straight line on every row — no per-card horizontal drift. The previous pass added a .frame(maxWidth: .infinity, alignment: .leading) on the inner VStack, which reduced but did not eliminate drift. This pass adds the same modifier to the OUTER body of both ScheduleCard and MangaScheduleCard (forcing the entire HStack to fill the row's full width and align leading), wraps the poster in a double .frame(width: 84, height: 112) so the poster's contribution to the HStack layout is identical on every row regardless of image loading state, and adds an explicit .frame(width: 32, height: 32) on the bell Button itself (not just the inner Image) so the bell's contribution is also identical on every row regardless of on/off state.",
            "Anime detail page poster now pulls from AniList's coverImage (extraLarge ?? large), matching the Home screen and long-press context menu preview. Previously the detail page used TVDBPosterImage which could resolve to a different TVDB-sourced poster than what Home and the context menu showed — making the same anime look like a different image when you navigated into it. The banner above the poster can still use TVDB fanart; only the small poster block needed to switch to AniList to match.",
            "Manga detail page section order now matches the anime detail page — Characters and Recommendations sections appear BEFORE the chapter list. Previously they appeared after the chapter list, which made them nearly unreachable on long manga (some have 100+ chapters, requiring an extremely long scroll past the chapter list to reach Characters/Recommendations). Now the order is: Synopsis → Buttons → Characters → Recommendations → Relations/Chapters (tab 0) or Connections (tab 1)."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.3",
        date: "2026-08-26",
        added: [],
        fixed: [
            "Ratings now display out of 10 (e.g. \"7.5\") instead of as a percentage (e.g. \"75%\") everywhere in the app. A previous fix was meant to apply this app-wide but only reached part of the Library section. This pass swept every screen that shows a rating — Home (anime + manga banners and posters), Library (grid card overlay + list view info), anime detail page (hero score badge + \"Rating\" info row + relations section), manga detail page (hero score badge + \"Rating\" info row), search result poster overlays, recommendation cards, and the anime notification detail page (hero score badge + \"Rating\" info row). No percentage-format ratings remain anywhere.",
            "Schedule section posters were horizontally misaligned across cards — some sat slightly left, some slightly right, instead of forming a single straight column. Same alignment issue that was previously fixed in the notification section. Applied the notification section's pattern to both ScheduleCard and MangaScheduleCard: the text column now absorbs all available width via .frame(maxWidth: .infinity, alignment: .leading), and the explicit Spacer between text column and bell was removed. The poster stays pinned to the leading edge and the bell stays pinned to the trailing edge on every card, regardless of title length or badge count."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "2.2",
        date: "2026-08-24",
        added: [],
        fixed: [
            "Auto Pick loading overlay removed — the progress overlay/spinner was unnecessary. Auto Pick now runs silently in the background and starts playback directly when a stream is found, with no visible loading animation."
        ],
        changed: [],
        improved: [],
        removed: [
            "Auto Pick progress overlay and autoPickStatus property — removed entirely per user request. No loading animation, no overlay, no spinner."
        ],
        other: []
    ),
    UpdateLogEntry(
        version: "2.1",
        date: "2026-08-24",
        added: [],
        fixed: [
            "Auto Pick playback not starting — root cause found: Auto Pick called onStreamsLoaded() which set pendingModuleStream, but since the Change Stream sheet was never opened (Auto Pick bypasses it), the sheet's onDismiss callback that actually calls selectStream() never fired. Playback was technically 'starting' in the logs but the player UI never received the stream. Fixed by calling selectStream() directly from autoPickAndPlay() instead of going through onStreamsLoaded().",
            "Auto Pick 30-second freeze — during the ~30 seconds between a Cloudflare rejection and streams being returned, the screen showed nothing (looked frozen). Added a progress overlay that shows the current step: 'Trying Miruro…' → 'Searching on Miruro…' → 'Fetching streams…' → 'Starting playback…'. The overlay uses the app's custom design language (regularMaterial card with accent-colored spinner).",
            "Schedule detail poster overflow — the hero poster image on the Schedule detail page was extending past the left edge of the screen. Added .clipped() to both the image's frame and the outer VStack to prevent any overflow."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: [
            "The 'Duplicate trigger ignored' warning is expected behavior — the guard correctly prevents duplicate Auto Pick executions. The double-trigger comes from SwiftUI re-rendering, which is inherent to the framework. The guard at the source (watchEpisode) is the correct fix — suppressing after the fact rather than trying to prevent the re-render itself."
        ]
    ),
    UpdateLogEntry(
        version: "2.0",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Manga cache key mismatch — MangaHomeView was requesting top/manga with limit=20 while the manga Schedule fallback requested the same endpoint with limit=25. Because the shared request layer's cache key is built from path + query items, these were treated as different requests and didn't share cache/dedup benefit. Standardized all manga top/manga call sites to limit=25 so they now hit the same cache key and deduplicate correctly."
        ],
        changed: [],
        improved: [
            "Section-level 'temporarily unavailable' UI state — when both AniList and Jikan fail for manga, the app now shows a clear, honest message: 'Manga data is temporarily unavailable. AniList and Jikan are both down. Please try again shortly.' instead of a generic error or blank section. Applied to manga Browse, manga Schedule, and manga Search. This only appears after the existing retry-once-with-backoff has been exhausted, not before."
        ],
        removed: [],
        other: [
            "Manga data loading is still dependent on Jikan's manga endpoints being healthy externally. The 504 errors on manga endpoints are confirmed as a Jikan-side issue (anime endpoints work fine through the same shared layer — only manga endpoints are 504-ing). What's fixed here is the app's own request behavior (cache key alignment) and its handling of the external failure (clear error state instead of blank/spinner)."
        ]
    ),
    UpdateLogEntry(
        version: "1.99",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Jikan request storm — root cause found and fixed. Multiple screens (Home, Manga Home, Schedule, Search) were independently calling the same Jikan endpoints (e.g. top/manga) within the same second, causing 3-4 concurrent requests that tripped Jikan's 3 req/sec rate limit and led to cascading 429/504 failures. Added a shared request layer to MALDiscoveryService that: (1) de-duplicates in-flight requests — if a request for the same URL is already running, subsequent callers await the same Task instead of firing a new one; (2) caches successful results for 120 seconds so screens loading shortly after each other reuse the cache; (3) rate-limits all outbound Jikan requests with a minimum 400ms spacing enforced app-wide."
        ],
        changed: [],
        improved: [
            "Jikan fallback reliability — the shared layer also handles retries (single retry on 429 after 2s, on 5xx after 3s) instead of each call site implementing its own retry logic. This prevents overlapping retries from interfering with each other (which caused the CancellationError logs)."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.98",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Jikan 502/504 fallback failures — Jikan's fetchList and fetchSingle now retry once after 3 seconds on 5xx errors (was: immediately throw). Also increased 429 backoff from 1s to 2s to reduce repeated rate-limit rejections when multiple fallback calls fire in quick succession.",
            "MAL token refresh spam for unauthenticated users — refreshIfNeeded now short-circuits immediately if there's no refresh token (user never signed in with MAL). Was previously attempting a network call that always failed with 'unauthenticated', logging the error every time.",
            "Search manga fallback — manga search now falls back to Jikan when AniList is unavailable. Previously only the Home and Schedule had fallback; Search had none."
        ],
        changed: [],
        improved: [
            "Jikan fallback logging — all Jikan 5xx retries are now logged with the endpoint path and status code, making it easy to trace which requests are failing.",
            "Backoff/retry limits — Jikan fetchList/fetchSingle retry at most once (was: unlimited for 429, none for 5xx). Prevents tight retry loops when Jikan is also down."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.97",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Manga and Schedule not loading when AniList is down — AniList is returning 403 'API temporarily disabled'. The app already had Jikan fallback for manga trending/popular, but the manga schedule tab had NO fallback at all. Added Jikan fallback for the manga schedule: when AniList fails, fetches top manga from Jikan's /top/manga endpoint. Also added topRated to the manga home Jikan fallback (was only fetching trending + popular). Jikan fallback errors are now logged instead of silently swallowed."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: [
            "The AniList 403 'API temporarily disabled due to severe stability issues' is a server-side issue on AniList's end — the API itself is down. The app handles it gracefully by falling back to Jikan/MAL. When AniList comes back online, pull-to-refresh will switch back automatically."
        ]
    ),
    UpdateLogEntry(
        version: "1.96",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Library layout — restored Grid/List toggle to the top-right toolbar as its own separate icon (next to Profile). Removed it from the filter row where it was incorrectly placed in v1.95. Filter row is back to its original left-aligned layout with just Status + Sort capsules.",
            "Schedule poster clipping — changed horizontal padding from hardcoded 16pt to .padding(.horizontal) which uses the system's safe area insets. Posters are no longer cut off on the left edge.",
            "Auto Pick duplicate execution — added autoPickInProgress state guard that prevents multiple Auto Pick operations from running simultaneously. When an Auto Pick is in progress, duplicate triggers are ignored and logged as '[AutoPick] Duplicate trigger ignored'. Each operation gets a unique request ID for log tracing. The guard is cleared when the operation completes (success or failure)."
        ],
        changed: [],
        improved: [
            "Auto Pick logging — every log line now includes a request ID (e.g. [AutoPick:ABCD1234]) so all messages for a single episode selection can be traced together. Duplicate triggers are logged separately as warnings."
        ],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.95",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Library alignment — moved the Grid/List toggle back into the filter row (filterCapsuleRow) so it shares alignment context with the Sort capsule. Was previously in the nav bar toolbar, which caused structural alignment drift between List/Grid modes. Now both controls are in the same HStack with consistent padding.",
            "Auto Pick Module functionality — when Auto Pick is ON, tapping an episode now runs the full automatic selection process: reads the module priority list, tries each module in order, searches for the anime, fetches episodes, matches the target episode, fetches streams, selects the best stream based on quality preference, and starts playback directly. No Change Stream UI is shown. If all modules fail, shows a clear error toast. Detailed logging for every step."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: [
            "When Auto Pick is OFF (default), the normal manual workflow is completely unchanged: Episode → Change Stream UI → Choose Module → Choose Stream → Watch.",
            "Auto Pick respects: module priority list, preferred quality (Auto/1080p/720p/480p), skip unavailable modules, and reports module health status."
        ]
    ),
    UpdateLogEntry(
        version: "1.94",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Manga section not loading — AniList HTTP 429 rate-limit errors were causing all manga queries to fail with no fallback. Added a 90-second rate-limit cooldown on AniListService.post() so the app stops sending requests that will also be rejected. When rate-limited, manga home now falls back to MAL/Jikan for trending and popular manga, same as the anime home already does. Anime home also updated to check rate-limit status before retrying."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.93",
        date: "2026-08-23",
        added: [],
        fixed: [
            "Schedule posters cut off on the left — restored the navigation title ('Schedule' / 'Releases') which was removed in v1.82. The empty title caused the content to extend under the safe area, clipping the leftmost poster. Posters are now fully visible with proper safe area insets.",
            "Duplicate Auto Pick settings — removed the inline toggle from the Streaming settings Advanced card. Now there's only ONE entry point: a NavigationLink to the full Auto Pick Settings page (which has its own master toggle). No more duplicate toggles for the same setting."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: [
            "Playback investigation — confirmed the 403/502 errors reported by the user are provider-side failures (pp.animex.one returning 403, multiple modules returning 502). The Auto Pick code does NOT touch the normal playback path — AniListDetailViewModel.watchEpisode() simply opens ModuleStreamPickerView (the manual picker), exactly as before. No Auto Pick code is referenced in the ViewModel, ModuleStreamPickerView, or DownloadModulePickerView. The normal manual workflow (Episode → Change Stream → Choose Module → Choose Stream → Watch) is completely unaffected by the Auto Pick toggle when it's OFF (the default).",
            "Update system verified — AppUpdateManager uses proper semantic version comparison (splits on '.', compares numeric components, handles 1.10 > 1.9 correctly). Network failures are handled gracefully. Manual 'Check for Updates' works. Cached results prevent spam."
        ]
    ),
    UpdateLogEntry(
        version: "1.92",
        date: "2026-08-23",
        added: [
            "Auto Pick Module Settings page (Settings → Streaming → Advanced → Auto Pick Settings) — experimental settings with collapsible sections for Module Priority, Quality Preferences, Audio & Subtitles, Fallback Settings, and Advanced. Clearly marked as Experimental with a purple banner. Disabled by default.",
            "Module Priority tier list — add/remove/reorder anime modules to set the priority order (#1 → #2 → #3 → #4). The app tries modules in this order when Auto Pick or Auto-Fallback is enabled. Shows module health status (green/yellow/red/orange dot) next to each module in the list. Includes a Reset Priority button.",
            "Preferred Quality setting (Auto, 1080p, 720p, 480p, Highest, Lowest) — Auto Pick considers this when choosing which stream to select.",
            "Preferred Audio setting (Auto, Japanese, English) — falls back to the next available if the preferred option isn't available.",
            "Preferred Subtitles setting (Auto, English, None) — same fallback behavior.",
            "Preferred Stream Type setting (Auto, Direct/MP4, Embedded/HLS).",
            "Additional Auto Pick preferences: Skip Unavailable Modules, Use Fallback Modules, Prefer Higher Quality, Remember Selection Per Anime. All organized in collapsible sections."
        ],
        fixed: [],
        changed: [
            "Search History reworked — history is now its own section/state. When the user is actively viewing search results, history is no longer shown underneath. History appears only when the query is empty and no search has been performed. Tapping a previous search performs it again.",
            "Surprise Me in History — the large Surprise Me button is replaced with a small shuffle icon in the history section header. The icon disappears when leaving the history section (e.g., when viewing search results). No duplicate Surprise Me buttons."
        ],
        improved: [],
        removed: [],
        other: []
    ),
    UpdateLogEntry(
        version: "1.91",
        date: "2026-08-23",
        added: [
            "Update Status card in Settings → About — shows 'You're up to date' with version number, or 'Update Available' with changelog and Update button. Includes a 'Check for Updates' button for manual checks. Handles network failures gracefully (shows 'Unable to check for updates' instead of falsely claiming up-to-date)."
        ],
        fixed: [
            "Schedule poster alignment — anime and manga schedule cards now have a fixed title height (42pt) so different title lengths no longer cause cards to shift vertically. All cards are the same height regardless of how long the title is."
        ],
        changed: [],
        improved: [],
        removed: [],
        other: []
    ),
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
        fixed: [],
        changed: [],
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
