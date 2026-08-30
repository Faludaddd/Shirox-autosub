import SwiftUI

/// Skip Intro / Recap / Credits / Preview button.
///
/// v2.15 — carries a small countdown chip showing how long until it
/// auto-dismisses (5 seconds after the segment becomes active). The chip is
/// driven by a `TimelineView` so it ticks every second even when the player's
/// periodic observer isn't firing (e.g. playback paused, controls hidden).
struct PlayerSkipButton: View {
    let segmentType: SkipSegmentType
    /// Wall-clock moment the segment became active. Non-nil arms the countdown.
    var activatedAt: Date? = nil
    let onSkip: () -> Void
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true

    static let autoDismissInterval: TimeInterval = 5

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        Button(action: onSkip) {
            HStack(spacing: isPad ? 8 : 5) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: isPad ? 18 : 15, weight: .medium))
                Text(segmentType.label)
                    .font(isPad ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if activatedAt != nil {
                    skipCountdown
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isPad ? 20 : 14)
            .frame(height: isPad ? 48 : 36)
            .glassChrome(Capsule(), enabled: playerLiquidGlass, off: Color.white.opacity(0.2))
        }
        .buttonStyle(.plain)
    }

    /// Very small countdown ("4s") in its own capsule, ticking once a second.
    /// Self-updating via TimelineView so it stays live regardless of how often
    /// the parent view re-renders.
    @ViewBuilder
    private var skipCountdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = remainingSeconds(now: context.date)
            if remaining > 0 {
                Text("\(remaining)s")
                    .font(.system(size: isPad ? 12 : 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
        }
    }

    private func remainingSeconds(now: Date) -> Int {
        guard let activatedAt else { return 0 }
        let elapsed = now.timeIntervalSince(activatedAt)
        return max(0, Int(ceil(Self.autoDismissInterval - elapsed)))
    }
}

struct PlayerSkipButton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSkipButton(segmentType: .intro, activatedAt: Date(), onSkip: {})
        }
    }
}
