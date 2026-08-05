import SwiftUI

/// Schedule tab — shows anime airing schedules grouped by Today, This Week, and Upcoming.
/// Fully embedded in the app's navigation hierarchy. Tapping an item opens AniListDetailView.
struct ScheduleView: View {
    @State private var todayItems: [AniListAiringScheduleItem] = []
    @State private var weekItems: [AniListAiringScheduleItem] = []
    @State private var upcomingItems: [Media] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && todayItems.isEmpty && weekItems.isEmpty && upcomingItems.isEmpty {
                    loadingView
                } else if let error = error, todayItems.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Retry") { Task { await load() } }
                        }
                    }
                } else {
                    scheduleList
                }
            }
            .navigationTitle("Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Schedule List

    @ViewBuilder
    private var scheduleList: some View {
        List {
            if !todayItems.isEmpty {
                Section {
                    ForEach(todayItems) { item in
                        ScheduleRow(item: item)
                    }
                } header: {
                    Text("Today")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }

            if !weekItems.isEmpty {
                Section {
                    ForEach(weekItems) { item in
                        ScheduleRow(item: item)
                    }
                } header: {
                    Text("This Week")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }

            if !upcomingItems.isEmpty {
                Section {
                    ForEach(upcomingItems) { media in
                        NavigationLink {
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                        } label: {
                            UpcomingRow(media: media)
                        }
                    }
                } header: {
                    Text("Upcoming")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 50, height: 70)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 120, height: 10)
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
            async let today = AniListService.shared.airingToday()
            async let week = AniListService.shared.airingThisWeek()
            async let upcoming = AniListService.shared.upcoming()
            let (t, w, u) = try await (today, week, upcoming)
            todayItems = t
            weekItems = w.filter { item in
                !todayItems.contains { $0.media.id == item.media.id && $0.episode == item.episode }
            }
            upcomingItems = u.map { AniListProvider.shared.mapMedia($0) }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Schedule Row

private struct ScheduleRow: View {
    let item: AniListAiringScheduleItem

    var body: some View {
        NavigationLink {
            AniListDetailView(mediaId: item.media.id, preloadedMedia: AniListProvider.shared.mapMedia(item.media))
        } label: {
            HStack(spacing: 12) {
                // Cover image
                CachedAsyncImage(urlString: item.media.coverImage.best ?? "")
                    .frame(width: 50, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.media.title.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("EP \(item.episode)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())

                        if let countdown = item.countdownDisplay {
                            Text(countdown)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let airDate = item.airDateDisplay {
                        Text(airDate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Upcoming Row

private struct UpcomingRow: View {
    let media: Media

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: media.coverImage.best ?? "")
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(media.title.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let season = media.season, let year = media.seasonYear {
                        Text("\(season.capitalized) \(year)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let status = media.statusDisplay {
                        Text("• \(status)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .buttonStyle(.plain)
    }
}
