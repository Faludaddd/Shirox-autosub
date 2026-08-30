import SwiftUI

/// The styled caption text, shared by EVERY subtitle surface.
///
/// v2.15 — one renderer for the in-player overlay AND the Settings preview,
/// so the preview can never drift from what actually plays. All styling is
/// read live from `SubtitleSettingsManager`.
struct SubtitleCaptionText: View {
    let text: String
    @ObservedObject var settings: SubtitleSettingsManager
    /// Hard cap for the caption width (points). When nil, the caller's
    /// container is expected to constrain width via `frame(maxWidth:)`.
    var maxWidthCap: CGFloat? = nil

    /// Outline color: auto-contrast with the text color so the caption stays
    /// legible on any background (white text → black outline and vice versa).
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

    /// Outline width scales with font size so big text keeps a proportional
    /// rim, capped so it never swallows the glyphs.
    private var outlineWidth: CGFloat {
        let raw = CGFloat(settings.resolvedStrokeWidth) * max(1, settings.fontSize / 24.0)
        return min(raw, 6)
    }

    /// Line spacing in points, derived from the multiplier and the font size.
    private var lineSpacingPoints: CGFloat {
        CGFloat((settings.lineSpacingMultiplier - 1.0) * settings.fontSize * 0.5)
    }

    var body: some View {
        let stroke = outlineWidth
        let strokeColor = SubtitleSettingsManager.color(fromName: settings.strokeColorName)
        let useAutoOutline = settings.resolvedStrokeWidth <= 0

        Text(text)
            .font(.system(size: settings.fontSize,
                          weight: settings.boldText ? .bold : .regular,
                          design: settings.fontDesign))
            .foregroundStyle(settings.foregroundColor.opacity(settings.textOpacity))
            .multilineTextAlignment(.center)
            .lineSpacing(lineSpacingPoints)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
            .background(
                settings.backgroundEnabled
                    ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.6))
                    : nil
            )
            .modifier(SubtitleOutlineModifier(
                color: useAutoOutline ? outlineColor : strokeColor,
                width: useAutoOutline ? 1 : stroke
            ))
            // Soft glow — the baseline look every existing install has
            // (`shadowRadius`, default 2).
            .shadow(color: .black.opacity(0.35), radius: max(CGFloat(settings.shadowRadius), 0))
            // Directional drop shadow — v2.15 addition (`shadowOffset`, 0 = off).
            .shadow(color: .black.opacity(settings.shadowOffset > 0 ? 0.5 : 0),
                    radius: CGFloat(max(settings.shadowOffset, 0)),
                    x: 0,
                    y: CGFloat(max(settings.shadowOffset / 2.0, 0)))
            .frame(maxWidth: maxWidthCap, alignment: .center)
    }
}

/// 8-direction text outline. A stroke of width `w` is drawn by shadowing the
/// text in all compass directions — the only reliable way to outline SwiftUI
/// `Text` without Core Text.
struct SubtitleOutlineModifier: ViewModifier {
    let color: Color
    let width: CGFloat

    func body(content: Content) -> some View {
        if width <= 0 || color == .clear {
            content
        } else {
            let w = width
            content
                .shadow(color: color, radius: 0, x: -w, y:  0)
                .shadow(color: color, radius: 0, x:  w, y:  0)
                .shadow(color: color, radius: 0, x:  0, y: -w)
                .shadow(color: color, radius: 0, x:  0, y:  w)
                .shadow(color: color, radius: 0, x: -w, y: -w)
                .shadow(color: color, radius: 0, x:  w, y: -w)
                .shadow(color: color, radius: 0, x: -w, y:  w)
                .shadow(color: color, radius: 0, x:  w, y:  w)
        }
    }
}

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

    var body: some View {
        GeometryReader { proxy in
            // Safe-area-aware horizontal padding so the caption never overflows
            // past the notch / home indicator in landscape. The available text
            // width is computed AFTER subtracting both the outer padding and
            // the inner text padding so multi-line wrapping has the full
            // visible width to break against.
            let outerPadding: CGFloat = 16
            let safeLR = proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            // Max width: user's percentage of the visible width, clamped so
            // the caption can never touch the screen edges.
            let widthBudget = max(160, proxy.size.width - safeLR - outerPadding * 2)
            let availableWidth = min(widthBudget, widthBudget * CGFloat(min(max(settings.maxWidthPercent, 50), 100) / 100.0))
            let bottomOffset: CGFloat = 15 + max(0, CGFloat(settings.bottomPadding) - controlsRiseOffset) + CGFloat(settings.verticalOffset)
            let controlsOffset: CGFloat = showControls ? -min(CGFloat(settings.bottomPadding), controlsRiseOffset) : 0

            VStack {
                Spacer()
                if settings.enabled, let cue = activeCue {
                    SubtitleCaptionText(text: cue.text, settings: settings, maxWidthCap: availableWidth)
                        .padding(.bottom, bottomOffset)
                        .offset(y: controlsOffset)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                        .transition(.identity)
                }
            }
            .padding(.horizontal, outerPadding)
            .padding(.leading, proxy.safeAreaInsets.leading)
            .padding(.trailing, proxy.safeAreaInsets.trailing)
        }
    }
}
