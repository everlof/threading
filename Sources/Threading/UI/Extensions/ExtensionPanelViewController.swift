import AppKit
import ThreadingExtensionKit

/// A production host for one extension panel inside a session's display-pane tab.
///
/// The tab retains only stable extension/panel identifiers. Live panel values are accepted from
/// the currently registered process generation, and every AppKit view is rebuilt by Threading's
/// semantic renderer. If that generation disappears, the tab remains as a recoverable place and
/// shows an unavailable state until the same contribution returns.
@MainActor
final class ExtensionPanelViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {
    let extensionIdentifier: String
    let panelID: String

    private let context: ExtensionCommandContext
    private weak var router: ExtensionPanelRouting?
    private let fallbackTitle: String
    private let events = AppEventObservations()

    private var panel: ExtensionPanel?
    private var extensionName: String?
    private var processGeneration: String?
    private var loadedProcessGeneration: String?
    private var statusMessage: String?
    private var remoteFailureMessage: String?
    private var actionSequence = 0
    private var remoteSurfaceView: ExtensionRemoteSurfaceView?
    private var isPanelVisible = false
    /// Players, retained by document id rather than by row.
    ///
    /// The panel virtualizes its rows, so the cell holding a canvas is recycled the moment it
    /// scrolls away — and a player rebuilt per materialization would restart the animation every
    /// time the table reused a cell, which is the same defect as a panel replacement restarting
    /// it. The id is the identity; a document that keeps it keeps its position.
    private var playersByDocumentID: [String: MediaDocumentPlayerView] = [:]

