import SwiftUI
import Charts

struct ProfileStatsView: View {
    let stats: ProfileAnimeStats?
    var scoreFormat: ScoreFormat = .point10Decimal

    var body: some View {
        if let stats = stats {
            VStack(spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statBox(title: "Total Anime", value: Text("\(stats.count)"), icon: "play.tv")
                    statBox(title: "Episodes", value: Text("\(stats.episodesWatched)"), icon: "play.circle")
                    if stats.minutesWatched > 0 {
                        statBox(title: "Time Watched", value: Text(formatMinutes(stats.minutesWatched)), icon: "clock")
                    }
                    if stats.meanScore > 0 {
                        statBox(title: "Mean Score", value: scoreFormat.scoreText(for: stats.meanScore), icon: "star")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // Local watch stats — from the app's own data
                LocalWatchStatsView()
                    .padding(.top, 8)

                // Distribution charts need breakdown data (statuses/genres/scores),
                // which some providers (e.g. MAL's official API) do not supply.
                let hasBreakdowns = stats.statuses != nil || stats.genres != nil || stats.scores != nil
                if hasBreakdowns {
                    if #available(iOS 16, *) {
                        chartsSection(stats: stats)
                    } else {
                        statsListFallback(stats: stats)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Stats", systemImage: "chart.bar.xaxis")
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func chartsSection(stats: ProfileAnimeStats) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Status Distribution")
                .font(.headline)
                .padding(.horizontal)

            statusChart(stats.statuses)
                .frame(height: 200)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            Text("Genre Distribution")
                .font(.headline)
                .padding(.horizontal)

            genreChart(stats.genres)
                .frame(height: 250)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            Text("Score Distribution")
                .font(.headline)
                .padding(.horizontal)

            scoreChart(stats.scores)
                .frame(height: 200)
                .padding(.horizontal)
                .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func statsListFallback(stats: ProfileAnimeStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let statuses = stats.statuses {
                Text("Status Distribution")
                    .font(.headline)
                    .padding(.horizontal)
                ForEach(statuses.filter { $0.count > 0 }, id: \.status) { s in
                    HStack {
                        Text(s.status.capitalized).padding(.horizontal)
                        Spacer()
                        Text("\(s.count)").foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
                Divider().padding(.horizontal)
            }
            if let genres = stats.genres?.sorted(by: { $0.count > $1.count }).prefix(10) {
                Text("Top Genres")
                    .font(.headline)
                    .padding(.horizontal)
                ForEach(Array(genres), id: \.genre) { g in
                    HStack {
                        Text(g.genre).padding(.horizontal)
                        Spacer()
                        Text("\(g.count)").foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
            }
        }
        .padding(.bottom, 30)
    }

    private func statBox(title: String, value: Text, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                value.font(.subheadline.weight(.bold))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func statusChart(_ data: [ProfileStatusStat]?) -> some View {
        if let data = data?.filter({ $0.count > 0 }) {
            Chart(data, id: \.status) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Status", item.status.capitalized)
                )
                .foregroundStyle(by: .value("Status", item.status))
                .annotation(position: .trailing) {
                    Text("\(item.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel()
                }
            }
        } else {
            Text("No status data").foregroundStyle(.secondary)
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func genreChart(_ data: [ProfileGenreStat]?) -> some View {
        if let data = data?.sorted(by: { $0.count > $1.count }).prefix(10) {
            Chart(data, id: \.genre) { item in
                BarMark(
                    x: .value("Genre", item.genre),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary.gradient)
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel(orientation: .vertical)
                }
            }
        } else {
            Text("No genre data").foregroundStyle(.secondary)
        }
    }

    private var scoreChartAxisValues: [Int] {
        switch scoreFormat {
        case .point100: return [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        case .point10Decimal, .point10: return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        case .point5: return [1, 2, 3, 4, 5]
        case .point3: return [1, 2, 3]
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func scoreChart(_ data: [ProfileScoreStat]?) -> some View {
        if let data = data?.sorted(by: { $0.score < $1.score }) {
            Chart(data, id: \.score) { item in
                AreaMark(
                    x: .value("Score", item.score),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary.opacity(0.3).gradient)
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Score", item.score),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: scoreChartAxisValues)
            }
        } else {
            Text("No score data").foregroundStyle(.secondary)
        }
    }

    private func formatMinutes(_ mins: Int) -> String {
        let days = mins / 1440
        let hours = (mins % 1440) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else {
            return "\(hours)h \(mins % 60)m"
        }
    }
}

// MARK: - Local Watch Statistics (app's own data)

/// Local watch statistics dashboard — computed from the app's own
/// Continue Watching and Watch History data, not from AniList. Shows
/// the user's actual viewing habits inside Shirox.
struct LocalWatchStatsView: View {
    @ObservedObject private var cw = ContinueWatchingManager.shared
    @ObservedObject private var history = WatchHistoryService.shared

    private var totalEpisodesWatched: Int {
        cw.items.count
    }

    private var uniqueAnimeCount: Int {
        Set(cw.items.compactMap { $0.aniListID }).count
    }

    private var totalWatchSeconds: Double {
        cw.items.reduce(0) { $0 + $1.watchedSeconds }
    }

    private var totalWatchMinutes: Int {
        Int(totalWatchSeconds / 60)
    }

    private var averageEpisodeMinutes: Int {
        guard totalEpisodesWatched > 0 else { return 0 }
        return totalWatchMinutes / totalEpisodesWatched
    }

    private var episodesThisWeek: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return cw.items.filter { $0.lastWatchedAt >= weekAgo }.count
    }

    private var episodesThisMonth: Int {
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return cw.items.filter { $0.lastWatchedAt >= monthAgo }.count
    }

    private var topAnime: [(title: String, image: String?, seconds: Double)] {
        var byTitle: [String: Double] = [:]
        var images: [String: String] = [:]
        for item in cw.items {
            byTitle[item.mediaTitle, default: 0] += item.watchedSeconds
            images[item.mediaTitle] = item.imageUrl
        }
        return byTitle
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (title: $0.key, image: images[$0.key], seconds: $0.value) }
    }

    private var currentStreak: Int {
        // Count consecutive days with at least one watch entry.
        guard !cw.items.isEmpty else { return 0 }
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())
        let sorted = cw.items.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        guard let mostRecent = sorted.first else { return 0 }

        // If the most recent watch was today, start counting.
        if calendar.isDate(mostRecent.lastWatchedAt, inSameDayAs: checkDate) ||
           calendar.isDateInYesterday(mostRecent.lastWatchedAt) {
            while true {
                let hasWatch = cw.items.contains { calendar.isDate($0.lastWatchedAt, inSameDayAs: checkDate) }
                if hasWatch {
                    streak += 1
                    checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
                } else {
                    break
                }
            }
        }
        return streak
    }

    var body: some View {
        VStack(spacing: 16) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                Text("Shirox Watch Stats")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16)

            if totalEpisodesWatched == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No watch data yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Watch anime in the app to see your statistics here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                // Stat cards grid
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    statCard(title: "Episodes Watched", value: "\(totalEpisodesWatched)", icon: "play.circle.fill", color: .blue)
                    statCard(title: "Unique Anime", value: "\(uniqueAnimeCount)", icon: "tv.fill", color: .purple)
                    statCard(title: "Total Time", value: formatMinutes(totalWatchMinutes), icon: "clock.fill", color: .green)
                    statCard(title: "Avg / Episode", value: "\(averageEpisodeMinutes)m", icon: "timer", color: .orange)
                    statCard(title: "This Week", value: "\(episodesThisWeek)", icon: "calendar", color: .teal)
                    statCard(title: "This Month", value: "\(episodesThisMonth)", icon: "calendar.badge.clock", color: .pink)
                }
                .padding(.horizontal, 16)

                // Streak card
                statCard(
                    title: "Current Streak",
                    value: "\(currentStreak) day\(currentStreak == 1 ? "" : "s")",
                    icon: "flame.fill",
                    color: .red
                )
                .padding(.horizontal, 16)

                // Top anime list
                if !topAnime.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.yellow)
                            Text("Top Anime by Watch Time")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(topAnime.indices, id: \.self) { idx in
                                let anime = topAnime[idx]
                                HStack(spacing: 12) {
                                    Text("\(idx + 1)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)

                                    CachedAsyncImage(urlString: anime.image ?? "")
                                        .aspectRatio(2/3, contentMode: .fit)
                                        .frame(width: 30, height: 45)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(anime.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(formatMinutes(Int(anime.seconds / 60)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func formatMinutes(_ mins: Int) -> String {
        let hours = mins / 60
        let minutes = mins % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
