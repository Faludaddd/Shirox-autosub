import Foundation
import Combine

/// Companion to `ModuleManager` that exposes only manga modules.
///
/// The main `ModuleManager` owns the installed-modules list (the source of
/// truth) and is what actually loads a module's JS into `JSEngine`. This
/// manager is the manga UI's selection layer: it filters the installed list
/// down to entries where `module.isManga == true` and tracks which manga
/// module is active independently of the active anime module. Anime modules
/// therefore never resolve manga content and vice versa — manga views read
/// `MangaModuleManager.shared.activeModule`, anime views read
/// `ModuleManager.shared.activeModule`.
@MainActor
final class MangaModuleManager: ObservableObject {
    static let shared = MangaModuleManager()

    /// Manga-only subset of `ModuleManager.shared.modules`.
    @Published var modules: [ModuleDefinition] = []

    /// The currently selected manga module, or nil when none is chosen.
    @Published var activeModule: ModuleDefinition?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        syncFromMainManager()

        // Stay in sync as the source-of-truth manager installs/removes modules.
        ModuleManager.shared.$modules
            .sink { _ in
                Task { @MainActor [weak self] in
                    self?.syncFromMainManager()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Sync

    /// Re-reads the installed modules from `ModuleManager.shared` and keeps only
    /// manga modules. Preserves the active manga module when it is still
    /// installed (rebinding to the refreshed instance); clears it otherwise.
    func syncFromMainManager() {
        let mangaModules = ModuleManager.shared.modules.filter { $0.isManga }
        modules = mangaModules

        if let active = activeModule {
            if let refreshed = mangaModules.first(where: { $0.id == active.id }) {
                activeModule = refreshed
            } else {
                activeModule = nil
            }
        }
    }

    // MARK: - Selection

    /// Sets the active manga module. Only manga modules are accepted, so an
    /// anime module can never become the manga active module. This updates only
    /// this manager's selection state; callers that need the module's JS loaded
    /// into `JSEngine` should also drive `ModuleManager.shared` (e.g. via
    /// `selectAndAwaitReady(_:)`).
    func selectModule(_ module: ModuleDefinition) {
        guard module.isManga else { return }
        activeModule = module
    }

    // MARK: - Queries

    /// Returns true when at least one manga module is installed.
    func hasMangaModule() -> Bool {
        !modules.isEmpty
    }
}
