import SwiftUI

// MARK: - Data Sources settings (Batch 26 — complete redesign)
//
// A hub-and-detail layout a normal user can actually navigate:
//
//   DATA SOURCES (home)                PROVIDER DETAIL (per domain)
//   ┌───────────────────────┐          ┌─────────────────────────────┐
//   │ Anime     TVDB  ●     │  tap →   │ ANIME DATABASE              │
//   │ Discovery Kitsu ●     │  tap →   │ ① TVDB — description        │
//   │ Manga     MangaBaka ● │  tap →   │ FALLBACKS                   │
//   │ Schedule  AniChart ○  │  tap →   │ ② MAL ③ AniList ④ Kitsu ⑤… │
//   └───────────────────────┘          │ drag · toggle · test · reset│
//                                      └─────────────────────────────┘
//
// Every domain is a large interactive card showing the provider currently
// first in its chain, its live status, the full chain and a chevron —
// "What does my app use for anime/manga/schedules?" answers itself.
// The detail screen separates PRIMARY from FALLBACKS, uses plain-language
// descriptions (no API terminology), and offers drag reordering, toggles,
// make-primary, per-provider tests with real response times, a TEST ALL
// action, and a reset to the recommended defaults.

struct DataSourcesSettingsPage: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared

    @State private var testingKind: MetaProviderKind?
    @State private var isTestingAll = false
    @State private var animeCacheSize: Int64 = 0
    @State private var mangaCacheSize: Int64 = 0
    @State private var scheduleCacheSize: Int64 = 0
    @State private var discoveryCacheSize: Int64 = 0

    // User-configurable credentials (AnimeSchedule token / AniDB client).
    @State private var animescheduleToken = ""
    @State private var anidbClientName = ""
    @State private var anidbClientVersion = ""
    @State private var loadedCredentials = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                introCard
                domainDashboard
                searchDatabaseCard
                testAllCard
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
    }

    // MARK: - Intro

    private var introCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 46, height: 46)
                .background(Color.appAccent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("What does the app use?")
                    .font(.headline)
                Text("Tap a category to see and reorder its sources. Priority is tried top to bottom; a failing source is skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Domain dashboard (the 4 large cards)

    private var domainDashboard: some View {
        VStack(spacing: 12) {
            ProviderDomainCard(domain: .anime)
            ProviderDomainCard(domain: .discovery)
            ProviderDomainCard(domain: .manga)
            ProviderDomainCard(domain: .schedule)
        }
    }

    // MARK: - Search Database card (Batch 25, kept)

    private var searchDatabaseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.appAccent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Search Database")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("The database that answers every anime search first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(UnifiedProviderSystem.searchCapableProviders, id: \.rawValue) { kind in
                    searchDatabaseOption(kind)
                }
            }

            Text("Kitsu (default) is an anime-only database with posters and proper series pages, and it stays live while AniList and MyAnimeList are having outages. Whichever you pick, the other databases still back it up automatically. Manga search always tries MangaBaka first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func searchDatabaseOption(_ kind: MetaProviderKind) -> some View {
        let isSelected = providers.effectiveSearchPrimary == kind
        let isEnabled = providers.isEnabled(kind)
        return Button {
            providers.searchPrimary = kind
            Haptics.light()
        } label: {
            VStack(spacing: 6) {
                ProviderLogoMark(kind: kind, size: 36)
                Text(kind.shortName)
                    .font(.caption2.weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.appAccent : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .opacity(isEnabled ? 1 : 0.4)
            .background(
                isSelected ? Color.appAccent.opacity(0.12) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.appAccent.opacity(0.6) : Color.clear,
                                  lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(kind.displayName) as search database\(isSelected ? ", selected" : "")")
    }

    // MARK: - TEST ALL

    private var testAllCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.appAccent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Provider Health")
                        .font(.headline)
                    Text("Runs one real request against every enabled provider and shows the measured status — nothing is simulated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Button {
                Task { await testAll() }
            } label: {
                HStack(spacing: 8) {
                    if isTestingAll {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(isTestingAll ? "Testing every provider…" : "Test All Providers")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isTestingAll)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func testAll() async {
        isTestingAll = true
        for kind in MetaProviderKind.allCases where providers.isEnabled(kind) {
            testingKind = kind
            _ = await providers.testProvider(kind)
        }
        testingKind = nil
        isTestingAll = false
        Haptics.success()
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
            cacheRow(title: "Discovery Cache", detail: "Trending, genres, carousel and See All lists.", size: discoveryCacheSize) {
                providers.clearDiscoveryCache()
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
        discoveryCacheSize = providers.cacheSize(domain: .discovery)
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

// MARK: - Domain metadata (plain-language helpers)

extension ProviderDomain {
    /// The dashboard card title.
    var title: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .schedule: return "Schedule"
        case .discovery: return "Discovery"
        }
    }

    /// One-line plain-language description of what this domain controls.
    var subtitle: String {
        switch self {
        case .anime: return "Metadata for anime pages — artwork, characters, descriptions"
        case .manga: return "Manga search, series details and covers"
        case .schedule: return "The weekly airing timetable"
        case .discovery: return "What appears in Trending, Popular, genres and the carousel"
        }
    }

    var icon: String {
        switch self {
        case .anime: return "sparkles.tv"
        case .manga: return "text.book.closed.fill"
        case .schedule: return "calendar"
        case .discovery: return "safari.fill"
        }
    }

    /// The question the detail page answers, in the user's words.
    var question: String {
        switch self {
        case .anime: return "What does the app use for anime?"
        case .manga: return "What does the app use for manga?"
        case .schedule: return "What does the app use for the schedule?"
        case .discovery: return "What decides which anime I see?"
        }
    }

    /// The recommended chain, in display form.
    var recommendedChain: [MetaProviderKind] {
        switch self {
        case .anime: return UnifiedProviderSystem.recommendedAnimeOrder
        case .manga: return UnifiedProviderSystem.recommendedMangaOrder
        case .schedule: return UnifiedProviderSystem.recommendedScheduleOrder + [.kitsu]
        case .discovery: return UnifiedProviderSystem.recommendedDiscoveryOrder
        }
    }
}

extension MetaProviderKind {
    /// Plain-language description for a provider in a domain — no API
    /// terminology. Written so someone who has never heard of an API
    /// understands what each source does.
    func simpleDescription(domain: ProviderDomain) -> String {
        switch (self, domain) {
        case (.tvdb, _):
            return "Main source for anime artwork, characters, staff, descriptions and metadata."
        case (.mal, .anime):
            return "Fallback source used when TVDB can't provide something."
        case (.anilist, .anime):
            return "Additional fallback source for missing anime information."
        case (.kitsu, .anime):
            return "Additional anime metadata fallback — also backs up search."
        case (.anidb, _):
            return "Final anime metadata fallback. Needs a registered client to activate."
        case (.kitsu, .discovery):
            return "The discovery database — decides which anime appear in Trending, Popular, genres, the Home carousel and Surprise Me."
        case (.anilist, .discovery):
            return "Backup discovery database for trending and genre lists."
        case (.mal, .discovery):
            return "Second backup for discovery lists."
        case (.mangabaka, _):
            return "Main source for manga — search, series details and covers."
        case (.mal, .manga):
            return "Fallback source used when MangaBaka can't provide something."
        case (.anilist, .manga):
            return "Additional fallback for missing manga information."
        case (.kitsu, .manga):
            return "Additional manga fallback — keeps the Manga tab working through outages."
        case (.anichart, _):
            return "Primary schedule source — AniList's weekly airing chart."
        case (.animeschedule, _):
            return "Weekly timetable backup. Add a free API token below to activate it."
        case (.mal, .schedule):
            return "Airing-list backup from MyAnimeList when AniChart is down."
        case (.anilist, .schedule):
            return "Schedule backup from AniList's airing calendar."
        case (.kitsu, .schedule):
            return "Last resort — builds this week's timetable from Kitsu's airing list joined with TVDB's real air times."
        default:
            return "Metadata source."
        }
    }
}

extension ProviderHealthState {
    /// The user-facing status words. "Online" is only ever shown from a
    /// REAL measured success; "Not Tested" is the honest default.
    var friendlyLabel: String {
        switch self {
        case .healthy: return "Online"
        case .degraded: return "Degraded"
        case .rateLimited: return "Rate Limited"
        case .unavailable: return "Temporarily Unavailable"
        case .offline: return "Offline"
        case .unknown: return "Not Tested"
        }
    }
}

// MARK: - Domain dashboard card (the large interactive card)

/// One large card on the Data Sources home: the domain's CURRENT primary
/// provider, its live status, the chain, and a chevron. Tapping opens the
/// dedicated priority screen for that domain.
private struct ProviderDomainCard: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared
    let domain: ProviderDomain

    /// First enabled, healthy-enough provider in the domain's chain.
    private var livePrimary: MetaProviderKind? {
        let order = providers.order(for: domain).filter { providers.isEnabled($0) }
        for kind in order {
            if let st = providers.statuses[kind], st.state == .healthy, !st.isCoolingDown {
                return kind
            }
        }
        for kind in order {
            if let st = providers.statuses[kind], !st.isCoolingDown,
               st.state != .unavailable, st.state != .offline {
                return kind
            }
        }
        return order.first
    }

    private var statusColor: Color {
        guard let primary = livePrimary, let st = providers.statuses[primary] else {
            return .secondary.opacity(0.6)
        }
        switch st.state {
        case .healthy: return .green
        case .degraded, .rateLimited: return .orange
        case .unavailable: return .red
        case .offline: return .gray
        case .unknown: return .secondary.opacity(0.6)
        }
    }

    private var statusText: String {
        guard let primary = livePrimary, let st = providers.statuses[primary] else {
            return "Not Tested"
        }
        return st.state.friendlyLabel
    }

    var body: some View {
        NavigationLink {
            ProviderDomainDetailPage(domain: domain)
        } label: {
            HStack(spacing: 14) {
                // The current primary's logo — instantly answers "which
                // database does my app use for this?".
                ProviderLogoMark(kind: livePrimary ?? domain.recommendedChain[0], size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(domain.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("PRIMARY")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appAccent, in: Capsule())
                    }
                    Text(livePrimary?.displayName ?? domain.recommendedChain[0].displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // The chain, in order, as compact chips.
                    Text(chainPreview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)

                VStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 64)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the \(domain.title) sources screen")
    }

    private var chainPreview: String {
        providers.order(for: domain)
            .map { providers.isEnabled($0) ? $0.shortName : "\($0.shortName) (off)" }
            .joined(separator: " → ")
    }
}

// MARK: - Provider domain detail page (the priority screen)

/// The dedicated per-domain screen: PRIMARY and FALLBACKS sections with
/// plain-language descriptions, drag reordering, enable/disable,
/// make-primary, per-provider testing with real response times, TEST ALL
/// for the domain, and a reset to the recommended defaults.
struct ProviderDomainDetailPage: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared
    let domain: ProviderDomain

    @State private var testingKind: MetaProviderKind?
    @State private var isTestingDomain = false
    @State private var showResetConfirmation = false

    // User-configurable credentials (moved onto the relevant domains).
    @State private var animescheduleToken = ""
    @State private var anidbClientName = ""
    @State private var anidbClientVersion = ""
    @State private var loadedCredentials = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                testDomainCard
                prioritySection
                credentialsSection
                howItWorksCard
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        #if os(iOS)
        .background(Color(UIColor.systemBackground))
        #endif
        .navigationTitle(domain.title + " Sources")
        .inlineNavBar()
        .onAppear { loadCredentials() }
        .alert("Reset to Recommended?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                withAnimation {
                    providers.resetOrder(for: domain)
                }
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(domain.title) chain returns to \(domain.recommendedChain.map(\.shortName).joined(separator: " → ")).")
        }
    }

    // MARK: Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: domain.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 44, height: 44)
                .background(Color.appAccent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.question)
                    .font(.headline)
                Text(domain.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Test the whole domain

    private var testDomainCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Test every \(domain.title.lowercased()) source")
                    .font(.subheadline.weight(.semibold))
                Text("Runs one real request per enabled provider in this chain and shows the measured status and response time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await testDomain() }
            } label: {
                HStack(spacing: 6) {
                    if isTestingDomain {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(isTestingDomain ? "Testing…" : "Test All")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isTestingDomain)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func testDomain() async {
        isTestingDomain = true
        for kind in providers.order(for: domain) where providers.isEnabled(kind) {
            testingKind = kind
            _ = await providers.testProvider(kind)
        }
        testingKind = nil
        isTestingDomain = false
        Haptics.success()
    }

    // MARK: Priority list (PRIMARY + FALLBACKS)

    @ViewBuilder
    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Priority Order")
                    .font(.headline)
                Spacer()
                Button {
                    showResetConfirmation = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 2)

            // "PRIMARY — tried first" sits over the first card; the list
            // itself renders the FALLBACKS divider after it. The labels
            // are positional — whichever provider the user drags to the
            // top lands under PRIMARY.
            Text("PRIMARY — tried first")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            ReorderableProviderList(
                domain: domain,
                testingKind: testingKind,
                onTest: { kind in await runTest(kind) },
                onMakePrimary: { kind in makePrimary(kind) })

            Text("Drag the handle (≡) to reorder, or use the arrows. Turn a source off to remove it from the chain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
                .padding(.top, 2)
        }
    }

    private func runTest(_ kind: MetaProviderKind) async {
        testingKind = kind
        _ = await providers.testProvider(kind)
        testingKind = nil
    }

    /// Promotes a provider to PRIMARY (position 0) — the touch-friendly
    /// alternative to dragging all the way up.
    private func makePrimary(_ kind: MetaProviderKind) {
        var order = providers.order(for: domain)
        guard let index = order.firstIndex(of: kind), index > 0 else { return }
        order.remove(at: index)
        order.insert(kind, at: 0)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            providers.setOrder(order, for: domain)
        }
        Haptics.success()
    }

    // MARK: Credentials (domain-scoped)

    @ViewBuilder
    private var credentialsSection: some View {
        if domain == .schedule {
            AnimeScheduleTokenRow(token: $animescheduleToken)
        } else if domain == .anime {
            AniDBCredentialsRow(clientName: $anidbClientName, clientVersion: $anidbClientVersion)
        }
    }

    private func loadCredentials() {
        guard !loadedCredentials else { return }
        animescheduleToken = AnimeScheduleProvider.shared.apiToken
        anidbClientName = AniDBProvider.shared.clientName
        anidbClientVersion = AniDBProvider.shared.clientVersion
        loadedCredentials = true
    }

    // MARK: Plain-language explainer

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "The app always tries the primary source first. If it's slow or down, the next one in the list takes over automatically — you never see a blank page because one source failed.",
                systemImage: "arrow.down.circle")
            Label(
                "Turning a source off removes it from the chain everywhere in the app. You can also drag the handle or use the arrows to change the order.",
                systemImage: "hand.draw")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Drag-and-drop priority list (Batch 26 rework)

/// The reorderable chain: long-press a card's handle (≡) to lift it, drag
/// vertically — neighbors slide aside in real time with a haptic tick at
/// every slot crossing — and release to commit. The committed order is
/// persisted instantly and read by every request chain in the app; the
/// arrow buttons and "Make Primary" remain for precise, accessible
/// single-step control. The FALLBACKS divider renders after the first
/// card (positional — whichever provider is first sits under PRIMARY).
private struct ReorderableProviderList: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared
    let domain: ProviderDomain
    let testingKind: MetaProviderKind?
    let onTest: (MetaProviderKind) async -> Void
    let onMakePrimary: (MetaProviderKind) -> Void

    /// Estimated per-card stride for the drag-reorder math. Cards vary in
    /// height (metrics/test banners), so reordering snaps at this
    /// granularity; the arrows give exact single-step control.
    private let rowStride: CGFloat = 176

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
        return from < target ? -rowStride : rowStride
    }

    var body: some View {
        let order = providers.order(for: domain)
        VStack(spacing: 8) {
            ForEach(Array(order.enumerated()), id: \.element) { index, kind in
                // The FALLBACKS divider — positional, after the first card.
                if index == 1 {
                    Text("FALLBACKS — used when the sources above fail")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                        .offset(y: neighborShift(for: index - 1))
                        .zIndex(-1)
                }
                ProviderPriorityCard(
                    kind: kind,
                    domain: domain,
                    priorityIndex: index,
                    isTesting: testingKind == kind,
                    onTest: { await onTest(kind) },
                    onMoveUp: index > 0 ? { move(kind: kind, delta: -1) } : nil,
                    onMoveDown: index < order.count - 1 ? { move(kind: kind, delta: 1) } : nil,
                    onMakePrimary: index > 0 ? { onMakePrimary(kind) } : nil,
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

    /// Commits the drop: reorders the persisted chain order, then clears
    /// the drag state so everything settles into place.
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

// MARK: - Provider priority card

/// One provider's card in the priority list. Large touch-friendly controls,
/// plain-language description, REAL health + latency, numbered priority
/// badge (①-style), enable toggle, Make Primary, and Test.
private struct ProviderPriorityCard: View {
    @ObservedObject private var providers = UnifiedProviderSystem.shared
    let kind: MetaProviderKind
    let domain: ProviderDomain
    let priorityIndex: Int
    let isTesting: Bool
    let onTest: () async -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onMakePrimary: (() -> Void)?
    let dragHandle: ProviderDragHandle?

    private var status: ProviderStatus? { providers.statuses[kind] }
    private var health: ProviderHealthState { status?.state ?? .unknown }
    private var testResult: ProviderTestResult? { providers.lastTestResults[kind] }
    private var enabled: Bool { providers.isEnabled(kind) }
    private var isPrimary: Bool { priorityIndex == 0 }

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
            // Row 1 — identity: handle, brand tile, name + status, toggle.
            HStack(spacing: 10) {
                if let handle = dragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(handle.isLifted ? Color.appAccent : Color.secondary)
                        .frame(width: 28, height: 32)
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

                ProviderLogoMark(kind: kind, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(kind.displayName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if !enabled {
                            Text("Off")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .fixedSize()
                        }
                    }
                    // Status line: dot + label + measured latency.
                    HStack(spacing: 5) {
                        Circle().fill(healthColor)
                            .frame(width: 7, height: 7)
                        Text(health.friendlyLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let latency = status?.lastLatencyMs, health == .healthy {
                            Text("· \(latency) ms")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
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
                .scaleEffect(0.85)
                .frame(width: 46)
                .accessibilityLabel("\(kind.displayName) enabled")
            }

            // Row 2 — the plain-language description (what this source
            // actually does, in words a non-technical user understands).
            Text(kind.simpleDescription(domain: domain))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            // Test result banner (latest REAL result).
            if let result = testResult {
                HStack(spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                        .fixedSize()
                    Text(result.ok
                         ? "Online · \(result.latencyMs) ms"
                         : "\(result.message)")
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

            // Row 3 — actions: Test · Make Primary · arrows.
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
                        Text(isTesting ? "Testing…" : "Test")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isTesting)

                if let onMakePrimary = onMakePrimary, !isPrimary {
                    Button(action: onMakePrimary) {
                        HStack(spacing: 4) {
                            Image(systemName: "star")
                                .font(.system(size: 10, weight: .bold))
                            Text("Make Primary")
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Make \(kind.displayName) the primary source")
                }

                if let onMoveUp = onMoveUp {
                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Move \(kind.displayName) up")
                }
                if let onMoveDown = onMoveDown {
                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Move \(kind.displayName) down")
                }
            }
        }
        .padding(12)
        .background(
            enabled
                ? Color.secondary.opacity(0.05)
                : Color.secondary.opacity(0.02),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .opacity(enabled ? 1 : 0.75)
        .overlay(alignment: .topLeading) {
            // The numbered priority badge: ① on the primary, ② ③ ④ … on
            // fallbacks — the user's requested visual language.
            Text(isPrimary ? "1" : "\(priorityIndex + 1)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(isPrimary ? Color.appAccent : Color.secondary.opacity(0.55),
                            in: Circle())
                .offset(x: -6, y: -6)
                .accessibilityLabel(isPrimary ? "Primary source" : "Priority \(priorityIndex + 1)")
        }
    }
}
// MARK: - Provider logo marks (Batch 25 rework)
//
// Hand-drawn SwiftUI brand marks — each provider gets its own instantly
// recognizable SHAPE (AniList's three bars, TVDB's screen, Kitsu's ember,
// MangaBaka's open book, AniDB's database cylinder, …) in its brand color,
// not a generic two-letter monogram. Zero network dependency: a logo URL
// would die exactly when its provider is down — which is when the user
// looks at this page. Stable at every Dynamic Type size via the `size`
// parameter (34pt in card rows, 16pt in the chain chips, 36pt in the
// Search Database picker).

private struct ProviderLogoMark: View {
    let kind: MetaProviderKind
    var size: CGFloat = 34

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
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(brandColor.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(brandColor.opacity(0.45), lineWidth: 1)
            mark
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch kind {
        case .anilist:       AniListBarsMark(color: brandColor, size: size)
        case .mal:           MALWordMark(color: brandColor, size: size)
        case .kitsu:         KitsuEmberMark(color: brandColor, size: size)
        case .tvdb:          TVScreenMark(color: brandColor, size: size)
        case .mangabaka:     BookMark(color: brandColor, size: size)
        case .anidb:         DatabaseCylinderMark(color: brandColor, size: size)
        case .anichart:      ChartBarsMark(color: brandColor, size: size)
        case .animeschedule: ClockMark(color: brandColor, size: size)
        }
    }
}

/// AniList — the three ascending bars of its wordmark.
private struct AniListBarsMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.07) {
            Capsule().fill(color.opacity(0.6))
                .frame(width: size * 0.10, height: size * 0.20)
            Capsule().fill(color)
                .frame(width: size * 0.10, height: size * 0.44)
            Capsule().fill(color.opacity(0.8))
                .frame(width: size * 0.10, height: size * 0.32)
        }
        .frame(width: size, height: size)
    }
}

/// MyAnimeList — a wordmark tile (its own logo is literally "MAL").
private struct MALWordMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Text("MAL")
            .font(.system(size: size * 0.30, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.11)
            .padding(.vertical, size * 0.04)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// Kitsu — a stylized ember/flame.
private struct KitsuEmberMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Path { p in
            let w = size * 0.34
            let h = size * 0.44
            let cx = size * 0.5
            let top = size * 0.27
            let bottom = top + h
            p.move(to: CGPoint(x: cx, y: top))
            p.addCurve(to: CGPoint(x: cx + w * 0.5, y: bottom - w * 0.25),
                       control1: CGPoint(x: cx + w * 0.30, y: top + h * 0.30),
                       control2: CGPoint(x: cx + w * 0.5, y: bottom - w * 0.85))
            p.addCurve(to: CGPoint(x: cx - w * 0.5, y: bottom - w * 0.25),
                       control1: CGPoint(x: cx + w * 0.5, y: bottom),
                       control2: CGPoint(x: cx - w * 0.5, y: bottom))
            p.addCurve(to: CGPoint(x: cx, y: top),
                       control1: CGPoint(x: cx - w * 0.5, y: bottom - w * 0.85),
                       control2: CGPoint(x: cx - w * 0.30, y: top + h * 0.30))
            p.closeSubpath()
        }
        .fill(color)
        .frame(width: size, height: size)
    }
}

/// TVDB — a TV screen on a stand.
private struct TVScreenMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        VStack(spacing: size * 0.04) {
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .strokeBorder(color, lineWidth: max(1.2, size * 0.05))
                .frame(width: size * 0.46, height: size * 0.30)
            VStack(spacing: size * 0.015) {
                Rectangle()
                    .fill(color)
                    .frame(width: size * 0.045, height: size * 0.06)
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.22, height: size * 0.035)
            }
        }
        .frame(width: size, height: size)
    }
}

/// MangaBaka — an open book.
private struct BookMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.012) {
            RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                .fill(color.opacity(0.85))
                .frame(width: size * 0.185, height: size * 0.28)
                .rotationEffect(.degrees(-8))
            RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                .fill(color.opacity(0.85))
                .frame(width: size * 0.185, height: size * 0.28)
                .rotationEffect(.degrees(8))
        }
        .frame(width: size, height: size)
    }
}

/// AniDB — the classic database cylinder.
private struct DatabaseCylinderMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        let w = size * 0.30
        let capH = size * 0.10
        return VStack(spacing: 0) {
            Capsule().fill(color).frame(width: w, height: capH)
            Rectangle().fill(color).frame(width: w, height: size * 0.20)
            Capsule().fill(color).frame(width: w, height: capH)
        }
        .frame(width: size, height: size)
    }
}

/// AniChart — rising chart bars.
private struct ChartBarsMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.055) {
            Capsule().fill(color.opacity(0.6))
                .frame(width: size * 0.085, height: size * 0.16)
            Capsule().fill(color.opacity(0.85))
                .frame(width: size * 0.085, height: size * 0.25)
            Capsule().fill(color)
                .frame(width: size * 0.085, height: size * 0.36)
        }
        .frame(width: size, height: size)
    }
}

/// AnimeSchedule — a clock face.
private struct ClockMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        let r = size * 0.17
        let c = size * 0.5
        let lw = max(1.2, size * 0.055)
        return ZStack {
            Circle()
                .strokeBorder(color, lineWidth: lw)
                .frame(width: r * 2, height: r * 2)
            Path { p in
                p.move(to: CGPoint(x: c, y: c))
                p.addLine(to: CGPoint(x: c, y: c - r * 0.68))
                p.move(to: CGPoint(x: c, y: c))
                p.addLine(to: CGPoint(x: c + r * 0.52, y: c + r * 0.18))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: size, height: size)
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
