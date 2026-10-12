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

// MARK: - SpringPressStyle (v2.34)

/// An elastic, spring-based press: the control scales down slightly under
/// the finger and springs back with a touch of overshoot on release — the
/// tactile counterpart to the gooey pull-to-refresh, applied only where a
/// control deserves the emphasis (primary onboarding actions, setup cards,
/// theme options).
struct SpringPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.955
    var response: CGFloat = 0.32
    var damping: CGFloat = 0.62

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: response, dampingFraction: damping),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SpringPressStyle {
    /// The app's elastic press style — see `SpringPressStyle`.
    static var springPress: SpringPressStyle { SpringPressStyle() }
}

// MARK: - TabIconAnimator (v2.34)

#if os(iOS)
/// Animates the REAL tab bar icons when a tab is selected — Settings ›
/// Appearance › Animated Tab Icons.
///
/// SwiftUI's system tab bar (`Tab`/`tabItem`) exposes no public way to
/// animate its icons, and replacing the system bar wholesale would risk the
/// app's navigation behavior. So this works WITH the system bar: it walks
/// the live view hierarchy for the `UITabBar`, finds the icon view nearest
/// the selected slot's horizontal position, and runs a small UIKit spring
/// transform on it — a scale pop for most tabs, a downward nudge for
/// Downloads (the "download" motion), and a settle-back. Render-only, no
/// layout change; if the walk finds nothing (an OS redesign, Catalyst's
/// sidebar, an off-screen bar), it's a clean no-op.
@MainActor
enum TabIconAnimator {
    /// UserDefaults key for the Animated Tab Icons setting.
    static let settingKey = "animatedTabIcons"

    /// Pop the selected tab's icon. `index` is the tab's position (0-based),
    /// `count` the number of tabs in the bar.
    static func animateSelection(index: Int, count: Int) {
        guard UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true,
              !UIAccessibility.isReduceMotionEnabled,
              count > 0, index >= 0, index < count else { return }

        guard let tabBar = Self.tabBar(), let icon = Self.iconView(in: tabBar, slot: index, count: count) else {
            return
        }

        // The motion, per tab meaning: Downloads dips down (the direction
        // downloads go), everything else pops up in place.
        let transform: CGAffineTransform = index == 2
            ? CGAffineTransform(translationX: 0, y: 4).concatenating(
                CGAffineTransform(scaleX: 1.12, y: 1.12))
            : CGAffineTransform(scaleX: 1.22, y: 1.22)

        UIView.animate(withDuration: 0.16, delay: 0,
                       usingSpringWithDamping: 0.55, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction, .curveEaseOut]) {
            icon.transform = transform
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.5, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .curveEaseOut]) {
                icon.transform = .identity
            }
        }
    }

    /// The first live `UITabBar` in the key window's hierarchy (SwiftUI's
    /// `TabView` hosts a real one on iPhone/iPad).
    private static func tabBar() -> UITabBar? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        for window in windows where window.isKeyWindow {
            if let bar = Self.firstSubview(of: UITabBar.self, in: window) {
                return bar
            }
        }
        // Fall back to any window at all (e.g. during transitions).
        for window in windows {
            if let bar = Self.firstSubview(of: UITabBar.self, in: window) {
                return bar
            }
        }
        return nil
    }

    private static func firstSubview(of kind: AnyClass, in view: UIView) -> UIView? {
        if view.isKind(of: kind) { return view }
        for subview in view.subviews {
            if let found = firstSubview(of: kind, in: subview) { return found }
        }
        return nil
    }

    /// The tab bar's small square-ish subviews are the icons. The one
    /// closest to the selected slot's horizontal center wins — no private
    /// class names, no assumptions about internal structure beyond "icons
    /// sit above their labels inside the bar".
    private static func iconView(in tabBar: UITabBar, slot: Int, count: Int) -> UIView? {
        let slotCenterX = tabBar.bounds.width * (CGFloat(slot) + 0.5) / CGFloat(count)
        var best: (view: UIView, distance: CGFloat)?

        func visit(_ view: UIView) {
            let size = view.bounds.size
            let plausibleIcon = size.width >= 10, size.width <= 44,
                                  size.height >= 10, size.height <= 44,
                                  abs(view.center.x - slotCenterX) < tabBar.bounds.width / CGFloat(count)
            if plausibleIcon {
                let distance = abs(view.center.x - slotCenterX)
                if best.map({ distance < $0.distance }) ?? true {
                    best = (view, distance)
                }
            }
            for subview in view.subviews { visit(subview) }
        }
        visit(tabBar)
        return best?.view
    }
}
#endif
