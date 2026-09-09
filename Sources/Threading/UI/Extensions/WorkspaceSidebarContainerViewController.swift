import AppKit
import ThreadingExtensionKit
import ThreadingPluginKit

/// Owns selection and generation-safe failback while the navigator renderer owns only one
/// extension document. Keeping this shell separate makes the Native fallback an orchestration
/// invariant rather than another branch inside collection rendering.
final class WorkspaceSidebarContainerViewController: NSViewController {
    var onHoverChange: ((Bool) -> Void)? {
        didSet { trackingView.onHoverChange = onHoverChange }
    }
    var onThemedPresentationChange: ((Bool) -> Void)? {
        didSet { trackingView.onThemedPresentationChange = onThemedPresentationChange }
    }
    var onEffectiveSelectionChange: ((WorkspaceNavigatorSelection) -> Void)?

    private let trackingView = HoverTrackingView()
    private let nativeController: ProjectSidebarViewController
    private let routing: ExtensionWorkspaceNavigatorRouting
    private let nativeRegistry: NativeWorkspaceNavigatorRegistry
    private let nativeSnapshotSource: NativeWorkspaceNavigatorSnapshotSource
    private let nativeActivationHandler: (PluginWorkspaceItemIdentity) -> Bool
    private let nativeActionHandler:
        (PluginWorkspaceAction, PluginWorkspaceItemIdentity) -> Bool
    private let nativePluginLoader:
        NativePluginWorkspaceNavigatorHostViewController.LoadPlugin?
    private let contextProvider: WorkspaceNavigatorHostViewController.ContextProvider
    private let destinationHandler: WorkspaceNavigatorHostViewController.DestinationHandler
    private let factSnapshotProvider: WorkspaceNavigatorHostViewController.FactSnapshotProvider
    private let factSnapshotPatchProvider:
        WorkspaceNavigatorHostViewController.FactSnapshotPatchProvider
    private let registeredFactChoicesProvider:
        WorkspaceNavigatorHostViewController.RegisteredFactChoicesProvider
    private let intentHandler: WorkspaceNavigatorHostViewController.IntentHandler
    private let onSelectNative: () -> Void
    private var visibleController: NSViewController?
    private var extensionController: WorkspaceNavigatorHostViewController?
    private var nativePluginController: NativePluginWorkspaceNavigatorHostViewController?
    private var nativeSelectedIdentity: PluginWorkspaceItemIdentity?
    private var desiredSelection: WorkspaceNavigatorSelection = .native
    private var settingsOverride = false
    private var settingsPendingSessionIDs = Set<SessionID>()
    private var documentRefreshPending = false
    private var unavailableGeneration: String?

    private(set) var effectiveSelection: WorkspaceNavigatorSelection = .native {
        didSet {
            guard effectiveSelection != oldValue else { return }
            onEffectiveSelectionChange?(effectiveSelection)
        }
    }

    init(
        nativeController: ProjectSidebarViewController,
        routing: ExtensionWorkspaceNavigatorRouting,
        nativeRegistry: NativeWorkspaceNavigatorRegistry = .shared,
        nativeSnapshotSource: NativeWorkspaceNavigatorSnapshotSource = .init(),
        nativeActivationHandler: @escaping (PluginWorkspaceItemIdentity) -> Bool = { _ in false },
        nativeActionHandler:
            @escaping (PluginWorkspaceAction, PluginWorkspaceItemIdentity) -> Bool = { _, _ in
                false
            },
        nativePluginLoader: NativePluginWorkspaceNavigatorHostViewController.LoadPlugin? = nil,
        contextProvider: @escaping WorkspaceNavigatorHostViewController.ContextProvider,
        destinationHandler: @escaping WorkspaceNavigatorHostViewController.DestinationHandler,
        factSnapshotProvider: @escaping WorkspaceNavigatorHostViewController.FactSnapshotProvider = {
            _ in nil
        },
        factSnapshotPatchProvider:
            @escaping WorkspaceNavigatorHostViewController.FactSnapshotPatchProvider = {
                _, _, _ in nil
            },
        registeredFactChoicesProvider:
            @escaping WorkspaceNavigatorHostViewController.RegisteredFactChoicesProvider = {
                _, selected in selected.map { [.unavailable($0)] } ?? []
            },
        intentHandler: @escaping WorkspaceNavigatorHostViewController.IntentHandler = {
            _, _ in .targetUnavailable
        },
        onSelectNative: @escaping () -> Void = {}
    ) {
        self.nativeController = nativeController
        self.routing = routing
        self.nativeRegistry = nativeRegistry
        self.nativeSnapshotSource = nativeSnapshotSource
        self.nativeActivationHandler = nativeActivationHandler
        self.nativeActionHandler = nativeActionHandler
        self.nativePluginLoader = nativePluginLoader
        self.contextProvider = contextProvider
        self.destinationHandler = destinationHandler
        self.factSnapshotProvider = factSnapshotProvider
        self.factSnapshotPatchProvider = factSnapshotPatchProvider
        self.registeredFactChoicesProvider = registeredFactChoicesProvider
        self.intentHandler = intentHandler
        self.onSelectNative = onSelectNative
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        trackingView.onHoverChange = onHoverChange
        trackingView.onThemedPresentationChange = onThemedPresentationChange
        view = trackingView
        show(nativeController)
    }

