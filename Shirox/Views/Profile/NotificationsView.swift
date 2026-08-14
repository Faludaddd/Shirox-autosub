import SwiftUI

// MARK: - Loader that fetches an activity by ID then shows ActivityDetailView

struct ActivityFetchView: View {
    let activityId: Int
    @State private var activity: AniListActivity?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let activity {
                ActivityDetailView(activity: activity)
            } else {
                ContentUnavailableView("Activity not found", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationTitle("Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        activity = try? await AniListSocialService.shared.fetchActivityById(id: activityId)
        isLoading = false
    }
}

// MARK: - Main view

struct NotificationsView: View {
    @ObservedObject var vm: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showHistory = false
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider().opacity(0.4)

                content
            }
            .navigationTitle("Notifications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(vm.notifications.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Hidden navigation destination driven by `pendingNavNotif` so
            // tap-to-open works without wrapping each row in a NavigationLink
            // (which would interfere with the swipe gestures).
            .navigationDestinationCompat(item: $pendingNavNotif) { notif in
                destinationView(for: notif)
            }
            .alert("Clear All Notifications?", isPresented: $showClearConfirmation) {
                Button("Clear All", role: .destructive) {
                    vm.clearAllNotifications()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will dismiss all notifications. They'll be saved to history.")
            }
            .sheet(isPresented: $showHistory) {
                NotificationsHistoryView(vm: vm)
            }
        }
        .task { if vm.notifications.isEmpty { await vm.loadNotifications() } }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AniListNotificationFilter.allCases) { f in
                    let selected = vm.notificationFilter == f
                    Button {
                        Task { await vm.loadNotifications(filter: f) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: f.icon).font(.caption)
                            Text(f.label).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingNotifications && vm.notifications.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.notifications.isEmpty {
            ContentUnavailableView("No Notifications", systemImage: "bell.slash")
        } else {
            // Standard List with swipeActions for swipe-to-close (item 16).
            // Swipe left reveals a Close button; swipe right also dismisses.
            List {
                ForEach(vm.notifications) { notif in
                    NotificationRowContent(
                        notif: notif,
                        isTappable: isTappable(notif),
                        onTap: { handleTap(notif) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if isTappable(notif) {
                            Button { handleTap(notif) } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                        }
                        Button { dismissNotification(notif) } label: {
                            Label("Dismiss", systemImage: "xmark.circle")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            dismissNotification(notif)
                        } label: {
                            Label("Close", systemImage: "xmark.circle.fill")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            dismissNotification(notif)
                        } label: {
                            Label("Dismiss", systemImage: "hand.raised.fill")
                        }
                        .tint(.orange)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await vm.loadNotifications() }
        }
    }

    // MARK: - Tap Handling

    /// Tappable notifications navigate to their detail view via a hidden
    /// NavigationLink driven by `pendingNavNotif`. Non-tappable ones do
    /// nothing on tap (the swipe gestures still work).
    @State private var pendingNavNotif: ProviderNotification?

    private func handleTap(_ notif: ProviderNotification) {
        guard isTappable(notif) else { return }
        Haptics.light()
        pendingNavNotif = notif
    }

    // MARK: - Row

    /// Removes a notification with animation, ensures the underlying
    /// `ProfileViewModel.removeNotification(_:)` runs (which persists the
    /// deletion), and triggers a light haptic so the user gets feedback that
    /// the swipe-then-tap gesture actually committed.
    private func dismissNotification(_ notif: ProviderNotification) {
        Haptics.light()
        withAnimation(.easeInOut(duration: 0.25)) {
            vm.removeNotification(notif)
        }
    }

    private func isTappable(_ notif: ProviderNotification) -> Bool {
        switch notif.kind {
        case .airing(_, _, let mediaId, _):
            return mediaId != 0
        case .activityMessage(let id, _, _), .activityReply(let id, _, _),
             .activityMention(let id, _, _), .activityLike(let id, _, _):
            return id != nil
        case .mediaChange(_, _, _, let mediaId):
            return mediaId != nil
        default:
            return false
        }
    }

    @ViewBuilder
    private func destinationView(for notif: ProviderNotification) -> some View {
        switch notif.kind {
        case .airing(_, _, let mediaId, _):
            AniListDetailView(mediaId: mediaId, preloadedMedia: nil)
        case .activityMessage(let activityId, _, _), .activityReply(let activityId, _, _),
             .activityMention(let activityId, _, _), .activityLike(let activityId, _, _):
            if let id = activityId { ActivityFetchView(activityId: id) }
        case .mediaChange(_, _, _, let mediaId):
            if let id = mediaId { AniListDetailView(mediaId: id, preloadedMedia: nil) }
        default:
            EmptyView()
        }
    }

    private func iconFor(_ notif: ProviderNotification) -> (String, Color) {
        switch notif.kind {
        case .airing: return ("tv", .blue)
        case .following: return ("person.badge.plus", .green)
        case .activityMessage: return ("envelope", .purple)
        case .activityReply, .activityMention: return ("bubble.left", .orange)
        case .activityLike: return ("heart.fill", .pink)
        case .mediaChange: return ("arrow.triangle.2.circlepath", .gray)
        case .unknown: return ("bell", .gray)
        }
    }
}

// MARK: - NotificationSwipeRow
//
// Custom row with full gesture support:
//   • Swipe LEFT — reveals a Close button aligned to the right edge. Tapping
//     the button removes the notification.
//   • Swipe DOWN — fully dismisses the notification immediately (quick-
//     dismiss shortcut). The gesture has a minimum vertical distance and
//     requires the horizontal component to be small so it doesn't trigger
//     during normal vertical scrolling.
//   • Tap — opens the notification's detail view (if tappable).
//
// The row is built on a ScrollView-friendly VStack (NOT a List) so the
// swipe gestures don't conflict with the system list's scroll-vs-swipe
// gesture priority. Animations use spring/easeInOut for smooth translation,
// fade-out on dismissal, and eased return when cancelled.

private struct NotificationSwipeRow: View {
    let notif: ProviderNotification
    let isTappable: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    // Swipe-left reveal state.
    @State private var revealOffset: CGFloat = 0
    @State private var closeRevealed = false

    // Swipe-down dismiss state.
    @State private var verticalDragOffset: CGFloat = 0
    @State private var isDismissing = false

    private let closeRevealWidth: CGFloat = 80

    var body: some View {
        ZStack(alignment: .trailing) {
            // Background close button — revealed when swiped left.
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                    .frame(width: closeRevealWidth, height: 44)
            }
            .buttonStyle(.plain)
            .opacity(closeRevealed ? 1 : 0)
            .padding(.trailing, 8)

            // Foreground row content.
            rowContent
                .background(rowBackground)
                .offset(x: revealOffset)
                .offset(y: verticalDragOffset)
                .opacity(isDismissing ? 0 : 1)
                .gesture(horizontalSwipeGesture)
                .simultaneousGesture(verticalSwipeGesture)
                .onTapGesture {
                    if !closeRevealed { onTap() }
                }
        }
        .clipped()
    }

    // MARK: - Row Content

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            notificationIcon

            VStack(alignment: .leading, spacing: 3) {
                bodyText
                    .font(.subheadline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(notif.createdAt.toTimeAgo())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isTappable {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(10)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.07))
    }

    // MARK: - Icon (delegates to the parent's icon logic)

    private var notificationIcon: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        return Group {
            if let iconImage = notif.kind.iconImage {
                switch iconImage {
                case .avatar(let url):
                    ZStack(alignment: .bottomTrailing) {
                        CachedAsyncImage(urlString: url)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(color))
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 40, height: 40)
                case .cover(let url):
                    ZStack(alignment: .bottomTrailing) {
                        CachedAsyncImage(urlString: url)
                            .frame(width: 30, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(color))
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 34, height: 46)
                }
            } else {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(color))
            }
        }
    }

    private var bodyText: Text {
        switch notif.kind {
        case .airing(let episode, let mediaTitle, _, _):
            return Text("\(mediaTitle ?? "Anime") ").bold() + Text("episode \(episode) aired")
        case .following(_, let userName, _):
            return Text(userName ?? "Someone").bold() + Text(" followed you")
        case .activityMessage(_, let context, _), .activityReply(_, let context, _),
             .activityMention(_, let context, _), .activityLike(_, let context, _):
            return Text("Activity ") + Text(context ?? "")
        case .mediaChange(let title, let context, _, _):
            if let title, !title.isEmpty {
                return Text(title).bold() + Text(context ?? " was recently added to the site.")
            } else {
                return Text(context ?? "A title was updated")
            }
        case .unknown(let context):
            return Text(context ?? "Notification")
        }
    }

    // MARK: - Gestures

    /// Horizontal swipe — reveals the Close button when dragged left past a
    /// threshold. Snaps open/closed with a spring animation. Dragging right
    /// past the row's leading edge does nothing (no positive offset).
    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Only respond to predominantly-horizontal drags.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = closeRevealed ? -closeRevealWidth : 0
                let dragged = base + value.translation.width
                // Clamp so the row can't be dragged right past 0 (no
                // positive offset) or left past the close button width.
                revealOffset = min(0, max(dragged, -closeRevealWidth - 20))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let shouldReveal = closeRevealed
                    ? (value.translation.width > -closeRevealWidth / 2)  // swipe right to hide
                    : (value.translation.width < -closeRevealWidth / 2)  // swipe left to reveal
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    closeRevealed = shouldReveal
                    revealOffset = shouldReveal ? -closeRevealWidth : 0
                }
            }
    }

    /// Vertical swipe-down — fully dismisses the notification. Requires a
    /// predominantly-vertical drag with a minimum downward distance of 60pt
    /// so it doesn't trigger during normal vertical scrolling. The row
    /// translates downward and fades out before being removed.
    private var verticalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                // Only respond to predominantly-downward drags.
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else {
                    verticalDragOffset = 0
                    return
                }
                // Track the drag so the row follows the finger, but only
                // once the threshold is crossed.
                if value.translation.height > 30 {
                    verticalDragOffset = value.translation.height - 30
                }
            }
            .onEnded { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        verticalDragOffset = 0
                    }
                    return
                }
                // Dismiss if the user swiped down past 60pt total.
                if value.translation.height > 60 {
                    isDismissing = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        verticalDragOffset = 300
                    }
                    // Remove the notification after the fade-out animation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onClose()
                    }
                } else {
                    // Spring back — cancelled.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        verticalDragOffset = 0
                    }
                }
            }
    }

    // MARK: - Icon Helper

    static func iconAndColor(for notif: ProviderNotification) -> (String, Color) {
        switch notif.kind {
        case .airing: return ("tv", .blue)
        case .following: return ("person.badge.plus", .green)
        case .activityMessage: return ("envelope", .purple)
        case .activityReply, .activityMention: return ("bubble.left", .orange)
        case .activityLike: return ("heart.fill", .pink)
        case .mediaChange: return ("arrow.triangle.2.circlepath", .gray)
        case .unknown: return ("bell", .gray)
        }
    }
}

