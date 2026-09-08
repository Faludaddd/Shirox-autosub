import SwiftUI

// MARK: - MediaCarousel (Batch 27 — THE unified carousel)
//
// ONE carousel system for anime AND manga — the ORIGINAL ShiroX home
// design, restored from the app's own history (the "Infinite carousel"
// era structure: full-bleed paged hero, centered info stack, capsule
// page indicator), with the current data systems underneath it.
//
// The design (same on every slide, same component in both modes):
//   • full-width paged TabView — iPhone: screen-height hero, iPad: 9:16
//     fanart with ambient backdrop; bounded 3x window with an invisible
//     edge-reset so swiping feels infinite
//   • pull-down elastic stretch, parallax poster drift (machinery kept
//     from the original implementation)
//   • bottom gradient fading into the page background
//   • CENTERED info stack, the original order:
//       metadata pills  (rating / format / year / episodes | manga: status)
//       genre pills     (real genres from the same object)
//       title           (the anime's real LOGO — TVDB clear logo → clear
//                        art → title text; manga: always title text)
//       description     (footnote, 2 lines, ~120 chars, centered)
//       Watch/Read button (130×42, Color.primary, corner radius 12)
//   • capsule page indicator below (accentColor active pill)
//
// Data guarantees (MediaNormalizer.carouselItems):
//   every slide is a real object — valid title + artwork, JP catalog for
//   anime rows, no duplicates, no two seasons of the same franchise,
//   no empty/invalid media. Poster, logo, pills, description and button
//   ALL come from the ONE Media object of the current slide.
//
// Manga: same component, same design language — `isManga` switches the
// button ("Read"), the destination and the pill vocabulary (status +
// chapters instead of episodes). The title is the real title text from
// the same manga object as the cover/synopsis/pills.

struct MediaCarousel: View {
    let items: [Media]
    /// Reading Mode: the carousel routes to the manga detail page, the
    /// button reads "Read", and pills use manga metadata.
    var isManga: Bool = false
    /// The parent ScrollView's coordinate-space name — the pull-down
    /// stretch sensor reads the carousel's offset in THIS space (the
    /// anime home scrolls in "homeScroll", the manga home in
    /// "mangaHomeScroll"; the pull-stretch now works in both).
    var scrollSpace: String = "homeScroll"

    // Bounded infinite-wrap state (3 rotations; an invisible edge-reset
    // bounces the selection back to the middle rotation so swiping feels
    // endless without materialising thousands of pages).
    @State private var selectedTab = 0
    @State private var containerWidth: CGFloat = 0
    @State private var stretchAmount: CGFloat = 0
    @State private var didSetup = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Normalized slides — one pass, every guarantee, capped at 8.
    private var displayItems: [Media] {
        MediaNormalizer.carouselItems(from: items, isManga: isManga)
    }
    private var displayCount: Int { displayItems.count }
    private var pageCount: Int { max(displayCount * 3, displayCount) }
    private var currentIndex: Int {
        guard displayCount > 0 else { return 0 }
        return selectedTab % displayCount
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        iOSBody
        #else
        macBody
        #endif
    }

