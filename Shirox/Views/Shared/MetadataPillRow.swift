import SwiftUI

// MARK: - Metadata Pill (Batch 26 — the one shared pill component)
//
// The reusable metadata pill used by the anime carousel, the manga
// carousel, anime/manga details and any surface that shows genre /
// format / status / year / episode-count / rating chips.
//
// Design contract (the pill spec):
// • Slightly larger than the old chips — 13pt semibold text in a 30pt
//   capsule with 13pt horizontal padding.
// • The text is centered BOTH horizontally and vertically inside the
//   pill: the capsule frame fixes the height, fixedSize keeps the
//   content from being squeezed, and the HStack centers the content.
// • Every pill in a group is the same height; only width varies with
//   the text (never shrunk to unreadable sizes — 0.85 scale factor is
//   an emergency guard only).
// • The pill group centers inside its container and scrolls (never
//   clips) when it genuinely overflows.

struct MetadataPill: Identifiable, Hashable {
    let id: String
    let text: String
    /// Optional SF Symbol leading the text (e.g. "star.fill" for ratings).
    var icon: String? = nil
    /// Optional icon color (e.g. .yellow for stars).
    var iconColor: Color? = nil
    /// Dimmed style for overflow counters ("+3 more").
    var isOverflow: Bool = false

    init(text: String, icon: String? = nil, iconColor: Color? = nil, isOverflow: Bool = false) {
        self.id = text + (icon ?? "")
        self.text = text
        self.icon = icon
        self.iconColor = iconColor
        self.isOverflow = isOverflow
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(text) }
    static func == (lhs: MetadataPill, rhs: MetadataPill) -> Bool { lhs.id == rhs.id && lhs.text == rhs.text }
}

// MARK: - Single pill

struct MetadataPillView: View {
    let pill: MetadataPill
    /// Fixed capsule height shared by every pill in a group.
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 4) {
            if let icon = pill.icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(pill.iconColor ?? .primary)
                    .accessibilityHidden(true)
            }
            Text(pill.text)
                .font(.system(size: 13, weight: pill.isOverflow ? .semibold : .semibold))
                .foregroundStyle(pill.isOverflow ? .secondary : .primary)
                .lineLimit(1)
                // Emergency guard only — the pill grows with its text; it
                // is never intentionally shrunk to an unreadable size.
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .monospacedDigit()
        }
        // Fixed height + symmetric padding: every pill in a group is
        // exactly the same height and the content is vertically centered.
        .frame(height: height)
        .padding(.horizontal, 13)
        .frame(minHeight: height)
        .background(
            Capsule().fill(pill.isOverflow
                            ? Color.primary.opacity(0.06)
                            : Color.primary.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(
                Color.primary.opacity(pill.isOverflow ? 0.12 : 0.2),
                lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pill.text)
    }
}

// MARK: - The pill row (group centering + responsive overflow)

/// One row of metadata pills.
///
/// Layout contract (the pill-group spec):
/// • The ENTIRE GROUP is centered inside the row when the pills fit —
///   one pill, two pills, four pills, any text lengths: always centered
///   (the `maxWidth: .infinity` centering frame guarantees it).
/// • When the pills don't fit, the row scrolls horizontally — pills
///   never shrink below readable size, never clip mid-pill, never
///   overlap and never push the group off-screen.
/// • Consistent height, padding and 8pt spacing on every pill, every
///   surface, every device size.
/// • Edge fades on both sides signal scrollability without clipping
///   content abruptly (disable with `edgeFades: false`).
struct MetadataPillRow: View {
    let pills: [MetadataPill]
    /// Fixed capsule height (consistent within a row by construction —
    /// every pill in the row gets this height).
    var height: CGFloat = 30
    /// Group alignment inside the row. `.center` (default) centers the
    /// whole group; `.leading` keeps detail-page sections flush with
    /// their headers.
    var alignment: HAlignment = .center
    /// Horizontal edge fade when the row can scroll.
    var edgeFades: Bool = true
    /// The row sits over swipeable carousels in some callers — hit
    /// testing is off there so a horizontal strip can't eat swipes.
    var allowsHitTesting: Bool = false
    var spacing: CGFloat = 8

    enum HAlignment { case center, leading }

    private var hAlignment: Alignment {
        switch alignment {
        case .center: return .center
        case .leading: return .leading
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(pills) { pill in
                    MetadataPillView(pill: pill, height: height)
                }
            }
            // THE centering rule: the HStack expands to the scroll view's
            // full width and centers (or leads) within it. When the pills
            // are wider than the row, the content is simply scrollable —
            // no shrinking, no clipping, no overlap.
            .frame(maxWidth: .infinity, alignment: hAlignment)
        }
        .frame(height: height)
        .allowsHitTesting(allowsHitTesting)
        .mask {
            if edgeFades {
                HStack(spacing: 0) {
                    fade(rightToLeft: false)
                    Rectangle().frame(maxHeight: .infinity)
                    fade(rightToLeft: true)
                }
            } else {
                Rectangle()
            }
        }
    }

    /// A 22pt soft gradient fade at one edge — content underneath stays
    /// fully rendered; the fade just softens the row's edge.
    @ViewBuilder
    private func fade(rightToLeft: Bool) -> some View {
        LinearGradient(
            stops: rightToLeft
                ? [.init(color: .black, location: 0), .init(color: .clear, location: 1)]
                : [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading, endPoint: .trailing)
        .frame(width: 22)
    }
}

