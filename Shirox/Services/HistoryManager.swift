import Foundation
import Combine

/// Unified history tracking for anime watched + manga read. Each entry stores
/// the title, type, last-watched-episode / last-read-chapter, and timestamp.
/// Entries are deduplicated by media identity — a new activity on the same
/// title updates the existing entry's progress and timestamp instead of
/// creating a duplicate.
///
/// The manager is the single source of truth for the Library tab's History
/// section. It's fed by `ContinueWatchingManager` (anime) and
/// `MangaProgressManager` (manga) via `recordAnimeActivity` /
/// `recordMangaActivity`, so any progress update from either system
/// automatically reflects in History in real time.
@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published private(set) var entries: [HistoryEntry] = []

    private let key = "unifiedHistoryEntries"
    private let maxEntries = 200

    private init() { load() }

    // MARK: - Recording

    /// Records an anime watch activity. If an entry already exists for this
    /// media (matched by aniListID or mediaTitle), its episode number and
    /// timestamp are updated in place — no duplicate is created.
    func recordAnimeActivity(
        aniListID: Int?,
        mediaTitle: String,
        episodeNumber: Int,
        coverImageURL: String?
    ) {
        let identity = HistoryIdentity(aniListID: aniListID, mediaTitle: mediaTitle, kind: .anime)
        upsert(identity: identity, progress: episodeNumber, coverImageURL: coverImageURL)
    }

    /// Records a manga read activity. If an entry already exists for this
    /// manga (matched by mangaHref or mediaTitle), its chapter number and
    /// timestamp are updated in place — no duplicate is created.
    func recordMangaActivity(
        mangaHref: String,
        mediaTitle: String,
        chapterNumber: Double,
        coverImageURL: String?
    ) {
        let identity = HistoryIdentity(aniListID: nil, mediaTitle: mediaTitle, kind: .manga, mangaHref: mangaHref)
        upsert(identity: identity, progress: chapterNumber, coverImageURL: coverImageURL)
    }

    /// Removes a single history entry.
    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Clears all history.
    func clearAll() {
        entries.removeAll()
        persist()
    }

    /// Clears history of a specific kind (anime or manga).
    func clearKind(_ kind: HistoryEntry.Kind) {
        entries.removeAll { $0.kind == kind }
        persist()
    }

    // MARK: - Queries

    var animeEntries: [HistoryEntry] {
        entries.filter { $0.kind == .anime }
    }

    var mangaEntries: [HistoryEntry] {
        entries.filter { $0.kind == .manga }
    }

    // MARK: - Upsert

    private func upsert(identity: HistoryIdentity, progress: Double, coverImageURL: String?) {
        // Find an existing entry matching the identity. Anime entries match
        // on aniListID (preferred) or mediaTitle. Manga entries match on
        // mangaHref (preferred) or mediaTitle.
        if let index = entries.firstIndex(where: { entry in
            entry.matches(identity: identity)
        }) {
            // Update existing — refresh progress, timestamp, and cover.
            entries[index].progress = progress
            entries[index].timestamp = Date()
            if let coverImageURL, !coverImageURL.isEmpty {
                entries[index].coverImageURL = coverImageURL
            }
            // Move to top (most recent).
            let updated = entries.remove(at: index)
            entries.insert(updated, at: 0)
        } else {
            // Insert new at top.
            let entry = HistoryEntry(
                id: UUID(),
                aniListID: identity.aniListID,
                mangaHref: identity.mangaHref,
                mediaTitle: identity.mediaTitle,
                kind: identity.kind,
                progress: progress,
                timestamp: Date(),
                coverImageURL: coverImageURL
            )
            entries.insert(entry, at: 0)
        }
        // Cap the list size.
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}

// MARK: - HistoryEntry

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let aniListID: Int?       // nil for manga
    let mangaHref: String?    // nil for anime
    let mediaTitle: String
    let kind: Kind
    var progress: Double      // episode number (anime) or chapter number (manga)
    var timestamp: Date
    var coverImageURL: String?

    enum Kind: String, Codable {
        case anime
        case manga
    }

    /// True if this entry matches the given identity (same media, same kind).
    func matches(identity: HistoryIdentity) -> Bool {
        guard kind == identity.kind else { return false }
        // Anime: prefer aniListID match; fall back to title.
        if kind == .anime {
            if let myID = aniListID, let theirID = identity.aniListID {
                return myID == theirID
            }
            return mediaTitle == identity.mediaTitle
        }
        // Manga: prefer mangaHref match; fall back to title.
        if kind == .manga {
            if let myHref = mangaHref, let theirHref = identity.mangaHref,
               !myHref.isEmpty, !theirHref.isEmpty {
                return myHref == theirHref
            }
            return mediaTitle == identity.mediaTitle
        }
        return false
    }

    /// Human-readable progress text.
    var progressText: String {
        switch kind {
        case .anime:
            let ep = Int(progress)
            return "Episode \(ep) watched"
        case .manga:
            let ch = progress.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(progress))
                : String(progress)
            return "Chapter \(ch) read"
        }
    }

    /// Relative date label ("Today", "Yesterday", or full date).
    var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(timestamp) { return "Today" }
        if cal.isDateInYesterday(timestamp) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: timestamp)
    }
}

// MARK: - HistoryIdentity

private struct HistoryIdentity {
    let aniListID: Int?
    let mediaTitle: String
    let kind: HistoryEntry.Kind
    let mangaHref: String?

    init(aniListID: Int?, mediaTitle: String, kind: HistoryEntry.Kind, mangaHref: String? = nil) {
        self.aniListID = aniListID
        self.mediaTitle = mediaTitle
        self.kind = kind
        self.mangaHref = mangaHref
    }
}
