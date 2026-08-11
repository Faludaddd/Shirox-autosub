import SwiftUI

// MARK: - ToastData

/// A single, immutable toast payload. Equatable so SwiftUI animations can diff
/// on identity + content and `@Published` updates coalesce cleanly.
struct ToastData: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let icon: String          // SF Symbol name
    let iconColor: Color      // tint for the icon
    let duration: TimeInterval // auto-dismiss time, default 4s
    let action: (() -> Void)? // optional tap action

    // `action` is a closure — `==` can't compare closures, so we synthesize
    // equality on every other field and treat the action as opaque. Two toasts
    // are "equal" iff their visible content matches; the action never affects
    // the comparison (and thus never affects SwiftUI's view diffing).
    static func == (lhs: ToastData, rhs: ToastData) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.icon == rhs.icon
            && lhs.iconColor == rhs.iconColor
            && lhs.duration == rhs.duration
    }
}

// MARK: - ToastManager

/// Observable singleton that owns the live toast stack. Views overlay
/// `ToastContainerView` once and then any code path can fire a toast via
/// `ToastManager.shared.show(...)`.
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var toasts: [ToastData] = []
    private var maxStacked = 3  // max visible at once

    private init() {}

    func show(title: String,
              message: String,
              icon: String = "bell.fill",
              iconColor: Color = .accentColor,
              duration: TimeInterval = 4.0,
              action: (() -> Void)? = nil) {
        let toast = ToastData(title: title, message: message, icon: icon,
                              iconColor: iconColor, duration: duration, action: action)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.toasts.append(toast)
            }
            // Trim to maxStacked — remove oldest
            if self.toasts.count > self.maxStacked {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.toasts.removeFirst()
                }
            }
            // Auto-dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.dismiss(toast.id)
            }
        }
    }

    func dismiss(_ id: UUID) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                self.toasts.removeAll { $0.id == id }
            }
        }
    }

    func dismissAll() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.toasts.removeAll()
            }
        }
    }
}

// MARK: - ToastContainerView

/// The stacked overlay. Drop one of these on top of the app's root view; it
/// shows up to `maxStacked` toasts layered with later (older) ones slightly
/// offset behind the newest. Anchored to the BOTTOM of the screen, just above
/// the tab bar — so toasts slide up from the bottom edge and never collide
/// with the navigation bar / status bar.
///
/// #89 — the container fills the whole screen (so the toasts can be aligned
/// to the bottom via `.frame(maxHeight: .infinity, alignment: .bottom)`) but
/// the empty space above the toasts is touch-transparent so it never blocks
/// taps on the underlying content. Each individual toast re-enables hit
/// testing on itself.
struct ToastContainerView: View {
    @ObservedObject var manager = ToastManager.shared

    var body: some View {
        VStack(spacing: -8) {  // negative spacing for stacked/layered look
            ForEach(Array(manager.toasts.enumerated()), id: \.element.id) { index, toast in
                ToastView(toast: toast, stackIndex: index, total: manager.toasts.count)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9))
                    ))
                    .zIndex(Double(index))
            }
        }
        .padding(.horizontal, 16)
        // #89 — anchored just above the tab bar (~90pt). This keeps the toast
        // clear of the tab bar without overlapping it on any form factor.
        .padding(.bottom, 90)
        // Fill the whole screen so `.bottom` alignment can push the toast
        // stack to the bottom edge of the overlay.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The container itself is touch-transparent — empty space above the
        // toasts must NOT intercept taps on the underlying content. Each
        // toast re-enables hit testing for its own bounds below.
        .allowsHitTesting(false)
    }
}

// MARK: - ToastView

/// Individual frosted-glass toast card. The newest toast in the stack is
/// rendered fully opaque and at full scale; older toasts (higher stackIndex
/// relative to `total`) are scaled down and nudged up to create the layered,
/// "liquid glass" stack visual.
///
/// #89 — Interactions (top toast only):
/// - Tap: fires the optional action (if any) and dismisses.
/// - Swipe (any direction) past threshold: dismisses. The toast is COMPLETELY
///   STATIC during the drag — no visual offset, no revealed-behind panel.
///   The gesture only inspects the final translation at gesture END.
/// - Inline "X" button on the trailing edge: tap to dismiss at any time.
struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    /// #89 — Horizontal translation past which a swipe commits to dismissal.
    private let horizontalDismissThreshold: CGFloat = 80
    /// #89 — Vertical translation past which a swipe commits to dismissal.
    private let verticalDismissThreshold: CGFloat = 50

    var body: some View {
        let isTop = stackIndex == total - 1  // newest is on top of the stack

        HStack(spacing: 12) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(toast.iconColor.opacity(0.2))
                Image(systemName: toast.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(toast.iconColor)
            }
            .frame(width: 36, height: 36)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(toast.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // #89 — Inline "X" dismiss button, ALWAYS visible within the
            // toast's own bounds. No separate panel, no revealed-behind
            // layer — just a small circular close button on the trailing
            // edge. Only the top (interactive) toast shows it; older stacked
            // toasts hide it since they're not directly dismissible anyway.
            Button {
                Haptics.light()
                ToastManager.shared.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.secondary.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .opacity(isTop ? 1 : 0)
            .disabled(!isTop)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)  // liquid glass / frosted
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        // Stacked visual: non-top toasts are scaled down and nudged up.
        // These transforms are layout-only (driven by stackIndex, not user
        // input) — the toast itself never moves in response to a drag.
        .scaleEffect(isTop ? 1.0 : 0.95)
        .offset(y: isTop ? 0 : CGFloat((total - 1 - stackIndex)) * -6)
        .opacity(isTop ? 1.0 : 0.8)
        // #89 — Tap fires the optional action (if any) and dismisses.
        .contentShape(Rectangle())
        .onTapGesture {
            if let action = toast.action {
                action()
            }
            ToastManager.shared.dismiss(toast.id)
        }
        // #89 — Swipe-to-dismiss: the gesture ONLY inspects the final
        // translation on gesture END. It does NOT update any state during
        // the drag, so the toast stays COMPLETELY STATIC — no offset is
        // applied to the view at any point. We just decide at the end
        // whether the swipe was big enough to commit to dismissal.
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    guard isTop else { return }
                    let t = value.translation
                    // Horizontal swipe (either direction) past threshold.
                    if abs(t.width) > horizontalDismissThreshold {
                        // #96 — Light haptic feedback when the toast is swiped away.
                        Haptics.light()
                        ToastManager.shared.dismiss(toast.id)
                    } else if abs(t.height) > verticalDismissThreshold {
                        // Vertical swipe (either direction) past threshold.
                        Haptics.light()
                        ToastManager.shared.dismiss(toast.id)
                    }
                    // Otherwise: do nothing. The toast stays put — no snap-
                    // back animation needed because it never moved.
                }
        )
        // #89 — Re-enable hit testing on this individual toast so taps /
        // swipes / the X button all work, even though the parent container
        // has `.allowsHitTesting(false)`.
        .allowsHitTesting(true)
    }
}
