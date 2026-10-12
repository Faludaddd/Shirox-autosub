import SwiftUI

// MARK: - Language grouping (v2.36)

/// One language group of installed modules: the group's display title and
/// its modules sorted alphabetically by source name. Modules that don't
/// declare a language land in the trailing "Other" group — never invented,
/// never dropped.
struct ModuleLanguageGroup: Identifiable {
    let title: String
    let modules: [ModuleDefinition]
    var id: String { title }
}

enum ModuleGrouping {
    /// Groups modules by their declared `language`, each group sorted
    /// alphabetically (case-insensitive, stable) by source name, groups
    /// themselves ordered alphabetically with "Other" last.
    static func groups(from modules: [ModuleDefinition]) -> [ModuleLanguageGroup] {
        let keyed = Dictionary(grouping: modules) { module in
            let raw = (module.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        var groups: [ModuleLanguageGroup] = []
        for (key, list) in keyed where key != nil {
            groups.append(ModuleLanguageGroup(
                title: key!.capitalized,
                modules: list.sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }))
        }
        groups.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if let others = keyed[nil], !others.isEmpty {
            groups.append(ModuleLanguageGroup(
                title: "Other",
                modules: others.sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }))
        }
        return groups
    }
}

// MARK: - Source health (v2.36)

/// The real state of a module's SOURCE — where its manifest lives. Verified
/// by an actual network probe, never assumed: the module's `jsonUrl` is
/// fetched and the HTTP verdict is read.
enum ModuleSourceHealth: Equatable {
    case reachable
    /// The manifest is GONE (HTTP 404/410): the source has been
    /// discontinued — the module can still run from its cached script, but
    /// it will never update again and its site may follow.
    case discontinued
    /// The source couldn't be reached right now (network error, timeout,
    /// server error). Temporary until proven otherwise.
    case unreachable(String)
    /// No known source URL — installed before sources were tracked. No
    /// verdict, honestly none.
    case noSourceURL

    var title: String {
        switch self {
        case .reachable: return "Source OK"
        case .discontinued: return "Source discontinued"
        case .unreachable: return "Source unreachable"
        case .noSourceURL: return "Source unknown"
        }
    }
}

