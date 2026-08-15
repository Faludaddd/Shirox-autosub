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
    @State private var showClearConfirmation = false
    /// Layout toggle: list (default, full row per notification) or grid
    /// (2×2 compact cards). Persists across launches.
    @AppStorage("notificationsGridLayout") private var isGridLayout = false

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
                // Clear-all + Layout toggle on leading.
                // Done on trailing by itself — no overlap.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(vm.notifications.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.2)) { isGridLayout.toggle() }
                    } label: {
                        // Icon shows the layout you'll switch TO.
                        Image(systemName: isGridLayout ? "list.bullet" : "square.grid.2x2")
                    }
                    .disabled(vm.notifications.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                Text("This will dismiss all notifications.")
            }
        }
        .task { if vm.notifications.isEmpty { await vm.loadNotifications() } }
        #if os(iOS)
        // Full-height sheet — medium detent constrains the List and prevents
        // swipe gestures from registering properly.
        .adaptivePresentationDetents([.large])

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
        } else if isGridLayout {
            // 2×2 grid layout — compact visual cards. Posters/avatars are
            // the dominant element; text is condensed to 2 lines + type.
            gridContent
        } else {
            // Standard List with swipeActions for swipe-to-close (item 16).
            // Swipe left reveals a Close button; swipe right also dismisses.
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            ForEach(vm.notifications) { notif in
                NotificationRowContent(
                    notif: notif,
                    isTappable: isTappable(notif),
                    onTap: { handleTap(notif) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contextMenu {
                    if isTappable(notif) {
                        Button { handleTap(notif) } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                    }
                    Button { dismissNotification(notif) } label: {
                        Label("Dismiss", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) { dismissNotification(notif) } label: {
                        Label("Delete", systemImage: "trash")
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

    /// 2×2 grid layout. Each notification is a compact card: large poster
    /// (or avatar or icon) on top, type chip + 2-line body + timestamp
    /// below. Designed for visual scanning when the user has many
    /// notifications. Long-press dismisses via contextMenu (swipe actions
    /// aren't available outside a List).
    @ViewBuilder
    private var gridContent: some View {
        ScrollView {
            let columns = [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(vm.notifications) { notif in
                    NotificationGridCard(
                        notif: notif,
                        isTappable: isTappable(notif),
                        onTap: { handleTap(notif) },
                        onClose: { dismissNotification(notif) }
                    )
                    .contextMenu {
                        if isTappable(notif) {
                            Button { handleTap(notif) } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                        }
                        Button(role: .destructive) { dismissNotification(notif) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .refreshable { await vm.loadNotifications() }
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
}

// MARK: - NotificationSwipeRow
//
// Custom row with full gesture support. Kept for reference but the active
// list uses `NotificationRowContent` (below) inside a standard List so the
// built-in swipeActions work cleanly.

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
            NotificationRowContent(notif: notif, isTappable: isTappable, onTap: onTap)
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

    // MARK: - Gestures

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = closeRevealed ? -closeRevealWidth : 0
                let dragged = base + value.translation.width
                revealOffset = min(0, max(dragged, -closeRevealWidth - 20))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let shouldReveal = closeRevealed
                    ? (value.translation.width > -closeRevealWidth / 2)
                    : (value.translation.width < -closeRevealWidth / 2)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    closeRevealed = shouldReveal
                    revealOffset = shouldReveal ? -closeRevealWidth : 0
                }
            }
    }

    private var verticalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else {
                    verticalDragOffset = 0
                    return
                }
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
                if value.translation.height > 60 {
                    isDismissing = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        verticalDragOffset = 300
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onClose()
                    }
                } else {
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

// MARK: - NotificationRowContent (redesigned — large posters, strong layout)

/// Redesigned notification row. Posters/covers are scaled up significantly
/// (covers now 64×90pt, avatars 64×64pt) so visual content dominates the
/// row. The card uses a stronger rounded background, an accent stripe on
/// the left for the notification type, and a clearer text hierarchy.
private struct NotificationRowContent: View {
    let notif: ProviderNotification
    let isTappable: Bool
    let onTap: () -> Void

    private var accentColor: Color {
        NotificationSwipeRow.iconAndColor(for: notif).1
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
                notificationVisual
                textColumn
                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { onTap() }
    }

    // MARK: - Visual (poster / avatar)

    /// Scaled-up poster for cover-type notifications, large circle for
    /// avatars, large icon circle for plain notifications. The visual is
    /// the row's anchor — text wraps around it, not the other way around.
    @ViewBuilder
    private var notificationVisual: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        if let iconImage = notif.kind.iconImage {
            switch iconImage {
            case .avatar(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(color))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
                .frame(width: 78, height: 78)
            case .cover(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(color))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
                .frame(width: 78, height: 112)
            }
        } else {
            // Plain icon notification — bigger circle for stronger visual.
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: color.opacity(0.35), radius: 5, x: 0, y: 2)
        }
    }

    // MARK: - Text column

    @ViewBuilder
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Type chip — small pill at the top showing the notification category.
            typeChip

            bodyText
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                Text(notif.createdAt.toTimeAgo())
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var typeChip: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(typeLabel)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var typeLabel: String {
        switch notif.kind {
        case .airing: return "Airing"
        case .following: return "Follow"
        case .activityMessage: return "Message"
        case .activityReply: return "Reply"
        case .activityMention: return "Mention"
        case .activityLike: return "Like"
        case .mediaChange: return "Update"
        case .unknown: return "Notice"
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
/// Redesigned with the same large-poster layout as the main notifications list.
struct NotificationsHistoryView: View {
    @ObservedObject var vm: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            historyContent
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if vm.notificationHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "clock.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No notification history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(vm.notificationHistory.enumerated()), id: \.offset) { _, notif in
                        historyRow(notif)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ notif: ProviderNotification) -> some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        HStack(alignment: .top, spacing: 12) {
                if let iconImage = notif.kind.iconImage {
                    switch iconImage {
                    case .avatar(let url):
                        CachedAsyncImage(urlString: url)
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    case .cover(let url):
                        CachedAsyncImage(urlString: url)
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(width: 56, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
                    }
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(color))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(historyBodyText(for: notif))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .semibold))
                        Text(Date(timeIntervalSince1970: TimeInterval(notif.createdAt))
                            .formatted(date: .abbreviated, time: .standard))
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}

// MARK: - History body text helper (item 6)
private func historyBodyText(for notif: ProviderNotification) -> String {
    switch notif.kind {
    case .airing(let episode, let mediaTitle, _, _):
        return "\(mediaTitle ?? "Anime") — Episode \(episode) aired"
    case .following(_, let userName, _):
        return "\(userName ?? "Someone") followed you"
    case .activityMessage(_, let context, _), .activityReply(_, let context, _),
         .activityMention(_, let context, _), .activityLike(_, let context, _):
        return "Activity: \(context ?? "")"
    case .mediaChange(let title, let context, _, _):
        if let title, !title.isEmpty { return "\(title): \(context ?? "Updated")" }
        return context ?? "Media updated"
    case .unknown(let context):
        return context ?? "Notification"
    }
}

// MARK: - Notification Grid Card (2×2 grid layout)

/// Compact card for the 2×2 grid layout. Poster/avatar/icon fills the top
/// of the card; type chip + 2-line body + timestamp sit below. Tap opens
/// detail (if tappable); long-press shows context menu with Delete.
private struct NotificationGridCard: View {
    let notif: ProviderNotification
    let isTappable: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    private var accentColor: Color {
        NotificationSwipeRow.iconAndColor(for: notif).1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poster
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 4) {
                typeChip
                bodyText
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .semibold))
                    Text(notif.createdAt.toTimeAgo())
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var poster: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        if let iconImage = notif.kind.iconImage {
            switch iconImage {
            case .avatar(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                .frame(width: 60, height: 60)
                                .padding(.bottom, 12)
                        )
                    // Avatar shown as a circle on top of a colored banner.
                }
                .frame(height: 120)
                .overlay(alignment: .center) {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(color))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .padding(8)
                }
                .background(
                    LinearGradient(
                        colors: [color.opacity(0.3), color.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
            case .cover(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(color))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .padding(6)
                }
                .frame(height: 140)
            }
        } else {
            // Plain icon notification — colored banner with the icon.
            ZStack {
                LinearGradient(
                    colors: [color.opacity(0.35), color.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(height: 120)
        }
    }

    @ViewBuilder
    private var typeChip: some View {
        let (symbol, color) = NotificationSwipeRow.iconAndColor(for: notif)
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(typeLabel)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var typeLabel: String {
        switch notif.kind {
        case .airing: return "Airing"
        case .following: return "Follow"
        case .activityMessage: return "Message"
        case .activityReply: return "Reply"
        case .activityMention: return "Mention"
        case .activityLike: return "Like"
        case .mediaChange: return "Update"
        case .unknown: return "Notice"
        }
    }

    private var bodyText: Text {
        switch notif.kind {
        case .airing(let episode, let mediaTitle, _, _):
            return Text("\(mediaTitle ?? "Anime") ").bold() + Text("ep \(episode) aired")
        case .following(_, let userName, _):
            return Text(userName ?? "Someone").bold() + Text(" followed you")
        case .activityMessage(_, let context, _), .activityReply(_, let context, _),
             .activityMention(_, let context, _), .activityLike(_, let context, _):
            return Text(context ?? "Activity")
        case .mediaChange(let title, let context, _, _):
            if let title, !title.isEmpty {
                return Text(title).bold() + Text(" \(context ?? "updated")")
            } else {
                return Text(context ?? "Updated")
            }
        case .unknown(let context):
            return Text(context ?? "Notification")
        }
    }
}

