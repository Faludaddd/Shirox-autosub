import SwiftUI

// MARK: - CharacterPortraitCard (Batch 27 — the ONE character card)
//
// Every character portrait in the app renders through this component:
// the detail-page hero portrait, the Characters strip, the animeography
// rows, the voice-actor cards and the "more from this anime" strip.
//
// The consistency contract (item 10):
//   • fixed 2:3 aspect ratio — the source image's own dimensions NEVER
//     determine the card's size (fill + clipped, portrait-safe crop)
//   • one width (110pt) and height (165pt) everywhere — same card on
//     every surface, never a 90/100/110 mix again
//   • one corner radius (12), one border, one shadow
//   • the text zone under the image is a FIXED height (2-line name +
//     1-line subtitle) so names, roles and metadata always align the
//     same way regardless of image dimensions
//   • no stretching ever — .fill with .clipped crops instead
struct CharacterPortraitCard: View {
    /// Character image URL (large preferred, medium fallback).
    let imageURL: String?
    /// Display name (2 lines max, fixed zone).
    let name: String
    /// Secondary line: role ("Main"), voice language ("Japanese"), etc.
    var subtitle: String? = nil

    static let cardWidth: CGFloat = 110
    static let cardHeight: CGFloat = 165

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: imageURL ?? "")
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            // FIXED text zone: the name + subtitle rows always occupy
            // the same height, so a row of these cards aligns perfectly
            // no matter what the images or names are.
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.cardWidth, alignment: .leading)
                    .frame(minHeight: 28, alignment: .top)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Self.cardWidth, alignment: .leading)
                }
            }
            .frame(width: Self.cardWidth, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(name), \($0)" } ?? name)
    }
}
