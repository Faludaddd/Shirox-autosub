import SwiftUI

struct PlayerSubtitleOverlay: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    let showControls: Bool
    @ObservedObject var settings: SubtitleSettingsManager

    private var activeCue: SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        let adjustedTime = currentTime + settings.delaySeconds
        return cues.first { ($0.start...$0.end).contains(adjustedTime) }
    }

    // Safe area bottom inset (home indicator height on modern iPhones).
    private var safeAreaBottomInset: CGFloat {
        #if os(iOS)
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0
        #else
        0
        #endif
    }

    // How far the subtitle rises when controls appear.
    // Controls bottom bar occupies max(16, safeInset+8) inset from physical bottom
    // plus ~60pt for buttons+slider.  Subtract safeInset to get the height above
    // the safe area edge where the bar top sits.
    private var controlsRiseOffset: CGFloat {
        #if os(iOS)
        let s = safeAreaBottomInset
        return max(16, s + 8) - s + 60   // ≈ 68pt on modern iPhones
        #else
        return 60
        #endif
    }

    // Black outline for light text, white outline for dark text.
    private var outlineColor: Color {
        #if os(iOS) || os(tvOS)
        let ui = UIColor(settings.foregroundColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = NSColor(settings.foregroundColor).usingColorSpace(.deviceRGB) ?? .white
        let r = ns.redComponent
        let g = ns.greenComponent
        let b = ns.blueComponent
        #endif
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.5 ? .black : .white
    }

    var body: some View {
        // Issue #9 — GeometryReader ensures the subtitle container respects
        // the actual screen bounds in landscape. Without it, long caption
        // lines can overflow horizontally past the screen edge because the
        // VStack's intrinsic width isn't clamped to the viewport.
        GeometryReader { proxy in
            // Clamp the max caption width to 90% of the screen width (minus
            // horizontal padding) so text wraps instead of escaping the frame.
            let maxCaptionWidth = proxy.size.width * 0.9 - 32
            VStack {
                Spacer()

                if settings.enabled, let cue = activeCue {
                    Text(cue.text)
                        .font(.system(size: settings.fontSize))
                        .foregroundStyle(settings.foregroundColor)
                        // 4-directional outline
                        .shadow(color: outlineColor, radius: 0, x: -1, y:  0)
                        .shadow(color: outlineColor, radius: 0, x:  1, y:  0)
                        .shadow(color: outlineColor, radius: 0, x:  0, y: -1)
                        .shadow(color: outlineColor, radius: 0, x:  0, y:  1)
                        // drop shadow on top
                        .shadow(radius: settings.shadowRadius)
                        .multilineTextAlignment(.center)
                        // Issue #9 — Constrain the text width so it wraps
                        // instead of overflowing off-screen in landscape.
                        .frame(maxWidth: maxCaptionWidth)
                        .padding(.horizontal, 16)
                        .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
                        .background(
                            settings.backgroundEnabled
                                ? RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                                : nil
                        )
                        // Hidden floor: 8pt minimum above safe-area edge so the subtitle
                        // never sits flush with the screen bottom. Once bottomPadding
                        // exceeds controlsRiseOffset both states lift together.
                        .padding(.bottom, 15 + max(0, CGFloat(settings.bottomPadding) - controlsRiseOffset))
                        // Controls-visible rise is capped at controlsRiseOffset so the
                        // subtitle never overshoots the progress bar regardless of the
                        // slider value.
                        .offset(y: showControls ? -min(CGFloat(settings.bottomPadding), controlsRiseOffset) : 0)
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                        // No enter/exit animation between cues — cues snap in and out so
                        // text never lags behind audio.
                        .transition(.identity)
                }
            }
            // Issue #9 — Respect safe area insets so the subtitle never
            // escapes under the notch / home indicator in landscape. The
            // padding is applied INSIDE the GeometryReader so it doesn't
            // affect the width calculation above.
            .padding(.horizontal, max(8, proxy.safeAreaInsets.left))
            .padding(.bottom, proxy.safeAreaInsets.bottom > 0 ? 0 : 0)
        }
    }
}
