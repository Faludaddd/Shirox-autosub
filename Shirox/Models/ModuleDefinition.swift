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

    /// True for modules that serve manga content (not anime, not novels).
    ///
    /// Novel modules (type "novels") are excluded because they lack the
    /// `extractImages` function required for manga page reading — they can
    /// search and list chapters but return text, not image URLs. Including
    /// them in the manga store caused user confusion ("modules don't work")
    /// because they'd install a novel module, try to read manga, and get
    /// errors when `extractImages` was called.
    ///
    /// Only true manga modules (type "mangas" or "manga") are classified
    /// as manga. These have all four required functions: searchResults,
    /// extractDetails, extractChapters, extractImages.
    var isManga: Bool {
        let t = type.lowercased()
        return t == "mangas" || t == "manga"
    }

    /// True for novel-type modules specifically. These can search and list
    /// chapters but lack `extractImages` — they're text readers, not manga
    /// readers. Kept for potential future novel-reading support.
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
