import Foundation
import SkalmanExtensionKit

struct ExtensionsDidChange: AppEvent {
    static let name = Notification.Name("extensionsDidChange")
}

enum ExtensionServiceBrokerError: LocalizedError {
    case providerUnavailable(String)
    case serviceUnavailable(String, Int)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let identifier):
            return "The provider extension “\(identifier)” is not running."
        case .serviceUnavailable(let identifier, let version):
            return "The provider did not register service “\(identifier)” v\(version)."
        }
    }
}

enum ExtensionManagerError: LocalizedError {
    case operationInProgress(String)
    case companionUnavailable(extensionIdentifier: String, companionID: String)
    case companionOperationUnavailable(companionID: String, operationID: String)
    case extensionNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress(let identifier):
            return "Extension \(identifier) is already being updated."
        case .companionUnavailable(let extensionIdentifier, let companionID):
            return "Extension \(extensionIdentifier) does not declare companion \(companionID)."
        case .companionOperationUnavailable(let companionID, let operationID):
            return "Companion \(companionID) does not declare operation \(operationID)."
        case .extensionNotRunning(let identifier):
            return "Extension \(identifier) must be enabled and running before its companion can start."
        }
    }
}

enum InstalledExtensionStatus: Equatable {
    case disabled
    case starting
    case updating
    case running(commands: Int, panels: Int, tools: Int)
    case failed(String)
    case invalid(String)

    var summary: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .starting:
            return "Starting…"
        case .updating:
            return "Updating…"
        case .running(let commands, let panels, let tools):
            return "Running · \(commands) command(s), \(panels) panel(s), \(tools) tool(s)"
        case .failed(let message):
            return "Failed · \(message)"
        case .invalid(let message):
            return "Invalid package · \(message)"
        }
    }
}

enum InstalledCompanionStatus: Equatable {
    case disabled
    case onDemand
    case starting
    case running
    case failed(String)

    var summary: String {
        switch self {
        case .disabled:
            return "disabled"
        case .onDemand:
            return "ready on demand"
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .failed(let message):
            return "failed: \(message)"
        }
    }
}

struct InstalledExtensionSnapshot {
    let identifier: String
    let name: String
    let version: String?
    let profile: ExtensionProfile
    let contributionKinds: [ExtensionContributionKind]
    let capabilities: [String]
    let companions: [ExtensionCompanion]
    let companionStatuses: [String: InstalledCompanionStatus]
    let services: [ExtensionServiceDefinition]
    let serviceDependencies: [ExtensionServiceDependency]
    let packageURL: URL
    let provenance: ExtensionInstallProvenance?
    let isEnabled: Bool
    let status: InstalledExtensionStatus
}

struct ExtensionMCPToolInventory {
    let extensionIdentifier: String
    let extensionName: String
    let isExtensionEnabled: Bool
    let declaredTools: [ExtensionMCPTool]
    let registeredTools: [ExtensionMCPTool]

    var groupID: String { "extension.\(extensionIdentifier)" }
    var isRunning: Bool { !registeredTools.isEmpty }
}

struct ExtensionPanelInventoryItem: Equatable {
    let extensionIdentifier: String
    let extensionName: String
    let processGeneration: String
    let panel: ExtensionPanel
}

/// The narrow panel boundary consumed by the display pane.
///
/// Keeping it separate from installation and lifecycle APIs lets the product surface be tested
/// without giving it authority to enable, reload, or remove extensions.
@MainActor
protocol ExtensionPanelRouting: AnyObject {
    var extensionPanelInventory: [ExtensionPanelInventoryItem] { get }

    func registeredPanel(
        extensionIdentifier: String,
        panelID: String
    ) -> ExtensionPanelInventoryItem?

    func extensionImageResourceURL(
        extensionIdentifier: String,
        relativePath: String
    ) -> URL?

    @discardableResult
    func invokePanelAction(
        extensionIdentifier: String,
        panelID: String,
        actionID: String,
        context: ExtensionCommandContext,
        completion: @escaping (Result<ExtensionActionResponse, Error>) -> Void
    ) -> Bool

    func connectRemoteSurface(
        extensionIdentifier: String,
        panelID: String,
        context: ExtensionCommandContext,
        initialViewport: ExtensionRemoteSurfaceViewport,
        consumer: ExtensionRemoteSurfaceConsumer
    ) -> ExtensionRemoteSurfaceSubscription?
}

extension ExtensionPanelRouting {
    func connectRemoteSurface(
        extensionIdentifier: String,
        panelID: String,
        context: ExtensionCommandContext,
        initialViewport: ExtensionRemoteSurfaceViewport,
        consumer: ExtensionRemoteSurfaceConsumer
    ) -> ExtensionRemoteSurfaceSubscription? {
        nil
    }
}

