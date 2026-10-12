import SwiftUI

// MARK: - Shared hero components (v2.35)
//
// The one-time "unified carousel" this file held is retired: since v2.35
// the anime AND manga homes render the SAME hero — HomeView's
// FeaturedCarousel (the original ShiroX home design: full-bleed paged
// hero, parallax, pull-down stretch, capsule indicator) with an isManga
// flag for the Read button + manga routing.
//
// What still lives here, shared by every hero surface (the home hero,
// cinematic iPad pages, detail headers, the Mac hero):
//   • HeroLogoTitle      — the title slot: the real TVDB clear-logo when
//                          one resolves, bold title text otherwise (never
//                          a broken image box; manga always uses text);
//   • HeroLogoPrefetcher — the invisible offscreen logo warmer;
//   • DesignModeNavBarModifier (below) — the SHIROX/APPLE nav bar switch.

// MARK: - HeroLogoTitle (the ONE hero title slot)
//
// Shared by every hero surface (carousel slides, detail headers, Mac
// hero): shows the anime's real LOGO when one resolved, else the title
// TEXT. Rendering rules:
//   • scaledToFit — aspect ratio preserved, NEVER stretched or cropped
//   • max width/height bounds — never overflows its slot
//   • soft shadow behind transparent logos — stays legible on BOTH light
//     and dark backgrounds (TVDB clear logos are pure transparent PNGs;
//     a white logo would vanish over a light hero without it)
//   • constant slot height so the layout below never shifts
//   • VoiceOver always reads the title string
struct HeroLogoTitle: View {
    let media: Media
    /// iPad (regular width) gets the larger, streaming-hero-scale box.
    var isWide: Bool = false
    /// Centered (carousel) vs bottom-leading (detail headers / Mac hero).
    var centered: Bool = true

    @State private var logoURL: String?

    private var maxLogoWidth: CGFloat { isWide ? 448 : 336 }
    private var maxLogoHeight: CGFloat { isWide ? 118 : 90 }
    /// Constant slot height — everything below this slot is position-stable.
    private var slotHeight: CGFloat { maxLogoHeight + 8 }

    var body: some View {
        Group {
            if let logoURL, !media.isManga {
                CachedAsyncImage(urlString: logoURL, contentMode: .fit)
                    .frame(maxWidth: maxLogoWidth, maxHeight: maxLogoHeight)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .accessibilityLabel(media.fallbackTitle)
                    .transition(.opacity)
            } else {
                // Batch 27 — the TEXT fallback is BACK (v2.23's logo-only
                // rule blanked anime titles with no TVDB logo; the user
                // spec: logo → other provider → title text, never a
                // broken image box). Bold, shadowed, reads over any art.
                Text(media.fallbackTitle)
                    .font(.system(size: isWide ? 34 : 28, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .shadow(color: .black.opacity(0.65), radius: 3, x: 0, y: 1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: centered ? nil : maxLogoWidth)
        .frame(height: slotHeight)
        .animation(.easeInOut(duration: 0.25), value: logoURL)
        .task(id: media.uniqueId) {
            // The TEXT fallback renders IMMEDIATELY (no flicker — no blank
            // slot while the logo resolves); the logo cross-fades in only
            // when a candidate actually decodes.
            guard !media.isManga else { return }
            logoURL = nil
            logoURL = await AnimeLogoService.shared.logoURL(for: media)
        }
    }
}

/// Invisible offscreen warmer — resolves (and Kingfisher-caches) a
/// title's logo so the visible hero paints the moment its page becomes
/// current. 1x1, opacity 0, no hit testing.
struct HeroLogoPrefetcher: View {
    let media: Media

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: media.uniqueId) {
                _ = await AnimeLogoService.shared.logoURL(for: media)
            }
    }
}

// MARK: - Design-mode navigation bar treatment (Batch 27)
//
/// SHIROX applies the transparent, full-bleed navigation bar (the custom
/// streaming look); APPLE passes the content through untouched so the
/// STANDARD system navigation bar renders (native background material,
/// title, separators — the default iOS chrome).
struct DesignModeNavBarModifier: ViewModifier {
    @ObservedObject private var designMode = UIDesignModeManager.shared

    func body(content: Content) -> some View {
        if designMode.isShirox {
            content.modifier(TransparentNavBarModifier())
        } else {
            content
        }
    }
}
