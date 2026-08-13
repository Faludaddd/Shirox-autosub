import SwiftUI

/// Library tab's History view. Shows a unified feed of anime watched + manga
/// read, categorized into separate sections. Each entry shows the cover,
/// title, progress info ("Episode X watched" / "Chapter X read"), and date
/// of activity. Tapping a history item opens the corresponding anime or
/// manga detail page so the user can resume from where they left off.
///
/// The view observes `HistoryManager.shared` directly, so any progress
/// update from ContinueWatchingManager (anime) or MangaProgressManager
/// (manga) is reflected here in real time — no manual refresh needed.
struct LibraryHistoryView: View {
    @ObservedObject private var history = HistoryManager.shared
    @State private var selectedAnimeEntry: HistoryEntry?
    @State private var selectedMangaEntry: HistoryEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if history.entries.isEmpty {
                    emptyState
                } else {
                    if !history.animeEntries.isEmpty {
                        animeSection
                    }
                    if !history.mangaEntries.isEmpty {
                        mangaSection
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("History")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !history.entries.isEmpty {
                    Menu {
                        Button(role: .destructive) {
                            Haptics.light()
                            history.clearAll()
                        } label: {
                            Label("Clear All History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        // Hidden navigation destinations driven by tap-to-open.
        .navigationDestinationCompat(item: $selectedAnimeEntry) { entry in
            AniListDetailView(mediaId: entry.aniListID ?? 0, preloadedMedia: nil)
        }
        .navigationDestinationCompat(item: $selectedMangaEntry) { entry in
            // Manga entries need an AniList ID to open the detail page. If
            // the entry has no aniListID (purely local manga), we can't
            // navigate — show a brief toast instead.
            if entry.aniListID != nil {
                AniListMangaDetailView(mediaId: entry.aniListID!, preloadedMedia: nil)
            } else {
                ContentUnavailableView(
                    "Manga Detail Unavailable",
                    systemImage: "book.closed",
                    description: Text("This manga was read from a local module and doesn't have an AniList detail page.")
                )
            }
        }
    }

    // MARK: - Anime Section

    private var animeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Anime History", icon: "tv.fill")
            LazyVStack(spacing: 10) {
                ForEach(history.animeEntries) { entry in
                    Button {
                        Haptics.light()
                        selectedAnimeEntry = entry
                    } label: {
                        HistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Haptics.light()
                            withAnimation { history.remove(entry) }
                        } label: {
                            Label("Remove from History", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Manga Section

    private var mangaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Manga History", icon: "book.fill")
            LazyVStack(spacing: 10) {
                ForEach(history.mangaEntries) { entry in
                    Button {
                        Haptics.light()
                        selectedMangaEntry = entry
                    } label: {
                        HistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Haptics.light()
                            withAnimation { history.remove(entry) }
                        } label: {
                            Label("Remove from History", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No History Yet")
                .font(.title3.weight(.semibold))
            Text("Watch an anime or read a manga and your activity will show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Background

    private var background: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color.black.opacity(0.05)
        #endif
    }
}

// MARK: - HistoryRow
//
// One history entry. Matches the card style of Library items: cover image,
// title, progress info, and date. Tapping opens the detail page (resume).

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            // Cover image
            CachedAsyncImage(urlString: entry.coverImageURL ?? "")
                .frame(width: 52, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            // Title + progress + date
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: entry.kind == .anime ? "play.circle.fill" : "book.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(entry.progressText)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)

                Text(entry.dateLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
