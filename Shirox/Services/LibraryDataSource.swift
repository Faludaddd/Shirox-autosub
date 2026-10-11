import Foundation

/// Which backing store the Library tab is currently showing.
enum LibrarySource: Hashable {
    case provider(ProviderType)
    case local
}

extension LibrarySource {
    /// The provider choosing this source makes primary — none for My Library.
    var providerToSelect: ProviderType? {
        if case .provider(let type) = self { return type }
        return nil
    }

    /// What this source lists.
    var mediaKinds: [MediaKind] { [.anime, .manga] }

    /// The status lists this source can hold for `kind`, in the user's order.
    func statuses(in order: [MediaListStatus], for kind: MediaKind = .anime) -> [MediaListStatus] {
        order
    }

    /// The list a kind opens on.
    static func defaultStatus(for kind: MediaKind) -> MediaListStatus {
        .current
    }

    /// Where the Library goes when the list on screen signs out: the primary provider if it is
    /// still signed in, then any signed-in provider, then My Library.
    static func afterSignOut(primary: ProviderType?, signedIn: Set<ProviderType>) -> LibrarySource {
        if let primary, ProviderType.userProviders.contains(primary), signedIn.contains(primary) {
            return .provider(primary)
        }
        if let type = ProviderType.userProviders.first(where: { signedIn.contains($0) }) {
            return .provider(type)
        }
        return .local
    }
}

/// The four library operations the Library tab needs, decoupled from where the data lives.
@MainActor protocol LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry]
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws
    func deleteEntry(_ entry: LibraryEntry) async throws
}

/// Routes through `ProviderManager` (AniList / MAL, with its fallback logic).
@MainActor struct RemoteLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        try await ProviderManager.shared.call { try await $0.fetchLibrary() }
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        try await ProviderManager.shared.call {
            try await $0.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
        }
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        try await ProviderManager.shared.call { try await $0.deleteEntry(entryId: entry.id) }
    }
}

/// Reads/writes the on-device `LocalLibraryManager`. Update is an upsert; never throws.
@MainActor struct LocalLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        LocalLibraryManager.shared.entries
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        LocalLibraryManager.shared.upsert(media: media, status: status, progress: progress, score: score)
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        LocalLibraryManager.shared.remove(uniqueId: entry.media.uniqueId)
    }
}
