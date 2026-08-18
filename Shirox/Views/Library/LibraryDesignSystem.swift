import SwiftUI

// MARK: - LibraryDesignSystem
//
// Centralized sizing/style tokens for the Library tab. Every button, dropdown,
// pill, chip, and toggle in Library reads from these tokens so the whole surface
// looks like one cohesive design system — no random size drift between
// filter chips, sort menus, source pills, media-type pills, etc.
//
// To re-tune the Library's visual density, change the numbers here and
// every component picks up the new value automatically.

enum LibraryDS {
    // MARK: Heights

    /// Standard interactive height for ALL pills/chips/menus/toggles.
    /// Used by: filter chip, sort menu, source pill, media-type pill,
    /// grid/list toggle, view-mode segment. Every control in the Library
    /// shares this exact height — no exceptions.
    static let controlHeight: CGFloat = 44

    // MARK: Corner radii

    /// Capsule-style controls use Capsule() directly (no radius needed).
    /// Rounded-rectangle controls (cards, sheets) use this radius.
    static let cardCornerRadius: CGFloat = 14
    static let posterCornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8

    // MARK: Padding

    /// Horizontal padding inside a pill/chip/capsule (text + icon → edge).
    /// Shared by every control in the Library.
    static let pillHorizontalPadding: CGFloat = 16
    /// Vertical padding inside a pill/chip/capsule.
    /// Shared by every control in the Library.
    static let pillVerticalPadding: CGFloat = 11

    // MARK: Icon sizes

    static let pillIconSize: CGFloat = 14
    static let chevronSize: CGFloat = 10
    static let iconButtonIconSize: CGFloat = 16

    // MARK: Font sizes

    static let pillFont: Font = .system(size: 15, weight: .medium)
    static let chipFont: Font = .system(size: 12, weight: .semibold)
    static let sectionHeaderFont: Font = .system(size: 15, weight: .bold)
    static let cardTitleFont: Font = .system(size: 15, weight: .semibold)
    static let cardMetaFont: Font = .system(size: 11, weight: .medium)
    static let cardCaptionFont: Font = .system(size: 10, weight: .medium)

    // MARK: Spacing

    /// Spacing between controls in the same row (e.g. filter chip + sort menu).
    static let controlSpacing: CGFloat = 10
    /// Spacing between cards in the list view.
    static let listCardSpacing: CGFloat = 8
    /// Spacing between sections in the sectioned list.
    static let sectionSpacing: CGFloat = 18
    /// Spacing between grid cards.
    static let gridSpacing: CGFloat = 14
    /// Horizontal padding for the whole list/grid container.
    static let containerHorizontalPadding: CGFloat = 14

    // MARK: Colors

    /// Background fill for an unselected pill (layered over .ultraThinMaterial).
    static let pillIdleTint = Color.clear
    /// Background fill for a selected pill (layered over .ultraThinMaterial).
    static let pillSelectedTint = Color.primary.opacity(0.12)
    /// Border for an idle pill.
    static let pillIdleBorder = Color.primary.opacity(0.2)
    /// Border for a selected pill.
    static let pillSelectedBorder = Color.primary.opacity(0.3)
    /// Background fill for a card (list row).
    static let cardFill = Color.primary.opacity(0.04)
    /// Border for a card.
    static let cardBorder = Color.primary.opacity(0.07)
}

// MARK: - libraryCapsuleStyle (shared ViewModifier)
//
// The single source of truth for every capsule-style control in the Library.
// Applied via `.libraryCapsuleStyle(isActive:)` — works on any view content
// (Button labels, Menu labels, plain HStacks). Ensures every control shares
// the EXACT same height, padding, corner radius, background, stroke, and
// material — no drift between status filter, sort, grid toggle, media-type
// pill, or source switcher pill.
//
// Usage:
//   HStack { Image(...); Text(...) }
//     .libraryCapsuleStyle(isActive: isSelected)
//
// Layout dimensions (calculated):
//   Height:     LibraryDS.controlHeight (38pt, fixed)
//   H padding:  LibraryDS.pillHorizontalPadding (14pt)
//   V padding:  LibraryDS.pillVerticalPadding (9pt)
//   Shape:      Capsule
//   Background: .ultraThinMaterial + active tint overlay
//   Stroke:     1pt, opacity 0.2 idle / 0.3 active
//   Font:       LibraryDS.pillFont (.system 14 medium)

struct LibraryCapsuleStyle: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(LibraryDS.pillFont)
            .foregroundStyle(.primary)
            .padding(.horizontal, LibraryDS.pillHorizontalPadding)
            .padding(.vertical, LibraryDS.pillVerticalPadding)
            .frame(minHeight: LibraryDS.controlHeight)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                // Active-state tint layered over the material (Material and
                // Color are different types, so we can't use a ternary
                // inside .fill() — layer a Color overlay instead).
                Capsule().fill(isActive ? LibraryDS.pillSelectedTint : LibraryDS.pillIdleTint)
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? LibraryDS.pillSelectedBorder : LibraryDS.pillIdleBorder,
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
    }
}

extension View {
    /// Apply the shared Library capsule style. Every control in the Library
    /// filter/toolbar area uses this to guarantee identical height, padding,
    /// corner radius, background, and stroke.
    func libraryCapsuleStyle(isActive: Bool = false) -> some View {
        modifier(LibraryCapsuleStyle(isActive: isActive))
    }
}

// MARK: - Reusable LibraryPill
//
// One pill style for every tappable chip in the Library. Uses
// `libraryCapsuleStyle` internally so it's guaranteed to match every
// other capsule control. Used by:
//   • source switcher pill (My Library / AniList / MAL)
//   • media-type (Anime/Manga) pill
//   • any future standalone pill

struct LibraryPill<Label: View>: View {
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        isSelected: Bool = false,
        accentColor: Color = Color.appAccent,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isSelected = isSelected
        self.accentColor = accentColor
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .libraryCapsuleStyle(isActive: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Convenience for a pill with icon + text + optional chevron.
struct LibraryPillContent: View {
    let systemImage: String
    let text: String
    var showChevron: Bool = false
    var isSelected: Bool = false
    var accentColor: Color = Color.appAccent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: LibraryDS.pillIconSize, weight: .semibold))
            Text(text)
                .font(LibraryDS.pillFont)
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: LibraryDS.chevronSize, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Reusable LibraryIconButton
//
// Square icon button used for the grid/list toggle. Uses the same capsule
// style as the pill row so it matches every other control's height and
// background.

struct LibraryIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: LibraryDS.iconButtonIconSize, weight: .semibold))
                .libraryCapsuleStyle()
        }
        .buttonStyle(.plain)
    }
}
