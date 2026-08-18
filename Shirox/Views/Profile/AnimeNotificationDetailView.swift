import SwiftUI

/// Custom anime detail UI shown when tapping an airing notification.
/// Shows episode-specific info (episode number, title, release time,
/// countdown to next episode) plus anime metadata (status, schedule,
/// episode count/progress) in a polished layout consistent with the app.
///
/// This is a CUSTOM view — not the normal AniListDetailView. It focuses
/// on the notification context (what just aired, when, what's next)
/// rather than the full detail page.
struct AnimeNotificationDetailView: View {
    let mediaId: Int
    let episodeNumber: Int
    let mediaTitle: String?
    let coverImageURL: String?

    @State private var media: Media?
    @State private var isLoading = true
    @State private var error: String?
    @State private var timelineTimer: Timer?

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        Group {
            if let media = media {
                content(media: media)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(platformBackground)
            } else if let error = error {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
            }
        }
        .navigationTitle(mediaTitle ?? "Anime")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        #endif
        .task { await loadMedia() }
        .onDisappear { timelineTimer?.invalidate() }
    }

    @ViewBuilder
    private func content(media: Media) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(media: media)
                episodeInfoSection(media: media)
                countdownSection(media: media)
                statsSection(media: media)
                if let desc = media.plainDescription, !desc.isEmpty {
                    synopsisSection(desc: desc)
                }
                actionSection(media: media)
                Spacer().frame(height: 32)
            }
        }
        .coordinateSpace(name: "notifDetailScroll")
        .ignoresSafeArea(edges: .top)
        .background(platformBackground)
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(media: Media) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("notifDetailScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 360 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                CachedAsyncImage(urlString: media.bannerImage ?? media.coverImage.best ?? "")
                    .frame(width: proxy.size.width, height: imageH)
                    .clipped()
                    .overlay(Color.black.opacity(0.35))
                    .offset(y: imageY)
            }
            .frame(height: 360)
            .ignoresSafeArea(edges: .top)
            .mask(alignment: .bottom) { Rectangle().frame(height: 360 + 2000) }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: platformBackground.opacity(0.2), location: 0.45),
                    .init(color: platformBackground, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: media.coverImage.best ?? "")
                    .frame(width: 100, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(media.title.displayTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        if let score = media.averageScore {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.caption2.weight(.bold))
                                Text("\(score)%").font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                        if let status = media.statusDisplay {
                            Text(status)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Episode info

    @ViewBuilder
    private func episodeInfoSection(media: Media) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Episode")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                infoRow(label: "Episode", value: "\(episodeNumber)")
                if let total = media.episodes {
                    Divider().padding(.leading, 16)
                    infoRow(label: "Total Episodes", value: "\(total)")
                    Divider().padding(.leading, 16)
                    infoRow(label: "Progress", value: "\(episodeNumber) / \(total)")
                }
                Divider().padding(.leading, 16)
                infoRow(label: "Status", value: media.statusDisplay ?? "Unknown")
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(.horizontal, 16)
        }
        .padding(.top, 16)
    }

    // MARK: - Countdown (live-updating)

    @ViewBuilder
    private func countdownSection(media: Media) -> some View {
        if let next = media.nextAiringEpisode {
            VStack(alignment: .leading, spacing: 14) {
                Text("Next Episode")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    infoRow(label: "Episode", value: "\(next.episode)")
                    Divider().padding(.leading, 16)
                    infoRow(label: "Airs In", value: formatCountdown(next.timeUntilAiring))
                    Divider().padding(.leading, 16)
                    infoRow(label: "Air Date", value: formatAirDate(next.airingAt))
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .padding(.horizontal, 16)
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private func statsSection(media: Media) -> some View {
        let items = statisticsItems(for: media)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Statistics")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items, id: \.0) { item in
                        statisticCard(label: item.0, value: item.1)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 16)
        }
    }

    private func statisticsItems(for media: Media) -> [(String, String)] {
        var items: [(String, String)] = []
        if let type = media.type, !type.isEmpty {
            items.append(("Type", type.replacingOccurrences(of: "_", with: " ").capitalized))
        }
        if let format = media.format, !format.isEmpty {
            items.append(("Format", format.replacingOccurrences(of: "_", with: " ").capitalized))
        }
        if let status = media.statusDisplay { items.append(("Status", status)) }
        if let episodes = media.episodes { items.append(("Episodes", "\(episodes)")) }
        if let score = media.averageScore { items.append(("Rating", "\(score)%")) }
        if let pop = media.popularity, pop > 0 { items.append(("Popularity", "\(pop)")) }
        let seasonStr = [media.season?.capitalized, media.seasonYear.map { String($0) }]
            .compactMap { $0 }.joined(separator: " ")
        if !seasonStr.isEmpty { items.append(("Season", seasonStr)) }
        if let aired = media.airDateRange, !aired.isEmpty { items.append(("Aired", aired)) }
        if let source = media.sourceDisplay { items.append(("Source", source)) }
        if let studio = media.studioNames?.first, !studio.isEmpty { items.append(("Studio", studio)) }
        return items
    }

    @ViewBuilder
    private func statisticCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.2))
    }

    // MARK: - Synopsis

    @ViewBuilder
    private func synopsisSection(desc: String) -> some View {
        SynopsisSection(text: desc)
            .padding(.top, 16)
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionSection(media: Media) -> some View {
        VStack(spacing: 10) {
            NavigationLink {
                AniListDetailView(mediaId: media.id, preloadedMedia: media)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").font(.system(size: 14, weight: .bold))
                    Text("View Full Details").font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatCountdown(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Aired" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m \(secs)s" }
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }

    private func formatAirDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func loadMedia() async {
        do {
            let raw = try await AniListService.shared.detail(id: mediaId)
            await MainActor.run {
                media = AniListProvider.shared.mapMedia(raw)
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}
