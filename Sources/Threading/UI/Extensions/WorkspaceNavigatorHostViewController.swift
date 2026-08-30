import AppKit
import ThreadingExtensionKit

/// Presents one live extension navigator inside Threading's host-owned sidebar shell.
///
/// Full documents are rebuilt atomically. Live item content patches keep the existing collection
/// views in place and reload only rows addressed by stable semantic IDs.
final class WorkspaceNavigatorHostViewController: NSViewController {
    typealias ContextProvider = () -> ExtensionCommandContext
    typealias DestinationHandler = (ExtensionWorkspaceNavigatorDestination) -> String?

    static let maximumPendingSessionIDs =
        ExtensionWorkspaceNavigatorHostEvent.maximumSessionIDs * 4

    let extensionIdentifier: String
    let navigatorID: String
    let processGeneration: String

    private let routing: ExtensionWorkspaceNavigatorRouting
    private let contextProvider: ContextProvider
    private let destinationHandler: DestinationHandler
    private let onSelectNative: () -> Void
    private let onUnavailable: () -> Void
    /// Localized once from the validated registration. Runtime documents may replace content,
    /// never the host-owned option contract which scopes durable user choices.
    private let declaredOptions: [ExtensionWorkspaceNavigatorOption]
    private var navigator: ExtensionWorkspaceNavigator
    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: navigator.title)
        label.applyFont(.controlRegular)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("workspace.navigator.title")
        return label
    }()
    private lazy var menuButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: L10n.string("Navigator"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Navigator")
        button.presentsMenu = true
        button.setAccessibilityIdentifier("workspace.navigator.menu")
        button.onPress = { [weak self] in self?.showNavigatorMenu() }
        return button
    }()
    private lazy var header: PaneHeaderView = {
        let header = PaneHeaderView(
            leading: [titleLabel],
            trailing: [menuButton],
            margin: .paneEdge
        )
        header.setAccessibilityIdentifier("workspace.navigator.header")
        return header
    }()
    private var rootHost: NSView?
    private var activeMenuSession: AnyObject?
    private var collectionControllers: [WorkspaceNavigatorCollectionViewController] = []
    private var collectionStates: [String: WorkspaceNavigatorCollectionState] = [:]
    private var synchronizedDestination: ExtensionWorkspaceNavigatorDestination?
    private var actionSequence = 0
    private var ordinaryActionSequencesInFlight = Set<Int>()
    private var contentRevision = 0
    private var pendingSessionIDs = Set<SessionID>()
    private var inFlightSessionIDs = Set<SessionID>()
    private var isEventDispatchScheduled = false
    private var isEventActionInFlight = false
    private var isLiveEventDeliveryEnabled = true
    private var isFailingClosed = false
    private lazy var toasts = ToastPresenter(host: view, above: view.bottomAnchor)

    init(
        inventory: ExtensionWorkspaceNavigatorInventoryItem,
        routing: ExtensionWorkspaceNavigatorRouting,
        contextProvider: @escaping ContextProvider,
        destinationHandler: @escaping DestinationHandler,
        onSelectNative: @escaping () -> Void = {},
        onUnavailable: @escaping () -> Void
    ) {
        extensionIdentifier = inventory.extensionIdentifier
        navigatorID = inventory.navigator.id
        processGeneration = inventory.processGeneration
        navigator = inventory.navigator
        declaredOptions = inventory.navigator.options
        self.routing = routing
        self.contextProvider = contextProvider
        self.destinationHandler = destinationHandler
        self.onSelectNative = onSelectNative
        self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier("workspace.navigator.host")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let backdrop = SidebarBackdropView()
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        render(navigator)
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        guard let actionID = navigator.loadActionID else { return }
        invoke(actionID: actionID, value: nil)
    }

    func sessionDidChange(_ sessionID: SessionID) {
        guard !isFailingClosed, navigator.eventActionID != nil else { return }
        guard admitPendingSessionIDs([sessionID]) else { return }
        scheduleEventDispatch()
    }

    /// Pauses process work and returns every edge whose result has not yet been incorporated.
    /// The container retains these IDs while Settings owns the sidebar so a process-generation
    /// replacement cannot discard the catch-up set with the old host controller.
    func suspendLiveEventDelivery() -> Set<SessionID> {
        isLiveEventDeliveryEnabled = false
        return pendingSessionIDs.union(inFlightSessionIDs)
    }

    func setLiveEventDeliveryEnabled(_ enabled: Bool) {
        guard enabled != isLiveEventDeliveryEnabled else { return }
        isLiveEventDeliveryEnabled = enabled
        if enabled {
            scheduleEventDispatch()
        }
    }

    func synchronizeSelection(with destination: ExtensionWorkspaceNavigatorDestination?) {
        synchronizedDestination = destination
        for controller in collectionControllers {
            controller.synchronizeSelection(with: destination)
        }
    }

    /// The extension owns the document below this band; the host permanently owns the route
    /// out of it. Declared options remain absent until a host transform consumes their values,
    /// so v1 never presents a control whose result cannot change what is on screen.
    func navigatorMenuEntries() -> [ThemedMenuEntry] {
        [
            .item(ThemedMenuItem(
                title: L10n.string("Native"),
                onChoose: { [weak self] in self?.onSelectNative() }
            ))
        ]
    }

    func dismissPresentedMenu() {
        ThemedMenuPresenter.dismiss(activeMenuSession)
        activeMenuSession = nil
    }

    private func showNavigatorMenu() {
        let entries = navigatorMenuEntries()
        activeMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
            from: menuButton,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.activeMenuSession = nil }
        )
    }

    private func render(_ replacement: ExtensionWorkspaceNavigator) {
        guard replacement.options == declaredOptions else {
            failClosed(afterRendering: ExtensionValidationError(issues: [.init(
                path: "navigator.options",
                message: "must match the registered navigator option declaration"
            )]))
            return
        }
        let issues = replacement.validationIssues(path: "navigator")
        guard issues.isEmpty else {
            presentError(ExtensionValidationError(issues: issues).description)
            failClosed()
            return
        }

        capturePresentationState()
        let focusedIdentity = focusedAccessibilityIdentity()
        let previousRoot = rootHost
        let previousControllers = collectionControllers
        collectionControllers = []

        do {
            let built = try makeView(for: replacement.root)
            built.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(built, positioned: .above, relativeTo: previousRoot)
            NSLayoutConstraint.activate([
                built.topAnchor.constraint(equalTo: header.bottomAnchor),
                built.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                built.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                built.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            rootHost = built
            navigator = replacement
            titleLabel.stringValue = replacement.title
            contentRevision += 1
            if let synchronizedDestination {
                collectionControllers.forEach {
                    $0.synchronizeSelection(with: synchronizedDestination)
                }
            }

            previousRoot?.removeFromSuperview()
            previousControllers.forEach {
                $0.view.removeFromSuperview()
                $0.removeFromParent()
            }
            restoreFocus(identity: focusedIdentity)
        } catch {
            collectionControllers.forEach {
                $0.view.removeFromSuperview()
                $0.removeFromParent()
            }
            collectionControllers = previousControllers
            presentError(error.localizedDescription)
            failClosed()
        }
    }

    private func makeView(for node: ExtensionWorkspaceNavigatorNode) throws -> NSView {
        switch node {
        case .content(let content):
            return try renderSemanticContent(content)

        case .collection(let collection):
            let controller = WorkspaceNavigatorCollectionViewController(
                collection: collection,
                restoredState: collectionStates[collection.id],
                renderContent: { [weak self] node in
                    guard let self else { throw ExtensionProcessError.notRunning }
                    return try self.renderSemanticContent(node)
                },
                onActivation: { [weak self] activation, itemID in
                    self?.activate(activation, itemID: itemID)
                },
                onRenderFailure: { [weak self] error in
                    self?.failClosed(afterRendering: error)
                }
            )
            addChild(controller)
            collectionControllers.append(controller)
            return controller.view

        case .divider:
            return try renderSemanticContent(.divider)

        case .spacer(let spacing):
            return try renderSemanticContent(.spacer(spacing))

        case .flexibleSpacer:
            return try renderSemanticContent(.flexibleSpacer)

        case .stack(let axis, let spacing, let children):
            let views = try children.map(makeView)
            let stack = NSStackView(views: views)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = axis == .horizontal ? .horizontal : .vertical
            stack.spacing = spacingValue(spacing)
            stack.alignment = axis == .horizontal ? .centerY : .leading
            stack.distribution = .fill

            if axis == .vertical {
                for (child, childView) in zip(children, views) {
                    childView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    if case .collection = child {
                        childView.heightAnchor.constraint(
                            greaterThanOrEqualToConstant: 80
                        ).isActive = true
                    }
                }
            } else {
                for childView in views {
                    childView.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
                }
            }
            return stack

        case .overlay(let base, let overlay):
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let baseView = try makeView(for: base)
            let overlayView = try makeView(for: overlay)
            container.addSubview(baseView)
            container.addSubview(overlayView)
            for child in [baseView, overlayView] {
                child.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    child.topAnchor.constraint(equalTo: container.topAnchor),
                    child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                ])
            }
            return container
        }
    }

    private func renderSemanticContent(_ node: ExtensionNode) throws -> ExtensionNodeHostView {
        try ExtensionNodeRenderer.render(
            node,
            imageResolver: { [weak self] reference in
                self?.resolveImage(reference)
            },
            onEvent: { [weak self] actionID, value in
                self?.invoke(actionID: actionID, value: value)
            }
        )
    }

    private func resolveImage(_ reference: ExtensionImageReference) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .extensionResource(let path):
            guard let url = routing.extensionImageResourceURL(
                extensionIdentifier: extensionIdentifier,
                relativePath: path
            ) else {
                return nil
            }
            return ExtensionImageResourceLoader.image(at: url)
        case .hostAsset:
            return nil
        }
    }

    private func activate(
        _ activation: ExtensionWorkspaceNavigatorActivation,
        itemID: String
    ) {
        switch activation {
        case .destination(let destination):
            if let error = destinationHandler(destination) {
                presentError(error)
            }
        case .action(let actionID):
            invoke(actionID: actionID, value: .string(itemID))
        }
    }

    private func invoke(actionID: String, value: ExtensionJSONValue?) {
        actionSequence += 1
        let sequence = actionSequence
        ordinaryActionSequencesInFlight.insert(sequence)
        let accepted = routing.invokeWorkspaceNavigatorAction(
            extensionIdentifier: extensionIdentifier,
            navigatorID: navigatorID,
            actionID: actionID,
            value: value,
            context: contextProvider()
        ) { [weak self] result in
            guard let self else { return }
            guard self.ordinaryActionSequencesInFlight.remove(sequence) != nil else { return }
            defer { self.scheduleEventDispatch() }
            guard sequence == self.actionSequence else { return }
            guard self.routing.registeredWorkspaceNavigator(
                extensionIdentifier: self.extensionIdentifier,
                navigatorID: self.navigatorID
            )?.processGeneration == self.processGeneration else {
                self.onUnavailable()
                return
            }

            switch result {
            case .failure(let error):
                self.presentError(error.localizedDescription)
                if self.shouldFailClosed(after: error) {
                    self.onUnavailable()
                }
            case .success(let response):
                do {
                    try response.validate()
                    try self.applyItemPatches(response.itemPatches ?? [])
                } catch {
                    self.failClosed(afterRendering: error)
                    return
                }
                if let error = response.error {
                    self.presentError(error)
                    return
                }
                if let replacement = response.navigator {
                    self.render(replacement)
                }
                if let message = response.message {
                    self.present(message)
                }
            }
        }
        if !accepted,
           ordinaryActionSequencesInFlight.remove(sequence) != nil {
            onUnavailable()
        }
    }

    private func scheduleEventDispatch() {
        guard !isFailingClosed,
              isLiveEventDeliveryEnabled,
              !pendingSessionIDs.isEmpty,
              !isEventDispatchScheduled,
              !isEventActionInFlight,
              ordinaryActionSequencesInFlight.isEmpty else { return }
        isEventDispatchScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEventDispatchScheduled = false
            self.dispatchNextEventBatch()
        }
    }

    private func dispatchNextEventBatch() {
        guard !isFailingClosed,
              isLiveEventDeliveryEnabled,
              !isEventActionInFlight,
              ordinaryActionSequencesInFlight.isEmpty,
              let actionID = navigator.eventActionID,
              !pendingSessionIDs.isEmpty else {
            return
        }
        let sessionIDs = Array(
            pendingSessionIDs.sorted { $0.uuidString < $1.uuidString }.prefix(
                ExtensionWorkspaceNavigatorHostEvent.maximumSessionIDs
            )
        )
        pendingSessionIDs.subtract(sessionIDs)
        inFlightSessionIDs = Set(sessionIDs)
        let event = ExtensionWorkspaceNavigatorHostEvent(
            kind: .sessionChanged,
            sessionIDs: sessionIDs.map { $0.uuidString.lowercased() }
        )
        let value: ExtensionJSONValue
        do {
            try event.validate()
            value = try event.actionValue
        } catch {
            failClosed(afterRendering: error)
            return
        }

        let revision = contentRevision
        isEventActionInFlight = true
        let accepted = routing.invokeWorkspaceNavigatorAction(
            extensionIdentifier: extensionIdentifier,
            navigatorID: navigatorID,
            actionID: actionID,
            value: value,
            context: contextProvider()
        ) { [weak self] result in
            guard let self else { return }
            self.isEventActionInFlight = false
            self.inFlightSessionIDs.removeAll(keepingCapacity: true)
            defer { self.scheduleEventDispatch() }
            guard self.routing.registeredWorkspaceNavigator(
                extensionIdentifier: self.extensionIdentifier,
                navigatorID: self.navigatorID
            )?.processGeneration == self.processGeneration else {
                self.onUnavailable()
                return
            }

            switch result {
            case .failure(let error):
                self.presentError(error.localizedDescription)
                // A live edge is invalidation, not an optional user command. Losing the final
                // edge can leave a selected row stale forever, so any failed batch returns to
                // Native instead of pretending the old content is current.
                self.failClosed()
            case .success(let response):
                do {
                    try response.validateForHostEvent()
                } catch {
                    self.failClosed(afterRendering: error)
                    return
                }
                if let error = response.error {
                    self.presentError(error)
                    self.failClosed()
                    return
                }
                guard revision == self.contentRevision else {
                    _ = self.admitPendingSessionIDs(sessionIDs)
                    return
                }
                do {
                    try self.applyItemPatches(response.itemPatches ?? [])
                } catch {
                    self.failClosed(afterRendering: error)
                    return
                }
                if let message = response.message {
                    self.present(message)
                }
            }
        }
        if !accepted {
            isEventActionInFlight = false
            inFlightSessionIDs.removeAll(keepingCapacity: true)
            onUnavailable()
        }
    }

    @discardableResult
    private func admitPendingSessionIDs<S: Sequence>(_ sessionIDs: S) -> Bool
    where S.Element == SessionID {
        var admitted = pendingSessionIDs
        admitted.formUnion(sessionIDs)
        guard admitted.count <= Self.maximumPendingSessionIDs else {
            pendingSessionIDs.removeAll(keepingCapacity: true)
            failClosed(afterRendering: ExtensionValidationError(issues: [.init(
                path: "sessionIDs",
                message: "navigator event backlog exceeded the host limit"
            )]))
            return false
        }
        pendingSessionIDs = admitted
        return true
    }

    private func applyItemPatches(
        _ patches: [ExtensionWorkspaceNavigatorItemPatch]
    ) throws {
        guard !patches.isEmpty else { return }
        let controllersByID = Dictionary(
            uniqueKeysWithValues: collectionControllers.map { ($0.collectionID, $0) }
        )
        var grouped: [String: [ExtensionWorkspaceNavigatorItemPatch]] = [:]
        var issues: [ExtensionValidationIssue] = []
        for (index, patch) in patches.enumerated() {
            guard let controller = controllersByID[patch.collectionID] else {
                issues.append(.init(
                    path: "itemPatches[\(index)].collectionID",
                    message: "does not name a collection in the presented navigator"
                ))
                continue
            }
            guard controller.containsItem(patch.itemID) else {
                issues.append(.init(
                    path: "itemPatches[\(index)].itemID",
                    message: "does not name an item in collection '\(patch.collectionID)'"
                ))
                continue
            }
            grouped[patch.collectionID, default: []].append(patch)
        }
        guard issues.isEmpty else {
            throw ExtensionValidationError(issues: issues)
        }
        for (collectionID, patches) in grouped {
            controllersByID[collectionID]?.applyItemPatches(patches)
        }
        contentRevision += 1
    }

    private func shouldFailClosed(after error: Error) -> Bool {
        guard let processError = error as? ExtensionProcessError else { return true }
        switch processError {
        case .actionTimedOut:
            return false
        case .launchFailed,
             .registrationTimedOut,
             .commandTimedOut,
             .settingsTimedOut,
             .serviceTimedOut,
             .toolTimedOut,
             .outputLineTooLarge,
             .invalidMessage,
             .responseForUnknownRequest,
             .responsePanelMismatch,
             .responseNavigatorMismatch,
             .responseCommandMismatch,
             .responseSettingsMismatch,
             .responseServiceMismatch,
             .processEnded,
             .outputClosed,
             .notRunning,
             .writeFailed:
            return true
        }
    }

    /// Rendering can fail while the container is in the middle of installing this controller.
    /// Defer the failback one run-loop turn so that swap completes before Native replaces it.
    private func failClosed() {
        guard !isFailingClosed else { return }
        isFailingClosed = true
        DispatchQueue.main.async { [weak self] in
            self?.onUnavailable()
        }
    }

    private func failClosed(afterRendering error: Error) {
        presentError(error.localizedDescription)
        failClosed()
    }

    private func capturePresentationState() {
        for controller in collectionControllers {
            collectionStates[controller.collectionID] = controller.captureState()
        }
    }

    private func focusedAccessibilityIdentity() -> WorkspaceNavigatorFocusIdentity? {
        guard let rootHost else { return nil }
        if let fieldEditor = view.window?.firstResponder as? NSTextView,
           let field = fieldEditor.delegate as? NSTextField,
           field.isDescendant(of: rootHost) {
            return focusIdentity(for: field, root: rootHost)
        }
        guard let focused = view.window?.firstResponder as? NSView,
              focused.isDescendant(of: rootHost) else {
            return nil
        }
        return focusIdentity(for: focused, root: rootHost)
    }

    private func focusIdentity(
        for focused: NSView,
        root: NSView
    ) -> WorkspaceNavigatorFocusIdentity? {
        let elementIdentifier = focused.accessibilityIdentifier()
        guard !elementIdentifier.isEmpty else { return nil }
        var itemIdentifier: String?
        var ancestor: NSView? = focused
        while let candidate = ancestor {
            let identifier = candidate.accessibilityIdentifier()
            if identifier.hasPrefix("workspace.navigator.item.") {
                itemIdentifier = identifier
                break
            }
            if candidate === root { break }
            ancestor = candidate.superview
        }
        return .init(
            itemIdentifier: itemIdentifier,
            elementIdentifier: elementIdentifier
        )
    }

    private func restoreFocus(identity: WorkspaceNavigatorFocusIdentity?) {
        guard let identity, let rootHost else { return }
        DispatchQueue.main.async { [weak self, weak rootHost] in
            guard let self, let rootHost else { return }
            let searchRoot: NSView
            if let itemIdentifier = identity.itemIdentifier {
                guard let item = ([rootHost] + self.descendants(of: rootHost)).first(where: {
                    $0.accessibilityIdentifier() == itemIdentifier
                }) else {
                    return
                }
                searchRoot = item
            } else {
                searchRoot = rootHost
            }
            guard let match = ([searchRoot] + self.descendants(of: searchRoot)).first(where: {
                $0.accessibilityIdentifier() == identity.elementIdentifier
            }) else {
                return
            }
            self.view.window?.makeFirstResponder(match)
        }
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func present(_ message: String) {
        toasts.present(ToastRequest(
            message: message,
            detail: nil,
            actionTitle: nil,
            action: nil,
            identifier: "workspace.navigator.message"
        ))
    }

    private func presentError(_ message: String) {
        toasts.present(ToastRequest(
            message: L10n.string("Navigator extension"),
            detail: message,
            actionTitle: nil,
            action: nil,
            identifier: "workspace.navigator.error"
        ))
    }

    private func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        switch spacing {
        case .none: 0
        case .tight: Design.Spacing.tight
        case .small: Design.Spacing.small
        case .medium: Design.Spacing.medium
        case .large: Design.Spacing.large
        }
    }
}

