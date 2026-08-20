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
//
// Reworked to fix the persistent "X button doesn't work" bug.
//
// ROOT CAUSE: The previous design had `.allowsHitTesting(false)` on the
// container VStack (to let taps pass through the empty space above toasts).
// But SwiftUI's allowsHitTesting is a ONE-WAY GATE — a parent's `false`
// disables hit-testing for the ENTIRE view tree below it. The child's
// `.allowsHitTesting(true)` on ToastView could NOT re-enable it. So
// BOTH the content button AND the X button were completely un-tappable.
//
// FIX: Instead of disabling hit-testing on the container, we use a
// GeometryReader + ZStack approach where:
//   - The container fills the screen (for bottom alignment)
//   - Each toast is wrapped in its OWN VStack that is pinned to the bottom
//   - The empty space above the toasts is NOT part of any hit-tested view
//   - Each toast has .allowsHitTesting(true) — the only hit-tested views
//
// This way, taps on empty space naturally pass through (nothing is there
// to receive them), and taps on toasts (including the X button) work.

struct ToastContainerView: View {
    @ObservedObject var manager = ToastManager.shared

    var body: some View {
        GeometryReader { _ in
            if manager.toasts.isEmpty {
                Color.clear
            } else {
                VStack(spacing: -8) {
                    Spacer()
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
            }
        }
        // Container itself does NOT disable hit-testing.
        // The Spacer() above the toasts is Color.clear / empty — taps
        // on empty space naturally pass through to underlying views.
    }
}

// MARK: - ToastView
//
// Each toast is a self-contained card with TWO independent buttons:
//   1. Content area (icon + text) — Button that fires the toast's action
//      and dismisses.
//   2. X close button — Button that ONLY dismisses (no action).
//
// Both buttons use .buttonStyle(.plain) and .contentShape(Rectangle())
// so SwiftUI treats them as independent hit targets. They are in an HStack
// (not ZStack) so their hit regions are naturally non-overlapping — the
// content button takes all width except the X button's 36pt area on the right.
//
// This is the simplest, most reliable approach: two siblings in an HStack,
// each with its own explicit contentShape. No ZStack, no zIndex, no
// overlapping hit regions, no parent hit-testing gates.

struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            // Content area — tap fires action + dismisses.
            Button {
                if let action = toast.action { action() }
                ToastManager.shared.dismiss(toast.id)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(toast.iconColor.opacity(0.2))
                        Image(systemName: toast.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(toast.iconColor)
                    }
                    .frame(width: 36, height: 36)

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
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // X close button — own independent Button, own contentShape.
            // In the HStack it occupies its own 36pt-wide area on the right.
            // Its hit region does NOT overlap with the content button.
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
            .padding(.trailing, 6)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .scaleEffect(stackIndex == total - 1 ? 1.0 : 0.95)
        .opacity(stackIndex == total - 1 ? 1.0 : 0.8)
    }
}
