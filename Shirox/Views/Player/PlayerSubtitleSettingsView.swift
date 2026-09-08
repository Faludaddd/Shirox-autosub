import SwiftUI
import UniformTypeIdentifiers

/// The in-player Subtitle sheet — fully custom Shirox UI (Batch 25).
///
/// Before Batch 25 this was a stock iOS `Form`, which read as "the custom
/// subtitle UI was never built": plain grouped rows, no preview, presets
/// hidden away in Settings. The rebuilt sheet matches the player's own
/// design language (dark stage cards, brand-accent tiles, custom rows) and
/// leads with a LIVE preview rendered by the exact `SubtitleCaptionText`
/// the player draws with — what you see here is what plays.
///
/// Public API is unchanged from the Form version (PlayerView call site
/// untouched): settings, the optional embedded-track list, the selected
/// track binding, local-file import.
struct PlayerSubtitleSettingsView: View {
    @ObservedObject var settings: SubtitleSettingsManager
    var availableTracks: [SubtitleTrack]?
    @Binding var selectedTrack: SubtitleTrack?
    var allowLocalImport: Bool = false
    var onImport: ((SubtitleTrack) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false

    private let quickColors: [(name: String, color: Color)] = [
        ("white", .white), ("yellow", .yellow), ("cyan", .cyan),
        ("pink", .pink), ("green", .green)
    ]
    private let fontDesignOptions: [(label: String, value: String, icon: String)] = [
        ("Default", "default", "textformat"),
        ("Rounded", "rounded", "circle.grid.cross"),
        ("Serif", "serif", "textformat.size"),
        ("Mono", "monospaced", "chevron.left.forwardslash.chevron.right")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    showToggleCard
                    livePreviewCard
                    rendererCard
                    if !settings.useSystemRenderer {
                        presetCarouselCard
                        appearanceCard
                    }
                    if let tracks = availableTracks, !tracks.isEmpty {
                        trackCard(tracks)
                    }
                    if allowLocalImport {
                        importCard
                    }
                    syncCard
                    positionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Self.pageBackground.ignoresSafeArea())
            .navigationTitle("Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.subtitleTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first,
                   let track = LocalPlaybackCoordinator.shared.importSubtitle(from: url) {
                    onImport?(track)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Card shell

    /// Platform-safe page/card chrome. iOS + tvOS use the grouped
    /// system colors (the player sheet's dark-on-light look); a non-UIKit
    /// platform falls back to neutrals.
    private static var pageBackground: Color {
        #if os(iOS) || os(tvOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.primary.opacity(0.04)
        #endif
    }

    private static var cardBackground: Color {
        #if os(iOS) || os(tvOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    private func card<Content: View>(
        icon: String? = nil,
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 26, height: 26)
                            .background(Color.appAccent.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.cardBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Master toggle

    private var showToggleCard: some View {
        card {
            HStack {
                Label("Show Subtitles", systemImage: "captions.bubble.fill")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $settings.enabled)
                    .labelsHidden()
                    .tint(.appAccent)
            }
        }
    }

    // MARK: - Live preview stage

    /// The caption is drawn by the REAL renderer with the LIVE settings —
    /// dragging any knob below updates this stage frame by frame.
    private var livePreviewCard: some View {
        card {
            ZStack {
                // A stand-in for the video frame: the player's dark chrome
                // (deep gradient + a whisper of the progress bar) so the
                // caption is judged against a real background, not white.
                LinearGradient(
                    colors: [Color.black, Color(white: 0.16), Color(white: 0.09)],
                    startPoint: .top, endPoint: .bottom)
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Capsule().fill(.white.opacity(0.25)).frame(width: 26, height: 4)
                        Capsule().fill(Color.appAccent).frame(width: 64, height: 4)
                        Capsule().fill(.white.opacity(0.25)).frame(width: 18, height: 4)
                    }
                    .padding(.bottom, 18)
                }
                if settings.enabled {
                    SubtitleCaptionText(
                        text: "This is how your subtitles will look",
                        settings: settings)
                        .padding(.bottom, 34)
                } else {
                    Text("Subtitles are hidden")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Renderer choice (Apple default vs Shirox custom)

    private var rendererCard: some View {
        card(title: "Subtitle Style") {
            HStack(spacing: 10) {
                rendererTile(
                    title: "Apple Default",
                    icon: "captions.bubble",
                    subtitle: "System look",
                    selected: settings.useSystemRenderer) {
                    settings.useSystemRenderer = true
                }
                rendererTile(
                    title: "Shirox Custom",
                    icon: "paintbrush.fill",
                    subtitle: "Full styling",
                    selected: !settings.useSystemRenderer) {
                    settings.useSystemRenderer = false
                }
            }
            Text(settings.useSystemRenderer
                 ? "Embedded subtitles render with the system's native look. External subtitle files get the same clean default style."
                 : "Every subtitle renders through Shirox's styled overlay — the presets and appearance controls below all apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rendererTile(
        title: String, icon: String, subtitle: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? Color.appAccent : .secondary)
                VStack(spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                selected ? Color.appAccent.opacity(0.14) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.appAccent.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preset carousel

    /// Six one-tap styles. Each tile is a REAL render: the preset's name is
    /// drawn through `SubtitleCaptionText` in that preset's own style, so
    /// the tiles can never lie about what applying them does.
    private var presetCarouselCard: some View {
        card(icon: "wand.and.stars", title: "Style Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SubtitleStyle.presets, id: \.name) { preset in
                        presetTile(preset)
                    }
                }
                .padding(.vertical, 2)
            }
            if settings.presetName.isEmpty {
                Text("Custom — the appearance controls below are tuned by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presetTile(_ preset: (name: String, style: SubtitleStyle)) -> some View {
        let isSelected = settings.presetName.caseInsensitiveCompare(preset.name) == .orderedSame
        return Button {
            settings.applyPreset(named: preset.name)
            Haptics.light()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.black, Color(white: 0.18)],
                            startPoint: .top, endPoint: .bottom)
                        // The preset's own look, rendering its own name.
                        SubtitleCaptionText(text: preset.name, style: preset.style)
                            .padding(.horizontal, 6)
                    }
                    .frame(width: 104, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.appAccent)
                            .background(Circle().fill(.thinMaterial))
                            .offset(x: 4, y: -4)
                    }
                }
                Text(preset.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.appAccent : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Appearance controls

    private var appearanceCard: some View {
        card(icon: "paintbrush", title: "Appearance") {
            // Text color — quick dots (plus free-form picker off tvOS).
            VStack(alignment: .leading, spacing: 8) {
                controlLabel("Text Color")
                HStack(spacing: 10) {
                    ForEach(quickColors, id: \.name) { entry in
                        colorDot(entry.color, name: entry.name)
                    }
                    #if !os(tvOS)
                    ColorPicker("Custom color", selection: $settings.foregroundColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30, height: 30)
                    #endif
                }
            }

            #if !os(tvOS)
            sliderRow(
                "Text Size", icon: "textformat.size",
                value: $settings.fontSize, range: 12...40, step: 1,
                label: "\(Int(settings.fontSize)) pt")
            #else
            valueRow("Text Size", icon: "textformat.size",
                     label: "\(Int(settings.fontSize)) pt")
            #endif

            // Typeface chips.
            VStack(alignment: .leading, spacing: 8) {
                controlLabel("Typeface")
                HStack(spacing: 8) {
                    ForEach(fontDesignOptions, id: \.value) { option in
                        chip(
                            option.label, icon: option.icon,
                            selected: settings.fontDesignName == option.value) {
                            settings.fontDesignName = option.value
                            settings.presetName = ""
                        }
                    }
                }
            }

            toggleRow("Bold Text", icon: "bold", isOn: $settings.boldText)

            // Outline.
            VStack(alignment: .leading, spacing: 8) {
                controlLabel("Outline")
                HStack(spacing: 8) {
                    ForEach(["none", "black", "white", "gray"], id: \.self) { name in
                        outlineChip(name, selected: settings.strokeColorName == name)
                    }
                }
            }
            #if !os(tvOS)
            if settings.strokeColorName != "none" {
                sliderRow(
                    "Outline Width", icon: "circle.dashed",
                    value: $settings.strokeWidth, range: 0.5...4, step: 0.5,
                    label: String(format: "%.1f", settings.strokeWidth))
            }
            #else
            if settings.strokeColorName != "none" {
                valueRow("Outline Width", icon: "circle.dashed",
                         label: String(format: "%.1f", settings.strokeWidth))
            }
            #endif

            toggleRow("Background Plate", icon: "rectangle.fill", isOn: $settings.backgroundEnabled)

            #if !os(tvOS)
            sliderRow(
                "Shadow", icon: "shadow",
                value: $settings.shadowRadius, range: 0...8, step: 0.5,
                label: String(format: "%.1f", settings.shadowRadius))
            #endif
        }
    }

    // MARK: - Track selection

    private func trackCard(_ tracks: [SubtitleTrack]) -> some View {
        card(icon: "list.bullet.rectangle", title: "Subtitle Track") {
            VStack(spacing: 0) {
                trackRow(title: "Default", isActive: selectedTrack == nil) {
                    selectedTrack = nil
                }
                ForEach(tracks) { track in
                    Divider().padding(.leading, 12)
                    trackRow(title: track.title, isActive: selectedTrack?.id == track.id) {
                        selectedTrack = track
                    }
                }
            }
        }
    }

    private func trackRow(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Local import

    private var importCard: some View {
        card {
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text("Import subtitle file…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sync

    private var syncCard: some View {
        card(icon: "clock.arrow.circlepath", title: "Sync") {
            #if !os(tvOS)
            HStack {
                controlLabel("Delay")
                Spacer()
                Text(String(format: "%+.1fs", settings.delaySeconds))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Reset") { settings.delaySeconds = 0 }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.appAccent)
            }
            Slider(value: $settings.delaySeconds, in: -5...5, step: 0.1)
                .tint(.appAccent)
            #else
            HStack {
                controlLabel("Delay")
                Spacer()
                Text(String(format: "%+.1fs", settings.delaySeconds))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Reset") { settings.delaySeconds = 0 }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.appAccent)
            }
            #endif
        }
    }

    // MARK: - Position

    private var positionCard: some View {
        card(icon: "rectangle.compress.vertical", title: "Position") {
            #if !os(tvOS)
            sliderRow(
                "Bottom Spacing", icon: "arrow.down.to.line",
                value: $settings.bottomPadding, range: 20...200, step: 5,
                label: "\(Int(settings.bottomPadding)) pt")
            #else
            valueRow("Bottom Spacing", icon: "arrow.down.to.line",
                     label: "\(Int(settings.bottomPadding)) pt")
            #endif
        }
    }

    // MARK: - Custom control primitives

    private func controlLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
    }

    private func sliderRow(
        _ title: String, icon: String,
        value: Binding<Double>, range: ClosedRange<Double>, step: Double,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { _ in
                settings.presetName = ""
            }
            .tint(.appAccent)
        }
    }

    /// tvOS-safe stand-in where Slider/Stepper are unavailable: shows the
    /// current value read-only (adjusted from the iOS/catalyst settings
    /// page, which syncs through the same persisted keys).
    private func valueRow(_ title: String, icon: String, label: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func toggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.appAccent)
        }
    }

    private func colorDot(_ color: Color, name: String) -> some View {
        Button {
            settings.foregroundColor = color
            settings.presetName = ""
            Haptics.light()
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: 24, height: 24)
                if colorDotMatches(color) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(colorIsLight(color) ? .black : .white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func colorDotMatches(_ color: Color) -> Bool {
        // Compare via RGBA so palette dots highlight only on an exact match
        // with the live color (a custom picker color never matches).
        #if os(iOS) || os(tvOS)
        let a = UIColor(color), b = UIColor(settings.foregroundColor)
        return a.isEqual(b)
        #else
        let a = NSColor(color), b = NSColor(settings.foregroundColor)
        return a == b
        #endif
    }

    private func colorIsLight(_ color: Color) -> Bool {
        #if os(iOS) || os(tvOS)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.5
    }

    private func chip(
        _ title: String, icon: String? = nil,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? Color.appAccent.opacity(0.16) : Color.secondary.opacity(0.08),
                in: Capsule())
            .foregroundStyle(selected ? Color.appAccent : .primary)
        }
        .buttonStyle(.plain)
    }

    private func outlineChip(_ name: String, selected: Bool) -> some View {
        Button {
            settings.strokeColorName = name
            settings.presetName = ""
        } label: {
            Text(name.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    selected ? Color.appAccent.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: Capsule())
                .foregroundStyle(selected ? Color.appAccent : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import types

    private static var subtitleTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .data]
        if let vtt = UTType(filenameExtension: "vtt") { types.insert(vtt, at: 0) }
        if let srt = UTType(filenameExtension: "srt") { types.insert(srt, at: 0) }
        return types
    }
}
