import SwiftUI

/// Notifications page — opened via the bell icon in HomeView's toolbar.
/// Fully embedded in the app's navigation stack (not a sheet or overlay).
/// Fetches AniList notifications and displays them in a chronological list.
struct NotificationsPage: View {
    @State private var notifications: [AniListNotification] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && notifications.isEmpty {
                loadingView
            } else if let error = error, notifications.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
            } else if notifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("You're all caught up!")
                )
            } else {
                notificationsList
            }
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Notifications List

    @ViewBuilder
    private var notificationsList: some View {
        List {
            ForEach(notifications, id: \.id) { notification in
                NotificationRow(notification: notification)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 180, height: 10)
                    }
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        error = nil
        do {
            notifications = try await AniListSocialService.shared.fetchNotifications()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: AniListNotification

    var body: some View {
        HStack(spacing: 12) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(description)
                    .font(.subheadline)
                    .lineLimit(2)

                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch notification {
        case .airing: return "tv"
        case .following: return "person.fill.checkmark"
        case .activityMessage, .activityReply, .activityReplySubscribed, .activityMention: return "bubble.left.fill"
        case .activityLike, .activityReplyLike: return "heart.fill"
        case .threadCommentMention, .threadCommentReply, .threadCommentSubscribed, .threadCommentLike, .threadLike: return "text.bubble.fill"
        case .mediaAddition, .mediaDataChange, .mediaMerge: return "arrow.triangle.2.circlepath"
        case .mediaDeletion: return "trash.fill"
        case .unknown: return "bell.fill"
        }
    }

    private var description: String {
        switch notification {
        case .airing(let n):
            let title = n.media?.title?.romaji ?? n.media?.title?.english ?? "New Episode"
            return "Episode \(n.episode) of \(title) is now available"
        case .following(let n):
            return n.context ?? "Started following you"
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            return n.context ?? "Activity notification"
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            return n.context ?? "Thread notification"
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            return n.context ?? "Media update"
        case .mediaDeletion(let n):
            return n.context ?? "Media deleted"
        case .unknown:
            return "Notification"
        }
    }

    private var timestamp: String {
        let ts = notification.createdAt
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