// MARK: - NotificationRowContent (item 16 — standard List row without custom gestures)

/// Simple row content for use inside a List with standard swipeActions.
/// Renders the same visual content as NotificationSwipeRow but without
/// the custom gesture wrapper — the List's built-in swipe handles dismiss.
private struct NotificationRowContent: View {
    let notif: ProviderNotification
    let isTappable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                notificationIcon

                VStack(alignment: .leading, spacing: 3) {
                    bodyText
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(notif.createdAt.toTimeAgo())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private var notificationIcon: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        return Group {
            if let iconImage = notif.kind.iconImage {
                switch iconImage {
                case .avatar(let url):
                    ZStack(alignment: .bottomTrailing) {
                        CachedAsyncImage(urlString: url)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(color))
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 40, height: 40)
                case .cover(let url):
                    ZStack(alignment: .bottomTrailing) {
                        CachedAsyncImage(urlString: url)
                            .frame(width: 30, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(color))
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 34, height: 46)
                }
            } else {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(color))
            }
        }
    }

    private var bodyText: Text {
        switch notif.kind {
        case .airing(let episode, let mediaTitle, _, _):
            return Text("\(mediaTitle ?? "Anime") ").bold() + Text("episode \(episode) aired")
        case .following(_, let userName, _):
            return Text(userName ?? "Someone").bold() + Text(" followed you")
        case .activityMessage(_, let context, _), .activityReply(_, let context, _),
             .activityMention(_, let context, _), .activityLike(_, let context, _):
            return Text("Activity ") + Text(context ?? "")
        case .mediaChange(let title, let context, _, _):
            if let title, !title.isEmpty {
                return Text(title).bold() + Text(context ?? " was recently added to the site.")
            } else {
                return Text(context ?? "A title was updated")
            }
        case .unknown(let context):
            return Text(context ?? "Notification")
        }
    }
}

// MARK: - Notifications History View (item 9)

/// Shows past/dismissed notifications with their original date/time.
struct NotificationsHistoryView: View {
    @ObservedObject var vm: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.notificationHistory.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock.slash")
                } else {
                    List {
                        ForEach(vm.notificationHistory) { notif in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NotificationSwipeRow.iconAndColor(for: notif).0)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(notif.createdAt.toTimeAgo())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(notif.createdAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
