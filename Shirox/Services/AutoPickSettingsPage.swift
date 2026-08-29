#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Auto Pick Module Settings — v2.10 rebuild.
///
/// Every control on this page maps 1:1 to a setting the AutoPickEngine
/// actually reads at run time. The old page carried six placebos (audio
/// language, subtitle language, stream type, "prefer higher", per-anime
/// memory, auto-fallback duplicate) that were saved but never used —
/// all removed.
///
/// What the engine does with these:
///   - Module Priority — try order. Fallback walks down this list.
///   - Preferred Quality — real resolution matching, not title sorting.
///   - Preferred Language — Sub/Dub parsed from stream titles.
///   - Use Fallback — off = only the first eligible module is tried.
///   - Skip Unavailable — modules marked error/blocked are skipped.
struct AutoPickSettingsPage: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("autoPickModuleTesting") private var autoPickEnabled = false
    @AppStorage("autoPickPreferredQuality") private var preferredQuality = "Auto"
    @AppStorage("autoPickPreferredLanguage") private var preferredLanguage = "Sub"
    @AppStorage("autoPickSkipUnavailable") private var skipUnavailable = true
    @AppStorage("autoPickUseFallback") private var useFallback = true

    @State private var modulePriority: [String] = []
    @State private var expandedSections: Set<String> = ["priority"]
    /// Module id currently being dragged in the priority list (drag-to-reorder).
    @State private var draggingModuleId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                howItWorksCard
                masterToggleCard
                prioritySection
                qualitySection
                languageSection
                fallbackSection
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Auto Pick Module")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPriority() }
    }

    // MARK: - How It Works

    private var howItWorksCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("How it works")
                    .font(.subheadline.weight(.bold))
                Text("When enabled, tapping an episode tries your modules in priority order and plays the best stream automatically. Progress shows right on the episode row. If nothing works, the normal manual picker opens so you're never stuck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appAccent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Master Toggle

    private var masterToggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto Pick Module")
                        .font(.headline)
                    Text("Off by default. When off, tapping an episode opens the manual module picker exactly as before.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $autoPickEnabled)
                    .tint(Color.appAccent)
                    .labelsHidden()
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
        .padding(.horizontal, 16)
    }

    // MARK: - Collapsible Section

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        title: String,
        icon: String,
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if expandedSections.contains(id) {
                        expandedSections.remove(id)
                    } else {
                        expandedSections.insert(id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: expandedSections.contains(id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedSections.contains(id) {
                content()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Module Priority Section

    private var prioritySection: some View {
        collapsibleSection(title: "Module Priority", icon: "list.number", id: "priority") {
            VStack(spacing: 8) {
                Text("Drag rows to reorder (arrows work too). Modules are tried top to bottom — the first one that returns a playable stream wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if modulePriority.isEmpty {
                    Text("No modules in priority list. Add modules below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(modulePriority, id: \.self) { moduleId in
                        priorityRow(for: moduleId)
                            .opacity(draggingModuleId == moduleId ? 0.35 : 1)
                            .scaleEffect(draggingModuleId == moduleId ? 0.97 : 1)
                            .onDrag {
                                draggingModuleId = moduleId
                                Haptics.light()
                                return NSItemProvider(object: moduleId as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: PriorityDropDelegate(
                                    item: moduleId,
                                    list: $modulePriority,
                                    dragging: $draggingModuleId,
                                    onCommit: { savePriority() }
                                )
                            )
                    }
                }

                Divider().opacity(0.3)

                Menu {
                    ForEach(availableModulesToAdd, id: \.id) { module in
                        Button(module.sourceName) {
                            modulePriority.append(module.id)
                            savePriority()
                        }
                    }
                } label: {
                    Label("Add Module", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .disabled(availableModulesToAdd.isEmpty)

                Button("Reset Priority") {
                    modulePriority = moduleManager.modules.filter { !$0.isManga }.map { $0.id }
                    savePriority()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var availableModulesToAdd: [ModuleDefinition] {
        moduleManager.modules.filter { !$0.isManga && !modulePriority.contains($0.id) }
    }

    @ViewBuilder
    private func priorityRow(for moduleId: String) -> some View {
        if let index = modulePriority.firstIndex(of: moduleId),
           let module = moduleManager.modules.first(where: { $0.id == moduleId }) {
            let health = moduleManager.health(for: module)
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let h = health {
                        HStack(spacing: 4) {
                            Image(systemName: h.status.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(h.status.color)
                            Text(h.status.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Drag affordance — the whole row is draggable; the grip
                // signals it. Long-press a row and drop it on another to
                // reorder (v2.11).
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(width: 20)

                Button {
                    if index > 0 {
                        modulePriority.swapAt(index, index - 1)
                        savePriority()
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(index > 0 ? Color.appAccent : .secondary.opacity(0.3))
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    if index < modulePriority.count - 1 {
                        modulePriority.swapAt(index, index + 1)
                        savePriority()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(index < modulePriority.count - 1 ? Color.appAccent : .secondary.opacity(0.3))
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(index == modulePriority.count - 1)

                Button {
                    modulePriority.removeAll { $0 == moduleId }
                    savePriority()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Quality Section

    private var qualitySection: some View {
        collapsibleSection(title: "Preferred Quality", icon: "4k.tv", id: "quality") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preferred Quality", selection: $preferredQuality) {
                    Text("Auto (Best Available)").tag("Auto")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                    Text("Highest Available").tag("Highest")
                    Text("Lowest Available").tag("Lowest")
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)

                Text("Auto picks the highest resolution the winning module offers. A specific target (e.g. 1080p) uses an exact match when available, otherwise the closest resolution above it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        collapsibleSection(title: "Audio Language", icon: "waveform", id: "language") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preferred Language", selection: $preferredLanguage) {
                    Text("Sub").tag("Sub")
                    Text("Dub").tag("Dub")
                    Text("Any").tag("Any")
                }
                .pickerStyle(.segmented)

                Text("Streams are filtered by their SUB/DUB label. If the winning module doesn't label its streams (or has no match), all of them stay in the pool.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Fallback Section

    private var fallbackSection: some View {
        collapsibleSection(title: "Fallback", icon: "arrow.triangle.2.circlepath", id: "fallback") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Try Next Module on Failure", isOn: $useFallback)
                    .tint(Color.appAccent)
                Text("Off = only the first module in the priority list is tried. On = Auto Pick walks down the list until something plays.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Skip Unavailable Modules", isOn: $skipUnavailable)
                    .tint(Color.appAccent)
                Text("Modules currently marked as error or blocked in the module list are skipped entirely.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each module gets a 25-second budget. A module that hangs counts as a failure and the chain moves on — Auto Pick can no longer get stuck forever.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Priority Persistence

    private func loadPriority() {
        let saved = UserDefaults.standard.stringArray(forKey: "autoPickModulePriority") ?? []
        if saved.isEmpty {
            modulePriority = moduleManager.modules.filter { !$0.isManga }.map { $0.id }
        } else {
            modulePriority = saved
        }
    }

    private func savePriority() {
        UserDefaults.standard.set(modulePriority, forKey: "autoPickModulePriority")
    }
}

// MARK: - Drag-to-Reorder Delegate

/// Enables drag-to-reorder inside the plain (non-List) priority VStack.
/// As the dragged row enters another row's frame, the two swap with a
/// spring animation; the new order is persisted when the drop commits.
private struct PriorityDropDelegate: DropDelegate {
    let item: String
    @Binding var list: [String]
    @Binding var dragging: String?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != item else { return }
        guard let from = list.firstIndex(of: dragged),
              let to = list.firstIndex(of: item) else { return }
        guard from != to else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        Haptics.light()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit()
        Haptics.medium()
        return true
    }
}
#endif
