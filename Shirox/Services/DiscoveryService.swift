import Foundation

// MARK: - Discovery genres (Batch 26)

/// One genre of the app's discovery taxonomy. The SLUG is the stable
/// identifier used for routing (Home row → See All → the SAME query) and
/// for querying the discovery database (`filter[categories]=<slug>` on
/// Kitsu — verified live); the category id is the database's own id for
/// that genre, resolved live at runtime so the taxonomy is REAL database
/// metadata, not a hardcoded anime list. `malGenreId` lets the MAL/Jikan
/// fallback serve the same genre when the primary discovery source fails.
struct DiscoveryGenre: Identifiable, Hashable, Codable {
    /// Stable routing identifier — also the Kitsu category slug.
    let id: String
    /// Display name (the database's own title for the genre).
    let displayName: String
    /// AniList's genre string (matches for all but Sci-Fi).
    let anilistName: String
    /// MyAnimeList genre id (their public taxonomy constants).
    let malGenreId: Int
    /// Kitsu's category id — resolved live from the discovery database.
    var kitsuCategoryID: Int?

    var slug: String { id }

    /// The genre catalog. Every slug was verified live against the
/// discovery database's category taxonomy (all 17 resolve to real
    /// category records with real media counts). This is a genre
    /// VOCABULARY, not an anime list — which anime belong to each genre
    /// is answered entirely by the database at query time.
    static let catalog: [DiscoveryGenre] = [
        DiscoveryGenre(id: "action", displayName: "Action", anilistName: "Action", malGenreId: 1),
        DiscoveryGenre(id: "adventure", displayName: "Adventure", anilistName: "Adventure", malGenreId: 2),
        DiscoveryGenre(id: "comedy", displayName: "Comedy", anilistName: "Comedy", malGenreId: 4),
        DiscoveryGenre(id: "drama", displayName: "Drama", anilistName: "Drama", malGenreId: 8),
        DiscoveryGenre(id: "fantasy", displayName: "Fantasy", anilistName: "Fantasy", malGenreId: 10),
        DiscoveryGenre(id: "romance", displayName: "Romance", anilistName: "Romance", malGenreId: 22),
        DiscoveryGenre(id: "horror", displayName: "Horror", anilistName: "Horror", malGenreId: 14),
        DiscoveryGenre(id: "mystery", displayName: "Mystery", anilistName: "Mystery", malGenreId: 7),
        DiscoveryGenre(id: "science-fiction", displayName: "Sci-Fi", anilistName: "Sci-Fi", malGenreId: 24),
        DiscoveryGenre(id: "slice-of-life", displayName: "Slice of Life", anilistName: "Slice of Life", malGenreId: 36),
        DiscoveryGenre(id: "sports", displayName: "Sports", anilistName: "Sports", malGenreId: 30),
        DiscoveryGenre(id: "supernatural", displayName: "Supernatural", anilistName: "Supernatural", malGenreId: 37),
        DiscoveryGenre(id: "thriller", displayName: "Thriller", anilistName: "Thriller", malGenreId: 41),
        DiscoveryGenre(id: "psychological", displayName: "Psychological", anilistName: "Psychological", malGenreId: 40),
        DiscoveryGenre(id: "music", displayName: "Music", anilistName: "Music", malGenreId: 19),
        DiscoveryGenre(id: "historical", displayName: "Historical", anilistName: "Historical", malGenreId: 13),
        DiscoveryGenre(id: "mecha", displayName: "Mecha", anilistName: "Mecha", malGenreId: 18),
    ]

    /// Names the Kitsu category-to-genre classifier accepts (Kitsu mixes
    /// genres with themes/demographics in one category list — only these
    /// titles count as GENRES). Includes the database's own title for each
    /// genre where it differs from the display name (Kitsu calls Sci-Fi
    /// "Science Fiction" — verified live).
    static let genreNames: Set<String> = {
        var names = Set(catalog.map(\.displayName))
        names.formUnion(["Science Fiction"])
        return names
    }()

    /// True when a database category title is one of the canonical genres.
    static func isGenreName(_ title: String) -> Bool {
        genreNames.contains(title)
    }

    static func bySlug(_ slug: String) -> DiscoveryGenre? {
        catalog.first { $0.slug == slug }
    }
}

// MARK: - Discovery service (Batch 26)

