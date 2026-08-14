import SwiftUI

// MARK: - LibraryDesignSystem
//
// Centralized sizing/style tokens for the Library tab. Every button, dropdown,
// pill, and chip in Library reads from these tokens so the whole surface
// looks like one cohesive design system — no random size drift between
// filter chips, sort menus, source pills, etc.
//
// To re-tune the Library's visual density, change the numbers here and
// every component picks up the new value automatically.

enum LibraryDS {
    // MARK: Heights

    /// Standard interactive height for all pills/chips/menus/toggles.
    /// Used by: filter chip, sort menu, source pill, media-type pill,
    /// grid/list toggle, view-mode segment.
    static let controlHeight: CGFloat = 34

    /// Smaller height for tightly-packed rows (e.g. the grid/list toggle
    /// icon button — square, sits at the end of the filter row).
    static let iconButtonSize: CGFloat = 30

    // MARK: Corner radii

    /// Capsule-style controls use Capsule() directly (no radius needed).
    /// Rounded-rectangle controls (cards, sheets) use this radius.
    static let cardCornerRadius: CGFloat = 14
    static let posterCornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8

    // MARK: Padding

    /// Horizontal padding inside a pill/chip (text + icon → edge).
    static let pillHorizontalPadding: CGFloat = 12
    /// Vertical padding inside a pill/chip.
    static let pillVerticalPadding: CGFloat = 7

    // MARK: Icon sizes

    static let pillIconSize: CGFloat = 12
    static let chevronSize: CGFloat = 9
    static let iconButtonIconSize: CGFloat = 13

    // MARK: Font sizes

    static let pillFont: Font = .system(size: 13, weight: .semibold)
    static let chipFont: Font = .system(size: 12, weight: .semibold)
    static let sectionHeaderFont: Font = .system(size: 15, weight: .bold)
    static let cardTitleFont: Font = .system(size: 15, weight: .semibold)
    static let cardMetaFont: Font = .system(size: 11, weight: .medium)
    static let cardCaptionFont: Font = .system(size: 10, weight: .medium)

    // MARK: Spacing

    /// Spacing between controls in the same row (e.g. filter chip + sort menu).
    static let controlSpacing: CGFloat = 8
    /// Spacing between cards in the list view.
    static let listCardSpacing: CGFloat = 8
    /// Spacing between sections in the sectioned list.
    static let sectionSpacing: CGFloat = 18
    /// Spacing between grid cards.
    static let gridSpacing: CGFloat = 14
    /// Horizontal padding for the whole list/grid container.
    static let containerHorizontalPadding: CGFloat = 14

    // MARK: Colors

    /// Background fill for an unselected pill.
    static let pillIdleFill = Color.secondary.opacity(0.10)
    /// Background fill for a selected pill (accent-tinted).
    static func pillSelectedFill(_ color: Color = Color.appAccent) -> Color {
        color.opacity(0.15)
    }
    /// Border for a selected pill.
    static func pillSelectedBorder(_ color: Color = Color.appAccent) -> Color {
        color.opacity(0.4)
    }
    /// Background fill for a card (list row).
    static let cardFill = Color.primary.opacity(0.04)
    /// Border for a card.
    static let cardBorder = Color.primary.opacity(0.07)
}

// MARK: - Reusable LibraryPill
//
// One pill style for every tappable chip in the Library. Capsule shape,
// fixed height, consistent icon+text+chevron layout. Used by:
//   • status filter chip
//   • sort menu
//   • source switcher pill
//   • media-type (Anime/Manga) pill
//   • view-mode (Library/History) pill

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
                .foregroundStyle(isSelected ? accentColor : .primary)
                .frame(height: LibraryDS.controlHeight - 2 * LibraryDS.pillVerticalPadding)
                .padding(.horizontal, LibraryDS.pillHorizontalPadding)
                .padding(.vertical, LibraryDS.pillVerticalPadding)
                .background(
                    Capsule().fill(isSelected
                        ? LibraryDS.pillSelectedFill(accentColor)
                        : LibraryDS.pillIdleFill)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? LibraryDS.pillSelectedBorder(accentColor) : Color.clear,
                        lineWidth: 1
                    )
                )
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
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: LibraryDS.pillIconSize, weight: .semibold))
            Text(text)
                .font(LibraryDS.pillFont)
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: LibraryDS.chevronSize, weight: .bold))
            }
        }
        .foregroundStyle(isSelected ? accentColor : .primary)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Reusable LibraryIconButton
//
// Square icon button used for the grid/list toggle. Fixed size, circular
// background, consistent with the pill row height.

struct LibraryIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: LibraryDS.iconButtonIconSize, weight: .semibold))
                .frame(width: LibraryDS.iconButtonSize, height: LibraryDS.iconButtonSize)
                .background(Circle().fill(LibraryDS.pillIdleFill))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
