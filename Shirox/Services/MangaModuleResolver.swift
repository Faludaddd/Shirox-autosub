import Foundation

/// Resolves a provider-synced manga (title only, no module href) to a module
/// `SearchItem` so it can open in the reader. Mirrors the Continue Reading reopen
/// pattern: switch to a manga module, search it by title, pick the best hit.
///
/// **Multi-module support:** if the user has more than one manga module
/// installed, the resolver tries each in order until one returns search
/// results. The previous implementation only ever tried the first manga
/// module, so if that module didn't have the title (e.g. a French-only
/// module when the user searched for an English title), reading silently
/// failed — even when a second installed module could have served it.
@MainActor final class MangaModuleResolver {
    static let shared = MangaModuleResolver()
    private init() {}

    /// Pure: exact case-insensitive title hit, else the top result, else nil.
    nonisolated static func pickTitleMatch(title: String, results: [SearchItem]) -> SearchItem? {
        guard !results.isEmpty else { return nil }
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return results.first { $0.title.lowercased() == needle } ?? results[0]
    }

    /// Returns a module `SearchItem` for `title`, or nil when no manga module
    /// is installed or no installed module returns results for the title.
    ///
    /// **Resolution order:**
    ///   1. If the currently-active module is a manga module, try it first
    ///      (avoids a needless context switch when the user is already in
    ///      reading mode).
    ///   2. Otherwise (and as a fallback), iterate over every installed manga
    ///      module and try each until one returns search results. This is
    ///      what fixes the "multiple manga modules installed but can't read"
    ///      bug — previously only the first manga module was ever tried.
    ///
    /// Side effect: switches the active module to whichever one ultimately
    /// resolves (same as Continue Reading).
    func resolve(title: String) async -> SearchItem? {
        let manager = ModuleManager.shared

        // Build the candidate list, active-manga-module first.
        var candidates: [ModuleDefinition] = []
        if let active = manager.activeModule, active.isManga {
            candidates.append(active)
        }
        for m in manager.modules where m.isManga && !candidates.contains(where: { $0.id == m.id }) {
            candidates.append(m)
        }
        guard !candidates.isEmpty else { return nil }

        // Try each candidate until one returns results.
        for module in candidates {
            if manager.activeModule?.id != module.id {
                guard await manager.selectAndAwaitReady(module) else { continue }
            }
            let results = (try? await JSEngine.shared.mangaSearch(keyword: title)) ?? []
            if let match = Self.pickTitleMatch(title: title, results: results) {
                return match
            }
            // No results (or no title match) — try the next manga module.
        }
        return nil
    }
}
