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
    private var maxStacked = 3

    var toastsEnabled: Bool {
        UserDefaults.standard.object(forKey: "inAppToastsEnabled") as? Bool ?? true
    }

    private init() {}

    func show(title: String,
              message: String,
              icon: String = "bell.fill",
              iconColor: Color = .accentColor,
              duration: TimeInterval = 4.0,
              action: (() -> Void)? = nil) {
        guard toastsEnabled else { return }
        let toast = ToastData(title: title, message: message, icon: icon,
                              iconColor: iconColor, duration: duration, action: action)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.toasts.append(toast)
            }
            if self.toasts.count > self.maxStacked {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.toasts.removeFirst()
                }
            }
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
/// Interactions:
/// - Tap the icon + text area (NOT the X button): fires the toast's
///   optional action and dismisses.
/// - Tap the X button: dismisses the toast WITHOUT firing the action.
///
/// The X button and the tap-to-act region are deliberately separated into
/// non-overlapping sub-views so SwiftUI's hit-testing can't intercept the
/// X button's tap with the parent's `.onTapGesture`. Previously both lived
/// in the same `HStack` with `.contentShape(Rectangle())` + `.onTapGesture`
/// covering the entire card — a known SwiftUI gesture conflict that made
/// the X button either do nothing or trigger the toast's action instead
/// of a clean dismiss. The fix: wrap ONLY the icon + text in a container
/// with the tap gesture, leaving the X button's region outside that
/// gesture entirely.
struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            // Tappable content area (icon + text + spacer). The tap
            // gesture is scoped to ONLY this region — the X button below
            // is a sibling, not a child, so its taps are never intercepted
            // by this gesture.
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle().fill(toast.iconColor.opacity(0.2))
                    Image(systemName: toast.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(toast.iconColor)
                }
                .frame(width: 36, height: 36)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(toast.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let action = toast.action { action() }
                ToastManager.shared.dismiss(toast.id)
            }

            // X close button — OUTSIDE the tap-gesture region above.
            // Its tap is handled exclusively by the Button's own action,
            // with no parent .onTapGesture competing for the hit.
            Button { ToastManager.shared.dismiss(toast.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .scaleEffect(stackIndex == total - 1 ? 1.0 : 0.95)
        .opacity(stackIndex == total - 1 ? 1.0 : 0.8)
        .allowsHitTesting(true)
    }
}
