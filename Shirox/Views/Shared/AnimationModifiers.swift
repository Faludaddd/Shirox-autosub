import SwiftUI

// MARK: - LiquidGlassTransition

/// A namespace of reusable transition modifiers that define the Shirox app's
/// navigation animation language.
///
/// Use these transitions to keep motion consistent across navigation stacks,
/// tab switches, and modal presentations. Each property returns an
/// `AnyTransition` so callers can pass them directly to `.transition(_:)` or
/// combine them with their own animations.
enum LiquidGlassTransition {
    /// Slide + fade transition for pushing detail views onto a navigation
    /// stack. The incoming view enters from the trailing edge while the
    /// outgoing view exits toward the leading edge.
    static var pushTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    /// Slide + fade transition for popping detail views off a navigation
    /// stack. The incoming view enters from the leading edge while the
    /// outgoing view exits toward the trailing edge.
    static var popTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    /// Opacity + slight scale transition for switching between top-level tabs.
    /// The gentle scale keeps the switch feeling soft without dramatic motion.
    static var tabSwitchTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)),
            removal: .opacity
        )
    }

    /// Scale + opacity transition for bottom sheets and modal presentations.
    /// Both insertion and removal use a slight scale-down so the sheet feels
    /// like it grows out of / collapses back into the dimmed backdrop.
    static var modalTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        )
    }
}

// MARK: - SmoothTabTransition

/// A view modifier that applies a smooth, spring-driven tab-switch transition.
///
/// Conforms the wrapped view to the standard Shirox tab animation: an opacity
/// + slight scale insertion paired with a plain opacity removal, all driven by
/// a spring animation keyed off the selected tab value. Generic over the tab
/// value's `Hashable` identity so it works equally well with `Int`, `String`,
/// or custom enums.
struct SmoothTabTransition<Value: Hashable>: ViewModifier {
    /// The currently selected tab. Changes to this value trigger the transition.
    var selectedTab: Value

    func body(content: Content) -> some View {
        content
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                removal: .opacity
            ))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedTab)
    }
}

// MARK: - CarouselDotIndicator

/// An animated horizontal dot indicator for carousels and paged scroll views.
///
/// The active dot widens into a capsule and uses a spring animation when the
/// current page changes. When an optional `progress` binding is supplied, the
/// active dot's width interpolates during a swipe gesture so the indicator
/// tracks the user's finger instead of snapping per page boundary.
struct CarouselDotIndicator: View {
    /// The index of the currently active page.
    var currentPage: Int
    /// The total number of pages to render dots for.
    var pageCount: Int
    /// An optional binding representing swipe progress (`0.0` ... `1.0`).
    /// When supplied, the active dot interpolates smoothly toward the next
    /// page during a swipe gesture. When `nil`, dots only animate on page
    /// commit via the spring keyed off `currentPage`.
    var progress: Binding<CGFloat>?

    /// Width of the active (widened) dot.
    private let activeWidth: CGFloat = 24
    /// Width of inactive dots.
    private let inactiveWidth: CGFloat = 8
    /// Height of every dot.
    private let dotHeight: CGFloat = 8
    /// Horizontal spacing between dots.
    private let spacing: CGFloat = 8

    init(currentPage: Int,
         pageCount: Int,
         progress: Binding<CGFloat>? = nil) {
        self.currentPage = currentPage
        self.pageCount = pageCount
        self.progress = progress
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<max(pageCount, 0), id: \.self) { index in
                Capsule()
                    .fill(index == currentPage
                          ? Color.primary
                          : Color.primary.opacity(0.3))
                    .frame(width: dotWidth(for: index), height: dotHeight)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: currentPage)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Page \(currentPage + 1) of \(pageCount)"))
    }

    /// Computes the width of the dot at the given index.
    ///
    /// When no swipe is in progress (or `progress` is out of range), the
    /// current page's dot uses `activeWidth` and all others use
    /// `inactiveWidth`. While swiping, the active dot's width is interpolated
    /// between the two based on the fractional distance from the swipe
    /// position, producing a smooth "stretch" between adjacent dots.
    private func dotWidth(for index: Int) -> CGFloat {
        guard let progressValue = progress?.wrappedValue,
              (0...1).contains(progressValue),
              pageCount > 0,
              currentPage >= 0, currentPage < pageCount else {
            return index == currentPage ? activeWidth : inactiveWidth
        }

        let position = CGFloat(currentPage) + progressValue
        let distance = abs(CGFloat(index) - position)

        guard distance < 1 else { return inactiveWidth }
        return inactiveWidth + (activeWidth - inactiveWidth) * (1 - distance)
    }
}

// MARK: - View Extensions

extension View {
    /// Applies the liquid-glass push transition used when navigating to a
    /// detail view.
    ///
    /// Equivalent to `.transition(LiquidGlassTransition.pushTransition)`.
    /// Pair with `.animation(.spring(...), value:)` at the call site so the
    /// transition actually runs.
    func liquidGlassTransition() -> some View {
        self.transition(LiquidGlassTransition.pushTransition)
    }

    /// Applies a smooth, spring-driven tab-switch transition driven by the
    /// provided selected-tab value.
    ///
    /// - Parameter value: The `Hashable` identity of the selected tab. Any
    ///   change to this value triggers the asymmetric opacity + scale
    ///   transition with a spring(response: 0.35, dampingFraction: 0.85).
    func smoothTabSwitch<Value: Hashable>(value: Value) -> some View {
        modifier(SmoothTabTransition(selectedTab: value))
    }
}
