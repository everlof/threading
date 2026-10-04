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
    var selectedThemeID: AppThemeID? { state.map { AppThemeID($0.selectedThemeID) } }

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
                standaloneThemeID: legacyTheme.rawValue,
                manuallyEnabledExtensionIDs: legacyEnabled
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
            manager?.adoptAppearanceEnablement(state.desiredExtensionIDs, startRuntimes: false)
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
        manager?.appearanceRuntimeAdmission = { [weak self] identifier in
            guard let self, let state = self.state,
                  !state.manuallyEnabledExtensionIDs.contains(identifier),
                  let pack = state.activePack else { return nil }
            return self.validationProblem(pack, snapshot: self.inventory())
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
        var runtimes: [String: AppearanceActivationInventory.Runtime] = [:]
        for item in manager?.installedExtensions ?? [] {
            let status: AppearanceActivationInventory.Runtime.Status
            let unavailable: String?
            switch item.status {
            case .disabled: status = .stopped; unavailable = nil
            case .starting: status = .starting; unavailable = nil
            case .running: status = .running; unavailable = nil
            case .failed(let reason): status = .failed(reason); unavailable = nil
            case .invalid(let reason): status = .failed(reason); unavailable = reason
            case .updating: status = .starting; unavailable = L10n.string("Updating")
            }
            runtimes[item.identifier] = .init(
                name: item.name,
                contentDigest: item.provenance?.contentDigest,
                unavailableReason: unavailable,
                requiredExtensionIDs: Set(item.serviceDependencies.filter(\.required).map(\.providerIdentifier)),
                status: status,
                capabilitySummary: item.capabilities.joined(separator: ", ")
            )
        }
        let snapshot = AppearanceActivationInventory(
            themeIDs: Set(AppThemeLibrary.all.map { $0.id.rawValue }),
            extensions: runtimes,
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

    func retry(_ packID: UUID) -> String? {
        guard let state, state.activePackID == packID, let pack = state.activePack else {
            return AppearanceActivationError.packUnavailable.localizedDescription
        }
        do {
            let snapshot = inventory()
            try snapshot.validate(pack, manualExtensionIDs: state.manuallyEnabledExtensionIDs)
            guard !isChanging else { throw AppearanceActivationError.changeInProgress }
            for member in pack.extensions {
                if case .failed = snapshot.extensions[member.identifier]?.status {
                    manager?.reload(identifier: member.identifier)
                }
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func packDetail(_ pack: AppearancePack, snapshot: AppearanceActivationInventory) -> String {
        let names = pack.extensions.map { snapshot.extensions[$0.identifier]?.name ?? $0.identifier }
        let themeName = AppThemeLibrary.theme(withID: AppThemeID(pack.themeID))?.name ?? pack.themeID
        let contents = ([themeName] + names).joined(separator: " · ")
        guard state?.activePackID == pack.id else { return contents }
        let status: String
        if extensionsSuppressed {
            status = L10n.string("Held back for this launch")
        } else if let reason = validationProblem(pack, snapshot: snapshot) {
            status = L10n.format("Needs attention: %@", reason)
        } else {
            let members = pack.extensions.compactMap { snapshot.extensions[$0.identifier] }
            if let failed = members.first(where: { if case .failed = $0.status { return true }; return false }) {
                status = L10n.format("Needs attention: %@", failed.name)
            } else if members.contains(where: { $0.status != .running }) {
                status = L10n.string("Starting")
            } else {
                status = L10n.string("Active")
            }
        }
        return status + " · " + contents
    }

    private func validationProblem(_ pack: AppearancePack, snapshot: AppearanceActivationInventory) -> String? {
        do {
            try snapshot.validate(pack, manualExtensionIDs: state?.manuallyEnabledExtensionIDs ?? [])
            return nil
        } catch { return error.localizedDescription }
    }

    func enablementDetail(identifier: String) -> String? {
        guard let state else { return nil }
        let manual = state.manuallyEnabledExtensionIDs.contains(identifier)
        if let pack = state.activePack, pack.extensionIDs.contains(identifier) {
            return manual
                ? L10n.format("Enabled manually and by %@", pack.name)
                : L10n.format("Enabled by %@", pack.name)
        }
        return manual ? L10n.string("Enabled manually") : nil
    }

    private func reconcile(_ previous: AppearanceActivationState, _ next: AppearanceActivationState) {
        manager?.adoptAppearanceEnablement(next.desiredExtensionIDs, startRuntimes: true)
        guard let theme = AppThemeLibrary.theme(withID: AppThemeID(next.selectedThemeID)) else {
            AppThemeLibrary.installResolved(AppThemeLibrary.defaultTheme)
            return
        }
        if previous.selectedThemeID != next.selectedThemeID {
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
