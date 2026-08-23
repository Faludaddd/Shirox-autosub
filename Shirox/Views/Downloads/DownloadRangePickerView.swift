import SwiftUI

/// Custom Download Range picker — works for both Anime (episodes) and
/// Manga (chapters). Replaces Apple's default pickers with a custom design
/// matching the app's existing style (card-based, rounded corners, accent
/// highlights).
///
/// Flow:
///   Anime: User picks start/end → tap Start Download → calls
///          `onAnimeRangeSelected(Set<Int>)` which typically pre-fills
///          `selectedEpisodeNumbers` on AniListDetailView and presents the
///          existing `BatchDownloadModulePickerView`.
///
///   Manga: User picks start/end → tap Start Download → calls
///          `onMangaRangeSelected([MangaChapter])` which typically calls
///          `MangaDownloadManager.shared.batchDownload(chapters:context:)`.
struct DownloadRangePickerView: View {
    enum ContentType {
        case anime
        case manga
    }

    let contentType: ContentType
    let title: String
    let imageUrl: String
    let total: Int

    /// Anime: closure receives the set of selected episode numbers. The
    /// caller is responsible for presenting the existing
    /// `BatchDownloadModulePickerView` (which picks module + stream).
    var onAnimeRangeSelected: ((Set<Int>) -> Void)? = nil

    /// Manga: closure receives the filtered chapter list. The caller is
    /// responsible for calling `MangaDownloadManager.shared.batchDownload`.
    var onMangaRangeSelected: (([MangaChapter]) -> Void)? = nil

    /// Manga chapter list — used to filter by the selected number range.
    /// Empty for anime.
    var chapters: [MangaChapter] = []

    /// Anime: returns true if the episode number is already downloaded
    /// (used to compute the "will be skipped" count).
    var isEpisodeDownloaded: ((Int) -> Bool)? = nil

    /// Manga: returns true if the chapter href is already downloaded.
    var isChapterDownloaded: ((String) -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var startValue: Int = 1
    @State private var endValue: Int = 1
    @State private var hasInitialized = false

    private var unitWord: String { contentType == .anime ? "Episode" : "Chapter" }
    private var unitWordPlural: String { contentType == .anime ? "Episodes" : "Chapters" }

    /// The clamped, valid selected range.
    private var selectedRange: ClosedRange<Int> {
        let s = max(1, min(startValue, total))
        let e = max(1, min(endValue, total))
        return min(s, e)...max(s, e)
    }

    private var selectedCount: Int {
        selectedRange.upperBound - selectedRange.lowerBound + 1
    }

    private var alreadyDownloadedCount: Int {
        let range = selectedRange
        if contentType == .anime {
            return (range.lowerBound...range.upperBound).filter { isEpisodeDownloaded?($0) ?? false }.count
        } else {
            return chapters.filter { chapter in
                let n = Int(chapter.number)
                guard n >= range.lowerBound && n <= range.upperBound else { return false }
                return isChapterDownloaded?(chapter.href) ?? false
            }.count
        }
    }

    private var willDownloadCount: Int {
        max(0, selectedCount - alreadyDownloadedCount)
    }

    private var isValid: Bool {
        total > 0 && startValue <= endValue && startValue >= 1 && endValue <= total
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    rangeSelectorCard
                    presetsCard
                    infoCard
                    Spacer().frame(height: 8)
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Download Range")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .tint(.primary)
            #endif
            .onAppear {
                if !hasInitialized {
                    startValue = 1
                    endValue = min(total, max(1, total))
                    hasInitialized = true
                }
            }
        }
        #if os(iOS)
        .adaptivePresentationDetents([.large])
        #endif
    }

    // MARK: - Header Card

    @ViewBuilder
    private var headerCard: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(urlString: imageUrl)
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: contentType == .anime ? "tv.fill" : "book.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text("\(total) \(total == 1 ? unitWord : unitWordPlural) available")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Range Selector Card