    // MARK: - iOS / iPadOS body (the original ShiroX hero)

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var iOSBody: some View {
        let isIPad = sizeClass == .regular
        let effectiveWidth = containerWidth > 0 ? containerWidth : UIScreen.main.bounds.width
        // The original hero proportion: the full screen height minus the
        // chrome on iPhone; a 9:16 fanart card on iPad.
        let imageHeight: CGFloat = isIPad
            ? effectiveWidth * (9.0 / 16.0)
            : UIScreen.main.bounds.height - 140

        let currentMedia = displayItems.indices.contains(currentIndex) ? displayItems[currentIndex] : nil

        VStack(spacing: 0) {
            ZStack {
                // Pull-down sensor: sibling of the TabView so re-evaluation
                // never cascades into TabView layout. stretchAmount only
                // changes while the user is actually pulling down.
                GeometryReader { proxy in
                    Color.clear.preference(key: CarouselStretchKey.self,
                                           value: max(0, proxy.frame(in: .named(scrollSpace)).minY))
                }

                // iPad ambient fanart backdrop behind the cards.
                if isIPad, !displayItems.isEmpty {
                    TVDBPosterImage(media: displayItems[currentIndex], type: .fanart, tvdbFirstPaint: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // The pager — completely stable: fixed height, no scroll
                // dependency. Images live inside the cards so they move
                // naturally with the swipe gesture.
                TabView(selection: $selectedTab) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        if !displayItems.isEmpty {
                            MediaCarouselCard(media: displayItems[index % displayCount], isWide: isIPad)
                                .equatable()
                                .allowsHitTesting(false)
                                .tag(index)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
            }
            .frame(height: imageHeight)
            // Elastic stretch: render-only transforms — layout size never
            // changes so the scroll view's bounce is never disrupted.
            .scaleEffect(1 + stretchAmount / max(imageHeight, 1), anchor: .top)
            .offset(y: -stretchAmount)
            .onPreferenceChange(CarouselStretchKey.self) { y in stretchAmount = y }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { w in containerWidth = w }
                }
            )
            .mask(alignment: .bottom) { Rectangle().frame(height: imageHeight + 2000) }
            .background {
                // Hidden preloader — fetches poster + fanart + LOGO for
                // every slide into the image caches (1x1, invisible).
                ForEach(displayItems.indices, id: \.self) { i in
                    TVDBPosterImage(media: displayItems[i], type: .fanart, tvdbFirstPaint: true)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    TVDBPosterImage(media: displayItems[i], type: .poster, tvdbFirstPaint: true)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    HeroLogoPrefetcher(media: displayItems[i])
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    // The original gradient: clear → background at 0.38 →
                    // 0.88 → solid — the hero dissolves into the page.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: platformBackground.opacity(0.5), location: 0.38),
                            .init(color: platformBackground.opacity(0.88), location: 0.68),
                            .init(color: platformBackground, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 360)
                    .allowsHitTesting(false)

                    if let currentMedia {
                        // The ORIGINAL centered info stack — pills,
                        // title, description, button, in that order.
                        VStack(spacing: 10) {
                            carouselMetaRow(currentMedia)
                            carouselGenreRow(currentMedia)
                            HeroLogoTitle(media: currentMedia, isWide: isIPad, centered: true)

                            if let desc = currentMedia.plainDescription, !desc.isEmpty {
                                Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.horizontal, 8)
                            }

                            // The original button: fixed 130×42, filled
                            // with the primary color, corner radius 12.
                            NavigationLink {
                                if isManga {
                                    AniListMangaDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
                                } else {
                                    AniListDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isManga ? "book.fill" : "play.fill")
                                        .font(.footnote.weight(.semibold))
                                    Text(isManga ? "Read" : "Watch")
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(platformBackground)
                                .frame(width: 130, height: 42)
                                .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                    }
                }
            }

            // The original page indicator: accent-colored active pill.
            CarouselPageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
        .onAppear {
            if displayCount > 0 {
                // Start in the middle rotation so the user can swipe in
                // both directions before the edge-reset fires.
                selectedTab = displayCount
            }
            DispatchQueue.main.async { didSetup = true }
        }
        .onChange(of: selectedTab) { _ in
            guard didSetup, displayCount > 1 else { return }
            // Invisible edge-reset: swiping into the first or last
            // rotation silently jumps back to the equivalent middle slot
            // (the visual page is unchanged — nothing shifts).
            if selectedTab < displayCount || selectedTab >= displayCount * 2 {
                let middleSlot = displayCount + (selectedTab % displayCount)
                guard selectedTab != middleSlot else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { selectedTab = middleSlot }
                }
            }
        }
    }
    #endif

    // MARK: - macOS / Catalyst body (original Mac hero: banner + poster)

    #if os(macOS) || targetEnvironment(macCatalyst)
    @ViewBuilder
    private var macBody: some View {
        MacMediaCarousel(items: displayItems, isManga: isManga)
    }
    #endif

    // MARK: - Info rows (the shared pill component, real metadata only)

    /// Metadata pills — rating / format / year / episodes for anime,
    /// rating / format / status / year for manga. Same object as the
    /// slide's poster, logo and button; nil fields produce no pill.
    @ViewBuilder
    private func carouselMetaRow(_ media: Media) -> some View {
        MetadataPillRow(
            pills: isManga
                ? MetadataPillRowBuilder.mangaMetaPills(for: media)
                : MetadataPillRowBuilder.animeMetaPills(for: media),
            height: 26,
            alignment: .center,
            edgeFades: false,
            allowsHitTesting: false,
            spacing: 6)
    }

    /// Genre pills — up to 6 real genres with the honest "+N" overflow
    /// chip, the whole group centered in the hero.
    @ViewBuilder
    private func carouselGenreRow(_ media: Media) -> some View {
        MetadataPillRow(
            pills: isManga
                ? MetadataPillRowBuilder.mangaGenrePills(for: media)
                : MetadataPillRowBuilder.animeGenrePills(for: media),
            height: 26,
            alignment: .center,
            edgeFades: true,
            allowsHitTesting: false,
            spacing: 6)
    }
}

// MARK: - Stretch preference

struct CarouselStretchKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

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

// MARK: - Page indicator (the original animated pill style)

/// The original indicator: 20pt active capsule in the accent color,
/// 5pt inactive dots at 25% primary opacity, easeInOut animation.
struct CarouselPageIndicator: View {
    let numberOfPages: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(numberOfPages, 1), id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.appAccent : Color.primary.opacity(0.25))
                    .frame(width: index == currentPage ? 20 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(currentPage + 1) of \(numberOfPages)")
    }
}

// MARK: - Hero card (platform-specific artwork)

private struct MediaCarouselCard: View, Equatable {
    let media: Media
    var isWide: Bool = false

