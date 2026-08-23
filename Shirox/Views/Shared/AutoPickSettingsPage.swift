#if os(iOS)
import SwiftUI

/// Auto Pick Module Settings — experimental settings page for the
/// Auto Pick Module feature. Contains:
///   - Module Priority tier list (reorder with up/down buttons)
///   - Quality Preferences (Auto, 1080p, 720p, 480p, etc.)
///   - Audio & Subtitle Preferences
///   - Fallback Settings
///   - Advanced options
///
/// All sections are collapsible. The page is clearly marked as
/// "Experimental" — disabled by default, does not interfere with
/// the normal manual workflow.
struct AutoPickSettingsPage: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("autoPickModuleTesting") private var autoPickEnabled = false
    @AppStorage("autoPickPreferredQuality") private var preferredQuality = "Auto"
    @AppStorage("autoPickPreferredAudio") private var preferredAudio = "Auto"
    @AppStorage("autoPickPreferredSubtitles") private var preferredSubtitles = "Auto"
    @AppStorage("autoPickPreferredStreamType") private var preferredStreamType = "Auto"
    @AppStorage("autoPickSkipUnavailable") private var skipUnavailable = true
    @AppStorage("autoPickUseFallback") private var useFallback = true
    @AppStorage("autoPickPreferHigher") private var preferHigher = true
    @AppStorage("autoPickRememberPerAnime") private var rememberPerAnime = false
    @AppStorage("autoFallbackEnabled") private var autoFallbackEnabled = false

    @State private var modulePriority: [String] = []
    @State private var expandedSections: Set<String> = ["priority"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                experimentalBanner
                masterToggleCard
                prioritySection
                qualitySection
                audioSubtitleSection
                fallbackSection
                advancedSection
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Auto Pick Module")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPriority() }
    }

    // MARK: - Experimental Banner

    private var experimentalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "flask.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Experimental Feature")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                Text("Disabled by default. Does not interfere with the normal manual module selection workflow unless explicitly enabled here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.purple.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
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
                    Text("When enabled, the app automatically selects a module and stream using the priority list below. The normal manual workflow is bypassed.")
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
                if modulePriority.isEmpty {
                    Text("No modules in priority list. Add modules below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(modulePriority.indices, id: \.self) { idx in
                        priorityRow(at: idx)
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
    private func priorityRow(at index: Int) -> some View {
        let moduleId = modulePriority[index]
        if let module = moduleManager.modules.first(where: { $0.id == moduleId }) {
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

                Button {
                    if index > 0 {
                        modulePriority.swapAt(index, index - 1)
                        savePriority()
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(index > 0 ? Color.appAccent : .secondary.opacity(0.3))
                        .frame(width: 30, height: 30)
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
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(index == modulePriority.count - 1)

                Button {
                    modulePriority.remove(at: index)
                    savePriority()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Quality Section

    private var qualitySection: some View {
        collapsibleSection(title: "Quality Preferences", icon: "4k.tv", id: "quality") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preferred Quality", selection: $preferredQuality) {
                    Text("Auto").tag("Auto")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                    Text("Highest Available").tag("Highest")
                    Text("Lowest Available").tag("Lowest")
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)

                Toggle("Prefer Higher Quality", isOn: $preferHigher)
                    .tint(Color.appAccent)
                Text("When two streams have different quality, prefer the higher one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Preferred Stream Type", selection: $preferredStreamType) {
                    Text("Auto").tag("Auto")
                    Text("Direct (MP4)").tag("Direct")
                    Text("Embedded (HLS)").tag("Embedded")
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)
            }
        }
    }

    // MARK: - Audio & Subtitles Section

    private var audioSubtitleSection: some View {
        collapsibleSection(title: "Audio & Subtitles", icon: "waveform", id: "audio") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preferred Audio", selection: $preferredAudio) {
                    Text("Auto").tag("Auto")
                    Text("Japanese").tag("Japanese")
                    Text("English").tag("English")
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)

                Picker("Preferred Subtitles", selection: $preferredSubtitles) {
                    Text("Auto").tag("Auto")
                    Text("English").tag("English")
                    Text("None").tag("None")
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)
                Text("If the preferred option is unavailable, the system falls back to the next available.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Fallback Section

    private var fallbackSection: some View {
        collapsibleSection(title: "Fallback Settings", icon: "arrow.triangle.2.circlepath", id: "fallback") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use Fallback Modules", isOn: $useFallback)
                    .tint(Color.appAccent)
                Text("If the primary module fails, try the next module in the priority list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Auto-Fallback (after failure)", isOn: $autoFallbackEnabled)
                    .tint(Color.appAccent)
                Text("Same as the toggle in Streaming settings — activates only after the selected module fails.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Skip Unavailable Modules", isOn: $skipUnavailable)
                    .tint(Color.appAccent)
                Text("Skip modules marked as unhealthy when trying the fallback chain.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        collapsibleSection(title: "Advanced", icon: "gearshape.2", id: "advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remember Selection Per Anime", isOn: $rememberPerAnime)
                    .tint(Color.appAccent)
                Text("Remember which module and stream worked for each anime so the app uses the same one next time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
#endif
