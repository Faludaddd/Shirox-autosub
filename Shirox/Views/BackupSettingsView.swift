#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// v2.36 — the Backup & Restore page, redesigned in Shirox's card design
/// language. Every underlying operation is the REAL one it always was —
/// `BackupManager.exportFile`, `summarize`, `importBackup` — with the same
/// `.shiroxbackup` format and compatibility; only the interface around them
/// is new: a clear explanation of what a backup contains, separated
/// Create/Restore sections with honest progress, success and error states,
/// and a destructive-action confirmation before anything is replaced.
struct BackupSettingsView: View {
    @State private var includeAccounts = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var pendingSummary: BackupSummary?
    @State private var importError: String?
    @State private var report: BackupImportReport?
    @State private var isRestoring = false
    @State private var isExporting = false

    /// The app declares `com.shirox.backup` in Info.plist; the fallbacks keep the picker
    /// usable if the declaration hasn't been registered yet (a fresh install from Xcode).
    private static var backupContentTypes: [UTType] {
        if let declared = UTType("com.shirox.backup") { return [declared, .json] }
        if let byExtension = UTType(filenameExtension: "shiroxbackup") { return [byExtension, .json] }
        return [.json]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                createCard
                restoreCard
                contentsCard
                if let report { reportCard(report) }
            }
            .padding()
        }
        .background(backupPageBackground)
        .navigationTitle("Backup & Restore")
        .inlineNavBar()
        // One importer only: two `.fileImporter` modifiers in a single view conflict —
        // see the note in SearchView.swift.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.backupContentTypes) { result in
            handlePickedFile(result)
        }
        .confirmationDialog("Restore this backup?",
                            isPresented: Binding(get: { pendingSummary != nil },
                                                 set: { if !$0 { clearPendingImport() } }),
                            titleVisibility: .visible) {
            Button("Replace Data on This Device", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { clearPendingImport() }
        } message: {
            if let pendingSummary { Text(Self.confirmationMessage(pendingSummary)) }
        }
        .alert("Couldn't Read Backup",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Couldn't Create Backup",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var backupPageBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.12))
                    .frame(width: 60, height: 60)
                Image(systemName: externalDriveIcon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(spacing: 6) {
                Text("Your Shirox, in one file")
                    .font(.headline)
                Text("A backup carries everything personal in the app — watch and read progress, your library, every setting and your installed modules. Restore it on any device to pick up exactly where you left off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(cardShape.fill(cardBackground))
    }

    private var externalDriveIcon: String {
        #if os(macOS)
        return "externaldrive.badge.timemachine"
        #else
        return "externaldrive.badge.icloud"
        #endif
    }

    // MARK: - Create

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Create a Backup", systemImage: "square.and.arrow.up.fill", tint: Color.appAccent)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                Text("Progress, library, settings and modules — no login tokens, safe to share.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // The one option, explained in plain words with its real risk.
            Toggle(isOn: $includeAccounts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include account sign-ins")
                        .font(.subheadline.weight(.semibold))
                    Text(includeAccounts
                         ? "This file will contain live login tokens for AniList, MyAnimeList and Jellyfin. Anyone who opens it can sign in as you — keep it to yourself."
                         : "Off — the backup can be shared freely; restoring it keeps your current sign-ins.")
                        .font(.caption2)
                        .foregroundStyle(includeAccounts ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(includeAccounts ? .orange : Color.appAccent)

            Button {
                createBackup()
            } label: {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView().tint(Color.appAccentForeground)
                    } else {
                        Image(systemName: "doc.badge.plus").font(.footnote)
                    }
                    Text(exportedURL == nil ? "Create Backup" : "Create a Fresh Backup")
                        .font(.headline)
                }
                .foregroundStyle(Color.appAccentForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.appAccent))
            }
            .buttonStyle(.springPress)
            .disabled(isExporting)

            // Success state: the file exists, its name and size are real,
            // and Share is one tap away (Mac keeps its save-panel flow).
            if let exportedURL {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backup ready")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("\(exportedURL.lastPathComponent) — created just now, saved in the app's documents.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    #if os(macOS)
                    Button {
                        saveBackup()
                    } label: {
                        Label("Save Backup to Disk…", systemImage: "internaldrive")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    #else
                    if #available(iOS 16.0, macOS 13.0, *) {
                        ShareLink(item: exportedURL) {
                            Label("Share \(exportedURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.08)))
                        }
                    }
                    #endif
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.08)))
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(cardBackground))
    }

    // MARK: - Restore

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Restore from a Backup", systemImage: "arrow.down.doc.fill", tint: .orange)

            Text("Pick a `.shiroxbackup` file. You'll see exactly what's inside — and confirm — before anything on this device is replaced. Downloaded episodes and chapters are never touched by a restore.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 8) {
                    if isRestoring {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "doc.badge.arrow.up").font(.footnote)
                    }
                    Text(isRestoring ? "Restoring…" : "Choose Backup File…")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.orange))
            }
            .buttonStyle(.springPress)
            .disabled(isRestoring)

            // Honest in-flight state: a restore in progress is a real,
            // data-writing operation — the user sees it working.
            if isRestoring {
                Label("Writing the backup's data — keep the app open.", systemImage: "gearshape.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(cardBackground))
    }

    // MARK: - What's inside

    private var contentsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("What a Backup Contains", systemImage: "list.bullet.clipboard.fill", tint: Color.appAccent)
            VStack(spacing: 0) {
                contentsRow(icon: "play.circle.fill", title: "Watch & read progress",
                            detail: "Every episode and chapter position, per title")
                contentsDivider
                contentsRow(icon: "books.vertical.fill", title: "Your library",
                            detail: "Tracked, planned, completed and rated entries")
                contentsDivider
                contentsRow(icon: "gearshape.fill", title: "Settings",
                            detail: "Appearance, notifications, playback and preferences")
                contentsDivider
                contentsRow(icon: "puzzlepiece.extension.fill", title: "Modules",
                            detail: "Installed modules and their configuration")
                contentsDivider
                contentsRow(icon: "person.crop.circle.badge.checkmark", title: "Account sign-ins",
                            detail: includeAccounts ? "Included in this backup (live login tokens)" : "Only when the option is turned on",
                            tint: includeAccounts ? .orange : nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(cardBackground))
    }

    private func contentsRow(icon: String, title: String, detail: String, tint: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? Color.appAccent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill((tint ?? Color.appAccent).opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var contentsDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Restore result

    @ViewBuilder
    private func reportCard(_ report: BackupImportReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Last Restore", systemImage: "checkmark.seal.fill",
                          tint: report.skipped.isEmpty ? .green : .orange)

            if !report.applied.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restored")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(report.applied.map(Self.label).joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                }
            }

            ForEach(report.warnings, id: \.detail) { note in
                Label(note.detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.skipped, id: \.detail) { note in
                Label("Skipped \(Self.label(note.section)): \(note.detail)",
                      systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if report.skipped.isEmpty && report.warnings.isEmpty {
                Label("Everything in the backup was restored.", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(cardBackground))
        .transition(.opacity)
    }

    // MARK: - Shared card pieces

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var cardBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - Export

    #if os(macOS)
    /// A Mac saves the file where it's told; the share row becomes a save panel.
    private func saveBackup() {
        createBackup()
        guard let exportedURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportedURL.lastPathComponent
        panel.allowedContentTypes = Self.backupContentTypes
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: exportedURL, to: destination)
            ToastManager.shared.show(message: "Backup saved", type: .success, duration: 3)
        } catch {
            exportError = error.localizedDescription
        }
    }
    #endif

    private func createBackup() {
        isExporting = true
        defer { isExporting = false }
        do {
            exportedURL = try BackupManager.shared.exportFile(includeAccounts: includeAccounts)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Import

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // A picked file lives outside the sandbox until the scope is opened.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                // summarize() is the gate: a missing, invalid, incompatible or
                // corrupted file throws HERE, before anything is written, and
                // the honest alert explains it — the device's data is
                // untouched (that's the whole point of summarize-then-confirm).
                let (_, summary) = try BackupManager.shared.summarize(data)
                pendingData = data
                pendingSummary = summary
            } catch {
                importError = Self.readErrorMessage(from: error)
            }
        }
    }

    /// A plain-language explanation for the three ways a picked file can be
    /// unreadable, without swallowing the technical detail.
    private static func readErrorMessage(from error: Error) -> String {
        let detail = error.localizedDescription
        if detail.lowercased().contains("data corrupted") || detail.lowercased().contains("decode") {
            return "That file isn't a valid Shirox backup (its contents couldn't be read).\n\n\(detail)"
        }
        return "The backup couldn't be read.\n\n\(detail)"
    }

    private func clearPendingImport() {
        pendingData = nil
        pendingSummary = nil
    }

    private static func confirmationMessage(_ summary: BackupSummary) -> String {
        var parts: [String] = []
        parts.append(summary.lines.isEmpty
                     ? "This backup records no data."
                     : summary.lines.joined(separator: " · "))
        parts.append("Made \(summary.createdAt.formatted(date: .abbreviated, time: .shortened)) with Shirox \(summary.appVersion).")
        parts.append("This replaces the progress, library, settings and modules on this device — current data is overwritten. Downloaded episodes and chapters are left alone.")
        if summary.includesAccounts {
            parts.append("It also signs this device into the accounts saved in the backup.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func runRestore() {
        guard let data = pendingData else { return }
        clearPendingImport()
        isRestoring = true
        Task {
            do {
                report = try await BackupManager.shared.importBackup(from: data)
            } catch {
                // A restore that fails partway preserves existing data —
                // importBackup's own contract — and the error is surfaced,
                // never swallowed.
                importError = "The restore didn't complete. Nothing was half-applied: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private static func label(_ sectionID: String) -> String {
        switch sectionID {
        case BackupSectionID.progress: return "Progress"
        case BackupSectionID.localLibrary: return "Local Library"
        case BackupSectionID.settings: return "Settings"
        case BackupSectionID.modules: return "Modules"
        case BackupSectionID.accounts: return "Accounts"
        default: return sectionID
        }
    }
}
#endif
