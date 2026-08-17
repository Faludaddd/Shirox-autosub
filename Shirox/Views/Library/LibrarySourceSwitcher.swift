import SwiftUI

/// Capsule-pill switcher for the Library tab. Always shows the local "My Library" pill,
/// plus a pill for each signed-in provider. Hidden when only one source exists (logged out:
/// local-only) so a lone pill isn't shown.
///
/// Every pill uses the shared `libraryCapsuleStyle` so it matches the status filter,
/// sort menu, grid toggle, and media-type pills exactly — same height, padding,
/// corner radius, background, and stroke.
struct LibrarySourceSwitcher: View {
    let selected: LibrarySource
    let onSelect: (LibrarySource) -> Void

    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var manager = ProviderManager.shared

    private var providerSources: [ProviderType] {
        var result: [ProviderType] = []
        if anilistAuth.isLoggedIn { result.append(.anilist) }
        if malAuth.isLoggedIn { result.append(.mal) }
        return result
    }

    private var isLocalSelected: Bool {
        if case .local = selected { return true }
        return false
    }

    /// A provider pill is highlighted when we're on a remote source and it is the active
    /// primary provider — driven by `ProviderManager`, the same store the data source reads.
    private func isProviderSelected(_ type: ProviderType) -> Bool {
        !isLocalSelected && manager.primary?.providerType == type
    }

    var body: some View {
        // local + each signed-in provider; only render when there's a real choice.
        // NOTE: a plain HStack (not a horizontal ScrollView) — at most three pills fit on
        // any width, and a horizontal ScrollView above the Library's List would steal the
        // `.searchable` bar's scroll-view association and break it across navigation.
        if !providerSources.isEmpty {
            HStack(spacing: LibraryDS.controlSpacing) {
                pill(title: "My Library", isLocal: true, selected: isLocalSelected) {
                    onSelect(.local)
                }
                ForEach(providerSources, id: \.self) { type in
                    // Short label keeps all three pills on one line; the icon identifies the
                    // provider. "MyAnimeList" is the only label wide enough to force a wrap.
                    pill(title: type == .mal ? "MAL" : type.displayName, isLocal: false,
                         selected: isProviderSelected(type),
                         iconURL: type.iconURL) {
                        ProviderManager.shared.selectProvider(type)
                        onSelect(.provider(type))
                    }
                }
                Spacer()
            }
            // No internal horizontal padding — call sites supply the 16pt inset (matching
            // `filterCapsuleRow`) so the pills sit flush-left with the List button + search bar.
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func pill(title: String, isLocal: Bool, selected: Bool,
                      iconURL: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLocal {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: LibraryDS.pillIconSize, weight: .semibold))
                } else if let iconURL {
                    CachedAsyncImage(urlString: iconURL)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(title)
                    .font(LibraryDS.pillFont)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .libraryCapsuleStyle(isActive: selected)
        }
        .buttonStyle(.plain)
    }
}
