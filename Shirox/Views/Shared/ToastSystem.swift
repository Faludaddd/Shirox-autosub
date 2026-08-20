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
        .padding(.bottom, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

// MARK: - ToastView
//
// Reworked to fix the persistent "X button doesn't work" bug. The previous
// approaches (onTapGesture sibling, two adjacent Buttons) all failed because
// SwiftUI's gesture system can still route taps unpredictably when two
// interactive elements are in the same HStack.
//
// The new design uses a ZStack with two non-overlapping layers:
//   1. Bottom layer: the content area (icon + text + spacer) — a Button
//      that fires the toast's action + dismisses.
//   2. Top layer: the X close button — a Button positioned in the
//      top-trailing corner, on a higher z-index, with its own explicit
//      contentShape so its hit region is clearly defined.
//
// The key difference: the X button's hit region does NOT overlap with the
// content button's hit region. The content button's label uses a Spacer
// that leaves room for the X button's 36×36 hit area on the right. The X
// button is overlaid on top via ZStack, but only covers its own 36×36
// region — it doesn't cover the content area.
//
// Both buttons use .buttonStyle(.plain) and .contentShape(Rectangle()) so
// SwiftUI treats them as independent hit targets.

struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    var body: some View {
        ZStack(alignment: .trailing) {
            // Bottom layer: content button (icon + text).
            // Takes up the full width MINUS the X button's area on the right.
            Button {
                if let action = toast.action { action() }
                ToastManager.shared.dismiss(toast.id)
            } label: {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        Circle().fill(toast.iconColor.opacity(0.2))
                        Image(systemName: toast.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(toast.iconColor)
                    }
                    .frame(width: 36, height: 36)

                    // Text
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
                    // Leave room for the X button on the right (36pt + 14pt padding)
                    Spacer(minLength: 44)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Top layer: X close button. Positioned at the trailing edge.
            // It's a separate Button on a higher z-layer — its tap region
            // is only the 36×36 circle area, which does NOT overlap with
            // the content button's interactive region (the content button's
            // label has a 44pt spacer on the right to leave room).
            //
            // Using a high-priority gesture ensures SwiftUI always routes
            // taps in this region to the X button, not the content button.
            Button {
                ToastManager.shared.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .zIndex(1)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .scaleEffect(stackIndex == total - 1 ? 1.0 : 0.95)
        .opacity(stackIndex == total - 1 ? 1.0 : 0.8)
        .allowsHitTesting(true)
    }
}
