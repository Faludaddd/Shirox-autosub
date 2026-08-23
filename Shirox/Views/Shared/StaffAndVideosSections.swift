import SwiftUI

/// Staff section — shows directors, producers, animators, composers
/// for the anime. Fetched from MAL/Jikan's /anime/{id}/staff endpoint.
/// Placed after Characters, before Recommendations.
struct StaffSection: View {
    let mediaId: Int
    let malId: Int?
    /// Optional preloaded staff from AniList — when the parent VM already
    /// has staff data (fetched as part of the detail query), pass them in
    /// to avoid a second network call. This is the primary data source;
    /// Jikan is only used as a fallback when preloaded is nil/empty.
    var preloaded: [AniListStaffEdge]? = nil

    @State private var fetchedStaff: [MALDiscoveryService.JikanStaffEdge] = []
    @State private var isLoading = false
    @State private var didFetch = false
    /// Collapsed by default — matches CharactersSection and
    /// RecommendationsSection so the detail page doesn't open with three
    /// expanded strips stacked on top of each other.
    @State private var isExpanded = false

    /// The staff to display — prefers preloaded AniList data (from the
    /// detail query), falls back to any we fetched ourselves from Jikan.
    private var displayStaff: [AniListStaffEdge] {
        if let preloaded, !preloaded.isEmpty { return preloaded }
        return []
    }

    private var hasJikanStaff: Bool {
        !fetchedStaff.isEmpty
    }

    var body: some View {
        // Always render the section header so the user can see Staff
        // exists (even when staff is empty after a failed fetch).
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            if isExpanded {
                if !displayStaff.isEmpty {
                    // AniList staff (primary source)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(displayStaff) { edge in
                                aniListStaffCard(edge)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                } else if hasJikanStaff {
                    // Jikan fallback
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(fetchedStaff.indices, id: \.self) { idx in
                                jikanStaffCard(fetchedStaff[idx])
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading staff…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                } else if didFetch {
                    // Jikan fetch completed but returned empty, and no
                    // AniList preloaded data. Show a clean empty state.
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text("No staff data available for this title.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                } else if preloaded != nil {
                    // AniList preloaded data exists but is empty — the anime
                    // genuinely has no staff data on AniList.
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text("No staff data available for this title.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                }
            }
        }
        .padding(.top, 8)
        .task {
            // Only fetch from Jikan if we don't have AniList preloaded data.
            // This avoids unnecessary API calls and Jikan rate-limiting.
            if (preloaded?.isEmpty ?? true) && !didFetch {
                await loadStaff()
            }
        }
    }

    /// Section header with chevron — tapping toggles `isExpanded`.
    private var sectionHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Staff")
                    .font(.title3.weight(.bold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aniListStaffCard(_ edge: AniListStaffEdge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: edge.node.image?.large ?? edge.node.image?.medium ?? "")
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 100, height: 100)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(edge.node.name?.full ?? "Unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(width: 100, alignment: .leading)
                if let role = edge.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: 100, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func jikanStaffCard(_ edge: MALDiscoveryService.JikanStaffEdge) -> some View {
        if let person = edge.person {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(urlString: person.images?.jpg?.image_url ?? "")
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name ?? "Unknown")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: 100, alignment: .leading)
                    if let positions = edge.positions, !positions.isEmpty {
                        Text(positions.joined(separator: ", "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(width: 100, alignment: .leading)
                    }
                }
            }
        }
    }

    private func loadStaff() async {
        didFetch = true
        isLoading = true
        // Resolve the MAL id: prefer the explicit idMal passed in; otherwise
        // fall back to the IDMappingService cache. Without this fallback,
        // anime whose preloaded media had no idMal would silently skip the
        // staff fetch — leaving the Staff section blank.
        var resolvedMalId = malId
        if resolvedMalId == nil || resolvedMalId == 0 {
            resolvedMalId = IDMappingService.shared.cachedMalId(forAnilistId: mediaId)
        }
        guard let resolved = resolvedMalId, resolved > 0 else {
            isLoading = false
            return
        }
        do {
            fetchedStaff = try await MALDiscoveryService.shared.staff(malId: resolved)
        } catch {
            fetchedStaff = []
        }
        isLoading = false
    }
}

/// Videos section — shows PVs, trailers, openings, endings (YouTube links)
/// for the anime. Fetched from MAL/Jikan's /anime/{id}/videos endpoint.
struct VideosSection: View {
    let mediaId: Int
    let malId: Int?

    @State private var videos: [MALDiscoveryService.JikanVideo] = []
    @State private var isLoading = false
    @State private var didFetch = false
    /// Collapsed by default — matches the other detail-page sections.
    @State private var isExpanded = false

    var body: some View {
        Group {
            if !videos.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    if isExpanded {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(videos) { video in
                                    videoCard(video)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.top, 8)
            } else if isLoading {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    if isExpanded {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading videos…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    }
                }
                .padding(.top, 8)
            }
        }
        .task {
            if !didFetch { await loadVideos() }
        }
    }

    /// Section header with chevron — tapping toggles `isExpanded`.
    private var sectionHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Videos")
                    .font(.title3.weight(.bold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func videoCard(_ video: MALDiscoveryService.JikanVideo) -> some View {
        let thumbnail = video.thumbnail ?? video.images?.jpg?.image_url ?? ""
        let videoURL = video.url ?? ""

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if !thumbnail.isEmpty {
                    CachedAsyncImage(urlString: thumbnail)
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(width: 160, height: 90)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 160, height: 90)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                if let type = video.type, !type.isEmpty {
                    Text(type)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                }
                Text(video.title ?? "Untitled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(width: 160, alignment: .leading)
            }
        }
        .onTapGesture {
            #if os(iOS)
            if let url = URL(string: videoURL) {
                UIApplication.shared.open(url)
            }
            #endif
        }
    }

    private func loadVideos() async {
        didFetch = true
        isLoading = true
        // Resolve MAL id same way as StaffSection — fall back to the
        // IDMappingService cache when the caller didn't pass one.
        var resolvedMalId = malId
        if resolvedMalId == nil || resolvedMalId == 0 {
            resolvedMalId = IDMappingService.shared.cachedMalId(forAnilistId: mediaId)
        }
        guard let resolved = resolvedMalId, resolved > 0 else {
            isLoading = false
            return
        }
        do {
            videos = try await MALDiscoveryService.shared.videos(malId: resolved)
        } catch {
            videos = []
        }
        isLoading = false
    }
}