    static func == (lhs: MediaCarouselCard, rhs: MediaCarouselCard) -> Bool {
        lhs.media == rhs.media && lhs.isWide == rhs.isWide
    }

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if isWide {
            // iPad: fanart with horizontal parallax.
            Color.clear
                .overlay(
                    ZStack {
                        GeometryReader { geo in
                            let minX = geo.frame(in: .global).minX
                            let screenW = geo.size.width > 0 ? geo.size.width : 1
                            let extra: CGFloat = 80
                            let px = -(extra / 2) - minX * (extra / (2 * screenW))
                            TVDBPosterImage(media: media, type: .fanart, tvdbFirstPaint: true)
                                .frame(width: geo.size.width + extra, height: geo.size.height)
                                .offset(x: px)
                                .clipped()
                        }
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.4), location: 0.5),
                                .init(color: .black.opacity(0.92), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // iPhone: portrait poster with horizontal parallax (TVDB
            // posters are higher-resolution than provider covers — the
            // hero paints visibly sharper at full-screen scale).
            GeometryReader { geo in
                let pageOffset = geo.frame(in: .global).minX
                let buffer: CGFloat = 100
                TVDBPosterImage(media: media, tvdbFirstPaint: true)
                    .frame(width: geo.size.width + buffer, height: geo.size.height)
                    .offset(x: -(buffer / 2) - pageOffset * 0.25)
            }
            .clipped()
        }
        #else
        // macOS: banner background + poster overlay (the original Mac
        // hero structure).
        Color.clear
            .overlay(
                ZStack(alignment: .bottomLeading) {
                    MediaCarouselMacBackground(media: media)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CachedAsyncImage(urlString: media.coverImage.best ?? "")
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 4)
                        .padding(.leading, 16)
                        .padding(.bottom, 12)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #endif
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
@ViewBuilder
private func MediaCarouselMacBackground(media: Media) -> some View {
    if let bannerUrlString = media.bannerImage {
        CachedAsyncImage(urlString: bannerUrlString)
    } else {
        LinearGradient(
            colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif

// MARK: - macOS carousel (timer-driven, the original Mac behavior)

#if os(macOS) || targetEnvironment(macCatalyst)
/// The Mac hero: 16:9 banner card, 5-second auto-advance, poster at the
/// leading edge, logo + description + button beside it, page indicator
/// below — the original macOS home carousel structure with the shared
/// logo/pill machinery.
private struct MacMediaCarousel: View {
    let items: [Media]
    var isManga: Bool = false
    @State private var currentIndex = 0
    @State private var timer: Timer?

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let cardHeight = geo.size.width * (9.0 / 16.0)
            ZStack(alignment: .bottom) {
                if !items.isEmpty {
                    let media = items[currentIndex]
                    ZStack(alignment: .bottomLeading) {
                        MediaCarouselMacBackground(media: media)
                            .frame(width: geo.size.width, height: cardHeight)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(width: geo.size.width, height: cardHeight)

                        HStack(alignment: .bottom, spacing: 12) {
                            CachedAsyncImage(urlString: media.coverImage.best ?? "")
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(radius: 4)

                            VStack(alignment: .leading, spacing: 6) {
                                HeroLogoTitle(media: media, centered: false)

                                if let desc = media.plainDescription, !desc.isEmpty {
                                    Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(2)
                                }

                                // Score + genres — the shared pill row.
                                MetadataPillRow(
                                    pills: [MetadataPill.rating(media.averageScore)]
                                        .compactMap { $0 }
                                        + (isManga
                                           ? MetadataPillRowBuilder.mangaGenrePills(for: media, limit: 2)
                                           : MetadataPillRowBuilder.animeGenrePills(for: media, limit: 2)),
                                    height: 24,
                                    alignment: .leading,
                                    edgeFades: false,
                                    allowsHitTesting: true,
                                    spacing: 6)

                                NavigationLink {
                                    if isManga {
                                        AniListMangaDetailView(mediaId: media.id, preloadedMedia: media)
                                    } else {
                                        AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isManga ? "book.fill" : "play.fill")
                                            .font(.footnote.weight(.semibold))
                                        Text(isManga ? "Read" : "Watch").fontWeight(.semibold)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(platformBackground)
                                    .frame(height: 36)
                                    .padding(.horizontal, 14)
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                    }
                    .frame(width: geo.size.width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                    .id(currentIndex)
                }

                CarouselPageIndicator(numberOfPages: items.count, currentPage: currentIndex)
                    .padding(.bottom, 6)
            }
            .frame(width: geo.size.width, height: cardHeight)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard items.count > 1 else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
#endif

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
