import SwiftUI

// MARK: - AnimatedBackgroundView

/// An animated, full-bleed gradient background rendered with `TimelineView` + `Canvas`.
///
/// Quality tiers (read from `@AppStorage("backgroundAnimationQuality")`):
/// - **low**:    1 drifting gradient layer
/// - **medium**: 2 drifting gradient layers
/// - **high**:   3 drifting gradient layers + floating particles
///
/// The refresh rate is governed by `@AppStorage("backgroundFrameRate")` (fps). When the user
/// has `Reduce Motion` enabled the animation is paused and a static gradient is shown instead.
struct AnimatedBackgroundView: View {

    // MARK: - AppStorage

    @AppStorage("backgroundAnimationQuality") private var qualityRaw: String = Quality.medium.rawValue
    @AppStorage("backgroundFrameRate") private var frameRate: Int = 30
    @AppStorage("reduceMotion") private var reduceMotion: Bool = false
    /// #126 — Performance Mode disables the animated background entirely
    /// (falls back to a flat static gradient) so older devices don't burn
    /// CPU/GPU on a decorative TimelineView while scrolling.
    @AppStorage("performanceModeEnabled") private var performanceModeEnabled: Bool = false

    // MARK: - Quality

    enum Quality: String, CaseIterable {
        case low
        case medium
        case high

        /// Number of drifting gradient layers to render.
        var layerCount: Int {
            switch self {
            case .low:    return 1
            case .medium: return 2
            case .high:   return 3
            }
        }

        /// Number of floating particles (only non-zero on `.high`).
        var particleCount: Int {
            self == .high ? 40 : 0
        }
    }

    private var quality: Quality {
        Quality(rawValue: qualityRaw) ?? .medium
    }

    // MARK: - Palette (warm aurora — no indigo/blue)

    private static let palette: [Color] = [
        Color(red: 0.85, green: 0.25, blue: 0.45), // rose
        Color(red: 0.95, green: 0.55, blue: 0.15), // amber
        Color(red: 0.20, green: 0.65, blue: 0.40)  // emerald
    ]

    // MARK: - Body

    var body: some View {
        Group {
            // #126 — Performance Mode gates the whole TimelineView/Canvas
            // pipeline off, the same as Reduce Motion. This is the single
            // biggest per-frame GPU cost on the home screen.
            if reduceMotion || performanceModeEnabled {
                staticGradient
            } else {
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / Double(max(frameRate, 1)),
                        paused: false
                    )
                ) { context in
                    Canvas { gfx, size in
                        let time = context.date.timeIntervalSinceReferenceDate
                        drawLayers(in: size, time: time, count: quality.layerCount, gfx: gfx)
                        if quality.particleCount > 0 {
                            drawParticles(in: size, time: time, count: quality.particleCount, gfx: gfx)
                        }
                    }
                }
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// A single static gradient shown when `reduceMotion` is on.
    private var staticGradient: some View {
        LinearGradient(
            colors: [
                Self.palette[0].opacity(0.25),
                Self.palette[1].opacity(0.15),
                Self.palette[2].opacity(0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Drawing

    /// Draws `count` large radial gradient blobs that drift in slow circular paths.
    private func drawLayers(in size: CGSize, time: Double, count: Int, gfx: GraphicsContext) {
        let minDim = min(size.width, size.height)
        guard minDim > 0 else { return }
        let endRadius = max(minDim * 0.55, 1)
        let fullRect = Path(CGRect(origin: .zero, size: size))

        for i in 0..<count {
            let color = Self.palette[i % Self.palette.count]
            let speed = 0.05 + 0.02 * Double(i)
            let phase = time * speed + Double(i) * 2.0944 // ~120° offset per layer

            let cx = size.width * (0.5 + 0.32 * cos(phase))
            let cy = size.height * (0.5 + 0.32 * sin(phase * 1.2 + Double(i)))

            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0.35), location: 0.0),
                    .init(color: color.opacity(0.0), location: 1.0)
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: endRadius
            )
            gfx.fill(fullRect, with: shading)
        }
    }

    /// Draws `count` slow-rising particles with gentle horizontal sway.
    private func drawParticles(in size: CGSize, time: Double, count: Int, gfx: GraphicsContext) {
        guard size.width > 0, size.height > 0 else { return }
        let totalHeight = size.height + 40

        for i in 0..<count {
            let seed = Double(i + 1)
            let randX = fract(sin(seed * 12.9898) * 43758.5453)
            let baseX = randX * size.width
            let sway = sin(time * 0.3 + seed) * 20
            let x = baseX + sway

            let speed = 15.0 + fract(sin(seed * 78.233) * 43758.5453) * 25.0
            let progress = (time * speed + seed * 37.0).truncatingRemainder(dividingBy: totalHeight)
            let y = size.height - progress + 20

            let radius = 1.0 + fract(sin(seed * 1.234) * 43758.5453) * 2.0
            let opacity = 0.25 + 0.4 * fract(sin(seed * 3.456) * 43758.5453)

            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            gfx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
        }
    }

    /// Fractional part of `x`.
    private func fract(_ x: Double) -> Double {
        x - floor(x)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        AnimatedBackgroundView()
    }
}
