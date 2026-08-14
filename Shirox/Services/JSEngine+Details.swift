import Foundation

extension JSEngine {
    func fetchDetails(url: String, title: String, image: String) async throws -> MediaDetail {
        let json = try await callAsyncJS("extractDetails", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            throw JSEngineError.parseError("Could not parse details")
        }
        return MediaDetail(
            title: title,
            image: image,
            description: first["description"] as? String ?? "N/A",
            aliases: first["aliases"] as? String ?? "N/A",
            airdate: first["airdate"] as? String ?? "N/A",
            episodes: []
        )
    }

    /// In-flight episode fetch dedup for the shared JSEngine. Prevents
    /// duplicate extractEpisodes calls for the same URL when multiple UI
    /// parts trigger the same fetch simultaneously (e.g. SwiftUI re-renders,
    /// download manager, auto-resolve).
    private static var inFlightEpisodes: [String: Task<[EpisodeLink], Error>] = [:]

    func fetchEpisodes(url: String) async throws -> [EpisodeLink] {
        // Dedup: if a fetch for this URL is already in flight, await it
        // instead of starting a new one. Prevents the duplicate episode-list
        // requests that happen when SwiftUI re-renders or multiple download
        // tasks fire simultaneously.
        if let existing = Self.inFlightEpisodes[url] {
            return try await existing.value
        }
        let task = Task<[EpisodeLink], Error> {
            defer { Self.inFlightEpisodes.removeValue(forKey: url) }
            let json = try await callAsyncJS("extractEpisodes", args: [url])
            guard let data = json.data(using: .utf8),
                  let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw JSEngineError.parseError("Could not parse episodes")
            }
            return array.compactMap { item in
                guard let href = item["href"] as? String else { return nil }
                let number: Double
                if let n = item["number"] as? Double {
                    number = n
                } else if let n = item["number"] as? Int {
                    number = Double(n)
                } else {
                    number = 0
                }
                return EpisodeLink(number: number, href: href)
            }
        }
        Self.inFlightEpisodes[url] = task
        return try await task.value
    }
}
