import SwiftUI

/// Batch 26 — the STABLE identifier every browse surface routes by.
/// A Home row, a grid tile and the See All page it opens all carry one
/// of these; the destination page runs the exact query the identifier
/// names. Never an array index, never a display title, never a route
/// shared by multiple categories.
enum BrowseQuery: Hashable {
    /// The six standard charts (trending / seasonal / popular / …).
    case category(BrowseCategory)
    /// A genre page — keyed by the genre SLUG (the discovery database's
    /// own category identifier).
    case genre(DiscoveryGenre)

    /// Page title for the See All destination.
    var title: String {
        switch self {
        case .category(let category): return category.title
        case .genre(let genre): return genre.displayName
        }
    }

    /// The unified-chain browse call this query runs — the SAME one for
    /// the Home shelf (page 1) and the See All grid (pages 1…N).
    func load(page: Int) async throws -> [Media] {
        switch self {
        case .category(let category):
            return try await UnifiedProviderSystem.shared.browse(category: category, page: page)
        case .genre(let genre):
            return try await UnifiedProviderSystem.shared.browse(genre: genre, page: page)
        }
    }
}

struct BrowseView: View {
    let query: BrowseQuery
    @StateObject private var vm: BrowseViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(query: BrowseQuery) {
        self.query = query
        _vm = StateObject(wrappedValue: BrowseViewModel(query: query))
    }

    /// Backward-compatible category initializer (existing callers).
    init(category: BrowseCategory) {
        self.init(query: .category(category))
    }

    private var columnCount: Int {
        #if os(iOS)
        return sizeClass == .regular ? 4 : 2
        #else
        return 4
        #endif
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty, let error = vm.error {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.retry() } }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.items, id: \.uniqueId) { media in
                            NavigationLink {
                                AniListDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                AniListCardView(media: media)
                                    .equatable()
                            }
                            .contentShape(Rectangle())
                            .buttonStyle(BrowseCardPressStyle())
                        }

                        // Infinite scroll sentinel
                        if vm.hasMore {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await vm.loadMore() } }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView()
                            .padding(.bottom, 16)
                    }
                }
                .refreshable { await vm.retry() }
            }
        }
        .navigationTitle(query.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await vm.loadMore() }
    }
}

private struct BrowseCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

