import SwiftUI
import Combine

/// Single source of truth for subtitle styling in the player.
///
/// v2.15 — this manager is now the ONLY subtitle settings system. The old
/// Settings → Subtitles page wrote a parallel set of `subtitleTextColor` /
/// `subtitleFontSize` / … keys that no player code ever read (the "preview
/// drifts from playback" bug): its preview rendered one implementation while
/// `PlayerSubtitleOverlay` rendered another from different storage. The page
/// now binds to this manager, and both the in-player overlay and the Settings
/// preview render through the same `SubtitleCaptionText` component, so what
/// you preview is exactly what plays.
///
/// Legacy keys (`subtitle.*`) are preserved so existing installs keep their
/// in-player settings; the placebo keys are migrated once (see `migrateLegacy`).
@MainActor
final class SubtitleSettingsManager: ObservableObject {
    static let shared = SubtitleSettingsManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        // Live keys — read by PlayerSubtitleOverlay.
        static let enabled           = "subtitle.enabled"
        static let fontSize          = "subtitle.fontSize"
        static let shadowRadius      = "subtitle.shadowRadius"
        static let backgroundEnabled = "subtitle.backgroundEnabled"
        static let bottomPadding     = "subtitle.bottomPadding"
        static let delay             = "subtitle.delay"
        static let colorR            = "subtitle.color.r"
        static let colorG            = "subtitle.color.g"
        static let colorB            = "subtitle.color.b"
        static let colorA            = "subtitle.color.a"

