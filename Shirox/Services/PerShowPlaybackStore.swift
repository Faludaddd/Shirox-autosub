import Foundation

/// Stores per-show playback preferences so the player remembers your
/// speed, subtitle, and audio preferences for each anime individually.
/// Keyed by the anime's AniList ID (or MAL ID as fallback).
///
/// Example: If you watch Anime A at 1.5× speed and Anime B at 1.0×,
/// the app remembers your choice for each show separately — you don't
/// have to re-set the speed every time you switch between them.
@MainActor
final class PerShowPlaybackStore: ObservableObject {
    static let shared = PerShowPlaybackStore()

    private let storageKey = "perShowPlaybackSettings"

    struct Settings: Codable {
        var playbackSpeed: Double?
        var preferredAudioLanguage: String?
        var preferredSubtitleLanguage: String?

        var isEmpty: Bool {
            playbackSpeed == nil && preferredAudioLanguage == nil && preferredSubtitleLanguage == nil
        }
    }

    private var cache: [String: Settings] = [:]

    private init() {
        loadFromStorage()
    }

    /// Builds a stable key for a show from its identifiers.
    private func key(for aniListID: Int?, malID: Int?) -> String? {
        if let aid = aniListID, aid > 0 { return "al-\(aid)" }
        if let mid = malID, mid > 0 { return "mal-\(mid)" }
        return nil
    }

    /// Gets the saved settings for a show. Returns an empty Settings if
    /// nothing is saved yet.
    func settings(for aniListID: Int?, malID: Int?) -> Settings {
        guard let key = key(for: aniListID, malID: malID) else { return Settings() }
        return cache[key] ?? Settings()
    }

    /// Saves the playback speed for a show.
    func saveSpeed(_ speed: Double, for aniListID: Int?, malID: Int?) {
        guard let key = key(for: aniListID, malID: malID) else { return }
        var s = cache[key] ?? Settings()
        s.playbackSpeed = speed
        cache[key] = s
        saveToStorage()
    }

    /// Clears the saved settings for a show.
    func clear(for aniListID: Int?, malID: Int?) {
        guard let key = key(for: aniListID, malID: malID) else { return }
        cache.removeValue(forKey: key)
        saveToStorage()
    }

    /// Clears all per-show settings.
    func clearAll() {
        cache.removeAll()
        saveToStorage()
    }

    /// Returns the number of shows with saved settings.
    var savedCount: Int { cache.count }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: Settings].self, from: data) else { return }
        cache = saved
    }
}