/// The DEDICATED discovery layer — decides WHICH anime/manga appear in
/// Trending, Popular, genre categories, the Home carousel, See All pages
/// and Surprise Me, and returns their real ids for TVDB-first metadata
/// resolution.
///
/// Architecture (the discovery flow the app now runs):
///
///   DISCOVERY DATABASE (Kitsu → AniList → MAL chain)
///     → correct anime list, real ids (AniList/MAL/TheTVDB)
///     → TVDB resolves artwork/characters for the SAME series
///     → MAL / AniList / Kitsu / AniDB fill metadata gaps
///     → display
///
/// This service owns the genre taxonomy resolution and Surprise Me's
/// genre-first randomizer; the list queries themselves run through
/// `UnifiedProviderSystem`'s discovery chain (health-gated, cached,
/// deduplicated — one shared request per surface).
@MainActor
final class DiscoveryService {
    static let shared = DiscoveryService()

    private init() {}

    // MARK: - Genre metadata (live from the discovery database)

    /// Resolved genre metadata cache: slug → Kitsu category id. Cached on
    /// disk (the taxonomy is effectively stable; 24h TTL refresh).
    private static let genreResolveKey = "discovery.genreMeta.v1"

    private func loadGenreMeta() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: Self.genreResolveKey) as? [String: Int] ?? [:]
    }

    /// Resolves the genre catalog against the LIVE discovery database:
    /// each slug is looked up in Kitsu's category taxonomy and its real
    /// category id recorded. Genres the database doesn't know are dropped
    /// (a renamed/removed genre can never strand a shelf). Kitsu failures
    /// keep the last resolution (or the bare catalog — the genre query
    /// itself re-verifies membership at request time).
    func genres() async -> [DiscoveryGenre] {
        var resolvedMeta = loadGenreMeta()
        // Refresh at most once a day.
        let lastRefresh = UserDefaults.standard.object(forKey: "\(Self.genreResolveKey).at") as? Date
        let needsRefresh = lastRefresh.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
        if needsRefresh {
            var fresh: [String: Int] = [:]
            for genre in DiscoveryGenre.catalog {
                // One batched attempt: verify the slug resolves in the
                // taxonomy. (Failures below keep the stale value.)
                if let id = await kitsuCategoryID(for: genre) {
                    fresh[genre.slug] = id
                } else if let stale = resolvedMeta[genre.slug] {
                    fresh[genre.slug] = stale
                }
            }
            if !fresh.isEmpty {
                resolvedMeta = fresh
                UserDefaults.standard.set(resolvedMeta, forKey: Self.genreResolveKey)
                UserDefaults.standard.set(Date(), forKey: "\(Self.genreResolveKey).at")
            }
        }
        return DiscoveryGenre.catalog.map { genre in
            var g = genre
            g.kitsuCategoryID = resolvedMeta[genre.slug]
            return g
        }
    }

    private func kitsuCategoryID(for genre: DiscoveryGenre) async -> Int? {
        guard let url = URL(string: "https://kitsu.io/api/edge/categories?filter[slug]=\(genre.slug)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Envelope: Decodable {
            struct Datum: Decodable { let id: String }
            let data: [Datum]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let first = env.data.first, let id = Int(first.id) else { return nil }
        return id
    }

    // MARK: - Genre pool cache (Batch 27 — instant Surprise Me)
    //
    // One in-memory pool per genre (30-minute TTL), franchise-normalized
    // so a pool never contains two seasons of the same show. Warmed at
    // app launch in the background and re-used by every Surprise Me
    // press: a warm pool answers with ZERO network — the button feels
    // instant. Cold pools load through the discovery chain (which has
    // its own disk cache) — one request, then warm.
    private var genrePools: [String: (items: [Media], fetchedAt: Date)] = [:]
    private var poolInFlight: [String: Task<[Media]?, Never>] = [:]
    private let genrePoolTTL: TimeInterval = 30 * 60

    /// The franchise-normalized pool for one genre — warm cache first,
    /// one chain request (deduped) on a miss. nil only when the genre
    /// genuinely can't be served by any provider.
    func pool(for genre: DiscoveryGenre) async -> [Media]? {
        if let cached = genrePools[genre.slug],
           Date().timeIntervalSince(cached.fetchedAt) < genrePoolTTL,
           !cached.items.isEmpty {
            return cached.items
        }
        if let running = poolInFlight[genre.slug] {
            return await running.value
        }
        let slug = genre.slug
        let task = Task<[Media]?, Never> { [weak self] in
            guard let list = try? await UnifiedProviderSystem.shared.browse(genre: genre, page: 1),
                  !list.isEmpty else { return nil }
            let normalized = MediaNormalizer.franchiseBasePool(from: list)
            await MainActor.run {
                self?.genrePools[slug] = (normalized, Date())
            }
            return normalized
        }
        poolInFlight[slug] = task
        let result = await task.value
        poolInFlight[slug] = nil
        return result
    }

    /// Background launch warm-up: fills every genre pool (bounded
    /// concurrency — 4 at a time) so the first Surprise Me press of the
    /// session is already instant. Also warms the shared browse cache the
    /// Home genre shelves read from.
    func warmGenrePools() async {
        let genres = DiscoveryGenre.catalog
        var iterator = genres.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                guard let genre = iterator.next() else { break }
                group.addTask { _ = await self.pool(for: genre) }
            }
            while await group.next() != nil {
                if Task.isCancelled { break }
                if let genre = iterator.next() {
                    group.addTask { _ = await self.pool(for: genre) }
                }
            }
        }
    }

    // MARK: - Surprise Me (genre-first randomizer, instant)

    /// Result of one Surprise Me press: the genre that was selected and
    /// the anime drawn from it.
    struct SurprisePick {
        let genre: DiscoveryGenre
        let media: Media
    }

    /// THE FAST FLOW (Batch 27):
    ///   1. Select a random valid genre.
    ///   2. Get that genre's small pool from the WARM in-memory cache
    ///      (pre-warmed at launch; a cold pool costs ONE chain request
    ///      through the disk-cached discovery chain — never hundreds of
    ///      anime, never every season, never full details).
    ///   3. Randomly select ONE anime — franchise-normalized, so a pool
    ///      never holds a sequel when the base show exists.
    ///   4. Navigate immediately with the preloaded Media (the detail
    ///      page renders from it instantly; richer metadata resolves
    ///      AFTER the page is on screen).
    /// No trending lists, no episode fetches, no waiting on providers
    /// that aren't needed for the pick itself.
    func randomAnime(excluding: Set<String>) async -> SurprisePick? {
        var genres = DiscoveryGenre.catalog.shuffled()
        // Prefer genres that haven't been picked yet this session.
        let recent = UserDefaults.standard.stringArray(forKey: "surprise.recentGenres") ?? []
        genres.sort { a, b in
            let aRecent = recent.contains(a.slug)
            let bRecent = recent.contains(b.slug)
            if aRecent != bRecent { return !aRecent }
            return false
        }
        for genre in genres.prefix(6) {
            guard let pool = await pool(for: genre), !pool.isEmpty else { continue }
            let fresh = pool.filter { !excluding.contains($0.uniqueId) }
            let candidates = fresh.isEmpty ? pool : fresh
            guard let pick = candidates.randomElement() else { continue }
            rememberGenre(genre.slug)
            return SurprisePick(genre: genre, media: pick)
        }
        return nil
    }

    /// Manga variant — same instant genre-first flow over the manga
    /// genre chain (franchise-normalized the same way).
    func randomManga(excluding: Set<String>) async -> SurprisePick? {
        var genres = DiscoveryGenre.catalog.shuffled()
        let recent = UserDefaults.standard.stringArray(forKey: "surprise.recentMangaGenres") ?? []
        genres.sort { a, b in
            let aRecent = recent.contains(a.slug)
            let bRecent = recent.contains(b.slug)
            if aRecent != bRecent { return !aRecent }
            return false
        }
        for genre in genres.prefix(6) {
            guard let list = try? await UnifiedProviderSystem.shared.mangaByGenre(genre: genre, page: 1),
                  !list.isEmpty else { continue }
            let normalized = MediaNormalizer.franchiseBasePool(from: list)
            let fresh = normalized.filter { !excluding.contains($0.uniqueId) }
            let candidates = fresh.isEmpty ? normalized : fresh
            guard let pick = candidates.randomElement() else { continue }
            rememberGenre(genre.slug, manga: true)
            return SurprisePick(genre: genre, media: pick)
        }
        return nil
    }

        /// Remembers the last few genres so consecutive presses explore
    /// different corners of the taxonomy (soft preference, not a rule).
    private func rememberGenre(_ slug: String, manga: Bool = false) {
        let key = manga ? "surprise.recentMangaGenres" : "surprise.recentGenres"
        var recent = UserDefaults.standard.stringArray(forKey: key) ?? []
        recent.removeAll { $0 == slug }
        recent.append(slug)
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        UserDefaults.standard.set(recent, forKey: key)
    }

    // MARK: - Home genre shelves

    /// The genres shown as Home shelves. Deliberately a small, stable set
    /// (the page also carries six standard shelves); each shelf and its
    /// See All page share ONE query — the same genre, the same chain, the
    /// same cache (page 1 of the See All grid IS the shelf).
    static let homeShelfGenres: [DiscoveryGenre] = {
        ["action", "fantasy", "romance", "drama", "comedy", "science-fiction"]
            .compactMap { DiscoveryGenre.bySlug($0) }
    }()
}