    func activate(_ selection: WorkspaceNavigatorSelection) {
        if selection != desiredSelection {
            unavailableGeneration = nil
            settingsPendingSessionIDs.removeAll(keepingCapacity: true)
            documentRefreshPending = false
        }
        desiredSelection = selection
        refreshAvailability()
    }

    func setSettingsOverride(_ enabled: Bool) {
        guard enabled != settingsOverride else { return }
        settingsOverride = enabled
        if enabled, let controller = extensionController {
            guard retainForSettings(controller.suspendLiveEventDelivery()) else { return }
        }
        refreshAvailability()
    }

    func refreshAvailability() {
        guard !settingsOverride else {
            extensionController?.setLiveEventDeliveryEnabled(false)
            effectiveSelection = .native
            show(nativeController)
            return
        }

        switch desiredSelection {
        case .native:
            extensionController?.setLiveEventDeliveryEnabled(false)
            extensionController = nil
            nativePluginController = nil
            effectiveSelection = .native
            show(nativeController)

        case .extensionNavigator(let extensionIdentifier, let navigatorID):
            showExtensionNavigator(
                extensionIdentifier: extensionIdentifier,
                navigatorID: navigatorID
            )

        case .nativePluginNavigator(let pluginIdentifier, let navigatorID):
            showNativePluginNavigator(
                pluginIdentifier: pluginIdentifier,
                navigatorID: navigatorID
            )
        }
    }

    private func showExtensionNavigator(extensionIdentifier: String, navigatorID: String) {
        guard let inventory = routing.registeredWorkspaceNavigator(
                  extensionIdentifier: extensionIdentifier,
                  navigatorID: navigatorID
              ),
              inventory.processGeneration != unavailableGeneration else {
            extensionController?.setLiveEventDeliveryEnabled(false)
            effectiveSelection = .native
            extensionController = nil
            nativePluginController = nil
            show(nativeController)
            return
        }
        unavailableGeneration = nil
        nativePluginController = nil

        let controller: WorkspaceNavigatorHostViewController
        let createdController: Bool
        if let current = extensionController,
           current.extensionIdentifier == extensionIdentifier,
           current.navigatorID == navigatorID,
           current.processGeneration == inventory.processGeneration {
            controller = current
            createdController = false
        } else {
            controller = WorkspaceNavigatorHostViewController(
                inventory: inventory,
                routing: routing,
                contextProvider: contextProvider,
                destinationHandler: destinationHandler,
                factSnapshotProvider: factSnapshotProvider,
                factSnapshotPatchProvider: factSnapshotPatchProvider,
                registeredFactChoicesProvider: registeredFactChoicesProvider,
                intentHandler: intentHandler,
                onSelectNative: onSelectNative,
                onUnavailable: { [weak self] in
                    self?.failBack(
                        extensionIdentifier: extensionIdentifier,
                        navigatorID: navigatorID,
                        processGeneration: inventory.processGeneration
                    )
                }
            )
            extensionController = controller
            createdController = true
        }
        // A replacement controller has not loaded its view yet. Keep events paused while `show`
        // loads it and queues the initial load action; otherwise catch-up can run first and an
        // older load response can overwrite the fresh event content with no edge left to retry.
        controller.setLiveEventDeliveryEnabled(false)
        if !createdController {
            controller.updateOptionValues(from: inventory)
        }
        let catchUpSessionIDs = settingsPendingSessionIDs
        settingsPendingSessionIDs.removeAll(keepingCapacity: true)
        catchUpSessionIDs.forEach(controller.sessionDidChange)
        effectiveSelection = desiredSelection
        show(controller)
        if createdController {
            // `viewDidLoad` queued the initial load, which subsumes any hidden project refresh.
            documentRefreshPending = false
        } else if documentRefreshPending {
            documentRefreshPending = false
            controller.refresh()
        }
        controller.setLiveEventDeliveryEnabled(true)
    }

