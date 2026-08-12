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

    private var safeAreaBottomInset: CGFloat {
        #if os(iOS)
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0
        #else
        0
        #endif
    }

    private var controlsRiseOffset: CGFloat {
        #if os(iOS)
        let s = safeAreaBottomInset
        return max(16, s + 8) - s + 60
        #else
        60
        #endif
    }

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
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 24
            let maxTextWidth = proxy.size.width - horizontalPadding * 2
            let bottomOffset: CGFloat = 15 + max(0, CGFloat(settings.bottomPadding) - controlsRiseOffset)
            let controlsOffset: CGFloat = showControls ? -min(CGFloat(settings.bottomPadding), controlsRiseOffset) : 0

            VStack {
                Spacer()
                if settings.enabled, let cue = activeCue {
                    Text(cue.text)
                        .font(.system(size: settings.fontSize))
                        .foregroundStyle(settings.foregroundColor)
                        .shadow(color: outlineColor, radius: 0, x: -1, y:  0)
                        .shadow(color: outlineColor, radius: 0, x:  1, y:  0)
                        .shadow(color: outlineColor, radius: 0, x:  0, y: -1)
                        .shadow(color: outlineColor, radius: 0, x:  0, y:  1)
                        .shadow(radius: settings.shadowRadius)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: maxTextWidth)
                        .padding(.horizontal, 12)
                        .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
                        .background(
                            settings.backgroundEnabled
                                ? RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                                : nil
                        )
                        .padding(.bottom, bottomOffset)
                        .offset(y: controlsOffset)
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                        .transition(.identity)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.leading, proxy.safeAreaInsets.leading)
            .padding(.trailing, proxy.safeAreaInsets.trailing)
        }
    }
}