private struct WorkspaceNavigatorFocusIdentity {
    let itemIdentifier: String?
    let elementIdentifier: String
}

struct WorkspaceNavigatorCollectionState {
    let selectedItemID: String?
    let expandedItemIDs: Set<String>
    let topVisibleItemID: String?
    let topVisibleOffset: CGFloat
}

private final class WorkspaceNavigatorCollectionNode: NSObject {
    enum Value {
        case section(ExtensionWorkspaceNavigatorSection)
        case item(ExtensionWorkspaceNavigatorItem)
    }

    let value: Value
    var children: [WorkspaceNavigatorCollectionNode] = []

    init(_ value: Value) {
        self.value = value
    }

    var item: ExtensionWorkspaceNavigatorItem? {
        guard case .item(let item) = value else { return nil }
        return item
    }
}

/// One virtualized list, outline, or grid in a navigator document.
final class WorkspaceNavigatorCollectionViewController:
    NSViewController,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    typealias ContentRenderer = (ExtensionNode) throws -> ExtensionNodeHostView
    typealias ActivationHandler = (ExtensionWorkspaceNavigatorActivation, String) -> Void
    typealias RenderFailureHandler = (Error) -> Void

    let collectionID: String

    private let collection: ExtensionWorkspaceNavigatorCollection
    private let itemIDs: Set<String>
    private let renderContent: ContentRenderer
    private let onActivation: ActivationHandler
    private let onRenderFailure: RenderFailureHandler
    private let restoredState: WorkspaceNavigatorCollectionState?
    private var roots: [WorkspaceNavigatorCollectionNode] = []
    private var nodesByItemID: [String: WorkspaceNavigatorCollectionNode] = [:]
    private var gridRows: [WorkspaceNavigatorGridRow] = []
    private var gridRowByItemID: [String: Int] = [:]
    private var contentOverrides: [String: ExtensionNode] = [:]
    private var selectedGridItemID: String?
    private var suppressSelectionCallback = false

    private lazy var outlineView: ThemedOutlineView = {
        let outline = ThemedOutlineView()
        outline.headerView = nil
        outline.style = .inset
        outline.indentationPerLevel = SidebarDefaults.indentationPerLevel
        outline.dataSource = self
        outline.delegate = self
        let column = NSTableColumn(identifier: .init("WorkspaceNavigatorColumn"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setAccessibilityIdentifier("workspace.navigator.collection.\(collectionID)")
        return outline
    }()

    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: .init("WorkspaceNavigatorGridColumn"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.setAccessibilityIdentifier("workspace.navigator.collection.\(collectionID)")
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    init(
        collection: ExtensionWorkspaceNavigatorCollection,
        restoredState: WorkspaceNavigatorCollectionState?,
        renderContent: @escaping ContentRenderer,
        onActivation: @escaping ActivationHandler,
        onRenderFailure: @escaping RenderFailureHandler
    ) {
        collectionID = collection.id
        self.collection = collection
        itemIDs = Set(collection.items.map(\.id))
        self.restoredState = restoredState
        self.renderContent = renderContent
        self.onActivation = onActivation
        self.onRenderFailure = onRenderFailure
        super.init(nibName: nil, bundle: nil)
        buildModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = isGrid ? tableView : outlineView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if isGrid {
            tableView.reloadData()
            restoreGridState()
        } else {
            outlineView.reloadData()
            restoreOutlineState()
        }
    }

    func captureState() -> WorkspaceNavigatorCollectionState {
        if isGrid {
            let visible = topVisibleGridItem()
            return .init(
                selectedItemID: selectedGridItemID,
                expandedItemIDs: [],
                topVisibleItemID: visible?.itemID,
                topVisibleOffset: visible?.offset ?? 0
            )
        }
        let selected = outlineView.selectedRow >= 0
            ? (outlineView.item(atRow: outlineView.selectedRow)
                as? WorkspaceNavigatorCollectionNode)?.item?.id
            : nil
        let expanded = Set(nodesByItemID.compactMap { id, node in
            outlineView.isItemExpanded(node) ? id : nil
        })
        let top = topVisibleOutlineItem()
        return .init(
            selectedItemID: selected,
            expandedItemIDs: expanded,
            topVisibleItemID: top?.itemID,
            topVisibleOffset: top?.offset ?? 0
        )
    }

    func synchronizeSelection(with destination: ExtensionWorkspaceNavigatorDestination?) {
        let matchingID = collection.selectionMode == .single
            ? destination.flatMap { destination in
            collection.items.first(where: {
                guard case .destination(let candidate) = $0.activation else { return false }
                return destinationsMatch(candidate, destination)
            })?.id
        }
            : nil
        if isGrid {
            selectedGridItemID = matchingID
            tableView.reloadData()
            return
        }
        suppressSelectionCallback = true
        if let matchingID, let node = nodesByItemID[matchingID] {
            expandAncestors(of: node)
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false
                )
            }
        } else {
            outlineView.deselectAll(nil)
        }
        suppressSelectionCallback = false
    }

    func containsItem(_ itemID: String) -> Bool {
        itemIDs.contains(itemID)
    }

    func applyItemPatches(_ patches: [ExtensionWorkspaceNavigatorItemPatch]) {
        for patch in patches {
            contentOverrides[patch.itemID] = patch.content
        }
        if isGrid {
            let rows = IndexSet(patches.compactMap { gridRowByItemID[$0.itemID] })
            tableView.reloadData(
                forRowIndexes: rows,
                columnIndexes: IndexSet(integer: 0)
            )
            return
        }
        let rows = IndexSet(patches.compactMap { patch in
            guard let node = nodesByItemID[patch.itemID] else { return nil }
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        })
        outlineView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private var isGrid: Bool {
        if case .grid = collection.layout { return true }
        return false
    }

    private var gridColumnCount: Int {
        guard case .grid(let columns) = collection.layout else { return 1 }
        return columns
    }

    private func buildModel() {
        if isGrid {
            buildGridRows()
            return
        }

        let sectionsByID = Dictionary(
            uniqueKeysWithValues: collection.sections.map { ($0.id, $0) }
        )
        var sectionNodes: [String: WorkspaceNavigatorCollectionNode] = [:]
        for section in collection.sections where section.header != nil {
            let node = WorkspaceNavigatorCollectionNode(.section(section))
            roots.append(node)
            sectionNodes[section.id] = node
        }
        for item in collection.items {
            let node = WorkspaceNavigatorCollectionNode(.item(item))
            nodesByItemID[item.id] = node
        }
        for item in collection.items {
            guard let node = nodesByItemID[item.id] else { continue }
            if let parentID = item.parentID, let parent = nodesByItemID[parentID] {
                parent.children.append(node)
            } else if let sectionID = item.sectionID,
                      sectionsByID[sectionID]?.header != nil,
                      let section = sectionNodes[sectionID] {
                section.children.append(node)
            } else {
                roots.append(node)
            }
        }
    }

    private func buildGridRows() {
        let sectionIDs = collection.sections.map(\.id)
        for section in collection.sections {
            if let header = section.header {
                gridRows.append(.header(header))
            }
            appendGridItems(collection.items.filter { $0.sectionID == section.id })
        }
        appendGridItems(collection.items.filter {
            $0.sectionID == nil || !sectionIDs.contains($0.sectionID ?? "")
        })
    }

    private func appendGridItems(_ items: [ExtensionWorkspaceNavigatorItem]) {
        guard !items.isEmpty else { return }
        for start in stride(from: 0, to: items.count, by: gridColumnCount) {
            let row = Array(
                items[start..<min(start + gridColumnCount, items.count)]
            )
            let rowIndex = gridRows.count
            for item in row {
                gridRowByItemID[item.id] = rowIndex
            }
            gridRows.append(.items(row))
        }
    }

    private func restoreOutlineState() {
        for root in roots {
            if case .section = root.value {
                outlineView.expandItem(root)
            }
        }
        let expanded = restoredState?.expandedItemIDs
            ?? Set(collection.items.filter(\.isExpanded).map(\.id))
        for id in expanded {
            if let node = nodesByItemID[id] {
                outlineView.expandItem(node)
            }
        }

        let selectedID = restoredState?.selectedItemID
            ?? collection.items.first(where: \.isSelected)?.id
        suppressSelectionCallback = true
        if collection.selectionMode == .single,
           let selectedID,
           let selected = nodesByItemID[selectedID] {
            expandAncestors(of: selected)
            let row = outlineView.row(forItem: selected)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        suppressSelectionCallback = false

        restoreScroll(
            to: restoredState?.topVisibleItemID,
            offset: restoredState?.topVisibleOffset ?? 0
        )
    }

    private func restoreGridState() {
        selectedGridItemID = restoredState?.selectedItemID
            ?? collection.items.first(where: \.isSelected)?.id
        restoreScroll(
            to: restoredState?.topVisibleItemID,
            offset: restoredState?.topVisibleOffset ?? 0
        )
    }

    private func restoreScroll(to itemID: String?, offset: CGFloat) {
        guard let itemID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let row: Int
            if self.isGrid {
                guard let matchingRow = self.gridRows.firstIndex(where: {
                    $0.contains(itemID)
                }) else {
                    return
                }
                row = matchingRow
            } else if let node = self.nodesByItemID[itemID] {
                self.expandAncestors(of: node)
                row = self.outlineView.row(forItem: node)
                guard row >= 0 else { return }
            } else {
                return
            }
            let table: NSTableView = self.isGrid ? self.tableView : self.outlineView
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            let maximumY = max(
                0,
                table.bounds.height - self.scrollView.contentView.bounds.height
            )
            let targetY = min(
                maximumY,
                max(0, table.rect(ofRow: row).minY + offset)
            )
            self.scrollView.contentView.scroll(to: NSPoint(
                x: self.scrollView.contentView.bounds.minX,
                y: targetY
            ))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    private func expandAncestors(of node: WorkspaceNavigatorCollectionNode) {
        var current: Any = node
        var ancestors: [Any] = []
        while let parent = outlineView.parent(forItem: current) {
            ancestors.append(parent)
            current = parent
        }
        ancestors.reversed().forEach(outlineView.expandItem)
    }

    private func activate(_ item: ExtensionWorkspaceNavigatorItem) {
        guard item.isEnabled else { return }
        if collection.selectionMode == .single {
            selectedGridItemID = item.id
        }
        if let activation = item.activation {
            onActivation(activation, item.id)
        }
    }

    private func topVisibleGridItem() -> (itemID: String, offset: CGFloat)? {
        for row in visibleRows(in: tableView) {
            guard gridRows.indices.contains(row) else { return nil }
            if let itemID = gridRows[row].firstItemID {
                return (itemID, visibleOffset(in: tableView, row: row))
            }
        }
        return nil
    }

    private func topVisibleOutlineItem() -> (itemID: String, offset: CGFloat)? {
        for row in visibleRows(in: outlineView) {
            if let itemID = (
                outlineView.item(atRow: row) as? WorkspaceNavigatorCollectionNode
            )?.item?.id {
                return (itemID, visibleOffset(in: outlineView, row: row))
            }
        }
        return nil
    }

    private func visibleOffset(in table: NSTableView, row: Int) -> CGFloat {
        max(0, table.visibleRect.minY - table.rect(ofRow: row).minY)
    }

    private func visibleRows(in table: NSTableView) -> [Int] {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return Array(range.location..<(range.location + range.length))
    }

    // MARK: Outline

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? WorkspaceNavigatorCollectionNode)?.children.count ?? roots.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? WorkspaceNavigatorCollectionNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceNavigatorCollectionNode)?.children.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldCollapseItem item: Any
    ) -> Bool {
        guard let node = item as? WorkspaceNavigatorCollectionNode else { return false }
        if case .section = node.value { return false }
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        guard let item = (item as? WorkspaceNavigatorCollectionNode)?.item else {
            return false
        }
        switch collection.selectionMode {
        case .single:
            return item.isEnabled
        case .none:
            return item.isEnabled && item.activation != nil
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback,
              outlineView.selectedRow >= 0,
              let item = (outlineView.item(
                  atRow: outlineView.selectedRow
              ) as? WorkspaceNavigatorCollectionNode)?.item else {
            return
        }
        activate(item)
        if collection.selectionMode == .none {
            suppressSelectionCallback = true
            outlineView.deselectAll(nil)
            suppressSelectionCallback = false
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? WorkspaceNavigatorCollectionNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceNavigatorRow")
        let host = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? WorkspaceNavigatorRowHostView ?? WorkspaceNavigatorRowHostView()
        host.identifier = identifier

        let content: ExtensionNode
        switch node.value {
        case .section(let section):
            guard let header = section.header else { return nil }
            content = header
            host.setAccessibilityIdentifier(
                "workspace.navigator.section.\(collectionID).\(section.id)"
            )
        case .item(let item):
            content = contentOverrides[item.id] ?? item.content
            host.setAccessibilityIdentifier(
                "workspace.navigator.item.\(collectionID).\(item.id)"
            )
        }
        do {
            try host.install(renderContent(content))
        } catch {
            onRenderFailure(error)
            return nil
        }
        return host
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        SidebarHoverRowView()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        SidebarDefaults.projectCompactRowHeight
    }

    // MARK: Grid table

    func numberOfRows(in tableView: NSTableView) -> Int {
        gridRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard gridRows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceNavigatorGridRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? WorkspaceNavigatorGridRowHostView ?? WorkspaceNavigatorGridRowHostView()
        host.identifier = identifier
        do {
            try host.install(
                gridRows[row].replacingContent(using: contentOverrides),
                collectionID: collectionID,
                columns: gridColumnCount,
                selectedItemID: selectedGridItemID,
                renderContent: renderContent,
                onActivate: { [weak self] item in
                    self?.activate(item)
                    self?.tableView.reloadData()
                }
            )
        } catch {
            onRenderFailure(error)
            return nil
        }
        return host
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard gridRows.indices.contains(row) else { return SidebarDefaults.rowHeight }
        switch gridRows[row] {
        case .header:
            return SidebarDefaults.headingRowHeight
        case .items:
            return 80
        }
    }

    private func destinationsMatch(
        _ lhs: ExtensionWorkspaceNavigatorDestination,
        _ rhs: ExtensionWorkspaceNavigatorDestination
    ) -> Bool {
        switch (lhs, rhs) {
        case (.project(let lhsID), .project(let rhsID)):
            return identifiersMatch(lhsID, rhsID)
        case (
            .session(let lhsID, let lhsProjectID),
            .session(let rhsID, let rhsProjectID)
        ):
            guard identifiersMatch(lhsID, rhsID) else { return false }
            switch (lhsProjectID, rhsProjectID) {
            case (nil, _), (_, nil):
                return true
            case (.some(let lhsProjectID), .some(let rhsProjectID)):
                return identifiersMatch(lhsProjectID, rhsProjectID)
            }
        default:
            return false
        }
    }

    private func identifiersMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsUUID = UUID(uuidString: lhs), let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs == rhs
    }
}

private enum WorkspaceNavigatorGridRow {
    case header(ExtensionNode)
    case items([ExtensionWorkspaceNavigatorItem])

    func contains(_ itemID: String) -> Bool {
        guard case .items(let items) = self else { return false }
        return items.contains { $0.id == itemID }
    }

    func replacingContent(using overrides: [String: ExtensionNode]) -> Self {
        guard case .items(let items) = self else { return self }
        return .items(items.map { item in
            guard let content = overrides[item.id] else { return item }
            return ExtensionWorkspaceNavigatorItem(
                id: item.id,
                sectionID: item.sectionID,
                parentID: item.parentID,
                content: content,
                accessibilityLabel: item.accessibilityLabel,
                activation: item.activation,
                isEnabled: item.isEnabled,
                isSelected: item.isSelected,
                isExpanded: item.isExpanded
            )
        })
    }

    var firstItemID: String? {
        guard case .items(let items) = self else { return nil }
        return items.first?.id
    }
}

private final class WorkspaceNavigatorRowHostView: NSView {
    private var installed: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(_ content: NSView) throws {
        installed?.removeFromSuperview()
        installed = content
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }
}

private final class WorkspaceNavigatorGridRowHostView: NSView {
    private var installed: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(
        _ row: WorkspaceNavigatorGridRow,
        collectionID: String,
        columns: Int,
        selectedItemID: String?,
        renderContent: (ExtensionNode) throws -> ExtensionNodeHostView,
        onActivate: @escaping (ExtensionWorkspaceNavigatorItem) -> Void
    ) throws {

        let content: NSView
        switch row {
        case .header(let header):
            content = try renderContent(header)

        case .items(let items):
            var cells: [NSView] = try items.map { item in
                let semantic = try renderContent(item.content)
                let cell = NavigatorGridItemView(content: semantic)
                cell.isEnabled = item.isEnabled
                cell.isSelected = item.id == selectedItemID
                if let accessibilityLabel = item.accessibilityLabel {
                    cell.setAccessibilityLabel(accessibilityLabel)
                }
                cell.setAccessibilityIdentifier(
                    "workspace.navigator.item.\(collectionID).\(item.id)"
                )
                if item.activation != nil {
                    cell.onActivate = { onActivate(item) }
                }
                return cell
            }
            while cells.count < columns {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                cells.append(spacer)
            }
            let stack = NSStackView(views: cells)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.spacing = Design.Spacing.small
            stack.distribution = .fillEqually
            content = stack
        }

        // Build the complete row first. A failed replacement leaves the previous reusable row
        // intact until the host atomically swaps back to the native navigator.
        installed?.removeFromSuperview()
        installed = content
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small)
        ])
    }
}