    private func showNativePluginNavigator(pluginIdentifier: String, navigatorID: String) {
        extensionController?.setLiveEventDeliveryEnabled(false)
        extensionController = nil
        unavailableGeneration = nil

        guard let descriptor = nativeRegistry.descriptor(
            pluginIdentifier: pluginIdentifier,
            navigatorID: navigatorID
        ) else {
            nativePluginController = nil
            effectiveSelection = .native
            show(nativeController)
            return
        }

        let controller: NativePluginWorkspaceNavigatorHostViewController
        let createdController: Bool
        if let current = nativePluginController, current.descriptor == descriptor {
            controller = current
            createdController = false
        } else {
            controller = NativePluginWorkspaceNavigatorHostViewController(
                descriptor: descriptor,
                initialSnapshot: nativeSnapshotSource.initialSnapshot(
                    selectedItemIdentity: nativeSelectedIdentity
                ),
                activate: nativeActivationHandler,
                perform: nativeActionHandler,
                loadPlugin: nativePluginLoader,
                onUnavailable: { [weak self] failure in
                    self?.failBack(nativeDescriptor: descriptor, failure: failure)
                }
            )
            nativePluginController = controller
            createdController = true
        }

        let catchUpSessionIDs = settingsPendingSessionIDs
        settingsPendingSessionIDs.removeAll(keepingCapacity: true)
        effectiveSelection = desiredSelection
        show(controller)
        if createdController {
            documentRefreshPending = false
        } else if documentRefreshPending {
            documentRefreshPending = false
            controller.receive(nativeSnapshotSource.replacement(
                selectedItemIdentity: nativeSelectedIdentity
            ))
        }
        catchUpSessionIDs.forEach { sessionID in
            if let update = nativeSnapshotSource.sessionUpdate(sessionID) {
                controller.receive(update)
            }
        }
    }

    func refreshDocument() {
        guard !settingsOverride else {
            switch desiredSelection {
            case .extensionNavigator, .nativePluginNavigator:
                documentRefreshPending = true
            case .native:
                break
            }
            return
        }
        switch effectiveSelection {
        case .extensionNavigator:
            extensionController?.refresh()
        case .nativePluginNavigator:
            nativePluginController?.receive(nativeSnapshotSource.replacement(
                selectedItemIdentity: nativeSelectedIdentity
            ))
        case .native:
            break
        }
    }

    func sessionDidChange(_ sessionID: SessionID) {
        switch desiredSelection {
        case .native:
            return
        case .extensionNavigator, .nativePluginNavigator:
            break
        }
        if settingsOverride {
            _ = retainForSettings([sessionID])
            return
        }
        switch effectiveSelection {
        case .extensionNavigator:
            extensionController?.sessionDidChange(sessionID)
        case .nativePluginNavigator:
            guard let update = nativeSnapshotSource.sessionUpdate(sessionID) else { return }
            nativePluginController?.receive(update)
        case .native:
            break
        }
    }

