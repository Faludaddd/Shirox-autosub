import SwiftUI

/// Custom long-press action sheet — replaces the default iOS `.contextMenu`
/// with a custom design that matches the Change Stream UI's card-based style.
///
/// Shows:
///  - The selected anime's poster, title, and score at the top
///  - Custom action cards for Add to Planning, Add to Watching, Mark as Completed
///
/// Each action card has an icon, title, and subtitle. Tapping a card runs
/// the action and dismisses the sheet. The sheet has a dimmed background
/// overlay and a close button, with smooth open/close animations.
struct CustomActionSheet: View {
    let media: Media
    let onAddToPlanning: () -> Void
    let onAddToWatching: () -> Void
    let onMarkCompleted: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                // Header — poster + title + score
                HStack(spacing: 14) {
                    CachedAsyncImage(urlString: media.coverImage.extraLarge ?? media.coverImage.large ?? "")
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: 70, height: 105)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(media.title.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if let score = media.averageScore {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.yellow)
                                Text("\(score)%")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let year = media.seasonYear {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Divider
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                // Action cards
                VStack(spacing: 8) {
                    actionCard(
                        icon: "bookmark.fill",
                        iconColor: .blue,
                        title: "Add to Planning",
                        subtitle: "Save to your Planning list",
                        action: {
                            onAddToPlanning()
                            onDismiss()
                        }
                    )
                    actionCard(
                        icon: "play.circle.fill",
                        iconColor: .green,
                        title: "Add to Watching",
                        subtitle: "Start tracking this anime",
                        action: {
                            onAddToWatching()
                            onDismiss()
                        }
                    )
                    actionCard(
                        icon: "checkmark.circle.fill",
                        iconColor: .purple,
                        title: "Mark as Completed",
                        subtitle: "You've finished this anime",
                        action: {
                            onMarkCompleted()
                            onDismiss()
                        }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                // Cancel button
                Button(action: onDismiss) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func actionCard(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
