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
        .padding(.bottom, 100)  // just above the tab bar
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .allowsHitTesting(true)
    }
}

// MARK: - ToastView

/// Individual frosted-glass toast card. The newest toast in the stack is
/// rendered fully opaque and at full scale; older toasts (higher stackIndex
/// relative to `total`) are scaled down and nudged up to create the layered,
/// "liquid glass" stack visual.
///
/// Interactions (top toast only):
/// - Tap: fires the optional action (if any) and dismisses.
/// - Swipe LEFT: slides the card leftward, revealing a red "Dismiss" action
///   behind it. Release past the threshold to dismiss; otherwise snap back.
/// - Swipe DOWN: dismisses immediately past the threshold.
struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    /// Live drag translation; only the top toast updates this.
    @State private var dragOffset: CGSize = .zero

    /// Horizontal translation (negative) past which a leftward swipe commits
    /// to dismissal.
    private let leftDismissThreshold: CGFloat = -100
    /// Vertical translation (positive) past which a downward swipe commits
    /// to dismissal.
    private let downDismissThreshold: CGFloat = 50

    var body: some View {
        let isTop = stackIndex == total - 1  // newest is on top of the stack

        ZStack {
            // Red "Dismiss" action — revealed behind the card as the user
            // swipes left. Only the top (interactive) toast can reveal it.
            if isTop && dragOffset.width < -8 {
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Dismiss")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.red.opacity(0.92))
                )
                .transition(.opacity)
            }

            // Toast content
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
            // Stacked visual: non-top toasts are scaled down and nudged up
            .scaleEffect(isTop ? 1.0 : 0.95)
            .offset(y: isTop ? 0 : CGFloat((total - 1 - stackIndex)) * -6)
            .opacity(isTop ? 1.0 : 0.8)
            // Drag offset — only the top toast receives drags, so non-top
            // toasts always have dragOffset == .zero and are unaffected.
            .offset(x: dragOffset.width, y: dragOffset.height)
            .onTapGesture {
                if let action = toast.action {
                    action()
                }
                ToastManager.shared.dismiss(toast.id)
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard isTop else { return }
                        // Constrain to leftward (negative width) and downward
                        // (positive height) translations only — swiping right
                        // or up does nothing, which keeps the gesture intuitive.
                        var translation = CGSize.zero
                        if value.translation.width < 0 {
                            translation.width = value.translation.width
                        }
                        if value.translation.height > 0 {
                            translation.height = value.translation.height
                        }
                        dragOffset = translation
                    }
                    .onEnded { value in
                        guard isTop else { return }
                        if value.translation.height > downDismissThreshold {
                            // Swipe DOWN — dismiss immediately.
                            // #96 — Light haptic feedback when the toast is swiped away.
                            Haptics.light()
                            ToastManager.shared.dismiss(toast.id)
                        } else if value.translation.width < leftDismissThreshold {
                            // Swipe LEFT past threshold — dismiss.
                            // #96 — Light haptic feedback when the toast is swiped away.
                            Haptics.light()
                            ToastManager.shared.dismiss(toast.id)
                        } else {
                            // Release without crossing a threshold — snap back.
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
        }
    }
}
