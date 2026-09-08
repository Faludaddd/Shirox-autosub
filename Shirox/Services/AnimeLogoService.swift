import Foundation
import SwiftUI

// MARK: - AnimeLogoService (Batch 27)
//
// The app-wide resolver for a title's official LOGO artwork — the
// transparent PNG a streaming hero shows instead of plain text.
//
// Resolution chain (each step is a real provider source; a step that
// yields nothing falls through — never a broken image box):
//
//   1. TheTVDB clear logo (artwork type 23) — the canonical source.
//   2. TheTVDB clear art  (artwork type 22) — the wide variant.
//   3. In-memory / mapping-cache hit from a previous resolve.
//   4. FALL BACK TO TITLE TEXT (handled by the caller — the service
//      returns nil and the hero renders `fallbackTitle`).
//
// Manga: TheTVDB has no manga records, so manga titles resolve to nil
// instantly (the caller always renders the title text for manga — the
// design never shows a broken logo slot there).
//
// The resolved URL is cached in memory per unique title (one resolve per
// series per session, shared by the hero, the detail header and the
// character-appearance rows) and re-uses TVDBMappingService's own disk
// cache for the candidate walk. `Media.animeLogo` mirrors the result so
// the value survives view identity changes.

@MainActor
final class AnimeLogoService {
    static let shared = AnimeLogoService()

    private init() {}

    /// In-memory resolution cache: uniqueId → resolved URL (nil value
    /// means "definitely no logo anywhere" — negative results are cached
    /// too so a logo-less title never re-walks the chain).
    private var resolved: [String: String?] = [:]
    /// In-flight dedup: one resolve per title at a time.
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// Resolves the best logo URL for a title, or nil when no provider
    /// has logo artwork for it (the caller shows the fallback title text).
    /// Ids already present on the canonical Media object (tvdbId /
    /// idMal / kitsuId) feed the mapping so resolution is id-keyed, never
    /// title-guessed.
    func logoURL(for media: Media) async -> String? {
        // Manga can never have TVDB artwork — answer instantly.
        if media.isManga { return nil }

        let key = media.uniqueId
        if let cached = resolved[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<String?, Never> { [weak self] in
            // TheTVDB's candidate walk (clear logo → clear art, English
            // first, ranked by score/resolution — the mapping service's
            // own ordering). TVDB id on the model wins when present.
            let candidates = await TVDBMappingService.shared.getLogoCandidates(
                for: media.id, provider: media.provider, malId: media.idMal)
            for url in candidates {
                if Task.isCancelled { return nil }
                // Only show a candidate that actually decodes — this is
                // what guarantees "never a broken image box".
                if await CachedAsyncImage.preload(urlString: url) {
                    return url
                }
            }
            return nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        resolved[key] = result
        return result
    }

    /// Warms the cache for a list of titles (used by the carousel's
    /// offscreen prefetcher and app launch) — 1x1, opacity-0 equivalents
    /// in the view layer call this so the visible hero paints instantly.
    func prefetch(for media: Media) async {
        _ = await logoURL(for: media)
    }

    func clearCache() {
        resolved.removeAll()
    }
}
