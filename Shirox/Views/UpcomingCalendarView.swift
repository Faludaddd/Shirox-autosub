import Combine
import SwiftUI

/// One episode's scheduled broadcast, in the app's own media type so the row
/// can use the same artwork rules as everywhere else.
struct AiringEpisode: Identifiable {
    let media: Media
    /// Nil when the source gives a broadcast slot rather than a numbered episode.
    var episode: Int?
    let airingAt: Date
    /// The last of several episodes released together — a season dropped at once.
    var lastEpisode: Int? = nil
    /// A season number, when the source carries one.
    var season: Int? = nil
    /// What "My library" matches against: the media's own id.
    var libraryID: Int? = nil

    /// Unique per broadcast, not per show — a series can air twice in one week.
    var id: String {
        "\(media.uniqueId)-\(season ?? 0)-\(episode.map(String.init) ?? "")-\(airingAt.timeIntervalSince1970)"
    }

    /// Soonest first.
    static func soonestFirst(_ a: AiringEpisode, _ b: AiringEpisode) -> Bool {
        a.airingAt < b.airingAt
    }

    /// What's airing, under the title.
    var caption: String {
        guard let episode else { return "Next episode" }
        let episodes = lastEpisode.map { "Episodes \(episode)–\($0)" } ?? "Episode \(episode)"
        return season.map { "Season \($0) · \(episodes)" } ?? episodes
    }
}

@MainActor
final class UpcomingCalendarViewModel: ObservableObject {
    /// Which tracker's schedule page this is. Both legs read AniList's public airing
    /// schedule today (the official MAL schedule service hasn't been ported yet), so the
    /// calendar is identical regardless of primary — the case stays so theMAL leg can
    /// switch to MAL's own data when that service arrives.
    enum Source: Hashable {
        case anilist, mal
    }

    @Published private(set) var days: [(date: Date, episodes: [AiringEpisode])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Restrict to shows already in the user's library — the reason most people open a schedule.
    @Published var libraryOnly = false {
        didSet { rebuild() }
    }

    private var all: [AiringEpisode] = []
    private var libraryIDs: Set<Int> = []
    /// The source asked for last; a load for any other has been overtaken.
    private var wanted: Source?

    /// How far ahead to look. A week is what people plan around, and it keeps the request to a
    /// single page.
    private static let window = 7

    var source: Source {
        ProviderManager.shared.primary?.providerType == .mal ? .mal : .anilist
    }

    func load() async {
        let source = source
        if wanted != source {
            all = []
            libraryIDs = []
            rebuild()
        }
        wanted = source
        isLoading = true
        errorMessage = nil
        defer { if wanted == source { isLoading = false } }

        do {
            let schedule = try await fetchSchedule(source)
            // Best effort: the schedule is still useful signed out, the filter just isn't.
            let library = await fetchLibraryIDs(source)
            guard wanted == source else { return }
            all = schedule
            libraryIDs = library
            rebuild()
        } catch {
            guard wanted == source else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// AniList publishes an exact timestamp per episode — the week's page in one request.
    private func fetchSchedule(_ source: Source) async throws -> [AiringEpisode] {
        let start = Int(Date().timeIntervalSince1970)
        guard let endDate = Calendar.current.date(byAdding: .day, value: Self.window, to: Date()),
              let end = Int(exactly: endDate.timeIntervalSince1970.rounded(.up)) else { return [] }
        let items = try await AniListService.shared.airingSchedules(from: start, to: end)
        return items.map {
            AiringEpisode(
                media: AniListProvider.shared.mapMedia($0.media),
                episode: $0.episode,
                airingAt: Date(timeIntervalSince1970: TimeInterval($0.airingAt))
            )
        }
    }

    /// The ids "My library" matches: the tracker's media ids.
    private func fetchLibraryIDs(_ source: Source) async -> Set<Int> {
        Set((try? await ProviderManager.shared.primary?.fetchLibrary())?.map(\.media.id) ?? [])
    }

    var canFilterByLibrary: Bool { !libraryIDs.isEmpty }

    private func inLibrary(_ entry: AiringEpisode) -> Bool {
        libraryIDs.contains(entry.libraryID ?? entry.media.id)
    }

    private func rebuild() {
        let visible = libraryOnly ? all.filter(inLibrary) : all
        let grouped = Dictionary(grouping: visible) {
            Calendar.current.startOfDay(for: $0.airingAt)
        }
        days = grouped
            .map { day in
                (date: day.key, episodes: day.value.sorted(by: AiringEpisode.soonestFirst))
            }
            .sorted { $0.date < $1.date }
    }

    /// What's empty, by what the schedule lists.
    var emptyTitle: String {
        libraryOnly ? "Nothing from your library" : "Nothing scheduled"
    }

    var emptyDescription: String {
        if libraryOnly {
            return "No show you're following airs in the next week."
        }
        return "No episodes are scheduled in the next week."
    }
}

/// A week of upcoming episodes, grouped by day.
///
/// AniList carries an exact timestamp per episode. Opened from Home's floating calendar
/// button, or from the Schedule tab's toolbar.
struct UpcomingCalendarView: View {
    @StateObject private var vm = UpcomingCalendarViewModel()

    /// A page pushed onto Home's navigation, so the back button closes it.
    var body: some View {
        Group {
            if vm.isLoading && vm.days.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = vm.errorMessage, vm.days.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if vm.days.isEmpty {
                ContentUnavailableView(
                    LocalizedStringKey(vm.emptyTitle),
                    systemImage: "calendar",
                    description: Text(vm.emptyDescription)
                )
            } else {
                list
            }
        }
        .navigationTitle("Upcoming")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                // A Mac shows the navigation title already, at the toolbar's leading edge.
                #if !os(macOS)
                Text("Upcoming").font(.headline)
                #else
                EmptyView()
                #endif
            }
            ToolbarItem(placement: .primaryAction) {
                if vm.canFilterByLibrary {
                    Button {
                        vm.libraryOnly.toggle()
                    } label: {
                        Label("My library", systemImage: vm.libraryOnly ? "bookmark.fill" : "bookmark")
                    }
                }
            }
        }
        .task { await vm.load() }
    }

    private var list: some View {
        List {
            ForEach(vm.days, id: \.date) { day in
                Section {
                    ForEach(day.episodes) { entry in
                        NavigationLink {
                            MediaDestination(media: entry.media)
                        } label: {
                            row(entry)
                        }
                    }
                } header: {
                    Text(Self.dayLabel(for: day.date))
                }
            }
        }
        .softScrollEdges()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func row(_ entry: AiringEpisode) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                CardTitle(entry.media.title.displayTitle)
                    .font(.subheadline.weight(.medium))
                Text(entry.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(entry.airingAt, style: .time)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .fullTitleContextMenu(entry.media.title.displayTitle)
    }

    /// "Today" and "Tomorrow" read faster than a date when they apply; everything else gets its
    /// weekday, since a week never repeats one.
    static func dayLabel(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
