import SwiftUI

// MARK: - Data Sources settings page (v2.24)
//
// The provider control room: every anime/manga/schedule source in one
// place, with REAL health, REAL priority ordering (drag or buttons),
// REAL provider tests, and per-domain cache controls. Everything shown
// here is measured from actual requests — no simulated statuses, no
// placeholder buttons.

struct DataSourcesSettingsPage: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared

    @State private var testingKind: MetaProviderKind?
    @State private var animeCacheSize: Int64 = 0
    @State private var mangaCacheSize: Int64 = 0
    @State private var scheduleCacheSize: Int64 = 0
    @State private var showResetConfirmation = false

    // User-configurable credentials (AnimeSchedule token / AniDB client).
    @State private var animescheduleToken = ""
    @State private var anidbClientName = ""
    @State private var anidbClientVersion = ""
    @State private var loadedCredentials = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                providerDomainCard(
                    domain: .anime,
                    title: "Anime Providers",
                    subtitle: "TVDB → MAL → AniList → Kitsu → AniDB",
                    icon: "sparkles.tv")
                providerDomainCard(
                    domain: .manga,
                    title: "Manga Providers",
                    subtitle: "MangaBaka → MAL → AniList",
                    icon: "text.book.closed.fill")
                providerDomainCard(
                    domain: .schedule,
                    title: "Schedule Providers",
                    subtitle: "AniChart → AnimeSchedule → MAL → AniList",
                    icon: "calendar")
                cacheCard
                footnoteCard
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .navigationTitle("Data Sources")
        .inlineNavBar()
        .onAppear {
            refreshCacheSizes()
            loadCredentials()
        }
        .alert("Reset to Recommended Order?", isPresented: $showResetConfirmation) {
            Button("Reset All", role: .destructive) {
                withAnimation {
                    providers.resetAllOrders()
                }
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anime: TVDB → MAL → AniList → Kitsu → AniDB\nManga: MangaBaka → MAL → AniList\nSchedule: AniChart → AnimeSchedule → MAL → AniList")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 46, height: 46)
                    .background(Color.appAccent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider System")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("One shared chain serves every screen — priority, health, cooldowns, caching and deduplication all live here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let servedBy = providers.lastServedBy {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Currently serving: \(servedBy.displayName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Provider domain card (the priority chain)

    private func providerDomainCard(
        domain: ProviderDomain,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Button {
                    showResetConfirmation = true
                } label: {
                    Text("Reset Order")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            providerFlow(domain: domain)

            // v2.24 — the priority list: drag-and-drop reordering (press
            // the handle, drag, drop) plus arrow buttons for precise
            // single-step moves. Both commit the same persisted order the
            // request chain reads.
            ReorderableProviderList(
                domain: domain,
                testingKind: testingKind,
                onTest: { kind in await runTest(kind) })

            // Domain-specific credential rows.
            if domain == .schedule {
                AnimeScheduleTokenRow(token: $animescheduleToken)
            }
            if domain == .anime {
                AniDBCredentialsRow(clientName: $anidbClientName, clientVersion: $anidbClientVersion)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The visual chain: provider badges joined with arrows, in priority
    /// order (disabled providers show struck-through).
    private func providerFlow(domain: ProviderDomain) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(providers.order(for: domain).enumerated()), id: \.element) { index, kind in
                    HStack(spacing: 8) {
                        if index > 0 {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        Text(kind.shortName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(providers.isEnabled(kind) ? .primary : .secondary)
                            .opacity(providers.isEnabled(kind) ? 1 : 0.4)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Color.appAccent.opacity(providers.isEnabled(kind) ? 0.15 : 0.06),
                                in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func runTest(_ kind: MetaProviderKind) async {
        testingKind = kind
        let result = await providers.testProvider(kind)
        testingKind = nil
        if result.ok {
            Haptics.success()
        } else {
            Haptics.error()
        }
    }

    // MARK: - Drag-and-drop priority list (v2.24)

    /// Long-press a card's handle (the three lines) to lift it, drag
    /// vertically to reposition — the neighbors slide aside in real time
    /// with a haptic tick at every slot crossing — and release to commit.
    /// The committed order is persisted instantly and read by every
    /// request chain in the app; the per-card arrow buttons remain for
    /// precise single-step moves and accessibility.
    private struct ReorderableProviderList: View {
        @ObservedObject private var providers = UnifiedProviderSystem.shared
        let domain: ProviderDomain
        let testingKind: MetaProviderKind?
        let onTest: (MetaProviderKind) async -> Void

        /// Estimated per-card stride for the drag-reorder math. Batch 23:
        /// the reworked cards are slightly taller (separated identity /
        /// health rows), so the stride follows. Cards vary in height
        /// (metrics rows / test banners), so reordering snaps at this
        /// granularity; the arrows give exact single-step control.
        private let rowStride: CGFloat = 152

        @State private var draggedIndex: Int?
        @State private var dragOffset: CGFloat = 0
        @State private var lastHapticTarget: Int?

        /// Slot the dragged card would land in if released right now.
        private var targetIndex: Int? {
            guard let from = draggedIndex else { return nil }
            let count = providers.order(for: domain).count
            let displacement = Int((dragOffset / rowStride).rounded(.awayFromZero))
            return min(max(from + displacement, 0), count - 1)
        }

        /// Live shift applied to non-dragged cards so a gap opens where the
        /// dragged card would land.
        private func neighborShift(for index: Int) -> CGFloat {
            guard let from = draggedIndex, let target = targetIndex, target != from else { return 0 }
            if index == from { return 0 }
            let lower = min(from, target)
            let upper = max(from, target)
            guard index >= lower, index <= upper else { return 0 }
            // Cards between the origin and the gap slide one stride in the
            // direction OPPOSITE the drag, opening the slot.
            return from < target ? -rowStride : rowStride
        }

        var body: some View {
            let order = providers.order(for: domain)
            VStack(spacing: 8) {
                ForEach(Array(order.enumerated()), id: \.element) { index, kind in
                    ProviderCardView(
                        kind: kind,
                        domain: domain,
                        priorityIndex: index,
                        isTesting: testingKind == kind,
                        onTest: { await onTest(kind) },
                        onMoveUp: { move(kind: kind, delta: -1) },
                        onMoveDown: { move(kind: kind, delta: 1) },
                        dragHandle: ProviderDragHandle(
                            isLifted: draggedIndex == index,
                            onDragStarted: {
                                draggedIndex = index
                                dragOffset = 0
                                lastHapticTarget = index
                                Haptics.selection()
                            },
                            onDragChanged: { y in
                                dragOffset = y
                                if let t = targetIndex, t != lastHapticTarget {
                                    Haptics.selection()
                                    lastHapticTarget = t
                                }
                            },
                            onDragEnded: { y in
                                dragOffset = y
                                commitDrop()
                            }))
                        .offset(y: index == draggedIndex
                                ? dragOffset
                                : neighborShift(for: index))
                        .scaleEffect(index == draggedIndex ? 1.03 : 1)
                        .zIndex(index == draggedIndex ? 10 : 0)
                        .opacity(index == draggedIndex ? 0.96 : 1)
                        .shadow(color: index == draggedIndex ? .black.opacity(0.18) : .clear,
                                radius: 12, y: 5)
                        .animation(draggedIndex == nil
                                   ? .spring(response: 0.32, dampingFraction: 0.82)
                                   : nil,
                                   value: draggedIndex)
                        .animation(draggedIndex == nil ? nil : .linear(duration: 0.12),
                                   value: targetIndex)
                }
            }
        }

        /// Commits the drop: reorders the persisted chain order, then
        /// clears the drag state so everything settles into place.
        private func commitDrop() {
            guard let from = draggedIndex, let target = targetIndex, target != from else {
                draggedIndex = nil
                dragOffset = 0
                lastHapticTarget = nil
                return
            }
            var order = providers.order(for: domain)
            let kind = order[from]
            order.remove(at: from)
            order.insert(kind, at: target)
            providers.setOrder(order, for: domain)
            Haptics.success()
            draggedIndex = nil
            dragOffset = 0
            lastHapticTarget = nil
        }

        private func move(kind: MetaProviderKind, delta: Int) {
            var order = providers.order(for: domain)
            guard let index = order.firstIndex(of: kind) else { return }
            let target = index + delta
            guard target >= 0, target < order.count else { return }
            order.swapAt(index, target)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                providers.setOrder(order, for: domain)
            }
            Haptics.selection()
        }
    }

    // MARK: - Cache controls

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Provider Cache")
                        .font(.headline)
                        .lineLimit(1)
                    Text("Cached provider responses keep repeat loads instant. Clearing never touches your downloads, library, or watch data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            cacheRow(title: "Anime Cache", detail: "Shelves, browse, search, TVDB detail fields.", size: animeCacheSize) {
                providers.clearAnimeCache()
                refreshCacheSizes()
            }
            cacheRow(title: "Manga Cache", detail: "Manga shelves, search, MangaBaka details.", size: mangaCacheSize) {
                providers.clearMangaCache()
                refreshCacheSizes()
            }
            cacheRow(title: "Schedule Cache", detail: "Airing timetable responses.", size: scheduleCacheSize) {
                providers.clearScheduleCache()
                refreshCacheSizes()
            }
            Button(role: .destructive) {
                providers.clearAllProviderCache()
                refreshCacheSizes()
                Haptics.success()
            } label: {
                Label("Clear All Provider Cache", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cacheRow(title: String, detail: String, size: Int64, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(detail) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Clear", action: onClear)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func refreshCacheSizes() {
        animeCacheSize = providers.cacheSize(domain: .anime)
        mangaCacheSize = providers.cacheSize(domain: .manga)
        scheduleCacheSize = providers.cacheSize(domain: .schedule)
    }

    private func loadCredentials() {
        guard !loadedCredentials else { return }
        animescheduleToken = AnimeScheduleProvider.shared.apiToken
        anidbClientName = AniDBProvider.shared.clientName
        anidbClientVersion = AniDBProvider.shared.clientVersion
        loadedCredentials = true
    }

    // MARK: - Footnote

    private var footnoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Priority is tried top to bottom. A failing provider is skipped for its cooldown window — and requests are shared across screens, so one slow source can never trigger a request storm.",
                systemImage: "info.circle")
            Label(
                "Field-level fallback: detail pages keep a provider's data and only ask lower-priority sources for the MISSING fields — a complete provider is never thrown away over one gap.",
                systemImage: "square.split.2x1")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Drag handle

/// The reorder affordance injected into a provider card. The card renders
/// the handle icon and attaches the press-hold-then-drag gesture; the
/// callbacks report lift / drag / drop back to the owning list, which owns
/// the reorder math and the committed order.
struct ProviderDragHandle {
    /// True while THIS card is the one being dragged (visual highlight).
    let isLifted: Bool
    /// Long-press completed — the card lifts.
    let onDragStarted: () -> Void
    /// Drag translation (points, positive = downward).
    let onDragChanged: (CGFloat) -> Void
    /// Finger lifted — commit the reorder at this translation.
    let onDragEnded: (CGFloat) -> Void
}

// MARK: - Provider brand tile (Batch 23, item 2)

/// A provider's recognizable identity tile: a two-letter monogram in the
/// provider's brand color on a rounded square. Always renders (no network
/// dependency — a logo URL would go dead exactly when its provider is
/// down, which is when the user looks at this page), readable at a glance,
/// and stable at every Dynamic Type size.
private struct ProviderLogoTile: View {
    let kind: MetaProviderKind

    private var monogram: String {
        switch kind {
        case .tvdb:          return "TV"
        case .mal:           return "M"
        case .anilist:       return "AL"
        case .kitsu:         return "K"
        case .anidb:         return "DB"
        case .mangabaka:     return "MB"
        case .anichart:      return "AC"
        case .animeschedule: return "AS"
        }
    }

    private var brandColor: Color {
        switch kind {
        case .tvdb:          return Color(red: 0.10, green: 0.62, blue: 0.92)   // TVDB sky blue
        case .mal:           return Color(red: 0.18, green: 0.32, blue: 0.64)   // MyAnimeList indigo
        case .anilist:       return Color(red: 0.01, green: 0.60, blue: 1.00)   // AniList #0299FF-ish
        case .kitsu:         return Color(red: 0.96, green: 0.33, blue: 0.25)   // Kitsu coral
        case .anidb:         return Color(red: 0.42, green: 0.13, blue: 0.22)   // AniDB dark maroon
        case .mangabaka:     return Color(red: 0.48, green: 0.31, blue: 0.92)   // MangaBaka violet
        case .anichart:      return Color(red: 0.00, green: 0.68, blue: 0.63)   // AniChart teal
        case .animeschedule: return Color(red: 0.20, green: 0.68, blue: 0.33)   // AnimeSchedule green
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(brandColor.opacity(0.18))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(brandColor.opacity(0.45), lineWidth: 1)
            Text(monogram)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(brandColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

// MARK: - Provider card

/// One provider's card, reworked in Batch 23 (item 2) so nothing can
/// overlap at any Dynamic Type size:
/// - Row 1: drag handle · brand tile · name + host stack · enable toggle.
/// - Row 2: priority badge · health pill (cooldown chip when active).
/// - Row 3: metrics (last success, latency) — single-line labels.
/// - Row 4: actions (Test Provider, move up, move down).
/// Every text is lineLimit(1) + minimumScaleFactor so rows keep a stable
/// height — that height stability is also what keeps the drag-reorder
/// math honest. All data comes from the real provider system.
private struct ProviderCardView: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared
    let kind: MetaProviderKind
    let domain: ProviderDomain
    let priorityIndex: Int
    let isTesting: Bool
    let onTest: () async -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    /// v2.24 — drag-to-reorder affordance (nil hides the handle).
    let dragHandle: ProviderDragHandle?

    private var status: ProviderStatus? { providers.statuses[kind] }
    private var health: ProviderHealthState { status?.state ?? .unknown }
    private var testResult: ProviderTestResult? { providers.lastTestResults[kind] }
    private var enabled: Bool { providers.isEnabled(kind) }

    private var healthColor: Color {
        switch health {
        case .healthy: return .green
        case .degraded: return .orange
        case .rateLimited: return .yellow
        case .unavailable: return .red
        case .offline: return .gray
        case .unknown: return .secondary.opacity(0.6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1 — identity: handle, brand tile, name + host, toggle.
            // The name/host stack takes the flexible space; the toggle is a
            // fixed trailing element. Nothing else shares this line.
            HStack(spacing: 10) {
                if let handle = dragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(handle.isLifted ? Color.appAccent : Color.secondary)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.25)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in
                                    switch value {
                                    case .first(true):
                                        handle.onDragStarted()
                                    case .second(true, let drag):
                                        if let drag {
                                            handle.onDragChanged(drag.translation.height)
                                        }
                                    default:
                                        break
                                    }
                                }
                                .onEnded { value in
                                    switch value {
                                    case .second(true, let drag):
                                        handle.onDragEnded(drag?.translation.height ?? 0)
                                    default:
                                        handle.onDragEnded(0)
                                    }
                                })
                        .accessibilityLabel("Reorder \(kind.displayName)")
                        .accessibilityHint("Drag up or down to change priority")
                }

                ProviderLogoTile(kind: kind)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if !enabled {
                            Text("Disabled")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text("\(providers.priorityLabel(for: kind, domain: domain)) · \(kind.apiHost)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        _ = providers.setEnabled(kind, newValue)
                        Haptics.selection()
                    }))
                .labelsHidden()
                .scaleEffect(0.8)
                .frame(width: 44)
                .accessibilityLabel("\(kind.displayName) enabled")
            }

            // Row 2 — priority + health on their own line, never competing
            // with the identity row.
            HStack(spacing: 8) {
                // Priority badge (#1 = PRIMARY — tried first).
                Text(priorityIndex == 0 ? "★" : "\(priorityIndex + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(priorityIndex == 0 ? .white : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        priorityIndex == 0 ? Color.appAccent : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(priorityIndex == 0 ? "Primary source" : "Priority \(priorityIndex + 1)")

                // Health pill — its own room to breathe.
                HStack(spacing: 5) {
                    Image(systemName: health.symbolName)
                        .font(.system(size: 9, weight: .bold))
                    Text(health.label)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(healthColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(healthColor.opacity(0.12), in: Capsule())
                .fixedSize(horizontal: true, vertical: true)

                Spacer(minLength: 4)

                // Cooldown chip — only while a cooldown is actually active.
                if let until = status?.cooldownUntil, until > Date() {
                    Label(
                        Int(until.timeIntervalSinceNow) > 90
                            ? "cooldown \(Int(until.timeIntervalSinceNow) / 60)m"
                            : "cooldown \(Int(until.timeIntervalSinceNow.rounded(.up)))s",
                        systemImage: "hourglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }

            // Row 3 — metrics: single-line labels that shrink, never wrap.
            HStack(spacing: 12) {
                if let success = status?.lastSuccess {
                    Label(
                        RelativeDateTimeFormatter().localizedString(for: success, relativeTo: Date()),
                        systemImage: "clock")
                        .lineLimit(1)
                } else {
                    Label("No requests yet", systemImage: "clock")
                        .lineLimit(1)
                }
                if let latency = status?.lastLatencyMs {
                    Label("\(latency) ms", systemImage: "speedometer")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Test result banner (latest REAL result).
            if let result = testResult {
                HStack(spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                        .fixedSize()
                    Text(result.ok
                         ? "Online · \(result.latencyMs) ms"
                         : "Unavailable · \(result.message)")
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text(RelativeDateTimeFormatter().localizedString(for: result.testedAt, relativeTo: Date()))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    (result.ok ? Color.green : Color.red).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if let note = status?.note, enabled, !note.isEmpty {
                // Honest requirement note (e.g. AniDB client registration).
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .fixedSize()
                    Text(note)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            // Row 4 — actions.
            HStack(spacing: 10) {
                Button {
                    Task { await onTest() }
                } label: {
                    HStack(spacing: 5) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "bolt.horizontal")
                        }
                        Text(isTesting ? "Testing…" : "Test Provider")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isTesting)

                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(priorityIndex == 0)
                .accessibilityLabel("Move \(kind.displayName) up")

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(priorityIndex >= providers.order(for: domain).count - 1)
                .accessibilityLabel("Move \(kind.displayName) down")
            }
        }
        .padding(12)
        .background(
            enabled
                ? Color.secondary.opacity(0.05)
                : Color.secondary.opacity(0.02),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .opacity(enabled ? 1 : 0.75)
    }
}

// MARK: - Credential rows

/// AnimeSchedule API token — the provider's v3 API requires a free token
/// from an AnimeSchedule account (their terms forbid embedding app tokens
/// in public code, so the app ships without one by design).
private struct AnimeScheduleTokenRow: View {
    @Binding var token: String
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("AnimeSchedule API Token (optional)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    withAnimation { showHelp.toggle() }
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            if showHelp {
                Text("Create a free account at animeschedule.net, open Account → API, create an application, and paste its token here. AnimeSchedule's terms require every app to use its own token — Shirox ships without one, so the provider activates only when you add yours.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField("Paste your application token", text: $token)
                .font(.caption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onChangeOf(token) { newValue in
                    AnimeScheduleProvider.shared.apiToken = newValue
                }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// AniDB client identity — AniDB's HTTP API only answers registered
/// client names, so users with their own registration fill it in here.
private struct AniDBCredentialsRow: View {
    @Binding var clientName: String
    @Binding var clientVersion: String
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("AniDB Client Identity (optional)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    withAnimation { showHelp.toggle() }
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            if showHelp {
                Text("AniDB's HTTP API rejects anonymous clients. If you have a client name + version registered with AniDB (wiki.anidb.net → API), enter them here and the provider will genuinely serve detail records. Without them it honestly reports as unavailable and the chain skips it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                TextField("Client name", text: $clientName)
                    .font(.caption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Version", text: $clientVersion)
                    .font(.caption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 110)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onChangeOf(clientName) { AniDBProvider.shared.clientName = $0 }
            .onChangeOf(clientVersion) { AniDBProvider.shared.clientVersion = $0 }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