/// The application-wide lifecycle owner for installed extension processes.
///
/// Installation and process startup happen away from the main thread. Inventory, desired
/// enablement, and user-visible status are committed on the main actor so Settings never observes
/// a partially transitioned extension.
@MainActor
final class ExtensionManager:
    ExtensionServiceRouting,
    ExtensionCompanionRouting,
    ExtensionPanelRouting
{
    static let shared = ExtensionManager()

    private let store: ExtensionPackageStore
    private let settingsStore: ExtensionSettingsValueStore
    private let launchPolicy: ExtensionLaunchPolicy
    private let companionLaunchPolicy: ExtensionCompanionLaunchPolicy
    private let companionPermissionAuthorizer:
        ExtensionCompanionSystemPermissionAuthorizing
    private var packages: [String: InstalledExtensionPackage] = [:]
    private var enabledIdentifiers: Set<String> = []
    private var statuses: [String: InstalledExtensionStatus] = [:]
    private var sessions: [String: ExtensionProcessSession] = [:]
    private var sessionGenerations: [String: String] = [:]
    private var registrations: [String: ExtensionRegistration] = [:]
    private struct CompanionKey: Hashable {
        let extensionIdentifier: String
        let companionID: String
    }
    private var companionSupervisors: [
        CompanionKey: ExtensionCompanionSupervisor
    ] = [:]
    private var companionStatuses: [CompanionKey: InstalledCompanionStatus] = [:]
    private final class RemotePresentation {
        let id: String
        let extensionIdentifier: String
        let companionID: String
        let surface: ExtensionRemoteSurface
        weak var consumer: ExtensionRemoteSurfaceConsumer?

        init(
            id: String,
            extensionIdentifier: String,
            companionID: String,
            surface: ExtensionRemoteSurface,
            consumer: ExtensionRemoteSurfaceConsumer
        ) {
            self.id = id
            self.extensionIdentifier = extensionIdentifier
            self.companionID = companionID
            self.surface = surface
            self.consumer = consumer
        }
    }
    private var remotePresentations: [String: RemotePresentation] = [:]
    private var companionStartCompletions: [
        CompanionKey: [(Result<Void, Error>) -> Void]
    ] = [:]
    private var companionStartTokens: [CompanionKey: String] = [:]
    private var generations: [String: Int] = [:]
    /// Package replacement is asynchronous, but every conflicting lifecycle action is
    /// main-actor isolated. This set makes that interval an explicit transition rather than a
    /// window in which old code can be restarted underneath the replacement.
    private var updatingIdentifiers: Set<String> = []

    /// The launcher the app uses, chosen once at startup.
    ///
    /// WebAssembly packages use the signed Wasm runner. Native format-1 packages remain on the
    /// generated Seatbelt launcher as a compatibility path while authors migrate.
    nonisolated static func defaultLaunchPolicy(
        usesContainedLauncher: Bool,
        bundle: Bundle = .main
    ) -> ExtensionLaunchPolicy {
        if usesContainedLauncher {
            SkalmanLogger.extensions.error(
                "Ignoring usesContainedExtensionLauncher: the App Sandbox helper can raise legacy Keychain authorization UI and is not a supported product path."
            )
        }
        return RuntimeSelectingLaunchPolicy(
            native: SandboxExecLaunchPolicy(),
            webAssembly: WasmLaunchPolicy(bundle: bundle)
        )
    }

    /// `launchPolicy` is resolved inside the initializer rather than as a default argument,
    /// because reading `AppSettings` is main-actor work and a default argument is not.
    init(
        store: ExtensionPackageStore = ExtensionPackageStore(),
        launchPolicy: ExtensionLaunchPolicy? = nil,
        companionLaunchPolicy: ExtensionCompanionLaunchPolicy =
            LocalExtensionCompanionLaunchPolicy(),
        companionPermissionAuthorizer:
            ExtensionCompanionSystemPermissionAuthorizing? = nil
    ) {
        self.store = store
        self.companionLaunchPolicy = companionLaunchPolicy
        self.companionPermissionAuthorizer = companionPermissionAuthorizer
            ?? SystemExtensionCompanionPermissionAuthorizer()
        self.launchPolicy = launchPolicy ?? Self.defaultLaunchPolicy(
            usesContainedLauncher: AppSettings.shared.usesContainedExtensionLauncher
        )
        self.settingsStore = ExtensionSettingsValueStore(
            rootURL: store.storageStore.settingsURL
        )
        refreshInventory(postChange: false)
        syncSettingsRegistry(postChange: false)
    }

    var installedExtensions: [InstalledExtensionSnapshot] {
        packages.values.map { package in
            let identifier = package.identifier
            let manifest = package.bundle?.manifest
            let status: InstalledExtensionStatus
            if let problem = package.problem {
                status = .invalid(problem)
            } else {
                status = statuses[identifier]
                    ?? (enabledIdentifiers.contains(identifier) ? .starting : .disabled)
            }

            return InstalledExtensionSnapshot(
                identifier: identifier,
                name: manifest?.name ?? identifier,
                version: manifest?.version,
                profile: manifest?.profile ?? .runtime,
                contributionKinds: manifest?.contributionKinds.sorted {
                    $0.rawValue < $1.rawValue
                } ?? [],
                capabilities: manifest?.capabilities.map(\.rawValue).sorted() ?? [],
                companions: manifest?.companions.sorted { $0.id < $1.id } ?? [],
                companionStatuses: Dictionary(
                    uniqueKeysWithValues: (manifest?.companions ?? []).map { companion in
                        let key = CompanionKey(
                            extensionIdentifier: identifier,
                            companionID: companion.id
                        )
                        let fallback: InstalledCompanionStatus
                        if !enabledIdentifiers.contains(identifier) {
                            fallback = .disabled
                        } else if companion.activation == .onDemand {
                            fallback = .onDemand
                        } else {
                            fallback = .starting
                        }
                        return (companion.id, companionStatuses[key] ?? fallback)
                    }
                ),
                services: manifest?.services ?? [],
                serviceDependencies: manifest?.serviceDependencies ?? [],
                packageURL: package.packageURL,
                provenance: package.provenance,
                isEnabled: enabledIdentifiers.contains(identifier),
                status: status
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func registration(for identifier: String) -> ExtensionRegistration? {
        registrations[identifier]
    }

    func isServiceAvailable(_ dependency: ExtensionServiceDependency) -> Bool {
        guard sessions[dependency.providerIdentifier] != nil else { return false }
        return registrations[dependency.providerIdentifier]?.services.contains {
            $0.id == dependency.serviceID && $0.version == dependency.version
        } == true
    }

    func settingValue(
        extensionIdentifier: String,
        field: ExtensionSettingField
    ) -> ExtensionJSONValue {
        (try? settingsStore.value(
            extensionIdentifier: extensionIdentifier,
            field: field
        )) ?? field.control.defaultValue
    }

    /// Persists one host-validated setting and, when the process is alive, waits for it to
    /// acknowledge the same value. Disabled or failed extensions read the persisted value from
    /// their launch environment the next time they start.
    func setSetting(
        extensionIdentifier: String,
        settingID: String,
        value: ExtensionJSONValue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let manifest = packages[extensionIdentifier]?.bundle?.manifest,
              let field = manifest.settings.field(id: settingID) else {
            completion(.failure(ExtensionSettingsManagerError.unknownSetting(settingID)))
            return
        }
        guard field.control.accepts(value) else {
            completion(.failure(ExtensionSettingsManagerError.invalidValue(settingID)))
            return
        }

        let oldValue = settingValue(extensionIdentifier: extensionIdentifier, field: field)
        do {
            try settingsStore.set(
                value,
                field: field,
                extensionIdentifier: extensionIdentifier
            )
        } catch {
            completion(.failure(error))
            return
        }

        guard let process = sessions[extensionIdentifier] else {
            NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
            completion(.success(()))
            return
        }

        process.updateSettings(values: [settingID: value]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response) where response.error == nil:
                NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
                completion(.success(()))
            case .success(let response):
                try? self.settingsStore.set(
                    oldValue,
                    field: field,
                    extensionIdentifier: extensionIdentifier
                )
                NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
                completion(.failure(
                    ExtensionSettingsManagerError.rejected(
                        response.error ?? "The extension rejected the value."
                    )
                ))
            case .failure(let error):
                try? self.settingsStore.set(
                    oldValue,
                    field: field,
                    extensionIdentifier: extensionIdentifier
                )
                NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
                completion(.failure(error))
            }
        }
    }

    /// Resolves a package-owned image without letting a publication escape its installed
    /// extension directory. The UI remains responsible for decoding the file as an image.
    func imageResourceURL(
        relativePath: String,
        extensionIdentifier: String
    ) -> URL? {
        resourceURL(
            relativePath: relativePath,
            extensionIdentifier: extensionIdentifier,
            maximumBytes: ExtensionResourceDefaults.maximumImageBytes
        )
    }

    func customSurfaceResourceURL(
        relativePath: String,
        extensionIdentifier: String
    ) -> URL? {
        resourceURL(
            relativePath: relativePath,
            extensionIdentifier: extensionIdentifier,
            maximumBytes: ExtensionResourceDefaults.maximumCustomSurfaceBytes
        )
    }

    private func resourceURL(
        relativePath: String,
        extensionIdentifier: String,
        maximumBytes: Int
    ) -> URL? {
        guard !relativePath.isEmpty,
              !NSString(string: relativePath).isAbsolutePath,
              NSString(string: relativePath).pathComponents.allSatisfy({
                  $0 != "." && $0 != ".." && $0 != "/"
              }),
              let root = packages[extensionIdentifier]?.bundle?.rootURL
                .standardizedFileURL.resolvingSymlinksInPath() else {
            return nil
        }

        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(
                  forKeys: [.isRegularFileKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= maximumBytes else {
            return nil
        }
        return candidate
    }

    /// Routes a host-rendered component action back to the process whose accepted patch
    /// contributed the replacement. The action ID is local to that extension.
    func invokeComponentAction(_ action: ComponentCustomizationAction) {
        guard let identifier = action.extensionIdentifier,
              enabledIdentifiers.contains(identifier),
              let process = sessions[identifier] else {
            return
        }

        process.invokeComponentAction(
            target: action.target,
            actionID: action.actionID
        ) { result in
            if case .failure(let error) = result {
                SkalmanLogger.extensions.error(
                    "Component action failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    var extensionPanelInventory: [ExtensionPanelInventoryItem] {
        registrations.flatMap { identifier, registration in
            guard enabledIdentifiers.contains(identifier),
                  sessions[identifier] != nil,
                  let processGeneration = sessionGenerations[identifier],
                  let manifest = packages[identifier]?.bundle?.manifest else {
                return [ExtensionPanelInventoryItem]()
            }
            return registration.panels.map {
                ExtensionPanelInventoryItem(
                    extensionIdentifier: identifier,
                    extensionName: manifest.name,
                    processGeneration: processGeneration,
                    panel: $0
                )
            }
        }
        .sorted {
            let extensionOrder = $0.extensionName.localizedCaseInsensitiveCompare(
                $1.extensionName
            )
            if extensionOrder != .orderedSame {
                return extensionOrder == .orderedAscending
            }
            return $0.panel.title.localizedCaseInsensitiveCompare($1.panel.title)
                == .orderedAscending
        }
    }

    func registeredPanel(
        extensionIdentifier: String,
        panelID: String
    ) -> ExtensionPanelInventoryItem? {
        guard enabledIdentifiers.contains(extensionIdentifier),
              sessions[extensionIdentifier] != nil,
              let processGeneration = sessionGenerations[extensionIdentifier],
              let manifest = packages[extensionIdentifier]?.bundle?.manifest,
              let panel = registrations[extensionIdentifier]?.panels.first(where: {
                  $0.id == panelID
              }) else {
            return nil
        }
        return ExtensionPanelInventoryItem(
            extensionIdentifier: extensionIdentifier,
            extensionName: manifest.name,
            processGeneration: processGeneration,
            panel: panel
        )
    }

    func extensionImageResourceURL(
        extensionIdentifier: String,
        relativePath: String
    ) -> URL? {
        imageResourceURL(
            relativePath: relativePath,
            extensionIdentifier: extensionIdentifier
        )
    }

    @discardableResult
    func invokePanelAction(
        extensionIdentifier: String,
        panelID: String,
        actionID: String,
        context: ExtensionCommandContext,
        completion: @escaping (Result<ExtensionActionResponse, Error>) -> Void
    ) -> Bool {
        guard enabledIdentifiers.contains(extensionIdentifier),
              registrations[extensionIdentifier]?.panels.contains(where: {
                  $0.id == panelID
              }) == true,
              let process = sessions[extensionIdentifier] else {
            completion(.failure(ExtensionProcessError.notRunning))
            return false
        }

        process.invoke(
            panelID: panelID,
            actionID: actionID,
            context: context,
            completion: completion
        )
        return true
    }

    func connectRemoteSurface(
        extensionIdentifier: String,
        panelID: String,
        context: ExtensionCommandContext,
        initialViewport: ExtensionRemoteSurfaceViewport,
        consumer: ExtensionRemoteSurfaceConsumer
    ) -> ExtensionRemoteSurfaceSubscription? {
        guard enabledIdentifiers.contains(extensionIdentifier),
              sessions[extensionIdentifier] != nil,
              let bundle = packages[extensionIdentifier]?.bundle,
              let panel = registrations[extensionIdentifier]?.panels.first(where: {
                  $0.id == panelID
              }),
              let reference = panel.remoteSurface,
              let companion = bundle.companions.first(where: {
                  $0.declaration.id == reference.companionID
              }),
              companion.declaration.capabilities.contains(.remoteSurfaces),
              let surface = companion.declaration.surfaces.first(where: {
                  $0.id == reference.surfaceID
              }),
              (try? ExtensionRemoteSurfaceMessage.viewport(initialViewport)
                  .validate(payloadCount: 0)) != nil,
              remotePresentations[initialViewport.presentationID] == nil else {
            return nil
        }

        let presentationID = initialViewport.presentationID
        let presentation = RemotePresentation(
            id: presentationID,
            extensionIdentifier: extensionIdentifier,
            companionID: reference.companionID,
            surface: surface,
            consumer: consumer
        )
        remotePresentations[presentationID] = presentation

        let subscription = ExtensionRemoteSurfaceSubscription(
            presentationID: presentationID,
            viewport: { [weak self] viewport in
                self?.updateRemoteSurfaceViewport(viewport)
            },
            input: { [weak self] input in
                self?.sendRemoteSurfaceInput(input)
            },
            cancellation: { [weak self] in
                self?.closeRemoteSurface(presentationID: presentationID)
            }
        )

        activateCompanion(
            extensionIdentifier: extensionIdentifier,
            companionID: reference.companionID
        ) { [weak self, weak consumer] result in
            guard let self,
                  let live = self.remotePresentations[presentationID],
                  live.consumer != nil else {
                return
            }
            switch result {
            case .failure(let error):
                self.remotePresentations.removeValue(forKey: presentationID)
                consumer?.remoteSurfaceDidDisconnect(message: error.localizedDescription)
            case .success:
                let key = CompanionKey(
                    extensionIdentifier: extensionIdentifier,
                    companionID: reference.companionID
                )
                guard let supervisor = self.companionSupervisors[key] else {
                    self.remotePresentations.removeValue(forKey: presentationID)
                    consumer?.remoteSurfaceDidDisconnect(
                        message: ExtensionProcessError.notRunning.localizedDescription
                    )
                    return
                }
                consumer?.remoteSurfaceDidConnect(definition: surface)
                supervisor.sendRemoteSurface(.open(.init(
                    presentationID: presentationID,
                    surfaceID: surface.id,
                    viewport: initialViewport,
                    projectID: context.projectID,
                    sessionID: context.sessionID
                )))
            }
        }
        return subscription
    }

    private func updateRemoteSurfaceViewport(
        _ viewport: ExtensionRemoteSurfaceViewport
    ) {
        guard (try? ExtensionRemoteSurfaceMessage.viewport(viewport)
            .validate(payloadCount: 0)) != nil,
              let presentation = remotePresentations[viewport.presentationID],
              let supervisor = companionSupervisor(for: presentation) else {
            return
        }
        supervisor.sendRemoteSurface(.viewport(viewport))
    }

    private func sendRemoteSurfaceInput(_ input: ExtensionRemoteSurfaceInput) {
        guard (try? ExtensionRemoteSurfaceMessage.input(input)
            .validate(payloadCount: 0)) != nil,
              let presentation = remotePresentations[input.presentationID],
              let supervisor = companionSupervisor(for: presentation) else {
            return
        }
        switch input.kind {
        case .pointerMoved, .pointerDown, .pointerUp, .scroll:
            guard presentation.surface.acceptsPointer else { return }
        case .keyDown, .keyUp:
            guard presentation.surface.acceptsKeyboard else { return }
        }
        supervisor.sendRemoteSurface(.input(input))
    }

    private func closeRemoteSurface(presentationID: String) {
        guard let presentation = remotePresentations.removeValue(
            forKey: presentationID
        ) else {
            return
        }
        companionSupervisor(for: presentation)?.sendRemoteSurface(
            .close(.init(presentationID: presentationID))
        )
    }

    private func companionSupervisor(
        for presentation: RemotePresentation
    ) -> ExtensionCompanionSupervisor? {
        companionSupervisors[CompanionKey(
            extensionIdentifier: presentation.extensionIdentifier,
            companionID: presentation.companionID
        )]
    }

    private func receiveRemoteSurfacePacket(
        _ packet: ExtensionRemoteSurfacePacket,
        key: CompanionKey,
        supervisor: ExtensionCompanionSupervisor
    ) {
        guard case .frame(let frame) = packet.message else { return }
        guard let presentation = remotePresentations[frame.presentationID],
              presentation.extensionIdentifier == key.extensionIdentifier,
              presentation.companionID == key.companionID,
              frame.width <= presentation.surface.maximumWidth,
              frame.height <= presentation.surface.maximumHeight,
              let consumer = presentation.consumer else {
            supervisor.acknowledgeRemoteSurfaceFrame(
                presentationID: frame.presentationID,
                sequence: frame.sequence,
                disposition: .dropped
            )
            return
        }
        let displayed = consumer.remoteSurfaceDidReceive(.init(
            metadata: frame,
            pixels: packet.payload
        ))
        supervisor.acknowledgeRemoteSurfaceFrame(
            presentationID: frame.presentationID,
            sequence: frame.sequence,
            disposition: displayed ? .displayed : .dropped
        )
    }

    private func disconnectRemoteSurfaces(
        for key: CompanionKey,
        message: String
    ) {
        let affected = remotePresentations.values.filter {
            $0.extensionIdentifier == key.extensionIdentifier
                && $0.companionID == key.companionID
        }
        for presentation in affected {
            remotePresentations.removeValue(forKey: presentation.id)
            presentation.consumer?.remoteSurfaceDidDisconnect(message: message)
        }
    }

    /// Runs one command only while its exact runtime registration still belongs to a live,
    /// enabled process. Menu metadata alone never keeps an extension entry point callable.
    @discardableResult
    func invokeCommand(
        extensionIdentifier: String,
        commandID: String,
        context: ExtensionCommandContext,
        requestID: String = UUID().uuidString.lowercased(),
        completion: @escaping (Result<ExtensionCommandResponse, Error>) -> Void
    ) -> Bool {
        guard enabledIdentifiers.contains(extensionIdentifier),
              registrations[extensionIdentifier]?.commands.contains(where: {
                  $0.id == commandID
              }) == true,
              let process = sessions[extensionIdentifier] else {
            completion(.failure(ExtensionProcessError.notRunning))
            return false
        }

        process.invokeCommand(
            commandID: commandID,
            context: context,
            requestID: requestID,
            completion: completion
        )
        return true
    }

    /// Static manifest metadata is visible in Tools settings before code runs. The registered
    /// subset is what the extension process may actually execute.
    var mcpToolInventory: [ExtensionMCPToolInventory] {
        packages.values.compactMap { package in
            guard let manifest = package.bundle?.manifest, !manifest.mcpTools.isEmpty else {
                return nil
            }
            return ExtensionMCPToolInventory(
                extensionIdentifier: manifest.identifier,
                extensionName: manifest.name,
                isExtensionEnabled: enabledIdentifiers.contains(manifest.identifier),
                declaredTools: manifest.mcpTools,
                registeredTools: registrations[manifest.identifier]?.mcpTools ?? []
            )
        }
        .sorted {
            $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName) == .orderedAscending
        }
    }

    /// Routes an MCP name back to its owning process. Returns `false` only when no installed
    /// extension declares the name; declared-but-disabled tools answer with a useful failure.
    @discardableResult
    func invokeMCPTool(
        named qualifiedName: String,
        arguments: ExtensionJSONValue,
        for sessionID: SessionID,
        requestID: String = UUID().uuidString.lowercased(),
        completion: @escaping (Result<ExtensionMCPToolResponse, Error>) -> Void
    ) -> Bool {
        guard let owner = mcpToolInventory.first(where: { inventory in
            inventory.declaredTools.contains {
                $0.qualifiedName(extensionIdentifier: inventory.extensionIdentifier) == qualifiedName
            }
        }), let declaration = owner.declaredTools.first(where: {
            $0.qualifiedName(extensionIdentifier: owner.extensionIdentifier) == qualifiedName
        }) else {
            return false
        }

        guard owner.isExtensionEnabled else {
            completion(.failure(ExtensionProcessError.notRunning))
            return true
        }
        guard AppSettings.shared.isToolGroupEnabled(owner.groupID) else {
            completion(.failure(ExtensionProcessError.notRunning))
            return true
        }
        guard owner.registeredTools.contains(declaration),
              let process = sessions[owner.extensionIdentifier] else {
            completion(.failure(ExtensionProcessError.notRunning))
            return true
        }

        process.invokeMCPTool(
            sessionID: sessionID.uuidString,
            toolID: declaration.id,
            arguments: arguments,
            requestID: requestID,
            completion: completion
        )
        return true
    }

    func invokeService(
        providerIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        callerExtensionIdentifier: String,
        arguments: ExtensionJSONValue,
        completion: @escaping (Result<ExtensionServiceResponse, Error>) -> Void
    ) {
        guard let process = sessions[providerIdentifier] else {
            completion(.failure(
                ExtensionServiceBrokerError.providerUnavailable(providerIdentifier)
            ))
            return
        }
        guard packages[providerIdentifier]?.bundle?.manifest.services.contains(where: {
            $0.id == serviceID && $0.version == serviceVersion
        }) == true,
        registrations[providerIdentifier]?.services.contains(where: {
            $0.id == serviceID && $0.version == serviceVersion
        }) == true else {
            completion(.failure(
                ExtensionServiceBrokerError.serviceUnavailable(serviceID, serviceVersion)
            ))
            return
        }

        process.invokeService(
            callerExtensionIdentifier: callerExtensionIdentifier,
            serviceID: serviceID,
            serviceVersion: serviceVersion,
            arguments: arguments,
            completion: completion
        )
    }

    func invokeCompanionOperation(
        extensionIdentifier: String,
        companionID: String,
        operationID: String,
        arguments: ExtensionJSONValue,
        completion: @escaping (
            Result<ExtensionCompanionOperationResponse, Error>
        ) -> Void
    ) {
        guard enabledIdentifiers.contains(extensionIdentifier),
              sessions[extensionIdentifier] != nil,
              let bundle = packages[extensionIdentifier]?.bundle,
              bundle.manifest.capabilities.contains(.companionOperations) else {
            completion(.failure(
                ExtensionManagerError.extensionNotRunning(extensionIdentifier)
            ))
            return
        }
        guard let companion = bundle.companions.first(where: {
                  $0.declaration.id == companionID
              }) else {
            completion(.failure(
                ExtensionManagerError.companionUnavailable(
                    extensionIdentifier: extensionIdentifier,
                    companionID: companionID
                )
            ))
            return
        }
        guard companion.declaration.operations.contains(where: {
            $0.id == operationID
        }) else {
            completion(.failure(
                ExtensionManagerError.companionOperationUnavailable(
                    companionID: companionID,
                    operationID: operationID
                )
            ))
            return
        }

        let key = CompanionKey(
            extensionIdentifier: extensionIdentifier,
            companionID: companionID
        )
        let invoke: () -> Void = { [weak self] in
            guard let self,
                  let supervisor = self.companionSupervisors[key] else {
                completion(.failure(
                    ExtensionManagerError.extensionNotRunning(extensionIdentifier)
                ))
                return
            }
            supervisor.invokeOperation(
                id: operationID,
                arguments: arguments,
                completion: completion
            )
        }
        if companionSupervisors[key]?.isRunning == true {
            invoke()
            return
        }
        activateCompanion(
            extensionIdentifier: extensionIdentifier,
            companionID: companionID
        ) { result in
            switch result {
            case .success:
                invoke()
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Starts every valid package whose persisted desired state is enabled.
    func startEnabledExtensions() {
        refreshInventory(postChange: false)
        for identifier in enabledIdentifiers.sorted() {
            guard packages[identifier]?.bundle != nil else { continue }
            start(identifier)
        }
    }

    /// Imports a package into app-owned storage. New installations are always disabled.
    func install(
        from sourceURL: URL,
        completion: @escaping (Result<InstalledExtensionSnapshot, Error>) -> Void
    ) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.install(from: sourceURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInventory(postChange: true)
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let bundle):
                    guard let installed = self.installedExtensions.first(where: {
                        $0.identifier == bundle.manifest.identifier
                    }) else {
                        completion(.failure(ExtensionPackageStoreError.installedCopyInvalid(
                            "the package disappeared after installation"
                        )))
                        return
                    }
                    completion(.success(installed))
                }
            }
        }
    }

    /// What replacing an installed extension with `sourceURL` would change.
    ///
    /// Read-only, so a caller can show the capability delta and let the user decide. Runs off
    /// the main thread because it inspects two packages on disk.
    func updatePlan(
        from sourceURL: URL,
        completion: @escaping (Result<ExtensionUpdatePlan, Error>) -> Void
    ) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.updatePlan(from: sourceURL) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Replaces an installed extension, stopping it first and restoring it afterwards.
    ///
    /// **The running generation is stopped before the package moves**, and that ordering is the
    /// whole reason this is not just `store.update`. An extension's executable is the file its
    /// process is running from; replacing it underneath a live child leaves a process whose
    /// image no longer matches its package, and the next thing to read that package — a reload,
    /// a capability check, the sandbox profile — would describe something the running process
    /// is not.
    ///
    /// Enablement is preserved, so an extension that was running is running again afterwards,
    /// on the new code. Nothing here re-asks for approval: `plan` is the caller's evidence that
    /// it already did, and `ExtensionPackageStore.update` re-checks that it still holds.
    func update(
        from sourceURL: URL,
        approving plan: ExtensionUpdatePlan,
        completion: @escaping (Result<InstalledExtensionSnapshot, Error>) -> Void
    ) {
        let identifier = plan.identifier
        guard packages[identifier] != nil else {
            completion(.failure(ExtensionPackageStoreError.notInstalled(identifier)))
            return
        }
        guard updatingIdentifiers.insert(identifier).inserted else {
            completion(.failure(ExtensionManagerError.operationInProgress(identifier)))
            return
        }
        // Stop synchronously, on the main actor, before any filesystem work is scheduled.
        stop(identifier, status: .updating)
        notifyChange()

        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.update(from: sourceURL, approving: plan) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatingIdentifiers.remove(identifier)
                self.statuses.removeValue(forKey: identifier)
                self.refreshInventory(postChange: true)

                // Desired state is read now, not captured before the asynchronous copy. Manager
                // actions are refused while updating, and re-reading persisted state also
                // makes an external administrative disable win over this completion.
                if self.enabledIdentifiers.contains(identifier) {
                    self.start(identifier)
                }
                switch result {
                case .failure(let error):
                    self.notifyChange()
                    completion(.failure(error))
                case .success(let bundle):
                    guard let installed = self.installedExtensions.first(where: {
                        $0.identifier == bundle.manifest.identifier
                    }) else {
                        completion(.failure(ExtensionPackageStoreError.installedCopyInvalid(
                            "the package disappeared after updating"
                        )))
                        return
                    }
                    completion(.success(installed))
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool, identifier: String) throws {
        guard !updatingIdentifiers.contains(identifier) else {
            throw ExtensionManagerError.operationInProgress(identifier)
        }
        guard let package = packages[identifier] else {
            throw ExtensionPackageStoreError.notInstalled(identifier)
        }
        if enabled, let problem = package.problem {
            throw ExtensionPackageStoreError.installedCopyInvalid(problem)
        }

        try store.setEnabled(enabled, identifier: identifier)
        enabledIdentifiers = store.enabledIdentifiers()

        if enabled {
            start(identifier)
        } else {
            stop(identifier, status: .disabled)
        }
        notifyChange()
    }

    func reload(identifier: String) {
        guard !updatingIdentifiers.contains(identifier),
              enabledIdentifiers.contains(identifier) else { return }
        stop(identifier, status: .starting)
        start(identifier)
    }

    /// Starts one declared companion through the same supervisor used for while-enabled
    /// workers. This is the host-side primitive a later Wasm-to-companion relay will call; it
    /// does not expose the process, its pipes, or any host bearer authority to the caller.
    func activateCompanion(
        extensionIdentifier: String,
        companionID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard enabledIdentifiers.contains(extensionIdentifier),
              sessions[extensionIdentifier] != nil,
              let bundle = packages[extensionIdentifier]?.bundle else {
            completion(.failure(
                ExtensionManagerError.extensionNotRunning(extensionIdentifier)
            ))
            return
        }
        guard let companion = bundle.companions.first(where: {
            $0.declaration.id == companionID
        }) else {
            completion(.failure(
                ExtensionManagerError.companionUnavailable(
                    extensionIdentifier: extensionIdentifier,
                    companionID: companionID
                )
            ))
            return
        }
        startCompanion(
            extensionBundle: bundle,
            companion: companion,
            extensionGeneration: generations[extensionIdentifier, default: 0],
            completion: completion
        )
    }

    /// Removes a package from discovery while preserving it under Extensions/Removed.
    @discardableResult
    func uninstall(identifier: String) throws -> URL {
        guard !updatingIdentifiers.contains(identifier) else {
            throw ExtensionManagerError.operationInProgress(identifier)
        }
        stop(identifier, status: .disabled)
        let recoveredAt = try store.uninstall(identifier: identifier)
        refreshInventory(postChange: true)
        return recoveredAt
    }

    func terminateAll() {
        let running = sessions
        let runningGenerations = sessionGenerations
        let companions = companionSupervisors
        for key in companions.keys {
            disconnectRemoteSurfaces(
                for: key,
                message: ExtensionProcessError.notRunning.localizedDescription
            )
        }
        // Presentations waiting for a companion launch are not in `companions` yet.
        let orphanedPresentations = Array(remotePresentations.values)
        remotePresentations.removeAll()
        for presentation in orphanedPresentations {
            presentation.consumer?.remoteSurfaceDidDisconnect(
                message: ExtensionProcessError.notRunning.localizedDescription
            )
        }
        sessions.removeAll()
        sessionGenerations.removeAll()
        registrations.removeAll()
        companionSupervisors.removeAll()
        companionStatuses.removeAll()
        companionStartTokens.removeAll()
        let pendingCompanionStarts = companionStartCompletions.values.flatMap { $0 }
        companionStartCompletions.removeAll()
        CommandRegistry.shared.removeAllExtensionCommands()
        for identifier in Set(running.keys).union(runningGenerations.keys) {
            generations[identifier, default: 0] += 1
            if let processGeneration = runningGenerations[identifier] {
                ExtensionHostService.shared.revoke(
                    extensionIdentifier: identifier,
                    processGeneration: processGeneration
                )
            }
        }
        pendingCompanionStarts.forEach {
            $0(.failure(ExtensionProcessError.notRunning))
        }
        companions.values.forEach { $0.stop() }
        running.values.forEach { $0.terminate() }
    }

    private func start(_ identifier: String) {
        guard !updatingIdentifiers.contains(identifier),
              enabledIdentifiers.contains(identifier),
              sessions[identifier] == nil,
              let bundle = packages[identifier]?.bundle else {
            return
        }

        generations[identifier, default: 0] += 1
        CommandRegistry.shared.removeExtensionCommands(extensionIdentifier: identifier)
        let generation = generations[identifier, default: 0]
        let processGeneration = UUID().uuidString.lowercased()
        statuses[identifier] = .starting
        notifyChange()

        let extensionOrder = enabledIdentifiers.sorted().firstIndex(of: identifier) ?? 0
        ExtensionHostService.shared.installServiceRouter(self)
        ExtensionHostService.shared.installCompanionRouter(self)
        ExtensionHostService.shared.installStorageStores(
            keyValue: store.storageStore,
            cache: store.storageStore
        )
        let transport = launchPolicy.hostTransport(for: bundle)
        let hostAuthorization: ExtensionHostAuthorization?
        do {
            hostAuthorization = try ExtensionHostService.shared.authorize(
                extensionIdentifier: identifier,
                processGeneration: processGeneration,
                order: extensionOrder,
                capabilities: bundle.manifest.capabilities,
                serviceDependencies: bundle.manifest.serviceDependencies,
                transport: transport
            )
        } catch {
            statuses[identifier] = .failed(error.localizedDescription)
            notifyChange()
            return
        }
        if hostAuthorization != nil {
            // Record authorization before the child starts. Disable/reload during its bounded
            // startup must revoke the token immediately, not after registration returns.
            sessionGenerations[identifier] = processGeneration
        }

        let storageStore = store.storageStore
        let settingsStore = settingsStore
        let launchPolicy = launchPolicy
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> ExtensionProcessSession.Started in
                var environment: [String: String]
                do {
                    environment = try storageStore.environment(
                        for: bundle.manifest,
                        transport: transport
                    )
                    let previousDataVersion = try storageStore.committedDataVersion(
                        identifier: identifier
                    )
                    guard bundle.manifest.dataVersion >= previousDataVersion else {
                        throw ExtensionStorageStoreError.dataVersionRollback(
                            identifier: identifier,
                            stored: previousDataVersion,
                            requested: bundle.manifest.dataVersion
                        )
                    }
                    environment[ExtensionDataMigrationEnvironment.previousVersion] =
                        String(previousDataVersion)
                    environment[ExtensionDataMigrationEnvironment.targetVersion] =
                        String(bundle.manifest.dataVersion)
                    if !bundle.manifest.settings.isEmpty {
                        let values = try settingsStore.effectiveValues(
                            extensionIdentifier: identifier,
                            settings: bundle.manifest.settings
                        )
                        environment[ExtensionSettingsEnvironment.valuesJSON] = String(
                            decoding: try JSONEncoder().encode(values),
                            as: UTF8.self
                        )
                    }
                } catch {
                    // Nothing has taken the broker socket yet — the launch policy consumes it,
                    // and this failed before reaching one. Leaving it open would keep the host
                    // end from ever seeing end-of-file.
                    if let descriptor = hostAuthorization?.childDescriptor {
                        close(descriptor)
                    }
                    throw error
                }
                environment.merge(hostAuthorization?.environment ?? [:]) {
                    _, hostValue in hostValue
                }
                let started = try ExtensionProcessSession.start(
                    bundle: bundle,
                    policy: launchPolicy,
                    additionalEnvironment: environment,
                    hostDescriptor: hostAuthorization?.childDescriptor
                )
                do {
                    try storageStore.commitDataVersion(
                        bundle.manifest.dataVersion,
                        identifier: identifier
                    )
                } catch {
                    started.session.terminate()
                    throw error
                }
                return started
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case .success(let started) = result {
                        started.session.terminate()
                    }
                    ExtensionHostService.shared.revoke(
                        extensionIdentifier: identifier,
                        processGeneration: processGeneration
                    )
                    return
                }
                guard self.generations[identifier] == generation,
                      self.enabledIdentifiers.contains(identifier) else {
                    if case .success(let started) = result {
                        started.session.terminate()
                    }
                    ExtensionHostService.shared.revoke(
                        extensionIdentifier: identifier,
                        processGeneration: processGeneration
                    )
                    return
                }

                switch result {
                case .failure(let error):
                    ExtensionHostService.shared.revoke(
                        extensionIdentifier: identifier,
                        processGeneration: processGeneration
                    )
                    if self.sessionGenerations[identifier] == processGeneration {
                        self.sessionGenerations.removeValue(forKey: identifier)
                    }
                    self.statuses[identifier] = .failed(error.localizedDescription)
                    CommandRegistry.shared.removeExtensionCommands(
                        extensionIdentifier: identifier
                    )
                    self.notifyChange()

                case .success(let started):
                    self.sessions[identifier] = started.session
                    self.sessionGenerations[identifier] = processGeneration
                    self.registrations[identifier] = started.registration
                    CommandRegistry.shared.replaceExtensionCommands(
                        extensionIdentifier: identifier,
                        extensionName: bundle.manifest.name,
                        commands: started.registration.commands
                    )
                    self.statuses[identifier] = .running(
                        commands: started.registration.commands.count,
                        panels: started.registration.panels.count,
                        tools: started.registration.mcpTools.count
                    )
                    if !bundle.manifest.settings.isEmpty,
                       let values = try? self.settingsStore.effectiveValues(
                           extensionIdentifier: identifier,
                           settings: bundle.manifest.settings
                       ),
                       !values.isEmpty {
                        started.session.updateSettings(values: values) { result in
                            if case .failure(let error) = result {
                                SkalmanLogger.extensions.error(
                                    "Initial settings sync failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                    }
                    started.session.observeTermination { [weak self, weak session = started.session] error in
                        guard let self, let session,
                              self.generations[identifier] == generation,
                              self.sessions[identifier] === session else {
                            return
                        }
                        self.sessions.removeValue(forKey: identifier)
                        if self.sessionGenerations[identifier] == processGeneration {
                            self.sessionGenerations.removeValue(forKey: identifier)
                        }
                        self.registrations.removeValue(forKey: identifier)
                        CommandRegistry.shared.removeExtensionCommands(
                            extensionIdentifier: identifier
                        )
                        ExtensionHostService.shared.revoke(
                            extensionIdentifier: identifier,
                            processGeneration: processGeneration
                        )
                        self.stopCompanions(
                            extensionIdentifier: identifier,
                            finalStatus: self.enabledIdentifiers.contains(identifier)
                                ? .failed("the extension core stopped")
                                : .disabled
                        )
                        if self.enabledIdentifiers.contains(identifier) {
                            self.statuses[identifier] = .failed(error.localizedDescription)
                        } else {
                            self.statuses[identifier] = .disabled
                        }
                        self.notifyChange()
                    }
                    self.startWhileEnabledCompanions(
                        extensionBundle: bundle,
                        extensionGeneration: generation
                    )
                    self.notifyChange()
                }
            }
        }
    }

    private func startWhileEnabledCompanions(
        extensionBundle: SkalmanExtensionBundle,
        extensionGeneration: Int
    ) {
        let identifier = extensionBundle.manifest.identifier
        for companion in extensionBundle.companions {
            let key = CompanionKey(
                extensionIdentifier: identifier,
                companionID: companion.declaration.id
            )
            switch companion.declaration.activation {
            case .onDemand:
                if companionSupervisors[key] == nil {
                    companionStatuses[key] = .onDemand
                }
            case .whileExtensionEnabled:
                startCompanion(
                    extensionBundle: extensionBundle,
                    companion: companion,
                    extensionGeneration: extensionGeneration,
                    completion: nil
                )
            }
        }
    }

    private func startCompanion(
        extensionBundle: SkalmanExtensionBundle,
        companion: SkalmanExtensionCompanionBundle,
        extensionGeneration: Int,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        let identifier = extensionBundle.manifest.identifier
        let key = CompanionKey(
            extensionIdentifier: identifier,
            companionID: companion.declaration.id
        )
        if let running = companionSupervisors[key], running.isRunning {
            completion?(.success(()))
            return
        }
        if let completion {
            companionStartCompletions[key, default: []].append(completion)
        }
        guard companionStartTokens[key] == nil else { return }
        let startToken = UUID().uuidString.lowercased()
        companionStartTokens[key] = startToken

        companionStatuses[key] = .starting
        notifyChange()
        do {
            try companionPermissionAuthorizer.authorize(
                capabilities: companion.declaration.capabilities
            )
        } catch {
            companionStartTokens.removeValue(forKey: key)
            let completions = companionStartCompletions.removeValue(forKey: key) ?? []
            companionStatuses[key] = .failed(error.localizedDescription)
            completions.forEach { $0(.failure(error)) }
            notifyChange()
            return
        }
        let policy = companionLaunchPolicy
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try ExtensionCompanionSupervisor.start(
                    extensionBundle: extensionBundle,
                    companion: companion,
                    policy: policy
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case .success(let supervisor) = result {
                        supervisor.stop()
                    }
                    return
                }
                guard self.companionStartTokens[key] == startToken else {
                    if case .success(let supervisor) = result {
                        supervisor.stop()
                    }
                    return
                }
                self.companionStartTokens.removeValue(forKey: key)
                let completions = self.companionStartCompletions.removeValue(
                    forKey: key
                ) ?? []

                guard self.generations[identifier] == extensionGeneration,
                      self.enabledIdentifiers.contains(identifier),
                      self.sessions[identifier] != nil else {
                    if case .success(let supervisor) = result {
                        supervisor.stop()
                    }
                    let error = ExtensionManagerError.extensionNotRunning(identifier)
                    completions.forEach { $0(.failure(error)) }
                    self.companionStatuses[key] = .disabled
                    self.notifyChange()
                    return
                }

                switch result {
                case .failure(let error):
                    self.companionStatuses[key] = .failed(error.localizedDescription)
                    completions.forEach { $0(.failure(error)) }

                case .success(let supervisor):
                    self.companionSupervisors[key] = supervisor
                    self.companionStatuses[key] = .running
                    supervisor.startRemoteSurfaces {
                        [weak self, weak supervisor] packet in
                        DispatchQueue.main.async {
                            guard let self, let supervisor,
                                  self.companionSupervisors[key] === supervisor else {
                                return
                            }
                            self.receiveRemoteSurfacePacket(
                                packet,
                                key: key,
                                supervisor: supervisor
                            )
                        }
                    }
                    completions.forEach { $0(.success(())) }
                    supervisor.observeTermination {
                        [weak self, weak supervisor] error in
                        guard let self, let supervisor,
                              self.generations[identifier] == extensionGeneration,
                              self.companionSupervisors[key] === supervisor else {
                            return
                        }
                        self.companionSupervisors.removeValue(forKey: key)
                        self.disconnectRemoteSurfaces(
                            for: key,
                            message: error.localizedDescription
                        )
                        self.companionStatuses[key] = self.enabledIdentifiers
                            .contains(identifier)
                            ? .failed(error.localizedDescription)
                            : .disabled
                        self.notifyChange()
                    }
                }
                self.notifyChange()
            }
        }
    }

    private func stopCompanions(
        extensionIdentifier: String,
        finalStatus: InstalledCompanionStatus?
    ) {
        let keys = Set(companionSupervisors.keys.filter {
            $0.extensionIdentifier == extensionIdentifier
        }).union(companionStartTokens.keys.filter {
            $0.extensionIdentifier == extensionIdentifier
        }).union(companionStatuses.keys.filter {
            $0.extensionIdentifier == extensionIdentifier
        })

        for key in keys {
            disconnectRemoteSurfaces(
                for: key,
                message: ExtensionProcessError.notRunning.localizedDescription
            )
            companionSupervisors.removeValue(forKey: key)?.stop()
            companionStartTokens.removeValue(forKey: key)
            let completions = companionStartCompletions.removeValue(forKey: key) ?? []
            let error = ExtensionManagerError.extensionNotRunning(extensionIdentifier)
            completions.forEach { $0(.failure(error)) }
            if let finalStatus {
                companionStatuses[key] = finalStatus
            } else {
                companionStatuses.removeValue(forKey: key)
            }
        }
    }

    private func stop(_ identifier: String, status: InstalledExtensionStatus) {
        generations[identifier, default: 0] += 1
        stopCompanions(
            extensionIdentifier: identifier,
            finalStatus: status == .disabled ? .disabled : nil
        )
        let session = sessions.removeValue(forKey: identifier)
        let processGeneration = sessionGenerations.removeValue(forKey: identifier)
        registrations.removeValue(forKey: identifier)
        CommandRegistry.shared.removeExtensionCommands(extensionIdentifier: identifier)
        statuses[identifier] = status
        if let processGeneration {
            ExtensionHostService.shared.revoke(
                extensionIdentifier: identifier,
                processGeneration: processGeneration
            )
        }
        session?.terminate()
    }

    private func refreshInventory(postChange: Bool) {
        let inventory = store.inventory()
        packages = Dictionary(
            inventory.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        enabledIdentifiers = store.enabledIdentifiers()

        statuses = statuses.filter { packages[$0.key] != nil }
        for package in inventory {
            if let problem = package.problem {
                statuses[package.identifier] = .invalid(problem)
            } else if statuses[package.identifier] == nil {
                statuses[package.identifier] = enabledIdentifiers.contains(package.identifier)
                    ? .starting
                    : .disabled
            }
        }

        if postChange {
            notifyChange()
        }
    }

    private func notifyChange() {
        syncSettingsRegistry()
        NotificationCenter.default.post(ExtensionsDidChange())
    }

    private func syncSettingsRegistry(postChange: Bool = true) {
        ExtensionSettingsRegistry.shared.replace(
            enabledManifests: enabledIdentifiers.compactMap {
                packages[$0]?.bundle?.manifest
            },
            postChange: postChange
        )
    }
}

private enum ExtensionResourceDefaults {
    static let maximumImageBytes = 4 * 1024 * 1024
    static let maximumCustomSurfaceBytes = 256 * 1024
}

private enum ExtensionSettingsManagerError: LocalizedError {
    case unknownSetting(String)
    case invalidValue(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unknownSetting(let id):
            return "The extension does not declare setting “\(id)”."
        case .invalidValue(let id):
            return "The value does not match extension setting “\(id)”."
        case .rejected(let message):
            return message
        }
    }
}
