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
