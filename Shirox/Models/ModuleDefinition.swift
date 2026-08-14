import Foundation

struct ModuleDefinition: Codable, Identifiable, Equatable {
    var id: String { scriptUrl }
    let sourceName: String
    let iconUrl: String?
    let author: ModuleAuthor?
    let version: String
    let baseUrl: String?               // absent in Luna manga manifests
    let searchBaseUrl: String?
    let scriptUrl: String
    let type: String
    let asyncJS: Bool?
    let streamType: String?
    let quality: String?
    let language: String?
    let softsub: Bool?
    let supportsLocalPlayback: Bool?   // true only for the special local-files module
    let supportsJellyfin: Bool?        // true only for the special Jellyfin module
    var jsonUrl: String?     // stored client-side; not present in module JSON
    var scriptContent: String? // cached script content
    var iconData: String?      // cached icon data (Base64)

    var isLocalPlayback: Bool { supportsLocalPlayback == true }
    var isJellyfin: Bool { supportsJellyfin == true }

    /// True for any module that serves manga or novel content (not anime).
    ///
    /// **Why a contains-check, not an exact match:** module manifests use a
    /// mix of type strings across registries — cufiy.net uses `"mangas"` and
    /// `"novels"`, Luna-style manifests sometimes use `"manga"`, and some
    /// community modules use compound types like `"manga/novels"`. The
    /// previous exact-match (`type == "mangas" || type == "manga"`) missed
    /// `"novels"` entirely, so novel modules installed via the Manga Module
    /// Store were silently classified as anime modules — appearing under
    /// Anime Settings and never being picked up by the manga reading flow.
    ///
    /// We also explicitly exclude the known anime-ish types (`"anime"`,
    /// `"movies/shows"`, `"shows"`, `"live/tv"`, `"vod/livestream"`) so a
    /// compound type like `"anime/movies"` is never mis-classified as manga
    /// just because it might contain the substring "manga" via some future
    /// naming oddity.
    var isManga: Bool {
        let t = type.lowercased()
        // Short-circuit: exact anime types are never manga.
        let animeTypes: Set<String> = [
            "anime", "movies/shows", "shows", "live/tv", "vod/livestream",
            "movies/shows/anime", "anime/movies", "anime/movies/shows",
            "anime/shows/movies", "shows/movies", "shows/movies/anime",
            "movies", "tv", "live"
        ]
        if animeTypes.contains(t) { return false }
        // Positive match: anything containing "manga" or "novel".
        return t.contains("manga") || t.contains("novel")
    }

    /// True for novel-type modules specifically (a subset of `isManga`).
    /// Used to fine-tune UI labels ("Read" vs "Read Chapter") if needed.
    var isNovel: Bool {
        type.lowercased().contains("novel")
    }

    private enum CodingKeys: String, CodingKey {
        case sourceName, iconUrl, author, version, baseUrl, searchBaseUrl,
             scriptUrl, type, asyncJS, streamType, quality, language, softsub,
             supportsLocalPlayback, supportsJellyfin, jsonUrl, scriptContent, iconData
    }

    /// Luna-style manifests capitalize URL ("iconURL"/"scriptURL") and omit baseUrl.
    /// Decoding accepts both spellings; encoding stays canonical (CodingKeys above)
    /// so modules already persisted by ModuleManager keep round-tripping.
    private enum LunaKeys: String, CodingKey {
        case iconURL, scriptURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let luna = try decoder.container(keyedBy: LunaKeys.self)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl)
            ?? luna.decodeIfPresent(String.self, forKey: .iconURL)
        author = try c.decodeIfPresent(ModuleAuthor.self, forKey: .author)
        version = try c.decode(String.self, forKey: .version)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        searchBaseUrl = try c.decodeIfPresent(String.self, forKey: .searchBaseUrl)
        if let s = try c.decodeIfPresent(String.self, forKey: .scriptUrl) {
            scriptUrl = s
        } else {
            scriptUrl = try luna.decode(String.self, forKey: .scriptURL)
        }
        type = try c.decode(String.self, forKey: .type)
        asyncJS = try c.decodeIfPresent(Bool.self, forKey: .asyncJS)
        streamType = try c.decodeIfPresent(String.self, forKey: .streamType)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        softsub = try c.decodeIfPresent(Bool.self, forKey: .softsub)
        supportsLocalPlayback = try c.decodeIfPresent(Bool.self, forKey: .supportsLocalPlayback)
        supportsJellyfin = try c.decodeIfPresent(Bool.self, forKey: .supportsJellyfin)
        jsonUrl = try c.decodeIfPresent(String.self, forKey: .jsonUrl)
        scriptContent = try c.decodeIfPresent(String.self, forKey: .scriptContent)
        iconData = try c.decodeIfPresent(String.self, forKey: .iconData)
    }
}

struct ModuleAuthor: Codable, Equatable {
    let name: String
    let icon: String?

    private enum CodingKeys: String, CodingKey { case name, icon }
    private enum LunaKeys: String, CodingKey { case iconURL }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let luna = try decoder.container(keyedBy: LunaKeys.self)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
            ?? luna.decodeIfPresent(String.self, forKey: .iconURL)
    }
}
