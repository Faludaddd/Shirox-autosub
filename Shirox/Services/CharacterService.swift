import Foundation

// MARK: - Character fallback chain (Batch 26)
//
// The Characters section's data pipeline. AniList's detail query is the
// ONLY source that used to feed it — and during the current AniList 403
// outage the section vanished from every anime page. The chain now walks
// the provider priority the app's architecture prescribes:
//
//   TVDB (cast records: character + actor + photo, already id-mapped)
//     → MAL / Jikan (characters + roles + voice actors with language)
//     → AniList (the classic edges)
//     → Kitsu (characters + roles + voice actors with locale)
//     → AniDB (requires a registered client — honest skip when absent)
//
// Cross-provider ids resolve through the canonical Media's own provider
// ids (discovery items carry them) and the id-mapping services — NEVER a
// title guess, so characters always belong to the SAME series. The rest
// of the page's metadata is untouched: whichever provider fills the
// character slot, the page keeps its TVDB-first metadata everywhere else.
//
// Failures are per-provider and honest: an empty chain produces the
// section's clean "unavailable" state, never a silent removal.

@MainActor
final class CharacterService {
    static let shared = CharacterService()

    private init() {}

    /// Where a character list came from (for honest source notices).
    enum CharacterSource: String {
        case tvdb, mal, anilist, kitsu, anidb

        var displayName: String {
            switch self {
            case .tvdb: return "TVDB"
            case .mal: return "MyAnimeList"
            case .anilist: return "AniList"
            case .kitsu: return "Kitsu"
            case .anidb: return "AniDB"
            }
        }
    }

    struct Result {
        let edges: [AniListCharacterEdge]
        let source: CharacterSource
    }

    /// In-memory cache per canonical title (keyed by uniqueId) — the
    /// detail page, the section's self-fetch and re-opens share one walk.
    private var cache: [String: Result] = [:]

    // MARK: - Chain entry point

    /// Loads characters for a canonical Media, walking the provider
    /// priority. `preferTVDBFirst` keeps the app's architecture (TVDB is
    /// the metadata primary): when TVDB HAS cast records they win, even
    /// if an AniList detail fetch also returned edges — the caller passes
    /// those as `anilistEdges` (already fetched as part of the detail
    /// query) so no redundant request is made.
    func characters(
        for media: Media,
        anilistEdges: [AniListCharacterEdge]?,
        tvdbFields: TVDBDetailFields?
    ) async -> Result? {
        let key = media.uniqueId
        if let cached = cache[key] { return cached }

        // 1. TVDB — cast records from the (already id-mapped) detail
        //    fields. The fetch happened as part of the page's TVDB-first
        //    enrichment; no extra request.
        if let tvdbFields,
           let edges = Self.mapTVDB(tvdbFields.characters),
           !edges.isEmpty {
            let result = Result(edges: edges, source: .tvdb)
            cache[key] = result
            return result
        }

        // 2. MAL / Jikan — characters with anime-specific artwork, roles
        //    and voice actors (with language).
        if let malId = media.idMal ?? (media.provider == .mal ? media.id : nil),
           let edges = try? await MALDiscoveryService.shared.characters(malId: malId),
           !edges.isEmpty {
            let mapped = Self.mapJikan(edges)
            if !mapped.isEmpty {
                let result = Result(edges: mapped, source: .mal)
                cache[key] = result
                return result
            }
        }

        // 3. AniList — the edges the detail query may already carry, or a
        //    fresh detail fetch (id-keyed, same series).
        if let anilistEdges, !anilistEdges.isEmpty {
            let result = Result(edges: anilistEdges, source: .anilist)
            cache[key] = result
            return result
        }
        if media.provider == .anilist,
           let raw = try? await AniListService.shared.detail(id: media.id),
           let edges = raw.characters?.edges, !edges.isEmpty {
            let result = Result(edges: edges, source: .anilist)
            cache[key] = result
            return result
        }

        // 4. Kitsu — full characters with roles + voice actors (locale
        //    labeled). Id resolution is provider-aware: the canonical
        //    Media's own kitsuId first (discovery items carry it), then
        //    anira/Kitsu mappings keyed by the id the Media actually
        //    uses — never a title guess, never a cross-provider id mix.
        var kitsuId: Int?
        if let direct = media.kitsuId {
            kitsuId = direct
        } else if media.provider == .anilist {
            kitsuId = await IDMappingService.shared.kitsuId(forAnilistId: media.id)
        } else if let malId = media.idMal ?? (media.provider == .mal ? media.id : nil) {
            kitsuId = await IDMappingService.shared.kitsuId(forMALId: malId)
        }
        if let kitsuId, kitsuId > 0,
           let edges = try? await KitsuProvider.shared.characters(kitsuId: kitsuId),
           !edges.isEmpty {
            let result = Result(edges: edges, source: .kitsu)
            cache[key] = result
            return result
        }

        // 5. AniDB — requires a registered client identity; skipped
        //    honestly by the chain when unconfigured.
        return nil
    }