    private let scrollView = ThemedScrollView()
    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: Self.contentColumnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = Design.Size.fieldHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.dataSource = self
        table.delegate = self
        return table
    }()

    private enum MessageTone {
        case status
        case unavailable
        case failure
    }

    private enum RowContent {
        case message(text: String, tone: MessageTone, identifier: String)
        case node(
            ExtensionNode,
            parentAxis: ExtensionAxis?,
            fillsContentWidth: Bool
        )
    }

    private struct PresentationRow {
        let content: RowContent
        let topInset: CGFloat
    }

    private var presentationRows: [PresentationRow] = []

    private static let contentColumnIdentifier = NSUserInterfaceItemIdentifier(
        "ExtensionPanelContent"
    )
    private static let contentRowIdentifier = NSUserInterfaceItemIdentifier(
        "ExtensionPanelVirtualRow"
    )

    var virtualRowCountForTesting: Int { presentationRows.count }
    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    var onChange: (() -> Void)?

    var panelTitle: String {
        panel?.title ?? fallbackTitle
    }

    init(
        extensionIdentifier: String,
        panelID: String,
        title: String,
        context: ExtensionCommandContext,
        router: ExtensionPanelRouting
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.panelID = panelID
        self.fallbackTitle = title
        self.context = context
        self.router = router
        super.init(nibName: nil, bundle: nil)

        events.observe(ExtensionsDidChange.self) { [weak self] _ in
            self?.refreshRegistration()
        }
        refreshRegistration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = tableView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        render()
        loadPanelIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isPanelVisible = true
        remoteSurfaceView?.setPresentationVisible(true)
        applyMediaPresentation()
    }

    override func viewDidDisappear() {
        isPanelVisible = false
        remoteSurfaceView?.setPresentationVisible(false)
        applyMediaPresentation()
        super.viewDidDisappear()
    }

    /// The clock stops when this panel is not the selected tab. Everything else a player watches
    /// — occlusion, miniaturization, a hidden ancestor — it observes itself; a tab going away is
    /// the one thing only its host knows.
    private func applyMediaPresentation() {
        for player in playersByDocumentID.values {
            player.setPresentationActive(isPanelVisible)
        }
    }

    private func refreshRegistration() {
        let item = router?.registeredPanel(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        )

        if let item {
            extensionName = item.extensionName
            if processGeneration != item.processGeneration {
                disconnectRemoteSurface()
                processGeneration = item.processGeneration
                loadedProcessGeneration = nil
                panel = item.panel
                statusMessage = nil
                remoteFailureMessage = nil
                actionSequence += 1
            }
        } else {
            disconnectRemoteSurface()
            processGeneration = nil
            loadedProcessGeneration = nil
            panel = nil
            statusMessage = nil
            remoteFailureMessage = nil
            actionSequence += 1
        }

        if isViewLoaded {
            render()
            loadPanelIfNeeded()
        }
        onChange?()
    }

    /// Loads context-dependent content once per process generation. A response panel may also
    /// carry `loadActionID`; generation tracking deliberately prevents that replacement from
    /// recursively loading itself.
    private func loadPanelIfNeeded() {
        guard let generation = processGeneration,
              loadedProcessGeneration != generation,
              let actionID = panel?.loadActionID else {
            return
        }
        loadedProcessGeneration = generation
        invoke(actionID, pendingMessage: "Loading…")
    }

    private func render() {
        presentationRows.removeAll(keepingCapacity: true)

        if let statusMessage {
            appendMessage(
                statusMessage,
                tone: .status,
                identifier: "extension.panel.status"
            )
        }

        guard let panel else {
            disconnectRemoteSurface()
            scrollView.isHidden = false
            let owner = extensionName ?? extensionIdentifier
            appendMessage(
                L10n.format(
                    "“%@” is unavailable because %@ is not running or no longer registers this panel.",
                    fallbackTitle,
                    owner
                ),
                tone: .unavailable,
                identifier: "extension.panel.unavailable"
            )
            tableView.reloadData()
            return
        }

        if panel.remoteSurface != nil, remoteFailureMessage == nil,
           renderRemoteSurface() {
            scrollView.isHidden = true
            tableView.reloadData()
            return
        }
        if panel.remoteSurface == nil {
            disconnectRemoteSurface()
        }
        scrollView.isHidden = false
        remoteSurfaceView?.isHidden = true

        if let remoteFailureMessage {
            appendMessage(
                remoteFailureMessage,
                tone: .status,
                identifier: "extension.remote-surface.fallback"
            )
        }

        pruneRetiredMediaPlayers(keeping: panel.root)
        do {
            try ExtensionNodeRenderer.validate(panel.root)
            appendSemanticNode(
                panel.root,
                parentAxis: nil,
                topInset: presentationRows.isEmpty
                    ? Design.Spacing.pane
                    : Design.Spacing.medium,
                fillsContentWidth: true
            )
        } catch {
            appendMessage(
                L10n.format(
                    "This extension panel could not be rendered: %@",
                    error.localizedDescription
                ),
                tone: .failure,
                identifier: "extension.panel.render-error"
            )
        }
        tableView.reloadData()
    }

    private func appendMessage(_ text: String, tone: MessageTone, identifier: String) {
        presentationRows.append(PresentationRow(
            content: .message(text: text, tone: tone, identifier: identifier),
            topInset: presentationRows.isEmpty ? Design.Spacing.pane : Design.Spacing.medium
        ))
    }

    /// Vertical stacks are layout grouping, not one indivisible view. Flattening them preserves
    /// their order and spacing while making the semantic child the table's reuse unit. Nodes whose
    /// meaning depends on two-dimensional composition remain intact inside that one visible row.
    private func appendSemanticNode(
        _ node: ExtensionNode,
        parentAxis: ExtensionAxis?,
        topInset: CGFloat,
        fillsContentWidth: Bool
    ) {
        if case .stack(.vertical, let spacing, let children) = node {
            for (index, child) in children.enumerated() {
                appendSemanticNode(
                    child,
                    parentAxis: .vertical,
                    topInset: index == 0 ? topInset : Self.spacingValue(spacing),
                    fillsContentWidth: Self.fillsWidthInsideVerticalStack(child)
                )
            }
            return
        }
        presentationRows.append(PresentationRow(
            content: .node(
                node,
                parentAxis: parentAxis,
                fillsContentWidth: fillsContentWidth
            ),
            topInset: topInset
        ))
    }

    private static func fillsWidthInsideVerticalStack(_ node: ExtensionNode) -> Bool {
        switch node {
        case .textInput, .scene, .divider, .media:
            true
        default:
            false
        }
    }

    private static func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        switch spacing {
        case .none: 0
        case .tight: Design.Spacing.tight
        case .small: Design.Spacing.small
        case .medium: Design.Spacing.medium
        case .large: Design.Spacing.large
        }
    }

    // MARK: - Virtual Semantic Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let row = presentationRows[tableRow]
        let cell = tableView.makeView(
            withIdentifier: Self.contentRowIdentifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        cell.identifier = Self.contentRowIdentifier

        let content: NSView
        switch row.content {
        case .message(let text, let tone, let identifier):
            content = messageView(text, tone: tone, identifier: identifier)

        case .node(let node, let parentAxis, let fillsContentWidth):
            do {
                let rendered = try ExtensionNodeRenderer.renderValidatedRow(
                    node,
                    parentAxis: parentAxis,
                    fillsContentWidth: fillsContentWidth,
                    imageResolver: { [weak self] reference in
                        self?.resolveImage(reference)
                    },
                    mediaPlayerFactory: { [weak self] document in
                        self?.player(for: document)
                    },
                    onEvent: { [weak self] actionID, value in
                        self?.invoke(actionID, value: value)
                    }
                )
                rendered.setAccessibilityIdentifier(
                    "extension.panel.\(extensionIdentifier).\(panelID)"
                )
                content = rendered
            } catch {
                content = messageView(
                    L10n.format(
                        "This extension panel could not be rendered: %@",
                        error.localizedDescription
                    ),
                    tone: .failure,
                    identifier: "extension.panel.render-error"
                )
            }
        }

        cell.install(
            content,
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Spacing.pane,
            topInset: row.topInset,
            bottomInset: tableRow == presentationRows.count - 1 ? Design.Spacing.pane : 0
        )
        return cell
    }

    private func messageView(
        _ text: String,
        tone: MessageTone,
        identifier: String
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        switch tone {
        case .status:
            label.applyFont(.detail())
            label.textColor = Design.Text.secondary
        case .unavailable:
            label.applyFont(.body)
            label.textColor = Design.Text.tertiary
        case .failure:
            label.applyFont(.body)
            label.textColor = Design.Status.negative
        }
        label.setAccessibilityIdentifier(identifier)
        return label
    }

    private func renderRemoteSurface() -> Bool {
        guard panel?.remoteSurface != nil else { return false }
        let surfaceView: ExtensionRemoteSurfaceView
        if let existing = remoteSurfaceView {
            surfaceView = existing
        } else {
            let created = ExtensionRemoteSurfaceView()
            created.translatesAutoresizingMaskIntoConstraints = false
            created.onDisconnect = { [weak self] message in
                guard let self else { return }
                self.remoteFailureMessage = message
                self.render()
            }
            view.addSubview(created)
            NSLayoutConstraint.activate([
                created.topAnchor.constraint(equalTo: view.topAnchor),
                created.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                created.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            remoteSurfaceView = created
            surfaceView = created
        }
        surfaceView.isHidden = false
        guard surfaceView.subscription == nil else {
            surfaceView.setPresentationVisible(isPanelVisible)
            return true
        }

        let presentationID = UUID().uuidString.lowercased()
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let viewport = ExtensionRemoteSurfaceViewport(
            presentationID: presentationID,
            width: Double(max(0, view.bounds.width)),
            height: Double(max(0, view.bounds.height)),
            scale: Double(scale),
            isVisible: isPanelVisible
        )
        guard let subscription = router?.connectRemoteSurface(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            context: context,
            initialViewport: viewport,
            consumer: surfaceView
        ) else {
            remoteFailureMessage = "The declared remote surface is unavailable. "
                + "Showing the extension's semantic fallback."
            surfaceView.isHidden = true
            return false
        }
        surfaceView.install(subscription: subscription)
        surfaceView.setPresentationVisible(isPanelVisible)
        return true
    }

    private func disconnectRemoteSurface() {
        remoteSurfaceView?.subscription?.cancel()
        remoteSurfaceView?.removeFromSuperview()
        remoteSurfaceView = nil
    }

    // MARK: - Media

    /// The player for one document, created once and kept for as long as the panel names it.
    private func player(for document: ExtensionMediaDocument) -> NSView? {
        let player: MediaDocumentPlayerView
        if let existing = playersByDocumentID[document.id] {
            player = existing
        } else {
            let identifier = extensionIdentifier
            let created = MediaDocumentPlayerView(loader: { [weak self] source in
                await self?.loadMediaDocument(source, for: identifier)
                    ?? .failure(.unresolvedSource)
            })
            created.onStateReport = { [weak self] report in
                guard let self,
                      let actionID = self.panel?.root.mediaDocuments
                          .first(where: { $0.id == report.documentID })?.stateActionID
                else { return }
                self.invoke(actionID, value: report.actionValue, silently: true)
            }
            playersByDocumentID[document.id] = created
            player = created
        }
        player.setPresentationActive(isPanelVisible)
        player.update(document: document)
        return player
    }

    /// Drops the players for documents this panel no longer names.
    ///
    /// The cardinality here is *documents the extension has shown*, which is externally sized: an
    /// asset browser walked through a hundred animations would otherwise retain a hundred decoded
    /// sessions, none of them on screen. A player is kept only while the panel still names it.
    private func pruneRetiredMediaPlayers(keeping root: ExtensionNode) {
        let live = Set(root.mediaDocuments.map(\.id))
        for (id, player) in playersByDocumentID where !live.contains(id) {
            player.setPresentationActive(false)
            player.removeFromSuperview()
            playersByDocumentID.removeValue(forKey: id)
        }
    }

    /// Resolves a source to bytes on the host's side of the boundary.
    ///
    /// Only `extensionResource` resolves here. A project-file handle is a separate authority
    /// (`host.project.files.read`) resolved by its own broker, and an attachment handle is valid
    /// **only** inside `attachments.preview@1` — replaying one into a panel is refused rather than
    /// quietly resolved, which is what keeps the preview contract from becoming a read authority.
    private func loadMediaDocument(
        _ source: ExtensionMediaSource,
        for extensionIdentifier: String
    ) async -> Result<Data, MediaDocumentFailure> {
        switch source {
        case .extensionResource(let path):
            guard let data = router?.extensionMediaResourceData(
                extensionIdentifier: extensionIdentifier,
                relativePath: path
            ) else {
                return .failure(.unresolvedSource)
            }
            return .success(data)
        case .fileHandle(let handle):
            guard let data = ExtensionProjectFileBroker.shared.documentData(
                forHandle: handle,
                extensionIdentifier: extensionIdentifier,
                maximumBytes: MediaDocumentLimits.default.maximumDocumentBytes
            ) else {
                return .failure(.unresolvedSource)
            }
            return .success(data)
        case .sessionAttachment:
            return .failure(.unresolvedSource)
        }
    }

    private func resolveImage(_ reference: ExtensionImageReference) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .extensionResource(let path):
            guard let url = router?.extensionImageResourceURL(
                extensionIdentifier: extensionIdentifier,
                relativePath: path
            ) else { return nil }
            return ExtensionImageResourceLoader.image(at: url)
        case .hostAsset:
            // Host assets are scoped to documented component contracts. A standalone panel
            // receives semantic snapshots and package resources instead of private view assets.
            return nil
        }
    }

    private func invoke(
        _ actionID: String,
        value: ExtensionJSONValue? = nil,
        pendingMessage: String? = nil,
        silently: Bool = false
    ) {
        actionSequence += 1
        let sequence = actionSequence
        // A state report is not something the user asked for, so it does not put "Running…" over
        // the panel and does not re-render the tree it was raised from — a re-render would tear
        // down the player mid-frame and report again.
        if !silently {
            statusMessage = pendingMessage ?? "Running “\(actionID)”…"
            render()
        }

        guard router?.invokePanelAction(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            actionID: actionID,
            value: value,
            context: context,
            completion: { [weak self] result in
                guard let self, self.actionSequence == sequence else { return }
                self.present(result)
            }
        ) == true else {
            statusMessage = "The extension panel is no longer available."
            render()
            return
        }
    }

    private func present(_ result: Result<ExtensionActionResponse, Error>) {
        switch result {
        case .failure(let error):
            statusMessage = error.localizedDescription

        case .success(let response):
            if let error = response.error {
                statusMessage = error
            } else {
                if let panel = response.panel {
                    if self.panel?.remoteSurface != panel.remoteSurface {
                        disconnectRemoteSurface()
                        remoteFailureMessage = nil
                    }
                    self.panel = panel
                }
                statusMessage = response.message
            }
        }
        render()
        onChange?()
    }
}