@MainActor
enum ModuleSourceProber {
    /// Probes one module's source manifest URL. Local files are inherently
    /// present; remote manifests get a real GET with a short timeout —
    /// 404/410 reads as discontinued, anything else unreachable-by-name.
    static func probe(_ module: ModuleDefinition) async -> ModuleSourceHealth {
        guard let json = module.jsonUrl, let url = URL(string: json) else {
            return .noSourceURL
        }
        if url.isFileURL { return .reachable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .reachable }
            switch http.statusCode {
            case 200..<300: return .reachable
            case 404, 410: return .discontinued
            default: return .unreachable("HTTP \(http.statusCode)")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared
    @Environment(\.dismiss) private var dismiss
    /// In a sheet (onboarding), a Done button closes it — a sheet can't always be swiped away.
    var showsDone = false
    @State private var moduleURL = ""
    @State private var isRefreshing = false
    @State private var isAddingModule = false
    @State private var addModuleError: String?
    @State private var isAddingLocalModule = false
    @State private var isAddingJellyfinModule = false
    /// v2.31 (original's feature): test a module by running it the way playing
    /// something runs it — search, an episode list, a stream URL.
    @State private var testReport: (module: ModuleDefinition, result: ModuleCheckResult)?
    @State private var testingModuleID: String? = nil
    /// v2.32 — the module whose details page is open (icon tap on a row).
    @State private var detailModule: ModuleDefinition?
    @FocusState private var isTextFieldFocused: Bool
    // v2.36 — real source health per module (keyed by module id), probed
    // on open and re-probed from the refresh button. [String: ModuleSourceHealth]
    @State private var sourceHealth: [String: ModuleSourceHealth] = [:]
    @State private var isProbingSources = false

    private let localFilesModuleURL = "https://raw.githubusercontent.com/xibrox/local-files-module/refs/heads/main/local.json"
    private let jellyfinModuleURL = "https://raw.githubusercontent.com/xibrox/jellyfin-module/refs/heads/main/jellyfin.json"

    var body: some View {
        List {
                Section {
                    addModuleCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if !isLocalModuleInstalled {
                    Section {
                        localFilesPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !isJellyfinModuleInstalled {
                    Section {
                        jellyfinPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let error = addModuleError {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let error = moduleManager.errorMessage {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(ProviderType.userProviders, id: \.self) { type in
                        builtInProviderRow(type)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Built-in Providers")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                if moduleManager.modules.isEmpty {
                    Section {
                        emptyModulesView
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } else {
                    // v2.36 — modules grouped by LANGUAGE, each group
                    // sorted alphabetically by source name. The flat
                    // drag-to-reorder list is gone by design: a grouped,
                    // alphabetized listing can't be meaningfully
                    // hand-ordered (the module PICKER still lists every
                    // module; selection itself is unchanged).
                    ForEach(ModuleGrouping.groups(from: moduleManager.modules)) { group in
                        Section {
                            ForEach(group.modules) { module in
                                moduleRow(module)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                                    .contextMenu {
                                        Button {
                                            detailModule = module
                                        } label: {
                                            Label("Module Details", systemImage: "info.circle")
                                        }
                                        Button {
                                            testModule(module)
                                        } label: {
                                            Label("Test Module", systemImage: "stethoscope")
                                        }
                                        Button {
                                            Task { await probeModule(module) }
                                        } label: {
                                            Label("Check Source", systemImage: "network")
                                        }
                                        Button(role: .destructive) {
                                            removeModule(module)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                    .font(.caption2)
                                Text("\(group.title) — \(group.modules.count) module\(group.modules.count == 1 ? "" : "s")")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #elseif !os(tvOS)
            .listStyle(.inset)
            #endif
            .hideScrollContentBackground()
            #if os(iOS)
            .scrollDismissesKeyboardImmediately()
            #endif
            #if os(iOS)
            .background(Color(.systemBackground))
            #elseif os(tvOS)
            // TODO: add back background color
            #else
            .background(Color(NSColor.windowBackgroundColor))
            #endif
            .navigationTitle("Modules")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert(
                testReport.map { "Test: \($0.module.sourceName) " + Self.testOutcomeTitle($0.result) } ?? "Test Module",
                isPresented: Binding(
                    get: { testReport != nil },
                    set: { if !$0 { testReport = nil } }
                ),
                presenting: testReport
            ) { _ in
                Button("OK", role: .cancel) { testReport = nil }
            } message: { report in
                Text(Self.testOutcomeMessage(report.result))
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            isRefreshing = true
                            async let updates: Void = moduleManager.checkForUpdates()
                            async let probes: Void = probeAllSources()
                            _ = await (updates, probes)
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .disabled(moduleManager.modules.isEmpty || isRefreshing)
                }
            }
        .modifier(DoneItem(isShown: showsDone) { dismiss() })
        .onChangeOf(moduleURL) { _ in
            addModuleError = nil
            moduleManager.errorMessage = nil
        }
        // v2.36 — probe every module's source once when the page opens
        // (a few light GETs), so discontinued/unreachable sources are
        // identified by their REAL verdicts, not guesses.
        .task { await probeAllSources() }
        // v2.32 — tapping a module's icon opens its details page; the rest of
        // the row keeps its select/deactivate behavior.
        .navigationDestinationCompat(item: $detailModule) { module in
            ModuleDetailView(source: .installed(module))
        }
    }

    // MARK: - Source probing

    /// Probes every installed module's source URL concurrently; each
    /// verdict lands in `sourceHealth` the moment it arrives.
    private func probeAllSources() async {
        guard !moduleManager.modules.isEmpty else { return }
        isProbingSources = true
        await withTaskGroup(of: (String, ModuleSourceHealth).self) { group in
            for module in moduleManager.modules {
                group.addTask {
                    await (module.id, ModuleSourceProber.probe(module))
                }
            }
            for await (id, health) in group {
                sourceHealth[id] = health
            }
        }
        isProbingSources = false
    }

    private func probeModule(_ module: ModuleDefinition) async {
        sourceHealth[module.id] = await ModuleSourceProber.probe(module)
    }

    // MARK: - Add Module Card
    private var addModuleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Module")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                TextField("Module JSON URL", text: $moduleURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .focused($isTextFieldFocused)
                    .disabled(isAddingModule)
                    .onSubmit {
                        addModule()
                    }

                // Paste button — reads clipboard and fills URL field
                if !isAddingModule {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Clear button — empties the URL field
                if !moduleURL.isEmpty && !isAddingModule {
                    Button {
                        moduleURL = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    addModule()
                } label: {
                    if isAddingModule {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(moduleURL.isEmpty ? Color.secondary : Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(moduleURL.isEmpty || isAddingModule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    // MARK: - Local Files Promo
    private var isLocalModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isLocalPlayback }
    }

    private var localFilesPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Play Local Files")
                        .font(.headline)
                    Text("Watch videos from your device's Files app — subtitles, AirPlay, PiP, and Continue Watching included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(localFilesModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyLocalFilesURL()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addLocalFilesModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingLocalModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("Add Module", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingLocalModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Jellyfin Promo
    private var isJellyfinModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isJellyfin }
    }

    private var jellyfinPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect Jellyfin")
                        .font(.headline)
                    Text("Stream your own Jellyfin server — browse your library, resume where you left off, and sync watch state back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(jellyfinModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyJellyfinURL()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addJellyfinModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingJellyfinModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("Add Module", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingJellyfinModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Error Banner
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)   // Error remains red for clarity
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Color.red)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(iOS)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        #elseif os(tvOS)
        // TODO: add back background color
        #else
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        #endif
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Built-in Provider Row
    private func builtInProviderRow(_ type: ProviderType) -> some View {
        let isChosen = providerManager.orderedProviders.first?.providerType == type
        let isSelected = moduleManager.activeModule == nil
        let isDown = isChosen && providerManager.fallbackActive

        return Button {
            if moduleManager.activeModule != nil {
                moduleManager.deselectModule()
            }
            providerManager.selectProvider(type)
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: type.iconURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure, .empty:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    @unknown default:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName).font(.headline)
                    HStack(spacing: 6) {
                        Text("Built-in · anime metadata")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isDown {
                            Text("Unavailable")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Spacer()
                if isSelected && isChosen && !isDown {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                (isSelected && isChosen) ? Color.primary.opacity(0.08) : Color.black.opacity(0.001),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .opacity(isDown ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.2), value: providerManager.fallbackActive)
    }

    // MARK: - Module Row

    /// v2.31 — runs `ModuleCheck` (the original's module test) and reports
    /// the verdict. A Cloudflare wall is reported as "needs verification", not
    /// as a broken module.
    private func testModule(_ module: ModuleDefinition) {
        guard testingModuleID == nil else { return }
        testingModuleID = module.id
        Task { @MainActor in
            let result = await ModuleCheck.check(module)
            testingModuleID = nil
            testReport = (module, result)
        }
    }

    static func testOutcomeTitle(_ result: ModuleCheckResult) -> String {
        switch result {
        case .passed: return "passed"
        case .needsVerification: return "needs verification"
        case .failed: return "failed"
        case .skipped: return "was skipped"
        }
    }

    static func testOutcomeMessage(_ result: ModuleCheckResult) -> String {
        switch result {
        case .passed:
            return "The module searched, listed an episode's list and reached a playable stream."
        case .needsVerification(let host):
            return "\(host) answered with a Cloudflare check. Pass it the next time you play something from this module — that's not a sign the module is broken."
        case .failed(let step, let reason):
            return "It got as far as \(step.label.lowercased()) and then: \(reason)"
        case .skipped(let reason):
            return reason
        }
    }

    private func moduleRow(_ module: ModuleDefinition) -> some View {
        let isActive = moduleManager.activeModule?.id == module.id
        return Button {
            if !isActive {
                moduleManager.selectModule(module)
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
        } label: {
            HStack(spacing: 14) {
                // v2.32 — the icon is its own tap target now: it opens the
                // module's details page. Everything else in the row still
                // selects / stays selected.
                Button {
                    detailModule = module
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    Group {
                        CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appAccent)
                            .offset(x: 5, y: 5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(module.sourceName)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName).font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(module.version)").font(.caption).foregroundStyle(.secondary)
                        if let author = module.author, !author.name.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(author.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if let lang = module.language, !lang.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(lang.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // v2.36 — the module's REAL source verdict, probed from
                    // its manifest URL. Healthy sources stay quiet; problems
                    // are named and explained, never guessed.
                    sourceHealthView(module)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isActive ? Color.primary.opacity(0.08) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    /// The honest per-module source status: nothing when healthy (or before
    /// the first verdict lands), a named explanation when there's a problem.
    @ViewBuilder
    private func sourceHealthView(_ module: ModuleDefinition) -> some View {
        switch sourceHealth[module.id] {
        case .discontinued:
            Label("Source discontinued — the manifest is gone (404). The cached copy still runs, but this module can never update; its site may stop working too.", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable(let reason):
            Label("Source unreachable right now (\(reason)). May be temporary — refresh to re-check.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .noSourceURL:
            Label("Source URL unknown — installed before sources were tracked. Test the module to check it works.", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .reachable, .none:
            // Healthy (or not yet probed): no line at all. A module whose
            // source is fine shouldn't wear a badge.
            EmptyView()
        }
    }

    // MARK: - Empty State
    private var emptyModulesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No modules installed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Paste a module JSON URL above to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.clear)
    }

    // MARK: - Actions
    private func addModule() {
        let trimmedURL = moduleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            addModuleError = "Invalid URL"
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            return
        }

        withAnimation {
            addModuleError = nil
            isAddingModule = true
        }

        Task {
            do {
                try await moduleManager.addModule(from: url)
                // v2.31 (original's behaviour): test a module the moment it's
                // added — a module that installs fine can still be broken.
                if moduleManager.errorMessage == nil, let added = moduleManager.modules.last {
                    let result = await ModuleCheck.check(added)
                    testReport = (added, result)
                }
            } catch { /* errorMessage already set */ }

            await MainActor.run {
                withAnimation {
                    isAddingModule = false
                    if moduleManager.errorMessage == nil {
                        moduleURL = ""
                        isTextFieldFocused = false
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func copyLocalFilesURL() {
        #if os(iOS)
        UIPasteboard.general.string = localFilesModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localFilesModuleURL, forType: .string)
        #endif
    }

    /// Reads the clipboard and fills the module URL field. Validates that the
    /// clipboard content looks like a URL.
    private func pasteFromClipboard() {
        #if os(iOS)
        guard let clipboard = UIPasteboard.general.string else { return }
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            moduleURL = trimmed
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #elseif os(macOS)
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { moduleURL = trimmed }
        #endif
    }

    private func addLocalFilesModule() {
        guard let url = URL(string: localFilesModuleURL) else {
            addModuleError = "Invalid URL"
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingLocalModule = true
        }
        Task {
            do { try await moduleManager.addModule(from: url) } catch { /* errorMessage already set */ }

            await MainActor.run {
                withAnimation {
                    isAddingLocalModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func copyJellyfinURL() {
        #if os(iOS)
        UIPasteboard.general.string = jellyfinModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jellyfinModuleURL, forType: .string)
        #endif
    }

    private func addJellyfinModule() {
        guard let url = URL(string: jellyfinModuleURL) else {
            addModuleError = "Invalid URL"
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingJellyfinModule = true
        }
        Task {
            do { try await moduleManager.addModule(from: url) } catch { /* errorMessage already set */ }

            await MainActor.run {
                withAnimation {
                    isAddingJellyfinModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func removeModule(_ module: ModuleDefinition) {
        moduleManager.removeModule(module)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

/// The Done button of a sheet, left out rather than left empty elsewhere: from iOS 26 an
/// empty item still draws its glass. (A bare `if` in a toolbar builder needs iOS 16; before
/// it, the condition lives inside the item.)
private struct DoneItem: ViewModifier {
    let isShown: Bool
    let done: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.toolbar {
                if isShown {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isShown { Button("Done", action: done) }
                }
            }
        }
    }
}