    // MARK: - TVDB mapping

    /// TVDB cast records → display edges. TVDB's series `characters` are
    /// person-centric: character name, actor (personName), actor photo.
    /// The edge carries the actor as the voice actor with their photo.
    static func mapTVDB(_ records: [TVDBCharacterInfo]?) -> [AniListCharacterEdge]? {
        guard let records, !records.isEmpty else { return nil }
        var edges: [AniListCharacterEdge] = []
        for (index, record) in records.enumerated() {
            guard let name = record.name, !name.isEmpty else { continue }
            let photo = record.image
            var voiceActors: [AniListVoiceActor] = []
            if let person = record.person, !person.isEmpty {
                voiceActors.append(AniListVoiceActor(
                    id: index,
                    name: AniListCharacterName(full: person, native: nil, alternative: nil, alternativeSpoiler: nil),
                    language: nil,
                    image: AniListCharacterImage(large: photo, medium: photo)))
            }
            edges.append(AniListCharacterEdge(
                role: (record.role ?? "Cast").capitalized,
                node: AniListCharacter(
                    id: index,
                    name: AniListCharacterName(full: name, native: nil, alternative: nil, alternativeSpoiler: nil),
                    image: AniListCharacterImage(large: photo, medium: photo),
                    description: nil,
                    gender: nil,
                    dateOfBirth: nil,
                    age: nil,
                    bloodType: nil,
                    favourites: nil,
                    siteUrl: nil),
                voiceActors: voiceActors.isEmpty ? nil : voiceActors))
        }
        return edges.isEmpty ? nil : edges
    }

    // MARK: - Jikan mapping

    /// Jikan character edges → display edges (anime-specific artwork,
    /// roles, voice actors with language + person photos).
    static func mapJikan(_ edges: [MALDiscoveryService.JikanCharacterEdge]) -> [AniListCharacterEdge] {
        edges.compactMap { edge in
            guard let char = edge.character else { return nil }
            return AniListCharacterEdge(
                role: edge.role,
                node: AniListCharacter(
                    id: char.mal_id,
                    name: AniListCharacterName(
                        full: char.name,
                        native: char.name_kanji,
                        alternative: nil,
                        alternativeSpoiler: nil),
                    image: AniListCharacterImage(
                        large: char.images?.jpg?.image_url,
                        medium: char.images?.jpg?.image_url),
                    description: char.about,
                    gender: nil,
                    dateOfBirth: nil,
                    age: nil,
                    bloodType: nil,
                    favourites: nil,
                    siteUrl: nil),
                voiceActors: edge.voice_actors?.compactMap { va in
                    guard let person = va.person else { return nil }
                    return AniListVoiceActor(
                        id: person.mal_id,
                        name: AniListCharacterName(
                            full: person.name,
                            native: nil,
                            alternative: nil,
                            alternativeSpoiler: nil),
                        language: va.language,
                        image: AniListCharacterImage(
                            large: person.images?.jpg?.image_url,
                            medium: person.images?.jpg?.image_url))
                })
        }
    }

    // MARK: - Cache control

    func clearCache() {
        cache.removeAll()
    }
}
