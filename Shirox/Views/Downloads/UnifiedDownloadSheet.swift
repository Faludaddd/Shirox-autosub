#if os(iOS)
import SwiftUI

// MARK: - Unified Download Sheet
//
// Merges Download Range into the normal download flow without touching
// either path's machinery:
//
//   • "This Episode" / "These Chapters" keeps the EXACT existing flow —
//     the same module/stream picker (DownloadModulePickerView) with the
//     same callbacks the episode-row download button used to open
//     directly. One extra tap on a clean choice card is all that's added.
//   • "Download Range" exposes a From/To stepper pair (plus quick
//     presets), a live "what will be downloaded" summary that accounts
//     for already-downloaded entries, and a confirm that routes into the
//     existing batch machinery (BatchDownloadModulePickerView for anime,
//     MangaDownloadManager.batchDownload for manga).
//
// Everything is custom-Shirox styled: card layout, capsule badges,
// continuous corners, haptics — no Apple-default pickers.

// MARK: - Anime (episodes)

struct UnifiedAnimeDownloadSheet: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let totalEpisodes: Int
    let coverImage: String
    let isEpisodeDownloaded: (Int) -> Bool
    /// The parent's EXISTING single-episode handler — receives the chosen
    /// stream and episode href exactly like the old direct sheet did, so
    /// the classic flow (module → stream → download) is byte-for-byte the
    /// same machinery it always was.
    var onEpisodeStreamsLoaded: (([StreamResult], String?) -> Void)? = nil
    /// Receives the confirmed episode numbers; the caller dismisses this
    /// sheet and presents the existing BatchDownloadModulePickerView.
    let onRangeConfirmed: (Set<Int>) -> Void

    private enum Mode {
        case choose
        case episode
        case range
    }

    @State private var mode: Mode = .choose
    @State private var rangeStart: Int
    @State private var rangeEnd: Int
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var moduleManager: ModuleManager

    init(mediaId: Int?,
         animeTitle: String,
         episodeNumber: Int,
         totalEpisodes: Int,
         coverImage: String,
         isEpisodeDownloaded: @escaping (Int) -> Bool,
         onEpisodeStreamsLoaded: (([StreamResult], String?) -> Void)? = nil,
         onRangeConfirmed: @escaping (Set<Int>) -> Void) {
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.totalEpisodes = max(1, totalEpisodes)
        self.coverImage = coverImage
        self.isEpisodeDownloaded = isEpisodeDownloaded
        self.onEpisodeStreamsLoaded = onEpisodeStreamsLoaded
        self.onRangeConfirmed = onRangeConfirmed
        // Anchor the range on the episode the user tapped.
        _rangeStart = State(initialValue: episodeNumber)
        _rangeEnd = State(initialValue: episodeNumber)
    }

    var body: some View {
        Group {
            switch mode {
            case .choose:
                choiceView
            case .episode:
                // The existing single-episode flow, untouched — same picker,
                // same callbacks, same download machinery as before.
                DownloadModulePickerView(
                    mediaId: mediaId,
                    animeTitle: animeTitle,
                    episodeNumber: episodeNumber,
                    onDismiss: { dismiss() },
                    onStreamsLoaded: { streams, episodeHref in
                        onEpisodeStreamsLoaded?(streams, episodeHref)
                    }
                )
                .environmentObject(moduleManager)
            case .range:
                rangeView
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            Haptics.light()
        }
    }

    // MARK: - Choice screen

    private var choiceView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                headerCard
                optionCard(
                    title: "Download Episode \(episodeNumber)",
                    subtitle: "Pick a source and stream, then download just this episode — the classic flow.",
                    icon: "arrow.down.circle.fill",
                    tint: .accentColor
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .episode }
                }
                optionCard(
                    title: "Download Range",
                    subtitle: "Grab several episodes at once (e.g. 50 → 53). Already-downloaded episodes are skipped.",
                    icon: "arrow.down.to.line.compact",
                    tint: .blue
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .range }
                }
                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: coverImage)
                .frame(width: 54, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Download")
                    .font(.system(size: 19, weight: .bold))
                Text(animeTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(totalEpisodes) episode\(totalEpisodes == 1 ? "" : "s") available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func optionCard(title: String, subtitle: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Range editor

    private var selectedRange: ClosedRange<Int> {
        let s = max(1, min(rangeStart, totalEpisodes))
        let e = max(1, min(rangeEnd, totalEpisodes))
        return min(s, e)...max(s, e)
    }

    private var alreadyDownloaded: Int {
        (selectedRange.lowerBound...selectedRange.upperBound)
            .filter { isEpisodeDownloaded($0) }
            .count
    }

    private var rangeView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                rangeHeader
                DownloadRangeStepperCard(
                    total: totalEpisodes,
                    rangeStart: $rangeStart,
                    rangeEnd: $rangeEnd,
                    unitSingular: "Episode",
                    unitPlural: "Episodes"
                )
                presetRow
                DownloadRangeSummaryCard(
                    range: selectedRange,
                    totalCount: selectedRange.count,
                    alreadyDownloaded: alreadyDownloaded,
                    unitSingular: "episode",
                    unitPlural: "episodes"
                )
                confirmButton
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .choose }
                } label: {
                    Text("Back")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var rangeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download Range")
                    .font(.system(size: 19, weight: .bold))
                Text(animeTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.label) { preset in
                    Button {
                        Haptics.selection()
                        applyPreset(preset)
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color(.secondarySystemGroupedBackground))
                            )
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct PresetOption {
        let label: String
        let apply: () -> Void
    }

    private var presets: [PresetOption] {
        var options: [PresetOption] = [
            PresetOption(label: "1–\(min(5, totalEpisodes))") {
                rangeStart = 1
                rangeEnd = min(5, totalEpisodes)
            }
        ]
        if totalEpisodes > 10 {
            options.append(PresetOption(label: "1–10") {
                rangeStart = 1
                rangeEnd = min(10, totalEpisodes)
            })
        }
        if totalEpisodes > 5 {
            let last = max(1, totalEpisodes)
            options.append(PresetOption(label: "Last 5") {
                rangeStart = max(1, last - 4)
                rangeEnd = last
            })
        }
        if totalEpisodes > 10 {
            let last = max(1, totalEpisodes)
            options.append(PresetOption(label: "Last 10") {
                rangeStart = max(1, last - 9)
                rangeEnd = last
            })
        }
        options.append(PresetOption(label: "Entire Series") {
            rangeStart = 1
            rangeEnd = totalEpisodes
        })
        return options
    }

    private func applyPreset(_ preset: PresetOption) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            preset.apply()
        }
    }

    private var confirmButton: some View {
        Button {
            Haptics.success()
            let numbers = Set(selectedRange.lowerBound...selectedRange.upperBound)
            onRangeConfirmed(numbers)
        } label: {
            Label(
                "Download \(max(1, selectedRange.count - alreadyDownloaded)) Episode\(max(1, selectedRange.count - alreadyDownloaded) == 1 ? "" : "s")",
                systemImage: "arrow.down.circle.fill"
            )
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedRange.count - alreadyDownloaded <= 0)
        .opacity(selectedRange.count - alreadyDownloaded <= 0 ? 0.4 : 1)
    }
}