        // v2.15 keys — full styling set (previously only editable through the
        // disconnected Settings page; now honored by the actual renderer).
        static let boldText          = "subtitle.boldText"
        static let strokeColor       = "subtitle.strokeColor"
        static let strokeWidth       = "subtitle.strokeWidth"
        static let fontDesign        = "subtitle.fontDesign"
        static let textOpacity       = "subtitle.textOpacity"
        static let lineSpacing       = "subtitle.lineSpacing"
        static let maxWidthPercent   = "subtitle.maxWidthPercent"
        static let shadowOffset      = "subtitle.shadowOffset"
        static let verticalOffset    = "subtitle.verticalOffset"
    }

    // MARK: - Published Properties

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }
    @Published var foregroundColor: Color {
        didSet { saveColor(foregroundColor) }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var shadowRadius: Double {
        didSet { UserDefaults.standard.set(shadowRadius, forKey: Keys.shadowRadius) }
    }
    @Published var backgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: Keys.backgroundEnabled) }
    }
    @Published var bottomPadding: Double {
        didSet { UserDefaults.standard.set(bottomPadding, forKey: Keys.bottomPadding) }
    }
    @Published var delaySeconds: Double {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: Keys.delay) }
    }

    // v2.15 full styling set.
    @Published var boldText: Bool {
        didSet { UserDefaults.standard.set(boldText, forKey: Keys.boldText) }
    }
    /// Named color ("white", "yellow", …) for the outline/stroke. "none" disables it.
    @Published var strokeColorName: String {
        didSet { UserDefaults.standard.set(strokeColorName, forKey: Keys.strokeColor) }
    }
    @Published var strokeWidth: Double {
        didSet { UserDefaults.standard.set(strokeWidth, forKey: Keys.strokeWidth) }
    }
    /// "default" / "rounded" / "serif" / "monospaced".
    @Published var fontDesignName: String {
        didSet { UserDefaults.standard.set(fontDesignName, forKey: Keys.fontDesign) }
    }
    @Published var textOpacity: Double {
        didSet { UserDefaults.standard.set(textOpacity, forKey: Keys.textOpacity) }
    }
    @Published var lineSpacingMultiplier: Double {
        didSet { UserDefaults.standard.set(lineSpacingMultiplier, forKey: Keys.lineSpacing) }
    }
    /// Caption block max width as a percentage of the visible player width.
    @Published var maxWidthPercent: Double {
        didSet { UserDefaults.standard.set(maxWidthPercent, forKey: Keys.maxWidthPercent) }
    }
    /// Drop-shadow offset behind the caption (0 disables the drop shadow;
    /// independent of `shadowRadius`, which softens the glow).
    @Published var shadowOffset: Double {
        didSet { UserDefaults.standard.set(shadowOffset, forKey: Keys.shadowOffset) }
    }
    /// Extra lift toward the top of the screen, in points (0 = default position).
    /// Applied on top of `bottomPadding`.
    @Published var verticalOffset: Double {
        didSet { UserDefaults.standard.set(verticalOffset, forKey: Keys.verticalOffset) }
    }

    // MARK: - Init

    private init() {
        // register(defaults:) provides fallbacks only when a key has never been written —
        // previously saved values always take precedence.
        UserDefaults.standard.register(defaults: [
            Keys.enabled:           true,
            Keys.fontSize:          24.0,
            Keys.shadowRadius:      2.0,
            Keys.backgroundEnabled: false,
            Keys.bottomPadding:     60.0,
            Keys.delay:             0.0,
            Keys.boldText:          false,
            Keys.strokeColor:       "none",
            Keys.strokeWidth:       0.0,
            Keys.fontDesign:        "default",
            Keys.textOpacity:       1.0,
            Keys.lineSpacing:       1.0,
            Keys.maxWidthPercent:   90.0,
            Keys.shadowOffset:      0.0,
            Keys.verticalOffset:    0.0
        ])

        migrateLegacy()

        let d = UserDefaults.standard
        enabled           = d.bool(forKey: Keys.enabled)
        fontSize          = d.double(forKey: Keys.fontSize)
        shadowRadius      = d.double(forKey: Keys.shadowRadius)
        backgroundEnabled = d.bool(forKey: Keys.backgroundEnabled)
        bottomPadding     = d.double(forKey: Keys.bottomPadding)
        delaySeconds      = d.double(forKey: Keys.delay)
        foregroundColor   = SubtitleSettingsManager.loadColorFromDefaults()
        boldText          = d.bool(forKey: Keys.boldText)
        strokeColorName   = d.string(forKey: Keys.strokeColor) ?? "none"
        strokeWidth       = d.double(forKey: Keys.strokeWidth)
        fontDesignName    = d.string(forKey: Keys.fontDesign) ?? "default"
        textOpacity       = d.double(forKey: Keys.textOpacity)
        lineSpacingMultiplier = d.double(forKey: Keys.lineSpacing)
        maxWidthPercent   = d.double(forKey: Keys.maxWidthPercent)
        shadowOffset      = d.double(forKey: Keys.shadowOffset)
        verticalOffset    = d.double(forKey: Keys.verticalOffset)
    }

    /// One-time port of the old (disconnected) Settings-page keys onto the
    /// live keys. Runs only when the user actually changed a value on the old
    /// page (`object(forKey:) != nil` — @AppStorage only writes on change) and
    /// the corresponding live key has never been written.
    private func migrateLegacy() {
        let d = UserDefaults.standard
        let map: [(legacy: String, live: String, convert: (Any) -> Any)] = [
            ("subtitleFontSize",      Keys.fontSize,        { ($0 as? Double) ?? 24 }),
            ("subtitleBoldText",      Keys.boldText,        { ($0 as? Bool) ?? false }),
            ("subtitleStrokeColor",   Keys.strokeColor,     { ($0 as? String) ?? "none" }),
            ("subtitleStrokeWidth",   Keys.strokeWidth,     { ($0 as? Double) ?? 0 }),
            ("subtitleFontDesign",    Keys.fontDesign,      { ($0 as? String) ?? "default" }),
            ("subtitleTextOpacity",   Keys.textOpacity,     { ($0 as? Double) ?? 1 }),
            ("subtitleLineSpacing",   Keys.lineSpacing,     { ($0 as? Double) ?? 1 }),
            ("subtitleMaxWidth",      Keys.maxWidthPercent, { ($0 as? Double) ?? 90 }),
            ("subtitleDelaySeconds",  Keys.delay,           { ($0 as? Double) ?? 0 }),
            ("subtitleShadowOffset",  Keys.shadowOffset,    { ($0 as? Double) ?? 0 }),
            ("subtitleVerticalOffset", Keys.verticalOffset, { ($0 as? Double) ?? 0 }),
            ("subtitleBackgroundEnabled", Keys.backgroundEnabled, { ($0 as? Bool) ?? false })
        ]
        for entry in map where d.object(forKey: entry.legacy) != nil && d.object(forKey: entry.live) == nil {
            d.set(entry.convert(d.object(forKey: entry.legacy)!), forKey: entry.live)
        }
        // Text color: the old page stored a color NAME; the live manager stores
        // RGBA components. Port only when the live color was never customized.
        if d.object(forKey: "subtitleTextColor") != nil,
           d.object(forKey: Keys.colorR) == nil,
           let name = d.string(forKey: "subtitleTextColor") {
            let ui = UIColor(Self.color(fromName: name))
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            d.set(Double(r), forKey: Keys.colorR)
            d.set(Double(g), forKey: Keys.colorG)
            d.set(Double(b), forKey: Keys.colorB)
            d.set(Double(a), forKey: Keys.colorA)
        }
    }

    // MARK: - Resolved Values (shared by overlay, preview, and settings UI)

    var fontDesign: Font.Design {
        switch fontDesignName.lowercased() {
        case "rounded":    return .rounded
        case "serif":      return .serif
        case "monospaced": return .monospaced
        default:           return .default
        }
    }

    var resolvedStrokeWidth: Double {
        strokeColorName.lowercased() == "none" ? 0 : strokeWidth
    }

    static func color(fromName name: String) -> Color {
        switch name.lowercased() {
        case "white":  return .white
        case "black":  return .black
        case "yellow": return .yellow
        case "cyan":   return .cyan
        case "pink":   return .pink
        case "green":  return .green
        case "gray":   return .gray
        case "none":   return .clear
        default:       return .white
        }
    }

    // MARK: - Color Serialization

    private func saveColor(_ color: Color) {
#if os(iOS) || os(tvOS)
        let native = UIColor(color)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
#else
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        let r = native.redComponent
        let g = native.greenComponent
        let b = native.blueComponent
        let a = native.alphaComponent
#endif
        let d = UserDefaults.standard
        d.set(Double(r), forKey: Keys.colorR)
        d.set(Double(g), forKey: Keys.colorG)
        d.set(Double(b), forKey: Keys.colorB)
        d.set(Double(a), forKey: Keys.colorA)
    }

    private static func loadColorFromDefaults() -> Color {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.colorR) != nil else { return .white }
        return Color(
            red:     d.double(forKey: Keys.colorR),
            green:   d.double(forKey: Keys.colorG),
            blue:    d.double(forKey: Keys.colorB),
            opacity: d.double(forKey: Keys.colorA)
        )
    }
}
