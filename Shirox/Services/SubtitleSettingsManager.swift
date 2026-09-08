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
/// A complete, snapshot-able subtitle APPEARANCE (Batch 25).
///
/// Value type so preset previews can render REAL mini-captions through
/// the SAME `SubtitleCaptionText` renderer the player uses — a preview can
/// never drift from what actually plays. Applying a preset writes every
/// field atomically through `SubtitleSettingsManager.apply(_:)`.
/// Layout knobs (position, delay, max width) are deliberately NOT part of
/// a style: presets restyle the caption, they never move it.
struct SubtitleStyle: Equatable {
    var fontSize: Double
    var bold: Bool
    /// "default" / "rounded" / "serif" / "monospaced"
    var fontDesignName: String
    var foregroundColor: Color
    var textOpacity: Double
    /// "none" / "black" / "white" / "yellow" / …
    var strokeColorName: String
    var strokeWidth: Double
    var backgroundEnabled: Bool
    var shadowRadius: Double
    var shadowOffset: Double
    var lineSpacingMultiplier: Double
}

extension SubtitleStyle {
    /// The named preset catalog. Order = display order in the pickers.
    /// "Shirox" is the fresh-install default look: bold rounded white with
    /// a crisp black rim — visibly the app's own, unlike Apple's plain
    /// caption (that visual indistinctness is exactly why the custom UI
    /// read as "not done" before Batch 25).
    static let presets: [(name: String, style: SubtitleStyle)] = [
        ("Shirox", SubtitleStyle(
            fontSize: 26, bold: true, fontDesignName: "rounded",
            foregroundColor: .white, textOpacity: 1,
            strokeColorName: "black", strokeWidth: 1,
            backgroundEnabled: false,
            shadowRadius: 2, shadowOffset: 0, lineSpacingMultiplier: 1)),
        ("Classic", SubtitleStyle(
            fontSize: 30, bold: false, fontDesignName: "default",
            foregroundColor: .white, textOpacity: 1,
            strokeColorName: "black", strokeWidth: 1,
            backgroundEnabled: false,
            shadowRadius: 2, shadowOffset: 0, lineSpacingMultiplier: 1)),
        ("Minimal", SubtitleStyle(
            fontSize: 24, bold: false, fontDesignName: "default",
            foregroundColor: .white, textOpacity: 1,
            strokeColorName: "none", strokeWidth: 0,
            backgroundEnabled: false,
            shadowRadius: 0, shadowOffset: 0, lineSpacingMultiplier: 1)),
        ("Bold", SubtitleStyle(
            fontSize: 34, bold: true, fontDesignName: "default",
            foregroundColor: .yellow, textOpacity: 1,
            strokeColorName: "black", strokeWidth: 1.5,
            backgroundEnabled: true,
            shadowRadius: 2, shadowOffset: 0, lineSpacingMultiplier: 1)),
        ("Boxed", SubtitleStyle(
            fontSize: 26, bold: false, fontDesignName: "default",
            foregroundColor: .white, textOpacity: 1,
            strokeColorName: "none", strokeWidth: 0,
            backgroundEnabled: true,
            shadowRadius: 2, shadowOffset: 0, lineSpacingMultiplier: 1)),
        ("Fansub", SubtitleStyle(
            fontSize: 28, bold: true, fontDesignName: "default",
            foregroundColor: .yellow, textOpacity: 1,
            strokeColorName: "black", strokeWidth: 2,
            backgroundEnabled: false,
            shadowRadius: 1, shadowOffset: 0, lineSpacingMultiplier: 1))
    ]

