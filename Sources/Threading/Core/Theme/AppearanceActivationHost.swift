import AppKit

struct AppearanceActivationDidChange: AppEvent {
    static let name = Notification.Name("appearanceActivationDidChange")
}

/// Mac adapters for the application service. Created at launch, before theme restoration; an
/// ordinary hosted test never installs it and keeps its explicitly injected stores.
@MainActor
final class AppearanceActivationHost {
    static let shared = AppearanceActivationHost()

    private(set) var service: AppearanceActivationService?
    private(set) var isInstalled = false
    private(set) var failure: String?
    private var manager: ExtensionManager?
    private var extensionsSuppressed = false
    private let events = AppEventObservations()
    private var inventoryReconciliationScheduled = false
    private let inventoryProvider: (() -> AppearanceActivationInventory)?
    private var cachedInventory: AppearanceActivationInventory?
    var presentFailure: (String) -> Void = { message in
        NoticeAlert.show(NoticeRequest(
            title: L10n.string("Appearance change failed"), message: message, style: .warning
        ), in: NSApp.keyWindow)
    }

    var state: AppearanceActivationState? { service?.state }
    var isChanging: Bool { service?.isChanging == true }
    var selectedThemeID: AppThemeID? { state.map { AppThemeID($0.themeID) } }

    init(service: AppearanceActivationService? = nil, inventory: (() -> AppearanceActivationInventory)? = nil) {
        self.service = service
        inventoryProvider = inventory
        isInstalled = service != nil
        service?.didChange = { [weak self] in self?.publish() }
    }

    func prepare(startsExtensions: Bool) async {
        guard !isInstalled else { return }
        isInstalled = true
        extensionsSuppressed = !startsExtensions
        let legacyChoice = AppThemeLibrary.legacyStoredThemeID ?? AppThemeLibrary.defaultTheme.id
        let legacyTheme = AppThemeStyles.retiredIDs[legacyChoice] ?? legacyChoice
        let manager = startsExtensions ? ExtensionManager.shared : nil
        self.manager = manager
        let loaded: Result<AppearanceActivationState, Error>
        let persistence = AppearanceActivationStore(url: Self.storeURL())
        do {
            let legacyEnabled: Set<String>
            if let manager {
                legacyEnabled = manager.currentDesiredExtensionIDs
            } else {
                legacyEnabled = await Task.detached(priority: .utility) {
                    ExtensionPackageStore().enabledIdentifiers()
                }.value
            }
            loaded = .success(try await persistence.load(migrating: AppearanceActivationState(
                themeID: legacyTheme.rawValue,
                enabledExtensionIDs: legacyEnabled
            ), persistMigration: startsExtensions))
        } catch {
            loaded = .failure(error)
        }
        switch loaded {
        case .success(let state):
            let service = AppearanceActivationService(
                state: state,
                persistence: persistence,
                inventory: { [weak self] in self?.inventory() ?? .init(themeIDs: [], extensions: [:]) },
                beginMutation: { [weak self] in try self?.manager?.beginAppearanceMutation() },
                endMutation: { [weak self] in self?.manager?.endAppearanceMutation() },
                reconcile: { [weak self] previous, next in self?.reconcile(previous, next) }
            )
            self.service = service
            service.didChange = { [weak self] in self?.publish() }
            manager?.adoptAppearanceEnablement(state.enabledExtensionIDs, startRuntimes: false)
        case .failure(let error):
            failure = error.localizedDescription
            manager?.adoptAppearanceEnablement([], startRuntimes: false)
        }
        manager?.appearanceEnablementRequest = { [weak self] enabled, identifier in
            guard let self else { return }
            if let reason = self.submit(.setExtensionEnabled(identifier, enabled)) {
                throw AppearanceHostRequestError(message: reason)
            }
        }
        manager?.appearancePrepareForRemoval = { [weak self] identifier in
            try await self?.perform(.setExtensionEnabled(identifier, false))
        }
        events.observe(ExtensionsDidChange.self) { [weak self] _ in self?.inventoryDidChange() }
        events.observe(AppThemeLibraryDidChange.self) { [weak self] _ in self?.inventoryDidChange() }
        events.observe(AppThemeDidChange.self) { [weak self] _ in self?.publish() }
        events.observe(ThemesDidChange.self) { [weak self] _ in self?.publish() }
        events.observe(ProfileDidChange.self) { _ in
            ExtensionAppearanceRegistry.shared.prepareResources(for: AppThemeLibrary.current)
        }
        publish()
        if startsExtensions { await reconcileInventory() }
    }