// MARK: - Manga (chapters)

struct UnifiedMangaDownloadSheet: View {
    let mangaTitle: String
    let coverImage: String
    let chapters: [MangaChapter]
    let isChapterDownloaded: (MangaChapter) -> Bool
    /// "Select Chapters" — the caller dismisses this sheet and enters the
    /// existing selection mode (unchanged behavior).
    let onSelectChapters: () -> Void
    /// Range confirm — the caller dismisses and calls
    /// MangaDownloadManager.batchDownload with the filtered chapters.
    let onRangeConfirmed: ([MangaChapter]) -> Void

    private enum Mode {
        case choose
        case range
    }

    @State private var mode: Mode = .choose
    @State private var rangeStart: Int = 1
    @State private var rangeEnd: Int = 1
    @State private var appeared = false

    /// Chapters with a usable integral number (1, 2, 3…). Chapter
    /// numbers are Doubles; fractional/zero entries (rare module quirks)
    /// can't participate in a numeric range.
    private var numberedChapters: [MangaChapter] {
        chapters
            .filter { $0.number >= 1 && $0.number.truncatingRemainder(dividingBy: 1) == 0 }
            .sorted { $0.number < $1.number }
    }

    private var totalChapters: Int {
        max(1, numberedChapters.map { Int($0.number) }.max() ?? 1)
    }