    func synchronizeSelection(
        with destination: ExtensionWorkspaceNavigatorDestination?,
        nativeIdentity: PluginWorkspaceItemIdentity? = nil
    ) {
        extensionController?.synchronizeSelection(with: destination)
        nativeSelectedIdentity = nativeIdentity
        guard let update = nativeSnapshotSource.selectionUpdate(nativeIdentity) else { return }
        nativePluginController?.receive(update)
    }

    /// Routes a lifecycle receipt to whichever navigator shell is actually visible when the
    /// asynchronous result arrives. `show(_:)` also transfers requests which were already live
    /// before a shell swap, so neither completion ordering can strand Archive's Undo.
    func presentToast(_ toast: ToastRequest) {
        if let extensionHost = visibleController as? WorkspaceNavigatorHostViewController {
            extensionHost.presentToast(toast)
        } else if let nativePluginHost =
                    visibleController as? NativePluginWorkspaceNavigatorHostViewController {
            nativePluginHost.presentToast(toast)
        } else {
            nativeController.presentToast(toast)
        }
    }

    private func failBack(
        extensionIdentifier: String,
        navigatorID: String,
        processGeneration: String
    ) {
        guard let current = extensionController,
              current.extensionIdentifier == extensionIdentifier,
              current.navigatorID == navigatorID,
              current.processGeneration == processGeneration else {
            return
        }
        unavailableGeneration = processGeneration
        current.setLiveEventDeliveryEnabled(false)
        extensionController = nil
        effectiveSelection = .native
        show(nativeController)
    }

    private func failBack(
        nativeDescriptor: NativeWorkspaceNavigatorDescriptor,
        failure: PluginLoadFailure
    ) {
        guard let current = nativePluginController,
              current.descriptor == nativeDescriptor,
              desiredSelection == nativeDescriptor.selection else { return }
        nativePluginController = nil
        effectiveSelection = .native
        show(nativeController)
        if case .buildChanged = failure { nativeRegistry.refresh() }
    }

    @discardableResult
    private func retainForSettings<S: Sequence>(_ sessionIDs: S) -> Bool
    where S.Element == SessionID {
        var retained = settingsPendingSessionIDs
        retained.formUnion(sessionIDs)
        guard retained.count <= WorkspaceNavigatorHostViewController.maximumPendingSessionIDs
        else {
            settingsPendingSessionIDs.removeAll(keepingCapacity: true)
            extensionController?.setLiveEventDeliveryEnabled(false)
            if case .extensionNavigator(let extensionIdentifier, let navigatorID) = desiredSelection {
                unavailableGeneration = routing.registeredWorkspaceNavigator(
                    extensionIdentifier: extensionIdentifier,
                    navigatorID: navigatorID
                )?.processGeneration ?? extensionController?.processGeneration
            }
            extensionController = nil
            nativePluginController = nil
            effectiveSelection = .native
            show(nativeController)
            return false
        }
        settingsPendingSessionIDs = retained
        return true
    }

    /// Adds the replacement before removing the old controller, so failback and process reloads
    /// never expose an empty split item between generations.
    private func show(_ controller: NSViewController) {
        // `show` is also called from `loadView`. If an external refresh gets here first, force
        // that load to finish before checking identity; the inner call installs the controller
        // and this outer call then becomes a no-op instead of adding the same child twice.
        _ = view
        guard visibleController !== controller else { return }

        let previous = visibleController
        (previous as? WorkspaceNavigatorHostViewController)?.dismissPresentedMenu()
        let transferredToasts: [ToastRequest]
        if let extensionHost = previous as? WorkspaceNavigatorHostViewController {
            transferredToasts = extensionHost.takePresentedToastsForTransfer()
        } else if let nativePluginHost =
                    previous as? NativePluginWorkspaceNavigatorHostViewController {
            transferredToasts = nativePluginHost.takePresentedToastsForTransfer()
        } else if previous === nativeController {
            transferredToasts = nativeController.takePresentedToastsForTransfer()
        } else {
            transferredToasts = []
        }
        addChild(controller)
        let presented = controller.view
        presented.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(presented)
        NSLayoutConstraint.activate([
            presented.topAnchor.constraint(equalTo: view.topAnchor),
            presented.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            presented.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            presented.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        visibleController = controller

        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
        transferredToasts.forEach(presentToast)
    }
}