// MARK: - Media → pill builders (real metadata only)
//
// Every pill below comes from the Media object itself — the SAME object
// the surrounding surface renders. Fields that are nil produce NO pill
// (values are never invented).

extension MetadataPill {
    /// Rating pill ("8.7" with a star) — only when a real score exists.
    static func rating(_ score: Int?) -> MetadataPill? {
        guard let score, score > 0 else { return nil }
        return MetadataPill(text: score.averageScoreOutOf10, icon: "star.fill", iconColor: .yellow)
    }

    /// Year pill — only when a real year exists.
    static func year(_ year: Int?) -> MetadataPill? {
        guard let year, year > 0 else { return nil }
        return MetadataPill(text: String(year))
    }

    /// Format pill ("TV", "MOVIE"…) — only when the format exists.
    static func format(_ format: String?) -> MetadataPill? {
        guard let format, !format.isEmpty else { return nil }
        return MetadataPill(text: format)
    }

    /// Episode-count pill ("12 eps") — anime; only with a real count.
    static func episodes(_ count: Int?) -> MetadataPill? {
        guard let count, count > 0 else { return nil }
        return MetadataPill(text: "\(count) ep\(count == 1 ? "" : "s")")
    }

    /// Chapter-count pill ("128 ch") — manga; only with a real count.
    static func chapters(_ count: Int?) -> MetadataPill? {
        guard let count, count > 0 else { return nil }
        return MetadataPill(text: "\(count) ch")
    }

    /// Volume-count pill — manga.
    static func volumes(_ count: Int?) -> MetadataPill? {
        guard let count, count > 0 else { return nil }
        return MetadataPill(text: "\(count) vols")
    }

    /// Status pill ("Airing", "Finished", "Upcoming"…) — display word,
    /// only when the status exists.
    static func status(_ media: Media) -> MetadataPill? {
        guard let status = media.statusDisplay, !status.isEmpty else { return nil }
        return MetadataPill(text: status)
    }

    /// Duration pill ("24 min") — only with a real runtime.
    static func duration(_ minutes: Int?) -> MetadataPill? {
        guard let minutes, minutes > 0 else { return nil }
        return MetadataPill(text: "\(minutes) min")
    }

    /// Season pill ("Fall 2025") — anime; real season + year only.
    static func season(_ media: Media) -> MetadataPill? {
        guard let season = media.season, !season.isEmpty else { return nil }
        let label = media.seasonYear.map { "\(season.capitalized) \($0)" } ?? season.capitalized
        return MetadataPill(text: label)
    }
}

// MARK: - Row-level builders for the standard surfaces

enum MetadataPillRowBuilder {
    /// The ANIME carousel's metadata row: rating / format / year /
    /// episodes (whichever are real on this Media).
    static func animeMetaPills(for media: Media) -> [MetadataPill] {
        [MetadataPill.rating(media.averageScore),
         MetadataPill.format(media.format),
         MetadataPill.year(media.seasonYear),
         MetadataPill.episodes(media.episodes)]
            .compactMap { $0 }
    }

    /// The ANIME carousel's genre row: up to 6 real genres + an honest
    /// "+N" overflow pill when the list is longer.
    static func animeGenrePills(for media: Media, limit: Int = 6) -> [MetadataPill] {
        let genres = (media.genres ?? []).filter { !$0.isEmpty }
        guard !genres.isEmpty else { return [] }
        var pills = genres.prefix(limit).map { MetadataPill(text: $0) }
        if genres.count > limit {
            pills.append(MetadataPill(text: "+\(genres.count - limit)", isOverflow: true))
        }
        return pills
    }

    /// The MANGA carousel's metadata row: rating / format / status /
    /// year — manga-appropriate metadata, same pill design language.
    static func mangaMetaPills(for media: Media) -> [MetadataPill] {
        [MetadataPill.rating(media.averageScore),
         MetadataPill.format(media.format),
         MetadataPill.status(media),
         MetadataPill.year(media.seasonYear)]
            .compactMap { $0 }
    }

    /// The MANGA carousel's genre row — same rules as anime.
    static func mangaGenrePills(for media: Media, limit: Int = 6) -> [MetadataPill] {
        animeGenrePills(for: media, limit: limit)
    }
}
