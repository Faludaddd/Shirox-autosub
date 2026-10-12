import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Module Details (v2.32)
//
// One dedicated details page for a module, opened by tapping the module's
// ICON — in the Module Store's tiles and in the installed-modules list.
// Both shapes the module system has are covered:
//
//   • a store listing (`StoreModuleItem`) — everything the cufiy.net
//     library knows: description, version, author, type, language,
//     install count, curation flags, note. Install runs right here.
//   • an installed module (`ModuleDefinition`) — the manifest's real fields
//     plus the actions the module system actually supports: set active /
//     deactivate, test, per-module update check, remove.
//
// Nothing is invented: rows only appear for fields the module really
// carries, actions only for operations ModuleManager/ModuleCheck really
// perform, and a link section offers the module's actual manifest URL.

struct ModuleDetailView: View {
    enum Source {
        case store(StoreModuleItem)
        case installed(ModuleDefinition)
    }

    let source: Source

    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Async states

    @State private var isInstalling = false
    @State private var installError: String?
    @State private var isTesting = false
    @State private var testReport: (module: ModuleDefinition, result: ModuleCheckResult)?
    @State private var isUpdating = false
    @State private var confirmRemove = false

    // MARK: - Display fields (real data only)

    private var name: String {
        switch source {
        case .store(let item): return item.name
        case .installed(let module): return module.sourceName
        }
    }

    private var iconURLString: String? {
        switch source {
        case .store(let item): return item.iconUrl
        case .installed(let module): return module.iconUrl
        }
    }

    private var iconBase64: String? {
        switch source {
        case .store: return nil
        case .installed(let module): return module.iconData
        }
    }

    private var authorName: String? {
        switch source {
        case .store(let item): return item.author
        case .installed(let module): return module.author?.name
        }
    }

    private var versionText: String? {
        switch source {
        case .store(let item): return item.version
        case .installed(let module): return module.version
        }
    }

    /// The module's actual URL: the manifest it installs/updates from.
    private var linkURL: URL? {
        switch source {
        case .store(let item): return URL(string: item.manifestUrl)
        case .installed(let module):
            if let json = module.jsonUrl, let url = URL(string: json) { return url }
            return URL(string: module.scriptUrl)
        }
    }

    private var descriptionText: String? {
        switch source {
        case .store(let item): return item.description
        // Installed manifests carry no description field — none is shown.
        case .installed: return nil
        }
    }

    /// The installed twin of whatever this page is describing (nil when the
    /// module isn't installed). Store entries match by source name — the
    /// same match the store's Installed badges use.
    private var installedModule: ModuleDefinition? {
        switch source {
        case .installed(let module):
            return moduleManager.modules.first { $0.id == module.id } ?? module
        case .store(let item):
            return moduleManager.modules.first { $0.sourceName == item.name }
        }
    }

    private var isActiveSource: Bool {
        guard let installed = installedModule else { return false }
        return moduleManager.activeModule?.id == installed.id
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if let descriptionText, !descriptionText.isEmpty {
                    descriptionCard(descriptionText)
                }
                if let installed = installedModule {
                    installedInfoCard(installed)
                } else if case .store(let item) = source {
                    storeInfoCard(item)
                }
                actionCard
                linkCard
            }
            .padding(14)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(name)
        .inlineNavBar()
        .alert(
            testReport.map { "Test: \($0.module.sourceName) " + ModuleListView.testOutcomeTitle($0.result) } ?? "Test Module",
            isPresented: Binding(
                get: { testReport != nil },
                set: { if !$0 { testReport = nil } }
            ),
            presenting: testReport
        ) { _ in
            Button("OK", role: .cancel) { testReport = nil }
        } message: { report in
            Text(ModuleListView.testOutcomeMessage(report.result))
        }
        .alert("Remove Module", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                if let installed = installedModule {
                    moduleManager.removeModule(installed)
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(name)\" will be removed from your installed modules. You can install it again from the Module Store at any time.")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(urlString: iconURLString ?? "", base64String: iconBase64)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)