    @ViewBuilder
    private var rangeSelectorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "ruler")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Select Range")
                    .font(.headline)
                Spacer()
            }

            HStack(alignment: .center, spacing: 12) {
                // Start selector
                rangeEndpointCard(
                    label: "From \(unitWord)",
                    value: $startValue,
                    range: 1...max(1, total)
                )

                VStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("\(selectedCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // End selector
                rangeEndpointCard(
                    label: "To \(unitWord)",
                    value: $endValue,
                    range: 1...max(1, total)
                )
            }

            // Validation message
            if startValue > endValue {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("Starting \(unitWord.lowercased()) must be less than or equal to ending \(unitWord.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.1))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// A single endpoint (From / To) card with a big number, +/- buttons,
    /// a manual text field for typing the number directly, and a slider
    /// for quick scrubbing. No Apple default picker used.
    @ViewBuilder
    private func rangeEndpointCard(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 10) {
                Button {
                    Haptics.light()
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .disabled(value.wrappedValue <= range.lowerBound)

                // Manual number input — lets the user type the number
                // directly instead of only using +/- buttons or the
                // slider. Numeric keyboard on mobile.
                TextField("", text: Binding(
                    get: { String(value.wrappedValue) },
                    set: { newText in
                        let trimmed = newText.filter(\.isNumber)
                        if trimmed.isEmpty {
                            value.wrappedValue = range.lowerBound
                        } else if let n = Int(trimmed) {
                            value.wrappedValue = max(range.lowerBound, min(range.upperBound, n))
                        }
                    }
                ))
                .keyboardType(.numberPad)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(minWidth: 50)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.3), lineWidth: 1)
                )

                Button {
                    Haptics.light()
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .disabled(value.wrappedValue >= range.upperBound)
            }

            // Slider for quick scrubbing — custom-styled via accentColor.
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { newValue in
                    value.wrappedValue = max(range.lowerBound, min(range.upperBound, Int(newValue)))
                }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            .tint(Color.appAccent)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Presets Card

    @ViewBuilder
    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Quick Presets")
                    .font(.headline)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip(title: "First 5") {
                        startValue = 1
                        endValue = min(total, 5)
                    }
                    presetChip(title: "First 10") {
                        startValue = 1
                        endValue = min(total, 10)
                    }
                    presetChip(title: "Last 5") {
                        startValue = max(1, total - 4)
                        endValue = total
                    }
                    presetChip(title: "Last 10") {
                        startValue = max(1, total - 9)
                        endValue = total
                    }
                    presetChip(title: "Entire Series") {
                        startValue = 1
                        endValue = total
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func presetChip(title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                action()
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.appAccent.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Info Card

    @ViewBuilder
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Summary")
                    .font(.headline)
                Spacer()
            }

            infoRow(
                label: "Selected",
                value: "\(selectedCount) \(selectedCount == 1 ? unitWord : unitWordPlural)",
                icon: "checkmark.circle",
                color: .secondary
            )

            infoRow(
                label: "Already downloaded (will skip)",
                value: "\(alreadyDownloadedCount)",
                icon: "checkmark.circle.fill",
                color: .green
            )

            infoRow(
                label: "Will download",
                value: "\(willDownloadCount)",
                icon: "arrow.down.circle.fill",
                color: Color.appAccent
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func infoRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)

            Button {
                startDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Download \(willDownloadCount)")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(Color.appAccentForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appAccent)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isValid || willDownloadCount == 0)
            .opacity((!isValid || willDownloadCount == 0) ? 0.5 : 1)
        }
    }

    // MARK: - Start Download

    private func startDownload() {
        let range = selectedRange
        Haptics.light()

        if contentType == .anime {
            let numbers = Set(range.lowerBound...range.upperBound)
            onAnimeRangeSelected?(numbers)
        } else {
            // Manga: filter chapters whose Int(number) is in the range.
            let selectedChapters = chapters.filter { chapter in
                let n = Int(chapter.number)
                return n >= range.lowerBound && n <= range.upperBound
            }
            onMangaRangeSelected?(selectedChapters)
        }
        dismiss()
    }
}