    private static func storeURL() -> URL {
        let root = StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Threading", isDirectory: true)
        return root.appendingPathComponent("Customization", isDirectory: true)
            .appendingPathComponent("appearance.json")
    }

    func inventory() -> AppearanceActivationInventory {
        if let inventoryProvider { return inventoryProvider() }
        if let cachedInventory { return cachedInventory }
        var installed: [String: AppearanceActivationInventory.InstalledExtension] = [:]
        for item in manager?.installedExtensions ?? [] {
            let unavailable: String?
            switch item.status {
            case .disabled, .starting, .running, .failed: unavailable = nil
            case .invalid(let reason): unavailable = reason
            case .updating: unavailable = L10n.string("Updating")
            }
            installed[item.identifier] = .init(name: item.name, unavailableReason: unavailable)
        }
        let snapshot = AppearanceActivationInventory(
            themeIDs: Set(AppThemeLibrary.all.map { $0.id.rawValue }),
            extensions: installed,
            extensionsSuppressed: extensionsSuppressed
        )
        cachedInventory = snapshot
        return snapshot
    }

    func unavailableReason(for action: AppearanceActivationAction) -> String? {
        failure ?? service?.unavailableReason(for: action)
            ?? (service == nil ? L10n.string("Appearance choices are still loading.") : nil)
    }

    /// A synchronous frontend admits the request and gets a later visible failure if commit fails.
    @discardableResult
    func submit(_ action: AppearanceActivationAction) -> String? {
        if let reason = unavailableReason(for: action) { return reason }
        Task { [weak self] in
            do { try await self?.perform(action) }
            catch { self?.presentFailure(error.localizedDescription) }
        }
        return nil
    }

    func perform(_ action: AppearanceActivationAction) async throws {
        guard let service else { throw AppearanceHostRequestError(message: failure ?? L10n.string("Appearance choices are still loading.")) }
        try await service.perform(action)
    }

    func requestTheme(_ theme: AppTheme) {
        if let reason = submit(.selectTheme(theme.id.rawValue)) { presentFailure(reason) }
    }

    private func reconcile(_ previous: AppearanceActivationState, _ next: AppearanceActivationState) {
        manager?.adoptAppearanceEnablement(next.enabledExtensionIDs, startRuntimes: true)
        guard let theme = AppThemeLibrary.theme(withID: AppThemeID(next.themeID)) else {
            AppThemeLibrary.installResolved(AppThemeLibrary.defaultTheme)
            return
        }
        if previous.themeID != next.themeID {
            ThemeTransitionPresenter.shared.presentResolved(theme)
        } else if AppThemeLibrary.current != theme {
            AppThemeLibrary.installResolved(theme)
        }
    }

    private func publish() {
        AppearanceCommands.refresh(host: self)
        NotificationCenter.default.post(AppearanceActivationDidChange())
    }

    private func inventoryDidChange() {
        cachedInventory = nil
        publish()
        guard !inventoryReconciliationScheduled, !isChanging, !extensionsSuppressed else { return }
        inventoryReconciliationScheduled = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryReconciliationScheduled = false }
            await self.reconcileInventory()
        }
    }

    private func reconcileInventory() async {
        guard let service, !service.isChanging, manager?.appearanceInventoryIsStable == true else { return }
        let snapshot = inventory()
        do {
            try await service.perform(.reconcileInventory(
                themeIDs: snapshot.themeIDs, extensionIDs: Set(snapshot.extensions.keys),
                fallbackThemeID: AppThemeLibrary.defaultTheme.id.rawValue
            ))
        } catch { presentFailure(error.localizedDescription) }
    }
}

private struct AppearanceHostRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
