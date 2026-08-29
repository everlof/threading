import AppKit
import ThreadingExtensionKit

/// Owns selection and generation-safe failback while the navigator renderer owns only one
/// extension document. Keeping this shell separate makes the Native fallback an orchestration
/// invariant rather than another branch inside collection rendering.
final class WorkspaceSidebarContainerViewController: NSViewController {
    private let nativeController: ProjectSidebarViewController
    private let routing: ExtensionWorkspaceNavigatorRouting
    private let contextProvider: WorkspaceNavigatorHostViewController.ContextProvider
    private let destinationHandler: WorkspaceNavigatorHostViewController.DestinationHandler
    private var visibleController: NSViewController?
    private var extensionController: WorkspaceNavigatorHostViewController?
    private var desiredSelection: WorkspaceNavigatorSelection = .native
    private var settingsOverride = false
    private var settingsPendingSessionIDs = Set<SessionID>()
    private var documentRefreshPending = false
    private var unavailableGeneration: String?

    private(set) var effectiveSelection: WorkspaceNavigatorSelection = .native

    init(
        nativeController: ProjectSidebarViewController,
        routing: ExtensionWorkspaceNavigatorRouting,
        contextProvider: @escaping WorkspaceNavigatorHostViewController.ContextProvider,
        destinationHandler: @escaping WorkspaceNavigatorHostViewController.DestinationHandler
    ) {
        self.nativeController = nativeController
        self.routing = routing
        self.contextProvider = contextProvider
        self.destinationHandler = destinationHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
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
            effectiveSelection = .native
            show(nativeController)
            return
        }
        guard case .extensionNavigator(let extensionIdentifier, let navigatorID) =
            desiredSelection,
              let inventory = routing.registeredWorkspaceNavigator(
                  extensionIdentifier: extensionIdentifier,
                  navigatorID: navigatorID
              ),
              inventory.processGeneration != unavailableGeneration else {
            extensionController?.setLiveEventDeliveryEnabled(false)
            effectiveSelection = .native
            extensionController = nil
            show(nativeController)
            return
        }
        unavailableGeneration = nil

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

    func refreshDocument() {
        guard !settingsOverride,
              case .extensionNavigator = effectiveSelection else {
            if case .extensionNavigator = desiredSelection {
                documentRefreshPending = true
            }
            return
        }
        extensionController?.refresh()
    }

    func sessionDidChange(_ sessionID: SessionID) {
        guard case .extensionNavigator = desiredSelection else { return }
        if settingsOverride {
            _ = retainForSettings([sessionID])
            return
        }
        extensionController?.sessionDidChange(sessionID)
    }

    func synchronizeSelection(with destination: ExtensionWorkspaceNavigatorDestination?) {
        extensionController?.synchronizeSelection(with: destination)
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
    }
}
