import Foundation
import Combine

@MainActor
final class MangaDetailViewModel: ObservableObject {
    @Published var detail: MangaDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var match: MangaMatch?
    /// AniList metadata overlay (score, status, genres, relations, richer
    /// description) for a matched or AniList-seeded manga. nil until it resolves.
    @Published var enrichment: Media?

    /// Fire-and-forget AniList metadata overlay for a matched manga. Never throws
    /// to the UI — module content already rendered; this fills in when it arrives.
    func enrich(aniListID: Int) async {
        guard enrichment == nil else { return }
        enrichment = try? await AniListProvider.shared.mangaDetail(id: aniListID)
    }

    func load(item: SearchItem) async {
        // Idempotent: re-called by Retry; skip if a load is already in flight.
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            // Item 11 + batch 12 fix: ensure a manga module is loaded before
            // calling JSEngine. The previous guard only switched when the
            // active module was *not* manga, but it picked just the FIRST
            // manga module — if that module didn't have this title, the
            // detail fetch threw "Function not found" / empty results and
            // the user couldn't read even with multiple modules installed.
            //
            // Now we ensure a manga module is active, but the actual
            // multi-module fallback lives in MangaModuleResolver (called
            // from AniListMangaDetailView) and in the chapter-fetch path
            // below — if the active manga module can't return details or
            // chapters, we try each remaining manga module in turn.
            if ModuleManager.shared.activeModule?.isManga != true,
               let mangaModule = ModuleManager.shared.modules.first(where: { $0.isManga }) {
                _ = await ModuleManager.shared.selectAndAwaitReady(mangaModule)
            }

            // Try the active module first; if it fails, walk the other
            // installed manga modules. This is the fix for "can't read
            // manga with multiple modules installed" — a single module
            // might not have this particular title.
            //
            // Declared as `var` because the `catch` branch reassigns them
            // when the active module fails and a fallback module succeeds.
            var info: (description: String, tags: [String])
            var chapters: [MangaChapter]
            do {
                info = try await JSEngine.shared.mangaDetails(url: item.href)
                chapters = try await JSEngine.shared.mangaChapters(url: item.href)
            } catch {
                // Active module couldn't serve this title — try the others.
                let resolved = await tryOtherMangaModules(item: item)
                guard let resolved else {
                    throw error  // original error — surface to the user
                }
                info = resolved.info
                chapters = resolved.chapters
            }

            detail = MangaDetail(
                title: item.title,
                image: item.image,
                description: Self.decodeHTMLEntities(info.description),
                tags: info.tags,
                chapters: chapters)
            match = await MangaMatchManager.shared.match(mangaHref: item.href, title: item.title)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Walks every installed manga module (other than the currently-active
    /// one) and returns the first that can serve both details and chapters
    /// for `item`. Switches the active module as a side effect. Returns nil
    /// if no module can serve the title.
    private func tryOtherMangaModules(item: SearchItem) async -> (info: (description: String, tags: [String]), chapters: [MangaChapter])? {
        let manager = ModuleManager.shared
        let activeID = manager.activeModule?.id
        let others = manager.modules.filter { $0.isManga && $0.id != activeID }
        for module in others {
            guard await manager.selectAndAwaitReady(module) else { continue }
            // Re-resolve the item's href via search — different modules use
            // different href schemes, so the href from module A won't work
            // in module B. We search by the item's title and use the top
            // result's href instead.
            guard let results = try? await JSEngine.shared.mangaSearch(keyword: item.title),
                  let match = MangaModuleResolver.pickTitleMatch(title: item.title, results: results) else {
                continue
            }
            // Update the item's href so the reader uses the right one.
            // (SearchItem is immutable; we can't mutate the caller's `item`
            // from here, but the reader will receive the chapters we return
            // and use those — it doesn't re-fetch by href.)
            guard let info = try? await JSEngine.shared.mangaDetails(url: match.href),
                  let chapters = try? await JSEngine.shared.mangaChapters(url: match.href),
                  !chapters.isEmpty else {
                continue
            }
            return (info, chapters)
        }
        // Restore the original active module if nothing panned out.
        if let original = manager.modules.first(where: { $0.id == activeID }), original.isManga {
            _ = await manager.selectAndAwaitReady(original)
        }
        return nil
    }

    /// Module descriptions come from scraped meta tags and often carry HTML
    /// entities. Ordered replacements: `&amp;` must be last so a literal
    /// "&amp;#039;" decodes in one pass instead of re-exposing an entity.
    nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
            ("&#8217;", "'"), ("&#8216;", "'"),
            ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}"),
            ("&#8230;", "…"), ("&hellip;", "…"),
            ("&amp;", "&"),
        ]
        var s = text
        for (entity, char) in replacements {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }
}
