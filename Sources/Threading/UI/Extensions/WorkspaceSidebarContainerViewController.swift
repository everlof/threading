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
        }
        desiredSelection = selection
        refreshAvailability()
    }

    func setSettingsOverride(_ enabled: Bool) {
        settingsOverride = enabled
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
            effectiveSelection = .native
            extensionController = nil
            show(nativeController)
            return
        }
        unavailableGeneration = nil

        let controller: WorkspaceNavigatorHostViewController
        if let current = extensionController,
           current.extensionIdentifier == extensionIdentifier,
           current.navigatorID == navigatorID,
           current.processGeneration == inventory.processGeneration {
            controller = current
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
        }
        effectiveSelection = desiredSelection
        show(controller)
    }

    func refreshDocument() {
        extensionController?.refresh()
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
        extensionController = nil
        effectiveSelection = .native
        show(nativeController)
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
