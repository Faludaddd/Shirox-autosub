import Foundation

/// AniDB HTTP-API provider — anime fallback #4 (last resort).
///
/// AniDB's HTTP API requires a REGISTERED client identity (name + version
/// registered with AniDB per their client API policy — anonymous clients
/// are rejected with error 302). The app does not embed anyone else's
/// registered identity. Users who HAVE their own registered client can
/// enter it in Data Sources settings; with one configured this provider
/// genuinely serves detail records (XML) keyed by AniDB id. Without one
/// the provider reports "requires registered client" and the chain moves
/// to the next source — the app never pretends AniDB answered.
@MainActor
final class AniDBProvider {
    static let shared = AniDBProvider()

    private let endpoint = "http://api.anidb.net:9001/httpapi"

    // MARK: - User-configurable registered client identity

    private let clientNameKey = "anidb.clientName.v1"
    private let clientVersionKey = "anidb.clientVersion.v1"

    var clientName: String {
        get { UserDefaults.standard.string(forKey: clientNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: clientNameKey) }
    }

    var clientVersion: String {
        get { UserDefaults.standard.string(forKey: clientVersionKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: clientVersionKey) }
    }

    /// True when the user has entered their own registered AniDB client
    /// identity — the only state in which requests are attempted.
    var isConfigured: Bool {
        !clientName.isEmpty && !clientVersion.isEmpty
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Health check (used by Test Provider)

    /// A REAL request against AniDB's HTTP API. With no configured client
    /// it reports the honest reason without touching the network; with one
    /// it sends the actual request and reports what AniDB really said.
    func healthCheck() async throws -> Bool {
        guard isConfigured else {
            throw ProviderChainError.allProvidersFailed(
                lastReason: "AniDB requires a registered client identity (name + version). Enter yours in the fields above — anonymous requests are rejected by their API.")
        }
        let url = URL(string: "\(endpoint)?request=anime&client=\(clientName)&clientver=\(clientVersion)&protover=1&aid=1")
        guard let url else { return false }
        let (data, response) = try await Self.session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<error") {
            // AniDB answers 200 with an XML error document — surface it.
            throw ProviderChainError.allProvidersFailed(
                lastReason: "AniDB rejected the request: \(body.replacingOccurrences(of: "<error code=", with: "").prefix(80))")
        }
        return body.contains("<anime")
    }

    // MARK: - Detail record (XML, keyed by AniDB id)

    /// Fetches AniDB's anime record as a raw XML string. AniDB ids come
    /// from other providers' mapping data (e.g. Kitsu mappings). Returns
    /// nil when the client isn't configured or AniDB answers with an
    /// error document.
    func animeRecord(aid: Int) async -> String? {
        guard isConfigured, aid > 0 else { return nil }
        let url = URL(string: "\(endpoint)?request=anime&client=\(clientName)&clientver=\(clientVersion)&protover=1&aid=\(aid)")
        guard let url, let (data, _) = try? await Self.session.data(for: URLRequest(url: url)) else { return nil }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("<anime") ? body : nil
    }
}
