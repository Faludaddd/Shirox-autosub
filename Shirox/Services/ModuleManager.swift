import Foundation
import SwiftUI
import Combine

/// User-facing install errors. Surfaced via `errorDescription` so callers
/// can show them in a toast or alert without extra mapping.
enum ModuleInstallError: Error, LocalizedError {
    case scriptDownloadFailed(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .scriptDownloadFailed(let name):
            return "Could not download the script for \"\(name)\". The module URL may be offline or blocked."
        case .invalidManifest(let reason):
            return "Invalid module manifest: \(reason)"
        }
    }
}

@MainActor
final class ModuleManager: ObservableObject {
    static let shared = ModuleManager()

    @Published var modules: [ModuleDefinition] = []
    @Published var activeModule: ModuleDefinition?
    @Published var moduleReadyId: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let storageKey = "savedModules"
    private let activeKey = "activeModuleId"

    private init() {
        loadFromStorage()
    }

    // MARK: - Add Module

    /// Installs a module from its JSON manifest URL.
    ///
    /// **Throws** on failure so callers can surface errors to the user (the
    /// previous non-throwing signature silently swallowed errors — `try await`
    /// on a non-throwing function is a no-op in Swift, so install failures
    /// from `ModulesSettingsPage` and `ModuleStorePage` were never reported,
    /// and the user saw no feedback when a module failed to install).
    ///
    /// The thrown error is also captured in `errorMessage` for callers that
    /// prefer to observe via the published property rather than `try`.
    func addModule(from jsonURL: URL) async throws {
        isLoading = true
        errorMessage = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: jsonURL)
            var module = try JSONDecoder().decode(ModuleDefinition.self, from: data)
            module.jsonUrl = jsonURL.absoluteString

            // Cache script and icon — but require the script to actually
            // download. A module without a runnable script is unusable, and
            // silently installing it would leave the user with a broken row
            // in the Modules tab.
            await cacheAssets(for: &module)
            if module.scriptContent == nil || module.scriptContent?.isEmpty == true {
                throw ModuleInstallError.scriptDownloadFailed(
                    module.sourceName.isEmpty ? "Unknown module" : module.sourceName
                )
            }

            // Avoid duplicates — replace any existing module with the same id.
            if modules.contains(where: { $0.id == module.id }) {
                modules.removeAll { $0.id == module.id }
            }
            modules.append(module)
            saveToStorage()

            // Auto-select if it's the first module of this kind (anime vs manga).
            // For manga modules, also kick the MangaModuleManager sync via the
            // $modules publisher so the manga UI picks it up immediately.
            if activeModule == nil && !module.isManga {
                selectModule(module)
            }

            Logger.shared.log(
                "[ModuleManager] Installed module: \(module.sourceName) (id=\(module.id), isManga=\(module.isManga))",
                type: "Module"
            )
        } catch {
            errorMessage = error.localizedDescription
            Logger.shared.log(
                "[ModuleManager] Failed to install module from \(jsonURL.absoluteString): \(error.localizedDescription)",
                type: "Error"
            )
            isLoading = false
            throw error
        }
        isLoading = false
    }

    // MARK: - Remove Module

    func removeModule(_ module: ModuleDefinition) {
        modules.removeAll { $0.id == module.id }
        if activeModule?.id == module.id {
            activeModule = nil
        }
        saveToStorage()
    }

    // MARK: - Select Module

    func selectModule(_ module: ModuleDefinition) {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        
        Task {
            do {
                try await JSEngine.shared.loadModule(module)
                moduleReadyId = module.id
            } catch {
                Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Like selectModule, but suspends until the module's JS is loaded.
    /// Returns false when the script failed to load. Used by flows that must
    /// call into the module immediately after switching (Continue Reading).
    func selectAndAwaitReady(_ module: ModuleDefinition) async -> Bool {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        do {
            try await JSEngine.shared.loadModule(module)
            moduleReadyId = module.id
            return true
        } catch {
            Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    // MARK: - Reorder Modules

    func moveModules(from source: IndexSet, to destination: Int) {
        modules.move(fromOffsets: source, toOffset: destination)
        saveToStorage()
    }

    func deselectModule() {
        activeModule = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    // MARK: - Restore Active Module on Launch

    func restoreActiveModule() async {
        guard let savedId = UserDefaults.standard.string(forKey: activeKey),
              let module = modules.first(where: { $0.id == savedId }) else { return }
        selectModule(module)
    }

    // MARK: - Auto-Update

    func checkForUpdates() async {
        var didUpdate = false
        for i in modules.indices {
            guard let jsonUrlStr = modules[i].jsonUrl,
                  let jsonURL = URL(string: jsonUrlStr),
                  let (data, _) = try? await URLSession.shared.data(from: jsonURL),
                  var fresh = try? JSONDecoder().decode(ModuleDefinition.self, from: data),
                  fresh.version != modules[i].version else { continue }
            fresh.jsonUrl = jsonUrlStr
            
            // Cache fresh assets
            await cacheAssets(for: &fresh)
            
            let wasActive = activeModule?.id == modules[i].id
            modules[i] = fresh
            if wasActive { selectModule(fresh) }
            didUpdate = true
        }
        if didUpdate { saveToStorage() }
    }

    // MARK: - Asset Caching

    private func cacheAssets(for module: inout ModuleDefinition) async {
        // 1. Script
        if let scriptURL = URL(string: module.scriptUrl),
           let (data, _) = try? await URLSession.shared.data(from: scriptURL),
           let script = String(data: data, encoding: .utf8) {
            module.scriptContent = script
        }
        
        // 2. Icon
        if let iconUrlStr = module.iconUrl,
           let iconURL = URL(string: iconUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: iconURL) {
            module.iconData = data.base64EncodedString()
        }
    }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(modules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ModuleDefinition].self, from: data) else { return }
        modules = saved
    }
}