            Text(name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let author = authorName, !author.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption)
                    Text(author)
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let versionText {
                    badge(text: "v\(versionText)", systemImage: "number.circle", tint: Color.appAccent)
                }
                if installedModule != nil {
                    badge(text: "Installed", systemImage: "checkmark.circle.fill", tint: .green)
                } else {
                    badge(text: "Not Installed", systemImage: "arrow.down.circle", tint: .secondary)
                }
                if isActiveSource {
                    badge(text: "Active Source", systemImage: "antenna.radiowaves.left.and.right", tint: .orange)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Description

    private func descriptionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Description", icon: "text.alignleft")
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Info (installed manifest fields)

    private func installedInfoCard(_ module: ModuleDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("About", icon: "info.circle")
                .padding(.bottom, 6)

            infoRow("tag", "Type", module.type)
            infoRow("globe", "Language", module.language)
            infoRow("waveform", "Stream type", module.streamType)
            infoRow("hifispeaker.2.fill", "Quality", module.quality)
            if let softsub = module.softsub {
                infoRow("captions.bubble", "Soft subtitles", softsub ? "Yes" : "No")
            }
            if let asyncJS = module.asyncJS {
                infoRow("curlybraces.square", "Async JS", asyncJS ? "Yes" : "No")
            }
            if module.isManga {
                infoRow("book", "Content", "Manga")
            }
            if module.isNovel {
                infoRow("books.vertical", "Content", "Novels")
            }
            if module.isLocalPlayback {
                infoRow("folder", "Content", "Local files")
            }
            if module.isJellyfin {
                infoRow("server.rack", "Content", "Jellyfin")
            }

            if let health = moduleManager.health(for: module) {
                Divider().padding(.vertical, 8)
                HStack(spacing: 10) {
                    Image(systemName: health.status.icon)
                        .foregroundStyle(health.status.color)
                        .frame(width: 24)
                    Text("Last activity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(health.status == .healthy ? "Working" : (health.cloudflareBlockedHost != nil ? "Needs verification" : health.status == .blocked ? "Blocked" : "Issues seen"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(health.status.color)
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Info (store listing fields)

    private func storeInfoCard(_ item: StoreModuleItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("About", icon: "info.circle")
                .padding(.bottom, 6)

            infoRow("tag", "Type", item.type)
            infoRow("globe", "Language", item.language)
            if let installs = item.installCount {
                infoRow("arrow.down.circle", "Installs", installs.formatted())
            }
            if let featured = item.featured, featured > 0 {
                infoRow("star.fill", "Curation", "Featured in the library")
            }
            if let note = item.note, !note.isEmpty {
                Divider().padding(.vertical, 8)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(_ icon: String, _ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            return AnyView(
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 2)
            )
        }
        return AnyView(EmptyView())
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appAccent)
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 2)
    }

    private var cardFill: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #elseif os(tvOS)
        return Color.secondary.opacity(0.12)
        #else
        return Color(.controlBackgroundColor)
        #endif
    }

    // MARK: - Actions

    private var actionCard: some View {
        VStack(spacing: 10) {
            if let installed = installedModule {
                // Set active / deactivate — the module system's "enable".
                if isActiveSource {
                    Button {
                        moduleManager.deselectModule()
                        ToastManager.shared.show(
                            title: name, message: "Deactivated as the active source.",
                            icon: "pause.circle.fill", iconColor: .secondary)
                    } label: {
                        actionLabel("Deactivate as Source", systemImage: "pause.circle", prominent: false, destructive: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        moduleManager.selectModule(installed)
                        ToastManager.shared.show(
                            title: name, message: "Set as the active source.",
                            icon: "antenna.radiowaves.left.and.right", iconColor: .green)
                    } label: {
                        actionLabel("Set as Active Source", systemImage: "antenna.radiowaves.left.and.right", prominent: true, destructive: false)
                    }
                    .buttonStyle(.plain)
                }

                // Test — the same live check the module list's menu runs.
                Button {
                    testModule(installed)
                } label: {
                    actionLabel(isTesting ? "Testing…" : "Test Module", systemImage: "stethoscope", prominent: false, destructive: false)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)

                // Per-module update check.
                Button {
                    checkForUpdate(installed)
                } label: {
                    actionLabel(isUpdating ? "Checking…" : "Check for Update", systemImage: "arrow.clockwise", prominent: false, destructive: false)
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)

                // Remove.
                Button {
                    confirmRemove = true
                } label: {
                    actionLabel("Remove", systemImage: "trash", prominent: false, destructive: true)
                }
                .buttonStyle(.plain)
            } else if case .store(let item) = source {
                // Install — the store's own flow, run from the details page.
                Button {
                    install(item)
                } label: {
                    actionLabel(isInstalling ? "Installing…" : "Install", systemImage: "arrow.down.circle.fill", prominent: true, destructive: false)
                }
                .buttonStyle(.plain)
                .disabled(isInstalling)

                if let error = installError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func actionLabel(_ title: String, systemImage: String, prominent: Bool, destructive: Bool) -> some View {
        HStack(spacing: 8) {
            if isBusy(title) {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(prominent
                      ? AnyShapeStyle(Color.appAccent)
                      : destructive
                      ? AnyShapeStyle(Color.red.opacity(0.12))
                      : AnyShapeStyle(Color.appAccent.opacity(0.12)))
        )
        .foregroundStyle(prominent ? Color.appAccentForeground : (destructive ? .red : Color.appAccent))
    }

    private func isBusy(_ title: String) -> Bool {
        (isInstalling && title.hasPrefix("Installing")) ||
        (isTesting && title.hasPrefix("Testing")) ||
        (isUpdating && title.hasPrefix("Checking"))
    }

    // MARK: - Link card

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Module Link", icon: "link")

            if let url = linkURL {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        copyLink(url)
                    } label: {
                        actionLabel("Copy Link", systemImage: "doc.on.doc", prominent: false, destructive: false)
                    }
                    .buttonStyle(.plain)

                    Button {
                        openLink(url)
                    } label: {
                        actionLabel("Open Link", systemImage: "safari", prominent: false, destructive: false)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("This module doesn't carry a URL — it was restored from a backup that predates manifest links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Actions (implementations)

    private func install(_ item: StoreModuleItem) {
        guard let url = URL(string: item.manifestUrl) else {
            installError = "This listing carries an invalid module URL."
            return
        }
        installError = nil
        isInstalling = true
        Task {
            do {
                try await moduleManager.addModule(from: url)
                await MainActor.run {
                    isInstalling = false
                    ToastManager.shared.show(
                        title: "Installed",
                        message: "\(item.name) is ready to use.",
                        icon: "checkmark.circle.fill",
                        iconColor: .green
                    )
                }
                // v2.31 behavior: test a module the moment it's added — a
                // module that installs fine can still be broken.
                if let added = await MainActor.run(body: { moduleManager.modules.first(where: { $0.sourceName == item.name }) }) {
                    let result = await ModuleCheck.check(added)
                    await MainActor.run { testReport = (added, result) }
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installError = error.localizedDescription
                    ToastManager.shared.show(
                        title: "Install Failed",
                        message: "\(item.name): \(error.localizedDescription)",
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red
                    )
                }
            }
        }
    }

    private func testModule(_ module: ModuleDefinition) {
        guard !isTesting else { return }
        isTesting = true
        Task { @MainActor in
            let result = await ModuleCheck.check(module)
            isTesting = false
            testReport = (module, result)
        }
    }

    private func checkForUpdate(_ module: ModuleDefinition) {
        guard !isUpdating else { return }
        isUpdating = true
        Task { @MainActor in
            let outcome = await moduleManager.updateModule(module)
            isUpdating = false
            switch outcome {
            case .updated(let newVersion):
                ToastManager.shared.show(
                    title: name,
                    message: "Updated to v\(newVersion).",
                    icon: "arrow.up.circle.fill",
                    iconColor: .green)
            case .upToDate:
                ToastManager.shared.show(
                    title: name,
                    message: "You're on the latest version (v\(module.version)).",
                    icon: "checkmark.circle.fill",
                    iconColor: .green)
            case .noManifestURL:
                ToastManager.shared.show(
                    title: name,
                    message: "No stored module URL to check against.",
                    icon: "questionmark.circle",
                    iconColor: .secondary)
            case .failed(let reason):
                ToastManager.shared.show(
                    title: "Couldn't check for updates",
                    message: reason,
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red)
            }
        }
    }

    private func copyLink(_ url: URL) {
        #if os(iOS) || os(tvOS)
        UIPasteboard.general.string = url.absoluteString
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
        ToastManager.shared.show(
            title: "Link Copied",
            message: url.absoluteString,
            icon: "doc.on.doc",
            iconColor: Color.appAccent)
    }

    private func openLink(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url) { opened in
            if !opened {
                DispatchQueue.main.async {
                    ToastManager.shared.show(
                        title: "Couldn't Open Link",
                        message: "No app on this device can open \(url.absoluteString).",
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red)
                }
            }
        }
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
