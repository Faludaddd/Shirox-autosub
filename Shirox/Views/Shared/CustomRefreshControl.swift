import SwiftUI

/// A custom pull-to-refresh spinner used as an overlay on top of the standard
/// `.refreshable` scroll view.
///
/// SwiftUI's built-in `.refreshable` spinner isn't customizable, so `HomeView`
/// keeps the system behavior (which drives the actual reload task) and overlays
/// this view at the top of the scroll content. The rotating `play.tv.fill`
/// glyph reads as a clear "loading" affordance on a media app, and the optional
/// "Refreshing..." caption only appears while the refresh is in flight so the
/// resting state stays clean.
///
/// The rotation is driven by a `@State` `Double` that resets to `0` when the
/// refresh completes, so the next pull starts from a predictable orientation.
struct CustomRefreshControl: View {
    @Binding var isRefreshing: Bool
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 20, weight: .bold))
                .rotationEffect(.degrees(rotation))
                .animation(
                    isRefreshing
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: isRefreshing
                )
                .foregroundStyle(Color.accentColor)
            if isRefreshing {
                Text("Refreshing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 40)
        .onChange(of: isRefreshing) { refreshing in
            if !refreshing { rotation = 0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRefreshing ? "Refreshing content" : "Ready to refresh")
    }
}