    static func preset(named name: String) -> SubtitleStyle? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.style
    }

    /// Mirrors `SubtitleSettingsManager.fontDesign` (same name → design).
    var fontDesign: Font.Design {
        switch fontDesignName.lowercased() {
        case "rounded":    return .rounded
        case "serif":      return .serif
        case "monospaced": return .monospaced
        default:           return .default
        }
    }

    /// Mirrors `SubtitleSettingsManager.resolvedStrokeWidth`: "none" stroke
    /// color disables the outline regardless of the width value.
    var resolvedStrokeWidth: Double {
        strokeColorName.lowercased() == "none" ? 0 : strokeWidth
    }
}

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
        // Batch 23 (item 7) — subtitle renderer choice.
        static let useSystemRenderer = "subtitle.useSystemRenderer"
        // Batch 25 — name of the applied style preset ("" = fully custom).
        static let presetName = "subtitle.presetName"
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

    // MARK: - Renderer choice (Batch 23, item 7)

    /// Which subtitle renderer the player uses:
    /// - `false` (default, Custom): the app's own overlay renders every
    ///   subtitle — embedded tracks are deselected so the custom styling
    ///   is ALWAYS what plays (the v2.15 contract).
    /// - `true` (System): AVPlayer renders EMBEDDED subtitle tracks
    ///   natively with Apple's default styling; external subtitle FILES
    ///   (which AVPlayer cannot side-load) still render through the app
    ///   overlay, but with Apple's default caption look instead of the
    ///   custom knobs.
    /// Persisted, so the choice survives restarts. Exposed in the
    /// in-player subtitle menu and in Settings → Subtitles.
    @Published var useSystemRenderer: Bool {
        didSet { UserDefaults.standard.set(useSystemRenderer, forKey: Keys.useSystemRenderer) }
    }

    // MARK: - Preset tracking (Batch 25)

    /// Name of the applied preset, or "" when the knobs have been touched
    /// by hand (the pickers show that state as a custom style). Presets
    /// themselves are pure `SubtitleStyle` values (see above); this string
    /// only remembers which one is active for the checkmark UI.
    @Published var presetName: String {
        didSet { UserDefaults.standard.set(presetName, forKey: Keys.presetName) }
    }

    /// The live appearance as a value — exactly what `SubtitleCaptionText`
    /// renders, so preset previews and the player share one source of truth.
    var currentStyle: SubtitleStyle {
        SubtitleStyle(
            fontSize: fontSize,
            bold: boldText,
            fontDesignName: fontDesignName,
            foregroundColor: foregroundColor,
            textOpacity: textOpacity,
            strokeColorName: strokeColorName,
            strokeWidth: strokeWidth,
            backgroundEnabled: backgroundEnabled,
            shadowRadius: shadowRadius,
            shadowOffset: shadowOffset,
            lineSpacingMultiplier: lineSpacingMultiplier)
    }

    /// Writes a whole style at once (used by every preset tap). Pass a
    /// preset name to track it for the checkmark; pass nil/"" for custom.
    func apply(_ style: SubtitleStyle, presetName name: String? = nil) {
        foregroundColor = style.foregroundColor
        fontSize = style.fontSize
        boldText = style.bold
        fontDesignName = style.fontDesignName
        textOpacity = style.textOpacity
        strokeColorName = style.strokeColorName
        strokeWidth = style.strokeWidth
        backgroundEnabled = style.backgroundEnabled
        shadowRadius = style.shadowRadius
        shadowOffset = style.shadowOffset
        lineSpacingMultiplier = style.lineSpacingMultiplier
        presetName = name ?? ""
    }

    /// Applies a catalog preset by name (no-op for unknown names).
    func applyPreset(named name: String) {
        guard let style = SubtitleStyle.preset(named: name) else { return }
        apply(style, presetName: name)
    }

    // MARK: - Init

    private init() {
        // register(defaults:) provides fallbacks only when a key has never been written —
        // previously saved values always take precedence.
        UserDefaults.standard.register(defaults: [
            Keys.enabled:           true,
            // Batch 25 — fresh installs (and anyone who never customized)
            // start on the distinctive "Shirox" look instead of a plain
            // white caption that read as identical to Apple's default.
            // Previously-written values always win, so customized setups
            // are untouched.
            Keys.fontSize:          26.0,
            Keys.shadowRadius:      2.0,
            Keys.backgroundEnabled: false,
            Keys.bottomPadding:     60.0,
            Keys.delay:             0.0,
            Keys.boldText:          true,
            Keys.strokeColor:       "black",
            Keys.strokeWidth:       1.0,
            Keys.fontDesign:        "rounded",
            Keys.textOpacity:       1.0,
            Keys.lineSpacing:       1.0,
            Keys.maxWidthPercent:   90.0,
            Keys.shadowOffset:      0.0,
            Keys.verticalOffset:    0.0,
            Keys.useSystemRenderer: false,
            Keys.presetName:        "Shirox"
        ])

        SubtitleSettingsManager.migrateLegacy()

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
        useSystemRenderer = d.bool(forKey: Keys.useSystemRenderer)
        presetName        = d.string(forKey: Keys.presetName) ?? ""
    }

    /// One-time port of the old (disconnected) Settings-page keys onto the
    /// live keys. Runs only when the user actually changed a value on the old
    /// page (`object(forKey:) != nil` — @AppStorage only writes on change) and
    /// the corresponding live key has never been written.
    private static func migrateLegacy() {
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
