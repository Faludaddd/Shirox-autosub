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
/// offset behind the newest.
struct ToastContainerView: View {
    @ObservedObject var manager = ToastManager.shared

    var body: some View {
        VStack(spacing: -8) {  // negative spacing for stacked/layered look
            ForEach(Array(manager.toasts.enumerated()), id: \.element.id) { index, toast in
                ToastView(toast: toast, stackIndex: index, total: manager.toasts.count)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9))
                    ))
                    .zIndex(Double(index))
            }
        }
        .padding(.top, 60)  // below status bar / nav
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }
}

// MARK: - ToastView

/// Individual frosted-glass toast card. The newest toast in the stack is
/// rendered fully opaque and at full scale; older toasts (higher stackIndex
/// relative to `total`) are scaled down and nudged up to create the layered,
/// "liquid glass" stack visual.
struct ToastView: View {
    let toast: ToastData
    let stackIndex: Int
    let total: Int

    var body: some View {
        let isTop = stackIndex == total - 1  // newest is on top

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

            // Close button (only on top toast)
            if isTop {
                Button {
                    ToastManager.shared.dismiss(toast.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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
        // Stacked visual: non-top toasts are scaled down and offset up
        .scaleEffect(isTop ? 1.0 : 0.95)
        .offset(y: isTop ? 0 : CGFloat((total - 1 - stackIndex)) * -6)
        .opacity(isTop ? 1.0 : 0.8)
        .onTapGesture {
            if let action = toast.action {
                action()
            }
            ToastManager.shared.dismiss(toast.id)
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width > 50 || abs(value.translation.height) > 50 {
                        ToastManager.shared.dismiss(toast.id)
                    }
                }
        )
    }
}