    init(mangaTitle: String,
         coverImage: String,
         chapters: [MangaChapter],
         isChapterDownloaded: @escaping (MangaChapter) -> Bool,
         onSelectChapters: @escaping () -> Void,
         onRangeConfirmed: @escaping ([MangaChapter]) -> Void) {
        self.mangaTitle = mangaTitle
        self.coverImage = coverImage
        self.chapters = chapters
        self.isChapterDownloaded = isChapterDownloaded
        self.onSelectChapters = onSelectChapters
        self.onRangeConfirmed = onRangeConfirmed
        let maxN = chapters
            .filter { $0.number >= 1 && $0.number.truncatingRemainder(dividingBy: 1) == 0 }
            .map { Int($0.number) }
            .max() ?? 1
        // Default: a small 1–3 window the user can widen.
        _rangeStart = State(initialValue: 1)
        _rangeEnd = State(initialValue: min(3, max(1, maxN)))
    }

    var body: some View {
        Group {
            if mode == .choose {
                choiceView
            } else {
                rangeView
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            Haptics.light()
        }
    }

    private var choiceView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                headerCard
                optionCard(
                    title: "Select Chapters",
                    subtitle: "Pick exactly which chapters to download from the chapter list — the classic flow.",
                    icon: "checkmark.circle.fill",
                    tint: .accentColor
                ) {
                    onSelectChapters()
                }
                optionCard(
                    title: "Download Range",
                    subtitle: "Grab several chapters at once (e.g. 50 → 53). Already-downloaded chapters are skipped.",
                    icon: "arrow.down.to.line.compact",
                    tint: .teal
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .range }
                }
                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: coverImage)
                .frame(width: 54, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Download")
                    .font(.system(size: 19, weight: .bold))
                Text(mangaTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(numberedChapters.count) numbered chapter\(numberedChapters.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func optionCard(title: String, subtitle: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Range editor

    private var selectedRange: ClosedRange<Int> {
        let s = max(1, min(rangeStart, max(1, totalChapters)))
        let e = max(1, min(rangeEnd, max(1, totalChapters)))
        return min(s, e)...max(s, e)
    }

    private var chaptersInRange: [MangaChapter] {
        numberedChapters.filter { chapter in
            let n = Int(chapter.number)
            return n >= selectedRange.lowerBound && n <= selectedRange.upperBound
        }
    }

    private var alreadyDownloaded: Int {
        chaptersInRange.filter { isChapterDownloaded($0) }.count
    }

    private var rangeView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download Range")
                            .font(.system(size: 19, weight: .bold))
                        Text(mangaTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if totalChapters >= 1 {
                    DownloadRangeStepperCard(
                        total: totalChapters,
                        rangeStart: $rangeStart,
                        rangeEnd: $rangeEnd,
                        unitSingular: "Chapter",
                        unitPlural: "Chapters"
                    )
                    presetRow
                    DownloadRangeSummaryCard(
                        range: selectedRange,
                        totalCount: chaptersInRange.count,
                        alreadyDownloaded: alreadyDownloaded,
                        unitSingular: "chapter",
                        unitPlural: "chapters"
                    )
                    confirmButton
                } else {
                    Text("This manga's chapters aren't numbered — use Select Chapters instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 24)
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .choose }
                } label: {
                    Text("Back")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.label) { preset in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            preset.apply()
                        }
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct PresetOption {
        let label: String
        let apply: () -> Void
    }

    private var presets: [PresetOption] {
        let total = max(1, totalChapters)
        var options: [PresetOption] = [
            PresetOption(label: "1–\(min(5, total))") {
                rangeStart = 1
                rangeEnd = min(5, total)
            }
        ]
        if total > 10 {
            options.append(PresetOption(label: "1–10") {
                rangeStart = 1
                rangeEnd = min(10, total)
            })
        }
        if total > 5 {
            options.append(PresetOption(label: "Last 5") {
                rangeStart = max(1, total - 4)
                rangeEnd = total
            })
        }
        if total > 10 {
            options.append(PresetOption(label: "Last 10") {
                rangeStart = max(1, total - 9)
                rangeEnd = total
            })
        }
        options.append(PresetOption(label: "All Chapters") {
            rangeStart = 1
            rangeEnd = total
        })
        return options
    }

    private var confirmButton: some View {
        let toDownload = chaptersInRange.filter { !isChapterDownloaded($0) }
        return Button {
            Haptics.success()
            onRangeConfirmed(toDownload)
        } label: {
            Label(
                "Download \(max(1, toDownload.count)) Chapter\(max(1, toDownload.count) == 1 ? "" : "s")",
                systemImage: "arrow.down.circle.fill"
            )
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(toDownload.isEmpty)
        .opacity(toDownload.isEmpty ? 0.4 : 1)
    }
}

// MARK: - Shared range UI

/// From/To stepper card — the "From: 50, To: 53" input.
struct DownloadRangeStepperCard: View {
    let total: Int
    @Binding var rangeStart: Int
    @Binding var rangeEnd: Int
    let unitSingular: String
    let unitPlural: String

    var body: some View {
        VStack(spacing: 12) {
            stepperRow(label: "From", value: $rangeStart)
            Divider().opacity(0.4)
            stepperRow(label: "To", value: $rangeEnd)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func stepperRow(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.headline)
            Spacer()
            stepperButton(icon: "minus", edge: .leading, value: value)
            Text("\(value.wrappedValue)")
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.appAccent)
                .frame(minWidth: 56)
                .contentShape(Rectangle())
            stepperButton(icon: "plus", edge: .trailing, value: value)
        }
    }

    private enum StepperEdge {
        case leading
        case trailing
    }

    private func stepperButton(icon: String, edge: StepperEdge, value: Binding<Int>) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                value.wrappedValue = min(total, max(1, value.wrappedValue + (edge == .leading ? -1 : 1)))
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(edge == .leading && value.wrappedValue <= 1)
        .disabled(edge == .trailing && value.wrappedValue >= total)
        .opacity((edge == .leading && value.wrappedValue <= 1)
                 || (edge == .trailing && value.wrappedValue >= total) ? 0.35 : 1)
    }
}

/// "What will be downloaded" summary — shown before confirming.
struct DownloadRangeSummaryCard: View {
    let range: ClosedRange<Int>
    let totalCount: Int
    let alreadyDownloaded: Int
    let unitSingular: String
    let unitPlural: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("Ready to download")
                    .font(.headline)
                Spacer()
            }
            HStack(spacing: 6) {
                summaryPill(
                    text: "\(range.lowerBound)–\(range.upperBound)",
                    icon: "number",
                    tint: Color.appAccent
                )
                summaryPill(
                    text: "\(totalCount) \(totalCount == 1 ? unitSingular : unitPlural)",
                    icon: "square.stack.3d.up.fill",
                    tint: .blue
                )
                if alreadyDownloaded > 0 {
                    summaryPill(
                        text: "\(alreadyDownloaded) skipped",
                        icon: "checkmark.circle.fill",
                        tint: .green
                    )
                }
            }
            if alreadyDownloaded > 0 {
                Text("Already-downloaded \(unitPlural.lowercased()) in this range are skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func summaryPill(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.1)))
    }
}
#endif
