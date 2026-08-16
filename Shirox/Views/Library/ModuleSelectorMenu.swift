import SwiftUI

/// Module selector menu shown in the toolbar of Anime/Manga detail pages.
///
/// **Visual:** the menu button shows the CURRENTLY ACTIVE module's icon +
/// name (truncated) so the user always knows which module is in use. Tapping
/// opens a native SwiftUI `Menu` listing every installed module of the
/// appropriate type, each with icon + name + a checkmark on the active one.
/// A "Module Settings" entry at the bottom deep-links into the right
/// settings page.
///
/// **Module separation:** the `mediaType` parameter controls which modules
/// are shown. Anime pages pass `.anime` → only anime modules appear. Manga
/// pages pass `.manga` → only manga modules appear. The filter uses
/// `ModuleDefinition.isManga`, so user-installed modules automatically land
/// in the correct selector based on their actual `type` field.
///
/// **Switching:** tapping a module calls `ModuleManager.selectModule(_:)`,
/// which loads the module's JS into `JSEngine`. The menu button's label
/// updates immediately because it reads from `@ObservedObject moduleManager`.
///
/// **Settings navigation:** the Settings entry uses a `@State` flag +
/// `.navigationDestination` rather than a `NavigationLink` inside the Menu
/// (Menu items don't push reliably on iOS 15 — the NavigationLink renders
/// but tap-to-push is intercepted by the Menu's dismissal gesture).
struct ModuleSelectorMenu: View {
    let mediaType: MediaKind

    @ObservedObject private var moduleManager = ModuleManager.shared
    /// Drives the Settings push via `navigationDestinationCompat(item:)`.
    /// Non-nil (1) when Settings should be shown; nil when hidden. We use
    /// `Int?` rather than `Bool` because the compat helper takes an
    /// `Optional` binding (it wraps a hidden NavigationLink).
    @State private var settingsPush: Int? = nil

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

    /// The module currently active for this content type. If the active
    /// module is of the WRONG type (e.g. user is on a manga page but an
    /// anime module is active), we fall back to the first relevant module
    /// so the label still shows something useful.
    private var activeModuleForType: ModuleDefinition? {
        if let active = moduleManager.activeModule {
            switch mediaType {
            case .manga: if active.isManga { return active }
            case .anime: if !active.isManga { return active }
            @unknown default: return active
            }
        }
        return relevantModules.first
    }

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
                                if activeModuleForType?.id == module.id {
                                    // Star indicator INSIDE the dropdown,
                                    // directly next to the active module's
                                    // name. Filled star in the accent color
                                    // — Apple-like, immediately scannable.
                                    // Only the currently-selected module
                                    // gets the star; switching modules
                                    // moves it instantly because the label
                                    // reads from @ObservedObject
                                    // moduleManager.
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(Color.appAccent)
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

            Divider()

            // Settings — uses a Button + @State flag rather than a
            // NavigationLink, because NavigationLink inside a Menu does
            // not push reliably on iOS 15 (the Menu's dismissal intercepts
            // the tap). The `navigationDestinationCompat(item:)` below
            // drives the actual push via a hidden NavigationLink.
            Button {
                settingsPush = 1
            } label: {
                Label("Module Settings", systemImage: "gearshape")
            }
        } label: {
            menuLabel
        }
        .navigationDestinationCompat(item: $settingsPush) { _ in
            ModulesSettingsPage(mediaType: mediaType == .manga ? .manga : nil)
                .environmentObject(moduleManager)
        }
    }

    // MARK: - Menu label (shows active module)

    /// The menu button shows the active module's icon + truncated name so
    /// the user always sees which module is in use at a glance. Falls back
    /// to a generic puzzle-piece icon when no relevant module is installed.
    ///
    /// **Sizing:** icon 25×25, text 15pt — ~40% larger than the original
    /// (18×18 / 13pt) so it's readable and tappable, matching the Add to
    /// Library button's visual weight. Padding kept tight so the touch
    /// area doesn't bloat.
    @ViewBuilder
    private var menuLabel: some View {
        if let active = activeModuleForType {
            HStack(spacing: 6) {
                moduleIconView(active)
                    .frame(width: 25, height: 25)
                Text(truncate(active.sourceName))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 15, weight: .semibold))
                Text("No Module")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Renders a module's icon — prefers cached base64 `iconData`, falls
    /// back to a puzzle-piece. Used both in the menu label and in each
    /// menu item so the icon style is consistent.
    @ViewBuilder
    private func moduleIconView(_ module: ModuleDefinition) -> some View {
        if let iconData = module.iconData,
           let data = Data(base64Encoded: iconData),
           let uiImage = UIImage(data: data) {
            #if canImport(UIKit)
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
            #else
            Image(systemName: "puzzlepiece.extension")
            #endif
        } else if let iconURL = module.iconUrl, !iconURL.isEmpty {
            // For the menu label, use a CachedAsyncImage so the icon loads
            // asynchronously. (Menu ITEMS can't use async images reliably,
            // but the menu LABEL can because it's a normal view, not a
            // Menu-provided row.)
            CachedAsyncImage(urlString: iconURL)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private var sectionTitle: String {
        mediaType == .manga ? "Manga Modules" : "Anime Modules"
    }

    /// Truncates long module names so the menu label doesn't overflow the
    /// toolbar. Keeps the first 12 chars + "…".
    private func truncate(_ name: String) -> String {
        name.count > 14 ? String(name.prefix(12)) + "…" : name
    }

    /// Builds a menu-item label with the module's icon (if cached) + name.
    /// Menu items can't render async images reliably, so for uncached icons
    /// we fall back to a system icon.
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
        } else {
            Label(module.sourceName, systemImage: "puzzlepiece.extension")
        }
    }
}
