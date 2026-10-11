import Foundation

struct StoredStream: Codable, Hashable {
    let title: String
    let url: String
    let headers: [String: String]
    let subtitle: String?
    var subtitleHeaders: [String: String]?
    var playlistKey: String? = nil

    var asStreamResult: StreamResult? {
        guard let url = URL(string: url) else { return nil }
        return StreamResult(title: title, url: url, headers: headers,
                            subtitle: subtitle, subtitleHeaders: subtitleHeaders ?? [:],
                            playlistKey: playlistKey)
    }
}

struct ContinueWatchingItem: Identifiable, Codable, Hashable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    var subtitleHeaders: [String: String]?
    var allSubtitles: [SubtitleTrack]?
    let streamTitle: String?  // the selected stream's title (e.g., "SUB", "DUB", "pahe")
    var allStreams: [StoredStream]?
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let detailHref: String?
    /// The playing episode's own unique href (not the show/detail href). Anchors next-episode
    /// resolution on resume so multi-season flat lists (numbers repeat) advance to the right
    /// season. Optional + decoded if-present, so items saved before this field stay valid.
    var episodeHref: String?
    var watchedSeconds: Double
    var totalSeconds: Double
    var totalEpisodes: Int?
    /// Number of episodes currently aired/available (may be less than totalEpisodes for ongoing shows).
    var availableEpisodes: Int?
    var isAiring: Bool?
    var lastWatchedAt: Date
    var thumbnailUrl: String?
    var aniListUpdatedAt: Int?
    var bookmarkData: Data?   // legacy: security-scoped bookmark for local-file resume; superseded by localImportName
    /// Filename of the picked video copied into the app's persistent imports directory.
    /// Resume reconstructs the file from the current container, so it survives the
    /// transient/sandboxed picker URLs that broke bookmark-based resume. Nil for normal streams.
    var localImportName: String?
    /// Filename of an up-front subtitle copied alongside the video, so resume reloads it.
    var localSubtitleImportName: String?
    /// The key the stream's playlists are scrambled with (see ``HLSPlaylistCipher``). Not kept
    /// before, so resuming a scrambled stream (Re:ANIME) handed the player a playlist it couldn't
    /// read and the episode never loaded. Optional, so saved items still decode.
    var playlistKey: String? = nil
}

extension ContinueWatchingItem {
    /// True when this item refers to the episode identified by `number`/`href`.
    ///
    /// On a flat multi-season list episode *numbers* repeat (S1 1…12, S2 1…12), so matching an
    /// item to a row by number alone lets S1 E5's progress bleed onto S2 E5. The saved
    /// `episodeHref` is unique per episode, so when both sides carry one it is authoritative.
    /// Falls back to the number only when either side lacks an href (legacy items, or a row
    /// without one) — there we can't disambiguate and best-effort number matching is unchanged.
    func matchesEpisode(number: Int, href: String?) -> Bool {
        if let itemHref = episodeHref, !itemHref.isEmpty,
           let href, !href.isEmpty {
            return itemHref == href
        }
        return episodeNumber == number
    }

    /// True when this item is the downloaded episode `number`/`href`: the href *and* the number.
    ///
    /// Some sources give every episode of a show the same href and tell them apart some other
    /// way, so a download's href alone matched every downloaded episode. Watching episode 19 put
    /// its progress on all of them, and each one then resumed a third of the way in. Both sides
    /// here come from the same download, so its number is in the same units and can be required.
    func matchesDownloadedEpisode(number: Int, href: String?) -> Bool {
        episodeNumber == number && matchesEpisode(number: number, href: href)
    }
}
