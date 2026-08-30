import AppKit
import ThreadingExtensionKit

/// Presents one live extension navigator inside Threading's host-owned sidebar shell.
///
/// Full documents are rebuilt atomically. Live item content patches keep the existing collection
/// views in place and reload only rows addressed by stable semantic IDs.
final class WorkspaceNavigatorHostViewController: NSViewController {
    typealias ContextProvider = () -> ExtensionCommandContext
    typealias DestinationHandler = (ExtensionWorkspaceNavigatorDestination) -> String?
    typealias FactSnapshotProvider = (Set<ExtensionFactKey>) -> ExtensionFactSnapshot?
    typealias FactSnapshotPatchProvider = (
        ExtensionFactSnapshot,
        Set<ExtensionFactCell>,
        Set<ExtensionFactKey>
    ) -> ExtensionFactSnapshotPatch?

    static let maximumPendingSessionIDs =
        ExtensionWorkspaceNavigatorHostEvent.maximumSessionIDs * 4

    let extensionIdentifier: String
    let navigatorID: String
    let processGeneration: String

    private let routing: ExtensionWorkspaceNavigatorRouting
    private let contextProvider: ContextProvider
    private let destinationHandler: DestinationHandler
    private let factSnapshotProvider: FactSnapshotProvider
    private let factSnapshotPatchProvider: FactSnapshotPatchProvider
    private let pipelineEvaluate: WorkspaceNavigatorPipelineEvaluationScheduler.Evaluate
    private let pipelineCalendarProvider: () -> Calendar
    private let pipelineNowProvider: () -> Date
    private let onSelectNative: () -> Void
    private let onUnavailable: () -> Void
    /// Localized once from the validated registration. Runtime documents may replace content,
    /// never the host-owned option contract which scopes durable user choices.
    private let declaredOptions: [ExtensionWorkspaceNavigatorOption]
    /// Pipeline declarations are compiled from the registration snapshot. A process response may
    /// replace fallback content, but cannot add, remove or mutate that static host program.
    private let declaredPipeline: ExtensionWorkspaceNavigatorPipeline?
    private let consumedFactKeys: Set<ExtensionFactKey>
    private var navigator: ExtensionWorkspaceNavigator
    private var optionValues: [String: ExtensionJSONValue]
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
    private lazy var pipelineSearchBand: WorkspaceNavigatorPipelineSearchBandView = {
        let band = WorkspaceNavigatorPipelineSearchBandView()
        band.onQueryChange = { [weak self] query in
            guard let self else { return }
            self.pipelineQuery = query
            self.schedulePipelineEvaluation()
        }
        return band
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
    private var compiledPipeline: CompiledWorkspaceNavigatorPipeline?
    /// The pipeline paired with the presentation currently owned by the table. Compilation may
    /// race ahead on the main actor; visible rows must stay fenced to their accepted snapshot.
    private var presentedPipeline: CompiledWorkspaceNavigatorPipeline?
    private var pipelineQuery = ""
    private var pendingPipelineFactChange: ExtensionFactChange?
    private var isPipelineRefreshScheduled = false
    private var pipelineEvaluationSequence = 0
    private lazy var pipelineEvaluationScheduler = WorkspaceNavigatorPipelineEvaluationScheduler(
        evaluate: pipelineEvaluate,
        deliver: { [weak self] output in
            guard let self,
                  output.sequence == self.pipelineEvaluationSequence,
                  output.query == self.pipelineQuery,
                  self.isLiveEventDeliveryEnabled,
                  !self.isFailingClosed else { return }
            guard output.pipeline.snapshot.revision
                == self.compiledPipeline?.snapshot.revision else {
                // An exact patch or full snapshot advanced while this worker was evaluating.
                // Submit the current frozen program; never combine it with the stale output.
                self.schedulePipelineEvaluation()
                return
            }
            self.renderPipelinePresentation(output.presentation, pipeline: output.pipeline)
        }
    )
    private var pipelineCollectionController: WorkspaceNavigatorPipelineCollectionViewController?
    private var pipelineResultsView: WorkspaceNavigatorPipelineResultsView?
    private var optionSequence = 0
    private var nextDayTimer: Timer?
    private let pipelineEvents = AppEventObservations()
    private lazy var toasts = ToastPresenter(host: view, above: view.bottomAnchor)

    init(
        inventory: ExtensionWorkspaceNavigatorInventoryItem,
        routing: ExtensionWorkspaceNavigatorRouting,
        contextProvider: @escaping ContextProvider,
        destinationHandler: @escaping DestinationHandler,
        factSnapshotProvider: @escaping FactSnapshotProvider = { _ in nil },
        factSnapshotPatchProvider: @escaping FactSnapshotPatchProvider = { _, _, _ in nil },
        pipelineEvaluate: @escaping WorkspaceNavigatorPipelineEvaluationScheduler.Evaluate = {
            request in
            let evaluation = WorkspaceNavigatorPipelineEvaluator(
                calendar: request.calendar,
                now: { request.referenceDate }
            ).evaluate(request.pipeline, query: request.query)
            return WorkspaceNavigatorPipelinePresentation(evaluation: evaluation)
        },
        pipelineCalendarProvider: @escaping () -> Calendar = { .current },
        pipelineNowProvider: @escaping () -> Date = Date.init,
        onSelectNative: @escaping () -> Void = {},
        onUnavailable: @escaping () -> Void
    ) {
        extensionIdentifier = inventory.extensionIdentifier
        navigatorID = inventory.navigator.id
        processGeneration = inventory.processGeneration
        navigator = inventory.navigator
        declaredOptions = inventory.navigator.options
        declaredPipeline = inventory.navigator.pipeline
        consumedFactKeys = Set(inventory.navigator.pipeline?.consumes.map(\.key) ?? [])
        optionValues = inventory.optionValues
        self.routing = routing
        self.contextProvider = contextProvider
        self.destinationHandler = destinationHandler
        self.factSnapshotProvider = factSnapshotProvider
        self.factSnapshotPatchProvider = factSnapshotPatchProvider
        self.pipelineEvaluate = pipelineEvaluate
        self.pipelineCalendarProvider = pipelineCalendarProvider
        self.pipelineNowProvider = pipelineNowProvider
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
        view.addSubview(pipelineSearchBand)
        NSLayoutConstraint.activate([
            pipelineSearchBand.topAnchor.constraint(equalTo: header.bottomAnchor),
            pipelineSearchBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pipelineSearchBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if declaredPipeline != nil {
            installPipelineInvalidation()
            requestPipelineRefresh()
        } else {
            render(navigator)
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        if declaredPipeline != nil {
            requestPipelineRefresh()
            return
        }
        guard let actionID = navigator.loadActionID else { return }
        invoke(actionID: actionID, value: nil)
    }

    func sessionDidChange(_ sessionID: SessionID) {
        guard declaredPipeline == nil,
              !isFailingClosed,
              navigator.eventActionID != nil else { return }
        guard admitPendingSessionIDs([sessionID]) else { return }
        scheduleEventDispatch()
    }

    /// Pauses process work and returns every edge whose result has not yet been incorporated.
    /// The container retains these IDs while Settings owns the sidebar so a process-generation
    /// replacement cannot discard the catch-up set with the old host controller.
    func suspendLiveEventDelivery() -> Set<SessionID> {
        setLiveEventDeliveryEnabled(false)
        return pendingSessionIDs.union(inFlightSessionIDs)
    }

    func setLiveEventDeliveryEnabled(_ enabled: Bool) {
        guard enabled != isLiveEventDeliveryEnabled else { return }
        isLiveEventDeliveryEnabled = enabled
        if !enabled, declaredPipeline != nil {
            // A running worker cannot be cancelled. Invalidate its delivery and latch a complete
            // catch-up even when no notification arrives during the suspended interval.
            pipelineEvaluationSequence += 1
            pipelineEvaluationScheduler.invalidate()
            pendingPipelineFactChange = .all
        }
        if enabled {
            scheduleEventDispatch()
            if pendingPipelineFactChange != nil {
                schedulePendingPipelineRefresh()
            }
        }
    }

    func synchronizeSelection(with destination: ExtensionWorkspaceNavigatorDestination?) {
        synchronizedDestination = destination
        pipelineCollectionController?.synchronizeSelection(with: destination)
        for controller in collectionControllers {
            controller.synchronizeSelection(with: destination)
        }
    }

    /// The host permanently owns the route out of an extension navigator. Options appear only
    /// for a declared pipeline, where the host compiler consumes them synchronously; legacy
    /// materialized documents still omit controls whose values cannot affect their content.
    func navigatorMenuEntries() -> [ThemedMenuEntry] {
        var entries = declaredPipeline == nil ? [] : declaredOptions.map(optionMenuEntry)
        if !entries.isEmpty {
            entries.append(.separator)
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Native"),
            onChoose: { [weak self] in self?.onSelectNative() }
        )))
        return entries
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

    private func optionMenuEntry(_ option: ExtensionWorkspaceNavigatorOption) -> ThemedMenuEntry {
        let current = optionValues[option.id] ?? option.control.defaultValue
        switch option.control {
        case .toggle:
            let enabled = current == .bool(true)
            return .item(ThemedMenuItem(
                title: option.title,
                isSelected: enabled,
                onChoose: { [weak self] in
                    self?.setPipelineOption(option, value: .bool(!enabled))
                }
            ))
        case .choice(_, let choices):
            let selectedID: String? = if case let .string(value) = current { value } else { nil }
            let selectedTitle = choices.first { $0.id == selectedID }?.title
            return .item(ThemedMenuItem(
                title: option.title,
                subtitle: selectedTitle,
                submenu: choices.map { choice in
                    .item(ThemedMenuItem(
                        title: choice.title,
                        isSelected: choice.id == selectedID,
                        onChoose: { [weak self] in
                            self?.setPipelineOption(option, value: .string(choice.id))
                        }
                    ))
                }
            ))
        case .text, .integer:
            // Registration validation rejects these controls. Keeping the runtime branch inert
            // preserves the menu's totality if a corrupt in-memory fixture bypasses validation.
            return .item(ThemedMenuItem(title: option.title, isEnabled: false))
        }
    }

    private func setPipelineOption(
        _ option: ExtensionWorkspaceNavigatorOption,
        value: ExtensionJSONValue
    ) {
        guard declaredPipeline != nil, option.control.accepts(value) else { return }
        optionSequence += 1
        let sequence = optionSequence
        let accepted = routing.setWorkspaceNavigatorOption(
            extensionIdentifier: extensionIdentifier,
            navigatorID: navigatorID,
            optionID: option.id,
            value: value,
            processGeneration: processGeneration
        ) { [weak self] result in
            guard let self, sequence == self.optionSequence else { return }
            guard self.routing.registeredWorkspaceNavigator(
                extensionIdentifier: self.extensionIdentifier,
                navigatorID: self.navigatorID
            )?.processGeneration == self.processGeneration else {
                self.onUnavailable()
                return
            }
            switch result {
            case .success(let values):
                self.optionValues = values
                self.requestPipelineRefresh()
            case .failure(let error):
                self.presentError(error.localizedDescription)
            }
        }
        if !accepted {
            onUnavailable()
        }
    }

    private func installPipelineInvalidation() {
        pipelineEvents.observe(ExtensionFactsDidChange.self) { [weak self] event in
            guard let self, self.factChangeAffectsPipeline(event.change) else { return }
            self.enqueuePipelineRefresh(event.change)
        }
        for name in [
            NSNotification.Name.NSCalendarDayChanged,
            NSNotification.Name.NSSystemClockDidChange,
            NSNotification.Name.NSSystemTimeZoneDidChange,
        ] {
            pipelineEvents.observe(name) { [weak self] in
                self?.enqueuePipelineRefresh(.all)
            }
        }
        scheduleNextDayRefresh()
    }

    private func factChangeAffectsPipeline(_ change: ExtensionFactChange) -> Bool {
        switch change {
        case .all:
            return true
        case .exact(let cells):
            let relevant = consumedFactKeys.union(ExtensionFactRegistry.snapshotStructuralKeys)
            return cells.contains { relevant.contains($0.key) }
        }
    }

    private func scheduleNextDayRefresh() {
        nextDayTimer?.invalidate()
        let calendar = pipelineCalendarProvider()
        let now = pipelineNowProvider()
        guard let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) else { return }
        let timer = Timer(
            timeInterval: max(1, nextDay.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { @MainActor [weak self] in
                guard let self else { return }
                self.enqueuePipelineRefresh(.all)
                self.scheduleNextDayRefresh()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        nextDayTimer = timer
    }

    private func enqueuePipelineRefresh(_ change: ExtensionFactChange) {
        let boundedChange: ExtensionFactChange
        switch change {
        case .all:
            boundedChange = .all
        case .exact(let cells):
            let relevantKeys = consumedFactKeys.union(
                ExtensionFactRegistry.snapshotStructuralKeys
            )
            let relevantCells = Set(cells.filter { relevantKeys.contains($0.key) })
            guard !relevantCells.isEmpty else { return }
            boundedChange = relevantCells.count > ExtensionFactRegistry.maximumExactNotificationCells
                ? .all
                : .exact(relevantCells)
        }
        switch (pendingPipelineFactChange, boundedChange) {
        case (.some(.all), _), (_, .all):
            pendingPipelineFactChange = .all
        case let (.exact(existing)?, .exact(incoming)):
            let combined = existing.union(incoming)
            pendingPipelineFactChange =
                combined.count > ExtensionFactRegistry.maximumExactNotificationCells
                ? .all
                : .exact(combined)
        case (nil, .exact(let cells)):
            pendingPipelineFactChange = .exact(cells)
        }
        guard isLiveEventDeliveryEnabled else { return }
        schedulePendingPipelineRefresh()
    }

    private func schedulePendingPipelineRefresh() {
        guard !isPipelineRefreshScheduled else { return }
        isPipelineRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPipelineRefreshScheduled = false
            guard self.isLiveEventDeliveryEnabled,
                  let change = self.pendingPipelineFactChange else { return }
            self.pendingPipelineFactChange = nil
            switch change {
            case .all:
                self.requestPipelineRefresh()
            case .exact(let cells):
                if !self.applyPresentationOnlyFactChange(cells) {
                    self.requestPipelineRefresh()
                }
            }
        }
    }

    /// Advances the frozen snapshot and reloads only source rows reached by changed cells when
    /// the active transform proves those keys cannot affect membership, section, order or route.
    private func applyPresentationOnlyFactChange(
        _ cells: Set<ExtensionFactCell>
    ) -> Bool {
        guard let compiledPipeline else { return false }
        var evaluationKeys = compiledPipeline.structuralEvaluationFactKeys
        if !pipelineQuery.isEmpty {
            evaluationKeys.formUnion(compiledPipeline.searchFactKeys)
        }
        guard cells.allSatisfy({ !evaluationKeys.contains($0.key) }),
              let patch = factSnapshotPatchProvider(
                compiledPipeline.snapshot,
                cells,
                consumedFactKeys
              ) else { return false }
        let presentationSharesBaseRevision = presentedPipeline?.snapshot.revision
            == compiledPipeline.snapshot.revision
        let patchedPipeline = compiledPipeline.replacing(snapshot: patch.snapshot)
        self.compiledPipeline = patchedPipeline
        if presentationSharesBaseRevision, let presentedPipeline {
            // Structural identity is unchanged by this proven presentation-only edge, so the
            // accepted table and its renderer may advance together without re-evaluation. When
            // a structural worker is already evaluating a newer base, keep the older visible
            // pair intact; its fenced result will submit this patched revision after delivery.
            self.presentedPipeline = presentedPipeline.replacing(snapshot: patch.snapshot)
            pipelineCollectionController?.reloadItems(
                withSourceSessionIDs: patch.affectedSourceSessionIDs
            )
        }
        return true
    }

    private func requestPipelineRefresh() {
        guard let declaredPipeline, !isFailingClosed else { return }
        guard isLiveEventDeliveryEnabled else {
            enqueuePipelineRefresh(.all)
            return
        }
        scheduleNextDayRefresh()

        guard let snapshot = factSnapshotProvider(consumedFactKeys) else {
            pipelineEvaluationSequence += 1
            pipelineEvaluationScheduler.invalidate()
            compiledPipeline = nil
            pipelineSearchBand.setPresented(false)
            renderPipelinePlaceholder(
                title: L10n.string("Waiting for navigator data."),
                detail: nil
            )
            return
        }
        switch WorkspaceNavigatorPipelineCompiler().compile(
            declaredPipeline,
            snapshot: snapshot,
            optionValues: optionValues
        ) {
        case .ready(let compiled):
            compiledPipeline = compiled
            if let search = compiled.search {
                pipelineSearchBand.configure(
                    placeholder: search.placeholder,
                    accessibilityLabel: search.accessibilityLabel,
                    query: pipelineQuery
                )
                pipelineSearchBand.setPresented(true)
            } else {
                pipelineSearchBand.setPresented(false)
            }
            schedulePipelineEvaluation()
        case .unavailable:
            pipelineEvaluationSequence += 1
            pipelineEvaluationScheduler.invalidate()
            compiledPipeline = nil
            pipelineSearchBand.setPresented(false)
            renderPipelinePlaceholder(
                title: L10n.string("Waiting for navigator data."),
                detail: nil
            )
        case .invalid(let issues):
            pipelineEvaluationSequence += 1
            pipelineEvaluationScheduler.invalidate()
            let error = ExtensionValidationError(issues: issues.map {
                .init(path: $0.path, message: $0.message)
            })
            failClosed(afterRendering: error)
        }
    }

    private func schedulePipelineEvaluation() {
        guard let compiledPipeline, isLiveEventDeliveryEnabled, !isFailingClosed else { return }
        pipelineEvaluationSequence += 1
        let sequence = pipelineEvaluationSequence
        let query = pipelineQuery
        let calendar = pipelineCalendarProvider()
        let referenceDate = pipelineNowProvider()
        pipelineEvaluationScheduler.submit(.init(
            sequence: sequence,
            pipeline: compiledPipeline,
            query: query,
            calendar: calendar,
            referenceDate: referenceDate
        ))
    }

    private func renderPipelinePresentation(
        _ presentation: WorkspaceNavigatorPipelinePresentation,
        pipeline compiled: CompiledWorkspaceNavigatorPipeline
    ) {
        let evaluation = presentation.evaluation
        let rowHeight = compiled.rowTemplate.map {
            WorkspaceNavigatorPipelineTemplateView.rowHeight(for: $0)
        } ?? SidebarDefaults.projectCompactRowHeight
        let overflowText = evaluation.omittedItemCount > 0
            ? String.localizedStringWithFormat(
                L10n.string("%lld more sessions are not shown."),
                Int64(evaluation.omittedItemCount)
            )
            : nil

        if let controller = pipelineCollectionController,
           controller.collectionID == compiled.output.collectionID,
           let results = pipelineResultsView {
            presentedPipeline = compiled
            controller.update(
                presentation,
                itemRowHeight: rowHeight,
                synchronizedDestination: synchronizedDestination
            )
            results.setOverflowText(overflowText)
            results.setEmptyState(
                title: presentation.rows.isEmpty
                    ? evaluation.emptyState?.title
                        ?? L10n.string("No sessions match this navigator.")
                    : nil,
                detail: presentation.rows.isEmpty ? evaluation.emptyState?.detail : nil
            )
            return
        }

        let controller = WorkspaceNavigatorPipelineCollectionViewController(
            collectionID: compiled.output.collectionID,
            presentation: presentation,
            itemRowHeight: rowHeight,
            renderItem: { [weak self] item in
                guard let self, let current = self.presentedPipeline else {
                    throw ExtensionProcessError.notRunning
                }
                let currentItem = WorkspaceNavigatorPipelineItem(
                    sourceSessionID: item.sourceSessionID,
                    projectID: item.projectID,
                    destination: item.destination,
                    snapshotRevision: current.snapshot.revision,
                    referenceDate: item.referenceDate
                )
                guard let realized = WorkspaceNavigatorPipelineEvaluator(
                    calendar: .current
                ).realizeVisibleRow(currentItem, in: current) else {
                    throw ExtensionValidationError(issues: [.init(
                        path: "pipeline.output.rowTemplate",
                        message: "could not realize a visible row from its snapshot revision"
                    )])
                }
                return WorkspaceNavigatorPipelineTemplateView(
                    node: realized,
                    imageResolver: { [weak self] image in
                        self?.resolvePipelineImage(image)
                    }
                )
            },
            onActivation: { [weak self] destination, itemID in
                self?.activate(.destination(destination), itemID: itemID)
            },
            onRenderFailure: { [weak self] error in
                self?.failClosed(afterRendering: error)
            }
        )
        let results = WorkspaceNavigatorPipelineResultsView(
            content: controller.view,
            overflowText: overflowText
        )
        results.setEmptyState(
            title: presentation.rows.isEmpty
                ? evaluation.emptyState?.title
                    ?? L10n.string("No sessions match this navigator.")
                : nil,
            detail: presentation.rows.isEmpty ? evaluation.emptyState?.detail : nil
        )
        addChild(controller)
        presentedPipeline = compiled
        replaceRoot(
            build: { results },
            didInstall: {
                self.pipelineCollectionController = controller
                self.pipelineResultsView = results
                controller.synchronizeSelection(with: self.synchronizedDestination)
            }
        )
    }

    private func renderPipelinePlaceholder(title: String, detail: String?) {
        let previousController = pipelineCollectionController
        presentedPipeline = nil
        pipelineCollectionController = nil
        pipelineResultsView = nil
        replaceRoot {
            WorkspaceNavigatorPipelinePlaceholderView(title: title, detail: detail)
        }
        if let previousController {
            previousController.view.removeFromSuperview()
            previousController.removeFromParent()
        }
    }

    private func resolvePipelineImage(_ image: WorkspaceNavigatorRealizedImage) -> NSImage? {
        switch image.reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .hostAsset(let identifier):
            return resolvePipelineHostIdentityAsset(identifier)
        case .extensionResource(let path):
            let source = image.factSource ?? .extension(
                identifier: extensionIdentifier,
                processGeneration: processGeneration
            )
            guard case let .extension(identifier, generation) = source,
                  let url = routing.extensionImageResourceURL(
                      extensionIdentifier: identifier,
                      relativePath: path,
                      processGeneration: generation
                  ) else { return nil }
            return ExtensionImageResourceLoader.image(at: url)
        }
    }

    /// Pipeline facts receive the same opaque identity IDs published by the host snapshots.
    /// Resolve only that closed vocabulary; arbitrary host-asset strings stay inert.
    private func resolvePipelineHostIdentityAsset(_ identifier: String) -> NSImage? {
        if let providerID = ExtensionIdentityAssetID.providerID(from: identifier),
           let provider = AgentKind(rawValue: providerID) {
            return provider.icon
        }
        if let accountID = ExtensionIdentityAssetID.accountID(from: identifier),
           let parsed = AccountID(rawValue: accountID),
           let account = NativeSidebarParity.host(
               .identityPresentation,
               AgentAccountDiscovery.account(
                   for: parsed.provider,
                   handle: parsed.handle
               )
           ) {
            return AccountBadge.chip(for: account)
        }
        return nil
    }

    private func render(_ replacement: ExtensionWorkspaceNavigator) {
        guard replacement.options == declaredOptions else {
            failClosed(afterRendering: ExtensionValidationError(issues: [.init(
                path: "navigator.options",
                message: "must match the registered navigator option declaration"
            )]))
            return
        }
        guard replacement.pipeline == declaredPipeline else {
            failClosed(afterRendering: ExtensionValidationError(issues: [.init(
                path: "navigator.pipeline",
                message: "must match the registered navigator pipeline declaration"
            )]))
            return
        }
        let issues = replacement.validationIssues(path: "navigator")
        guard issues.isEmpty else {
            presentError(ExtensionValidationError(issues: issues).description)
            failClosed()
            return
        }

        replaceRoot(
            build: { try self.makeView(for: replacement.root) },
            didInstall: {
                navigator = replacement
                titleLabel.stringValue = replacement.title
            }
        )
    }

    private func replaceRoot(
        build: () throws -> NSView,
        didInstall: () -> Void = {}
    ) {
        capturePresentationState()
        let focusedIdentity = focusedAccessibilityIdentity()
        let previousRoot = rootHost
        let previousControllers = collectionControllers
        collectionControllers = []

        do {
            let built = try build()
            built.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(built, positioned: .above, relativeTo: previousRoot)
            NSLayoutConstraint.activate([
                built.topAnchor.constraint(equalTo: pipelineSearchBand.bottomAnchor),
                built.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                built.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                built.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            rootHost = built
            didInstall()
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

/// A pipeline-only table backed by immutable value rows prepared off the main actor.
///
/// Unlike the general v1 outline bridge, it does not allocate one NSObject per emitted item.
/// AppKit asks this data source for visible rows and row reuse bounds the realized templates.
final class WorkspaceNavigatorPipelineCollectionViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    typealias ItemRenderer = (WorkspaceNavigatorPipelineItem) throws -> NSView
    typealias ActivationHandler = (ExtensionWorkspaceNavigatorDestination, String) -> Void
    typealias RenderFailureHandler = (Error) -> Void

    let collectionID: String

    private var presentation: WorkspaceNavigatorPipelinePresentation
    private var itemRowHeight: CGFloat
    private let renderItem: ItemRenderer
    private let onActivation: ActivationHandler
    private let onRenderFailure: RenderFailureHandler
    private var synchronizedDestination: ExtensionWorkspaceNavigatorDestination?
    private var suppressSelectionCallback = false
    private var retainedNonemptyState: WorkspaceNavigatorCollectionState?

    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("WorkspaceNavigatorPipelineColumn"))
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
        scroll.documentView = tableView
        return scroll
    }()

    init(
        collectionID: String,
        presentation: WorkspaceNavigatorPipelinePresentation,
        itemRowHeight: CGFloat,
        renderItem: @escaping ItemRenderer,
        onActivation: @escaping ActivationHandler,
        onRenderFailure: @escaping RenderFailureHandler
    ) {
        self.collectionID = collectionID
        self.presentation = presentation
        self.itemRowHeight = itemRowHeight
        self.renderItem = renderItem
        self.onActivation = onActivation
        self.onRenderFailure = onRenderFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
    }

    func update(
        _ presentation: WorkspaceNavigatorPipelinePresentation,
        itemRowHeight: CGFloat,
        synchronizedDestination: ExtensionWorkspaceNavigatorDestination?
    ) {
        let state = captureState()
        if !self.presentation.rows.isEmpty {
            retainedNonemptyState = state
        }
        self.presentation = presentation
        self.itemRowHeight = itemRowHeight
        self.synchronizedDestination = synchronizedDestination
        tableView.reloadData()
        guard !presentation.rows.isEmpty else { return }
        let restoration = retainedNonemptyState ?? state
        restoreSelection(preferredItemID: restoration.selectedItemID)
        restoreScroll(
            to: restoration.topVisibleItemID,
            offset: restoration.topVisibleOffset
        )
    }

    func reloadItems(withSourceSessionIDs sessionIDs: Set<String>) {
        let rows = IndexSet(sessionIDs.compactMap { presentation.rowBySourceSessionID[$0] })
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
    }

    func synchronizeSelection(with destination: ExtensionWorkspaceNavigatorDestination?) {
        synchronizedDestination = destination
        restoreSelection(preferredItemID: nil)
    }

    func captureState() -> WorkspaceNavigatorCollectionState {
        let selectedItemID = item(at: tableView.selectedRow)?.sourceSessionID
        let top = topVisibleItem()
        return .init(
            selectedItemID: selectedItemID,
            expandedItemIDs: [],
            topVisibleItemID: top?.itemID,
            topVisibleOffset: top?.offset ?? 0
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentation.rows.count
    }

    var itemRowHeightForTesting: CGFloat { itemRowHeight }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard presentation.rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceNavigatorPipelineRow")
        let host = tableView.makeView(withIdentifier: identifier, owner: self)
            as? WorkspaceNavigatorRowHostView ?? WorkspaceNavigatorRowHostView()
        host.identifier = identifier
        do {
            switch presentation.rows[row] {
            case .section(let title):
                host.setAccessibilityIdentifier("workspace.navigator.pipeline-section")
                try host.install(WorkspaceNavigatorPipelineTemplateView(
                    node: .text(title, role: .compactDetail),
                    imageResolver: { _ in nil }
                ))
            case .item(let item):
                host.setAccessibilityIdentifier(
                    "workspace.navigator.item.\(collectionID).\(item.sourceSessionID)"
                )
                try host.install(renderItem(item))
            }
        } catch {
            onRenderFailure(error)
            return nil
        }
        return host
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard presentation.rows.indices.contains(row) else { return itemRowHeight }
        return switch presentation.rows[row] {
        case .section:
            SidebarDefaults.headingRowHeight
        case .item:
            itemRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row) != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback,
              let item = item(at: tableView.selectedRow) else { return }
        onActivation(item.destination, item.sourceSessionID)
    }

    private func item(at row: Int) -> WorkspaceNavigatorPipelineItem? {
        guard presentation.rows.indices.contains(row),
              case .item(let item) = presentation.rows[row] else { return nil }
        return item
    }

    private func restoreSelection(preferredItemID: String?) {
        let matchingID: String?
        if let synchronizedDestination {
            matchingID = presentation.rows.lazy.compactMap {
                row -> WorkspaceNavigatorPipelineItem? in
                guard case .item(let item) = row else { return nil }
                return item
            }.first {
                destinationsMatch($0.destination, synchronizedDestination)
            }?.sourceSessionID
        } else {
            matchingID = preferredItemID
        }
        // Host navigation is authoritative, including when its destination has no row in the
        // current presentation. Retained table state applies only before the host synchronizes.
        suppressSelectionCallback = true
        if let matchingID, let row = presentation.rowBySourceSessionID[matchingID] {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
    }

    private func topVisibleItem() -> (itemID: String, offset: CGFloat)? {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        for row in range.location..<(range.location + range.length) {
            guard let item = item(at: row) else { continue }
            return (
                item.sourceSessionID,
                max(0, tableView.visibleRect.minY - tableView.rect(ofRow: row).minY)
            )
        }
        return nil
    }

    private func restoreScroll(to itemID: String?, offset: CGFloat) {
        guard let itemID, let row = presentation.rowBySourceSessionID[itemID] else { return }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        let maximumY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.minX,
            y: min(maximumY, max(0, tableView.rect(ofRow: row).minY + offset))
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
            case (nil, _), (_, nil): return true
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
    typealias ItemRenderer = (ExtensionWorkspaceNavigatorItem) throws -> NSView
    typealias ActivationHandler = (ExtensionWorkspaceNavigatorActivation, String) -> Void
    typealias RenderFailureHandler = (Error) -> Void

    let collectionID: String

    private let collection: ExtensionWorkspaceNavigatorCollection
    private let itemIDs: Set<String>
    private let renderContent: ContentRenderer
    private let renderItem: ItemRenderer?
    private let itemRowHeight: CGFloat?
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
        renderItem: ItemRenderer? = nil,
        itemRowHeight: CGFloat? = nil,
        onActivation: @escaping ActivationHandler,
        onRenderFailure: @escaping RenderFailureHandler
    ) {
        collectionID = collection.id
        self.collection = collection
        itemIDs = Set(collection.items.map(\.id))
        self.restoredState = restoredState
        self.renderContent = renderContent
        self.renderItem = renderItem
        self.itemRowHeight = itemRowHeight
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

        switch node.value {
        case .section(let section):
            guard let header = section.header else { return nil }
            host.setAccessibilityIdentifier(
                "workspace.navigator.section.\(collectionID).\(section.id)"
            )
            do {
                try host.install(renderContent(header))
            } catch {
                onRenderFailure(error)
                return nil
            }
        case .item(let item):
            host.setAccessibilityIdentifier(
                "workspace.navigator.item.\(collectionID).\(item.id)"
            )
            do {
                if let renderItem {
                    try host.install(renderItem(item))
                } else {
                    let content = contentOverrides[item.id] ?? item.content
                    try host.install(renderContent(content))
                }
            } catch {
                onRenderFailure(error)
                return nil
            }
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
        if let itemRowHeight,
           (item as? WorkspaceNavigatorCollectionNode)?.item != nil {
            return itemRowHeight
        }
        return SidebarDefaults.projectCompactRowHeight
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
