import SwiftUI

/// Module selector menu shown in the toolbar of Anime/Manga detail pages.
///
/// **Visual:** a clean puzzle-piece icon that opens a native SwiftUI `Menu`.
/// The menu lists every installed module of the appropriate type (anime or
/// manga — never mixed), each with its icon + name, plus a "Module Settings"
/// entry at the bottom that deep-links into the right settings page.
///
/// **Module separation:** the `mediaType` parameter controls which modules
/// are shown. Anime pages pass `.anime` → only anime modules appear. Manga
/// pages pass `.manga` → only manga modules appear. The filter uses
/// `ModuleDefinition.isManga`, so user-installed modules automatically land
/// in the correct selector based on their actual `type` field — no separate
/// registration system.
///
/// **Switching:** tapping a module calls `ModuleManager.selectModule(_:)`,
/// which loads the module's JS into `JSEngine`. The detail page's
/// "Watch"/"Start Reading" flow picks up the new active module automatically.
struct ModuleSelectorMenu: View {
    let mediaType: MediaKind

    /// Optional: highlight the currently-active module with a checkmark.
    /// Driven by `ModuleManager.shared.activeModule`.
    @EnvironmentObject private var moduleManager: ModuleManager

    init(mediaType: MediaKind) {
        self.mediaType = mediaType
    }

    /// Modules of the correct type, in the user's install order.
    private var relevantModules: [ModuleDefinition] {
        switch mediaType {
        case .manga:
            return moduleManager.modules.filter { $0.isManga }
        case .anime:
            return moduleManager.modules.filter { !$0.isManga }
        @unknown default:
            return moduleManager.modules.filter { !$0.isManga }
        }
    }

    /// True when at least one module of the right type is installed. When
    /// false, the menu still appears (tapping it shows the empty state +
        /// Settings link), so the user can jump straight to install one.
    private var hasModules: Bool { !relevantModules.isEmpty }

    var body: some View {
        Menu {
            if hasModules {
                Section(sectionTitle) {
                    ForEach(relevantModules) { module in
                        Button {
                            moduleManager.selectModule(module)
                        } label: {
                            HStack {
                                moduleLabel(module)
                                if moduleManager.activeModule?.id == module.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } else {
                Section(sectionTitle) {
                    Text("No \(mediaType == .manga ? "manga" : "anime") modules installed")
                        .font(.caption)
                }
            }

            Section {
                NavigationLink {
                    ModulesSettingsPage(mediaType: mediaType == .manga ? .manga : nil)
                        .environmentObject(moduleManager)
                } label: {
                    Label("Module Settings", systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .accessibilityLabel("Module selector")
        }
    }

    // MARK: - Helpers

    private var sectionTitle: String {
        mediaType == .manga ? "Manga Modules" : "Anime Modules"
    }

    /// Builds a menu label with the module's icon (if cached) + name.
    /// `Menu` items render as plain `Label`s on iOS, so we use the standard
    /// `Label` initializer — SwiftUI handles the icon/text layout natively.
    @ViewBuilder
    private func moduleLabel(_ module: ModuleDefinition) -> some View {
        if let iconData = module.iconData,
           let data = Data(base64Encoded: iconData),
           let uiImage = UIImage(data: data) {
            #if canImport(UIKit)
            Label {
                Text(module.sourceName)
            } icon: {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            }
            #else
            Label(module.sourceName, systemImage: "puzzlepiece.extension")
            #endif
        } else if let iconURL = module.iconUrl, let url = URL(string: iconURL) {
            // Async icon loading in a Menu is tricky (Menu items don't
            // support async images well). Fall back to a system icon and
            // let the name carry the identity. This matches how the
            // existing ModulesSettingsPage renders module rows.
            Label {
                Text(module.sourceName)
            } icon: {
                Image(systemName: "puzzlepiece.extension")
            }
        } else {
            Label(module.sourceName, systemImage: "puzzlepiece.extension")
        }
    }
}
