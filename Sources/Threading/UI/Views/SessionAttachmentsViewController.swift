import AppKit
import ThreadingExtensionKit
import WebKit

/// The synchronous main-thread work that presents one attachment preview.
///
/// Kept as nanoseconds so the stress fixture can subtract the preview from controller construction
/// without losing precision. It is a deterministic per-controller sample for the CLI benchmark;
/// the outer production span makes the same operation visible to xctrace and self-profile exports.
struct SessionAttachmentPreviewTiming {
    var format = "none"
    var metadataNanoseconds: UInt64 = 0
    var clearNanoseconds: UInt64 = 0
    var prepareNanoseconds: UInt64 = 0
    var installNanoseconds: UInt64 = 0
    var presentNanoseconds: UInt64 = 0
    var totalNanoseconds: UInt64 = 0
}

/// A session's inspectable deliverables: two panes, the chronology above its preview, and a
/// footer naming the selected file with the one action the user last took beside it.
///
/// The controller holds no file bytes. The referenced project file stays authoritative, so a
/// second mention after an overwrite refreshes the preview in place.
final class SessionAttachmentsViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    private let appEvents = AppEventObservations()

    /// Opens two of this session's files against each other, in the panel's own Compare tab.
    ///
    /// A closure rather than a reach into the display pane: this pane is a child of that
    /// controller and could walk up to it, but the comparison is the *panel's* to place — it
    /// decides which tab holds the pair and whether one already does — and a list that knew that
    /// would be a list that has to be given a whole panel to be tested.
    var onCompare: ((_ old: SessionAttachment, _ new: SessionAttachment) -> Void)?

    /// Where a file dropped on this list belongs, which decides whether it is referenced or
    /// copied into custody.
    ///
    /// Read through a closure rather than straight out of `ProjectStore` for the reason
    /// `PreferenceStore` exists: this bundle's tests are hosted in the app, so a fixture that
    /// registered a project to exercise a drop would leave a row in the developer's own sidebar.
    /// The default is the real answer, and the pane only ever exists for a session that has one.
    lazy var projectRootProvider: () -> URL? = { [sessionID] in
        ProjectStore.shared.workingDirectory(forSessionID: sessionID).map(URL.init(fileURLWithPath:))
    }

    /// Everything recorded for the session, and the subset the filter is showing. Both are kept:
    /// the filter decides whether it belongs on screen at all by looking at the whole list, so a
    /// pane filtered down to nothing must not then read as a session with no attachments.
    private var allAttachments: [SessionAttachment] = []
    private var attachments: [SessionAttachment] = []
    private var filter: AttachmentFilter = .all
    private var selectedRelativePath: String?
    /// `selectRowIndexes` invokes the delegate synchronously. A refresh owns the one presentation
    /// after it has restored selection, so its delegate notification must not present the same
    /// decoder or system renderer once on the way there and then again at the end of the refresh.
    private var isRestoringSelection = false

    /// The offer/decline shell for `attachments.preview@1`, and the body a candidate won with.
    ///
    /// Held per pane rather than per row: a new selection cancels the offer in flight, which is
    /// what keeps a slow candidate's late answer from replacing the preview of a row the user has
    /// already moved off.
    private lazy var previewOffer = SessionAttachmentPreviewOffer(
        router: ExtensionManager.shared
    )
    private var extensionPreviewHost: NSView?
    private var extensionPreviewPlayers: [String: MediaDocumentPlayerView] = [:]
    /// The attachment an extension preview may resolve a `sessionAttachment` handle for.
    ///
    /// Exactly one, and only while it is the row on screen. That is what makes the handle valid
    /// *inside* the preview contract and nowhere else — replayed into a panel, or asked for after
    /// the selection moved, it resolves to nothing.
    private var previewableAttachment: SessionAttachment?
    private(set) var firstPreviewTimingForTesting: SessionAttachmentPreviewTiming?
    private(set) var latestPreviewTimingForTesting = SessionAttachmentPreviewTiming()
    private(set) var previewPresentationCountForTesting = 0

    /// The one row a caller has explicitly asked to be looking at, resolved on the next refresh.
    ///
    /// Held rather than acted on immediately for two reasons. A pane belonging to an unselected
    /// session has no loaded view yet — `refresh()` returns early there — so the request has to
    /// survive until `viewDidLoad` asks for the list; and the row may be one the *filter* is
    /// hiding, which is a conflict only `refresh()` is in a position to settle. Cleared as soon
    /// as it has been answered, so a later reload does not keep dragging the selection back.
    private var revealPath: String?

    /// The list's height — its *rows'* height, capped at its share of the pane.
    ///
    /// It used to be a constant three rows tall, so a session with eight attachments read
    /// through a letterbox; and this list is the session's whole visual history, which a fixed
    /// three rows cannot be. The preview pane below the fold is the layout's one flexible
    /// element, so a pane too short for everything gives way in one order: the preview first,
    /// the list after it (`listHeightPriority` is below `required`), and the footer — whose
    /// band height and edges are required — never. The cap is what makes that safe: a list that
    /// can only ever ask for its share of the pane cannot be what pushes the footer's actions
    /// out of reach.
    ///
    /// The share is half the pane until the user moves the fold, and theirs afterwards
    /// (`AttachmentsListHeight`). Half is the right *opening* answer and the wrong permanent
    /// one: a session with eighteen attachments fills that cap, and the report the row is
    /// pointing at then gets half a pane to be read in whatever it is worth.
    private var listHeightConstraint: NSLayoutConstraint?

    private lazy var countLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.quaternary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private lazy var filterControl: ThemedSegmentedControl = {
        let control = ThemedSegmentedControl()
        control.configure(titles: AttachmentFilter.allCases.map(\.title))
        control.setAccessibilityLabel(L10n.string("Show attachments from"))
        control.onSelect = { [weak self] index in
            guard AttachmentFilter.allCases.indices.contains(index) else { return }
            self?.filter = AttachmentFilter.allCases[index]
            self?.refresh()
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()
    /// The count and the filter as one line: two halves of the same sentence, and a stack so a
    /// hidden filter takes its height with it rather than leaving a band of nothing behind.
    private lazy var headerRow: NSStackView = {
        let row = NSStackView(views: [countLabel, filterControl])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.small
        // The label absorbs the slack, which is what puts the filter on the trailing edge.
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // One line *means* one line. The row is pinned above (the pane's top) and below (the
        // list), and a stack left free to grow was where a tall pane's slack silently went:
        // the layout was ambiguous, the solver gave this band hundreds of points, and the
        // centred count label floated mid-pane with the list a screen below it — no constraint
        // broken, nothing logged, just a caption adrift.
        row.setHuggingPriority(.required, for: .vertical)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()
    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        table.headerView = nil
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onQuickLook = { [weak self] row in self?.inspectAttachment(atRow: row) ?? false }
        table.allowsEmptySelection = false
        // Several rows are a batch: dragging one selected row carries every selected row's
        // file — AppKit asks `pasteboardWriterForRow` per row — and the two places a batch
        // lands, a composer and a terminal, already take several files in one drop.
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: SessionAttachmentsDefaults.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        return table
    }()
    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()
    private lazy var previewHost: NSView = {
        let host = NSView()
        host.setAccessibilityIdentifier("attachments.preview-host")
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        return host
    }()
    private var imageView: ThemedImagePreview?
    /// PDFs, archives and office documents alike: PDFKit for the first, Quick Look for the
    /// rest, both already contained inside the one named system-chrome boundary.
    private var documentView: MediaInspectorDocumentView?

    /// The fold between the two panes: the chronology ends here, and what its selected row
    /// holds begins. Draggable, because which half a reader needs is not something the pane can
    /// know — see `listHeightConstraint`.
    private lazy var listFold: PaneFoldDivider = {
        let fold = PaneFoldDivider()
        fold.setAccessibilityLabel(L10n.string("Attachments list height"))
        fold.onDrag = { [weak self] travel in self?.foldDragged(by: travel) }
        fold.onReset = { [weak self] in self?.foldDidReset() }
        return fold
    }()
    private var htmlView: WKWebView?
    private struct PendingHTMLNavigation {
        let token: UUID
        let fileURL: URL
        let readAccessURL: URL
    }
    private var pendingHTMLNavigation: PendingHTMLNavigation?
    private(set) var latestHTMLRendererInstallNanosecondsForTesting: UInt64 = 0
    private(set) var latestHTMLNavigationNanosecondsForTesting: UInt64 = 0
    var hasPendingHTMLNavigationForTesting: Bool { pendingHTMLNavigation != nil }
    var hasInstalledHTMLRendererForTesting: Bool { htmlView != nil }
    private lazy var previewMessage: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// A diagram's *source*, in the theme's own code face. Text is what these files are —
    /// rendering Graphviz or Mermaid would take an engine the app does not carry — and their
    /// source is short, legible, and exactly what gets dragged into a chat box next.
    private var sourcePreview: ThemedTextScrollView?
    private var sourceTextView: ThemedTextView? { sourcePreview?.textView }
    private lazy var fileLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.subheading)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingMiddle
        // The footer's trailing controls keep their size; the name is what gives way.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    /// In the row's own voice — `.caption`, tertiary — because it is the row's own sentence:
    /// the list one inch above states exactly this name-over-path pair, and the footer restating
    /// it in mono read as a different kind of fact. The mono face also sat badly under the
    /// prose title: a monospaced x-height at caption scale is nearly the title's, so the two
    /// lines read cramped at the same `hairline` gap the row wears comfortably.
    private lazy var pathLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// The file's name over its place — the caption half of the footer's sentence, one block so
    /// the band can centre it against the control beside it.
    private lazy var fileTextBlock: NSStackView = {
        let block = NSStackView(views: [fileLabel, pathLabel])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = Design.Spacing.hairline
        block.translatesAutoresizingMaskIntoConstraints = false
        return block
    }()

    /// The one press the footer offers: whatever the menu was last used for.
    ///
    /// Finder's pattern, and the header's Open in control already states the rule here
    /// (`external-apps.md`, "last used wins"): there is no Settings row for a preferred action
    /// because the choice is made in the act of taking it — choosing from either menu retitles
    /// this button. `updatePrimaryAction()` re-resolves on every refresh, because what the
    /// memory names may stop being on offer (a remembered Chat with nothing listening).
    private lazy var primaryActionButton = ThemedButton(
        title: L10n.string("Open"),
        target: self,
        action: #selector(performRememberedAction)
    )

    /// The other ways to take it — the same entries as the row's own menu, one builder
    /// (`contextMenuEntries`), so the two surfaces cannot drift apart.
    private lazy var actionsChevron: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: DesignSymbols.chevron,
            accessibility: L10n.string("Attachment actions"),
            target: .titledSplitMenu
        )
        button.presentsMenu = true
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            self.presentActionsMenu(from: button)
        }
        return button
    }()

    /// The press and its chevron on one plate (`SplitButtonView`): the two act on **one** file,
    /// and spaced as siblings they read as a button with an unrelated chevron floating beside
    /// it — the same misreading the header's Open in control was welded to remove.
    ///
    /// This used to be the spread form, matching the composer's schedule chevron beside its
    /// send. That match was the wrong axis: the composer's pair is *forced* apart by emphasis —
    /// its press is the accent-filled primary, and a shared plate would hold a permanent colour
    /// seam between the accent and the chevron's neutral. This press is a neutral secondary, so
    /// the weld is available, and welding is what says "one file, one decision"
    /// (`design-system.md`).
    private lazy var actionsControl = SplitButtonView(
        action: primaryActionButton,
        chevron: actionsChevron
    )

    /// The pane's floor: the selected file named at one edge, what to do with it at the other,
    /// one centreline between them — the band's geometry, stated once in `PaneFooterView`.
    private lazy var footerBand: PaneFooterView = {
        let band = PaneFooterView(
            leading: [fileTextBlock],
            trailing: [actionsControl],
            margin: .paneEdge
        )
        // Two `PaneFooterView`s live in this pane; the identifier is what tells them apart.
        band.setAccessibilityIdentifier("attachments.footer")
        return band
    }()

    private var actionMenuSession: AnyObject?
    private var contextMenuSession: AnyObject?

    /// Which row is currently saying it would take the drop, or `-1` for none.
    ///
    /// Held rather than read back off the rows because the *transitions* are what the affordance
    /// costs: a drag reports its position continuously, and asking every visible row to hide four
    /// labels sixty times a second is a list relaying itself while the pointer moves.
    private var dropTargetRow = -1
    private lazy var emptyLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString:
            L10n.string(
                "Images, documents, archives, diagrams, and HTML from this session will appear here."
            )
        )
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Properties (the scope band)

    /// The caption half of the band: how many files the current scope is deciding about.
    ///
    /// Terse in the header's own voice, because it is the same fact from the other side — the
    /// header counts what is listed, this counts what the rule is holding back, or letting in.
    private lazy var scopeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.quaternary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private lazy var scopeButton: ThemedButton = {
        let button = ThemedButton(title: "", target: self, action: #selector(toggleScope))
        // The quiet tier: this is an aside about a setting, not one of the pane's three actions.
        button.emphasis = .tertiary
        return button
    }()
    /// Shown only when the setting would change *this* pane, which is the whole rule for it:
    /// a control that is present whatever it would do teaches nothing, and a session that never
    /// names a file outside its project should never be asked about files outside its project.
    private lazy var scopeBand: PaneFooterView = {
        let band = PaneFooterView(
            leading: [scopeLabel],
            trailing: [scopeButton],
            margin: .paneEdge
        )
        band.setAccessibilityIdentifier("attachments.scope-band")
        return band
    }()
    private var scopeBandConstraints: [NSLayoutConstraint] = []
    private var footerToPaneBottom: [NSLayoutConstraint] = []
    private var footerToScopeBand: [NSLayoutConstraint] = []
    private var scopeAdmissionTask: Task<Void, Never>?
    private var scopeAdmissionGeneration = 0

    // MARK: - Initialization

    init(sessionID: SessionID) {
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)

        appEvents.observe(SessionAttachmentsDidChange.self) { [weak self] event in
            guard event.sessionID == self?.sessionID else { return }
            self?.refresh()
        }
        // The empty state names detection being off; toggling it in Settings must retitle the
        // pane that is already open.
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.refresh()
        }
        // Whether anything can be handed an attachment is a fact about the *agent*, not about
        // the list, and it changes without the list changing: a dormant session has no door
        // until it launches, and loses it again when it exits. Only the footer's action is
        // re-resolved — activity churns several times a turn, and re-reading the store for each
        // would be a pane rebuilding itself while the agent thinks.
        appEvents.observe(SessionActivityDidChange.self) { [weak self] event in
            guard event.sessionID == self?.sessionID else { return }
            self?.updatePrimaryAction()
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyPreviewTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        scopeAdmissionTask?.cancel()
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupList()
        setupPreview()
        setupFooter()
        setupConstraints()
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
        updateListHeight()
    }

    // MARK: - Setup

    private func setupList() {
        view.addSubview(headerRow)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        tableView.onContextMenu = { [weak self] row, anchor in
            self?.presentContextMenu(forRow: row, anchor: anchor) ?? false
        }
        // A drag that leaves without landing has to lower the affordance it raised; the delegate
        // is told about neither exit. See `ThemedTableView.onDraggingExited`.
        tableView.onDraggingExited = { [weak self] in self?.markDropTarget(row: -1) }

        // Out of the list: a row carries its own file, which is what lets it be dropped on Finder,
        // on a composer, or on another row of this same list. In: a picture from anywhere, which
        // is the other half of the same gesture — see `tableView(_:validateDrop:…)`.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Both, in the app: this list answers a row-onto-row drag with `.generic` — nothing is
        // being copied, a question is being asked about two pictures — while a composer answers
        // the same drag with `.copy`, and a destination may only return an operation the source
        // allowed. Naming one of them here is how the promise in the comment above becomes a
        // gesture that quietly does nothing at the other end.
        tableView.setDraggingSourceOperationMask([.copy, .generic], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL, .png, .tiff])
        // The rows draw the drop themselves — a row says *what* dropping there would do, which a
        // blue ring around it cannot. See `SessionAttachmentRowView.isDropTarget`.
        tableView.draggingDestinationFeedbackStyle = .none
    }

    private func setupPreview() {
        view.addSubview(listFold)
        previewHost.addSubview(previewMessage)
        view.addSubview(previewHost)
        applyPreviewTheme()
    }

    private func setupFooter() {
        view.addSubview(footerBand)
        view.addSubview(scopeBand)
        scopeBand.isHidden = true
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            scrollView.topAnchor.constraint(
                equalTo: headerRow.bottomAnchor,
                constant: Design.Spacing.small
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Edge to edge, like the footer's own rule below: this is the fold between the
            // pane's two halves, and a rule that stops short of the pane it divides reads as a
            // stray line rather than as a boundary.
            listFold.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            listFold.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listFold.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // The preview is the layout's one flexible element: it fills whatever stands
            // between the fold and the footer, which is what makes the two halves *panes*
            // rather than a stack of bands with the slack pooling under them. Nothing here
            // states a content height, so nothing here can grow the window (the trap
            // `listHeightPriority`'s comment records).
            //
            // Flush against the fold, with no gap of its own: the divider's band *is* the gap
            // the pane used to hold here, which is what let the seam become a grip without
            // anything below it moving.
            previewHost.topAnchor.constraint(equalTo: listFold.bottomAnchor),
            previewHost.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            previewHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            previewHost.bottomAnchor.constraint(
                equalTo: footerBand.topAnchor,
                constant: -Design.Spacing.small
            ),

            previewMessage.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor),
            previewMessage.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor),
            previewMessage.leadingAnchor.constraint(
                greaterThanOrEqualTo: previewHost.leadingAnchor,
                constant: inset
            ),
            previewMessage.trailingAnchor.constraint(
                lessThanOrEqualTo: previewHost.trailingAnchor,
                constant: -inset
            ),

            footerBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
        ])

        // Stated twice because the floor moves: with the scope band installed the footer stops
        // above it, and one set is active at a time.
        footerToPaneBottom = [
            footerBand.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ]
        footerToScopeBand = [
            footerBand.bottomAnchor.constraint(equalTo: scopeBand.topAnchor)
        ]
        NSLayoutConstraint.activate(footerToPaneBottom)

        scopeBandConstraints = [
            // Edge to edge, and to the frame rather than the safe area: the band draws the
            // pane's own fold and states its content's inset from the corner-adapted region
            // itself. See `PaneFooterView`.
            scopeBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scopeBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scopeBand.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(scopeBandConstraints)

        // A list with no rows asks for no height, which is the same sentence said with a zero.
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        listHeight.priority = SessionAttachmentsDefaults.listHeightPriority
        listHeight.isActive = true
        listHeightConstraint = listHeight
        updateListHeight()
    }

    /// Re-aims `listHeightConstraint` at the rows the list currently holds, capped at its share
    /// of the pane. Called from `refresh()`, because the rows change, and from `viewDidLayout`,
    /// because the cap is a function of the pane's *height*.
    ///
    /// One row is a one-row-tall list; eight rows in a tall pane are eight visible rows; eight
    /// rows in a short one are the cap, scrolled.
    private func updateListHeight() {
        guard let constraint = listHeightConstraint else { return }
        let target = resolvedListHeight()
        if constraint.constant != target { constraint.constant = target }
    }

    /// The list's rows, under whichever cap is in force.
    private func resolvedListHeight() -> CGFloat {
        let rows = listRowHeights()
        // Before the pane has a height there is nothing to take a share of, so the content
        // stands in and `viewDidLayout` corrects it the moment the height is real.
        guard view.bounds.height > 0 else { return rows.content }
        return min(rows.content, listCap(noSmallerThan: rows.oneRow))
    }

    /// What the rows ask for, and what one of them costs — the two numbers every cap here is
    /// answered against.
    private func listRowHeights() -> (content: CGFloat, oneRow: CGFloat) {
        let rows = tableView.numberOfRows
        // The table's own row rects rather than rows × `rowHeight`: intercell spacing and the
        // padding the inset style puts above the first row — and, mirrored, below the last — are
        // the table's business, and a list measured as bare rows clips that padding off into a
        // scroller a list showing everything it has has no reason to offer.
        let padding = rows > 0 ? tableView.rect(ofRow: 0).minY : 0
        let content = rows > 0
            ? tableView.rect(ofRow: rows - 1).maxY + padding + listChromeHeight
            : 0
        let oneRow = rows > 0
            ? tableView.rect(ofRow: 0).maxY + padding + listChromeHeight
            : SessionAttachmentsDefaults.rowHeight + listChromeHeight
        return (content, oneRow)
    }

    /// The two limits the pane keeps whoever is placing the fold — its own opening answer as much
    /// as the user's drag.
    ///
    /// Never below a single row: a list capped into a sliver is a scroller with nothing legible
    /// beside it, and the pane has already lost by then. Never past `maximumListShareOfPane`,
    /// because a stored height is a point value and the pane it was chosen in is not the pane it
    /// is read back in — a fold left at 600 in a tall window would otherwise arrive in a short one
    /// as a list with the preview crushed underneath it.
    private func listLimits(oneRow: CGFloat) -> (floor: CGFloat, ceiling: CGFloat) {
        let ceiling = view.bounds.height * SessionAttachmentsDefaults.maximumListShareOfPane
        return (oneRow, max(ceiling, oneRow))
    }

    /// The tallest the list may stand: the fold where the user left it, or half the pane while
    /// they have never moved it, held between those limits either way.
    private func listCap(noSmallerThan oneRow: CGFloat) -> CGFloat {
        let limits = listLimits(oneRow: oneRow)
        let chosen = AttachmentsListHeight.stored
            ?? view.bounds.height * SessionAttachmentsDefaults.listShareOfPane
        return min(max(chosen, limits.floor), limits.ceiling)
    }

    // MARK: - The Fold

    /// The fold under the hand, travelling down as the pointer does.
    ///
    /// The list is content-sized, so what a drag moves is the *ceiling* on it rather than a
    /// position between two panes — and the running total is clamped to what the fold can
    /// actually express rather than carried on past it. An overshoot the fold cannot show is a
    /// dead zone the drag back has to cross before anything moves again, which is the shell
    /// drawer's overshoot problem inverted: there the travel past the floor is the answer, here
    /// there is nothing below the last row for it to mean.
    ///
    /// Internal rather than private, like `TerminalContainerViewController`'s pair and for the
    /// same reason: a synthesized `NSEvent` carries no `deltaY`, so the fold's own tests drive
    /// this seam rather than a drag nobody can fabricate.
    func foldDragged(by travel: CGFloat) {
        guard view.bounds.height > 0 else { return }
        let rows = listRowHeights()
        // Against the pane's *limits*, not against the cap in force: the cap is what the fold is
        // currently at, and a travel clamped to where it already stands is a fold that cannot
        // move at all.
        let limits = listLimits(oneRow: rows.oneRow)
        let proposed = (listHeightConstraint?.constant ?? rows.content) + travel
        AttachmentsListHeight.record(
            min(max(proposed, limits.floor), min(rows.content, limits.ceiling))
        )
        updateListHeight()
    }

    /// A double-click on the fold: the pane places it again.
    func foldDidReset() {
        AttachmentsListHeight.reset()
        updateListHeight()
    }

    /// What the scroll view costs above its document — a border, a themed inset. Zero in this
    /// pane today, and asked for rather than assumed so a bordered scroll view does not silently
    /// clip its last row.
    private var listChromeHeight: CGFloat {
        let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom
        let border = NSScrollView.frameSize(
            forContentSize: .zero,
            horizontalScrollerClass: nil,
            verticalScrollerClass: nil,
            borderType: scrollView.borderType,
            controlSize: .regular,
            scrollerStyle: scrollView.scrollerStyle
        ).height
        return insets + border
    }

    // MARK: - Public Methods

    /// Brings one file to the front of the pane: its row selected, scrolled to, and previewed.
    ///
    /// This is how a *shown* image arrives now — `display_image` records the file and points the
    /// list at it rather than spending a tab on it (see `mcp-and-display.md`). The list is the
    /// session's chronology, so the request is for a row in it, not for a new surface.
    func showAttachment(at url: URL) {
        revealPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        // An unloaded pane keeps the request: `viewDidLoad`'s own refresh answers it, which is
        // what makes this work for a session the user has not selected yet.
        guard isViewLoaded else { return }
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let wasRestoringSelection = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoringSelection }

        let previous = selectedAttachment?.relativePath ?? selectedRelativePath
        // Before the list is read: widening the scope elsewhere — the Settings page, another
        // window — leaves this session's refused paths in hand, and they are admitted here so
        // the answer the user gave is the answer the pane shows, not the answer it shows next
        // time an agent happens to print the path again.
        if AppSettings.shared.includesAttachmentsOutsideProject {
            beginScopeAdmissionIfNeeded()
        } else {
            cancelScopeAdmission()
        }
        let listSnapshot = SessionAttachmentStore.shared.listSnapshot(for: sessionID)
        allAttachments = listSnapshot.attachments
        // A file someone explicitly asked to be shown outranks the filter. The alternative is
        // the pane answering "show me this picture" with the list it was already showing, which
        // reads as the request having been dropped — and the filter is a convenience, while this
        // is an instruction.
        if let revealPath,
           filter != .all,
           let revealed = allAttachments.first(where: { matches($0, path: revealPath) }),
           !filter.admits(revealed) {
            filter = .all
        }
        attachments = allAttachments.filter(filter.admits)
        countLabel.stringValue = L10n.format(
            "ATTACHMENTS  %lld",
            Int64(attachments.count)
        )
        tableView.reloadData()
        // The rows the mark was held on are gone, so the mark is too — stated rather than assumed,
        // or the next drag over the same index would find nothing to change and stay silent.
        dropTargetRow = -1
        updateListHeight()
        emptyLabel.stringValue = emptyStateMessage()
        updateFilterControl()
        updateScopeBand(count: listSnapshot.countOfFilesOutsideProject)

        let hasAttachments = !attachments.isEmpty
        headerRow.isHidden = allAttachments.isEmpty
        scrollView.isHidden = !hasAttachments
        listFold.isHidden = !hasAttachments
        previewHost.isHidden = !hasAttachments
        footerBand.isHidden = !hasAttachments
        emptyLabel.isHidden = hasAttachments

        guard hasAttachments else {
            revealPath = nil
            selectedRelativePath = nil
            clearPreview()
            return
        }

        let revealed = revealPath.flatMap { path in
            attachments.firstIndex { matches($0, path: path) }
        }
        revealPath = nil
        let index = revealed
            ?? previous.flatMap { path in
                attachments.firstIndex { $0.relativePath == path }
            }
            ?? 0
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        showSelected()
    }

    /// Re-resolves the remembered action against what the selection can actually take, and
    /// retitles the footer's press with the answer.
    ///
    /// The memory may name Chat while nothing is listening — a dormant session has no door, and
    /// "is anything listening" is the question, not "is this session rendered natively" — and a
    /// button performing nothing is worse than a button saying something else. So the
    /// resolution falls back the way the header's Open in control does when the remembered
    /// editor was uninstalled, without overwriting the memory: the door reopening restores the
    /// remembered answer.
    private func updatePrimaryAction() {
        guard isViewLoaded else { return }
        let selection = selectedAttachments
        guard !selection.isEmpty else { return }
        let action = resolvedPrimaryAction()
        primaryActionButton.title = action.buttonTitle(for: selection)
    }

    /// The action the footer's press would take right now.
    private func resolvedPrimaryAction() -> AttachmentAction {
        AttachmentAction.resolvePreferred(
            storedID: PreferenceStore.shared.string(
                forKey: SessionAttachmentsDefaults.lastActionKey
            ),
            canChat: SessionContextHandoff.canReceiveContext(for: sessionID)
        )
    }

    /// Whether a row names `path`, which has already been standardized and resolved.
    ///
    /// Three answers because a row has three paths that can all be the one asked about: the file
    /// it is, the file it was declared from — a declared file from outside the checkout is
    /// *copied*, so those differ — and the same file spelled through a symlinked parent, which is
    /// what `/var` against `/private/var` is on every Mac.
    private func matches(_ attachment: SessionAttachment, path: String) -> Bool {
        attachment.sourcePath == path
            || attachment.url.path == path
            || attachment.url.standardizedFileURL.resolvingSymlinksInPath().path == path
    }

    /// Hidden while the whole list is one side's, which is the app's rule for a control that is
    /// offering no choice — and here it is also the common case, since most sessions exchange
    /// files in one direction only.
    private func updateFilterControl() {
        let origins = Set(allAttachments.map(\.origin))
        filterControl.isHidden = origins.count < 2
        if filterControl.isHidden, filter != .all {
            filter = .all
            attachments = allAttachments
        }
        if let index = AttachmentFilter.allCases.firstIndex(of: filter) {
            filterControl.selectedIndex = index
        }
    }

    /// The band appears only when the scope setting would change *this* session's list.
    ///
    /// The count is the same fact read from either side — files this session named outside its
    /// project — so the sentence never changes, only what the button would do with them. A
    /// session that never names one is never asked about them, which is the point: the setting
    /// is a real safety rule, and a rule advertised where it costs nothing teaches people to
    /// turn it off before they have ever needed it.
    private func updateScopeBand(count: Int) {
        let isShowing = AppSettings.shared.includesAttachmentsOutsideProject
        let wasHidden = scopeBand.isHidden

        scopeBand.isHidden = count == 0
        if scopeBand.isHidden != wasHidden {
            NSLayoutConstraint.deactivate(scopeBand.isHidden ? footerToScopeBand : footerToPaneBottom)
            NSLayoutConstraint.activate(scopeBand.isHidden ? footerToPaneBottom : footerToScopeBand)
        }
        guard !scopeBand.isHidden else { return }

        scopeLabel.stringValue = L10n.format("OUTSIDE THIS PROJECT  %lld", Int64(count))
        scopeButton.title = isShowing ? L10n.string("Hide") : L10n.string("Show")
        let explanation = isShowing
            ? L10n.string(
                """
                Files this session named outside the project are listed, and a paired phone can \
                fetch them. Hiding them leaves the list to files inside the project.
                """
            )
            : L10n.string(
                """
                Files this session named outside the project are not listed, so nothing outside \
                it can be fetched by a paired phone. Showing them copies them into Threading.
                """
            )
        scopeBand.toolTip = explanation
        scopeButton.toolTip = explanation
        scopeButton.setAccessibilityLabel(
            isShowing
                ? L10n.string("Hide files outside this project")
                : L10n.string("Show files outside this project")
        )
    }

    /// Starts the pane's one outstanding custody job. The generation is part of the authority:
    /// changing the setting again cancels the visible request, and a worker finishing afterward
    /// may discard its unpublished slots but may not publish them into this pane.
    private func beginScopeAdmissionIfNeeded() {
        guard scopeAdmissionTask == nil,
              AppSettings.shared.includesAttachmentsOutsideProject,
              !SessionAttachmentStore.shared.withheldReferences(for: sessionID).isEmpty else {
            return
        }

        scopeAdmissionGeneration &+= 1
        let generation = scopeAdmissionGeneration
        let sessionID = sessionID
        scopeAdmissionTask = Task { [weak self] in
            _ = await SessionAttachmentStore.shared.admitWithheldFilesOutsideProjectAsync(
                for: sessionID,
                shouldAdmit: { [weak self] in
                    guard let self else { return false }
                    return self.scopeAdmissionGeneration == generation
                        && AppSettings.shared.includesAttachmentsOutsideProject
                }
            )
            guard let self, self.scopeAdmissionGeneration == generation else { return }
            self.scopeAdmissionTask = nil
            // Admission announces when it publishes rows. A failed or now-missing path publishes
            // nothing, so this refresh also clears the completed attempt from the scope band.
            self.refresh()
        }
    }

    private func cancelScopeAdmission() {
        guard let task = scopeAdmissionTask else { return }
        scopeAdmissionGeneration &+= 1
        scopeAdmissionTask = nil
        task.cancel()
    }

    /// Flips the app-wide scope, then schedules custody of what this session already refused.
    @objc private func toggleScope() {
        let next = !AppSettings.shared.includesAttachmentsOutsideProject
        AppSettings.shared.includesAttachmentsOutsideProject = next
        if next {
            beginScopeAdmissionIfNeeded()
        } else {
            cancelScopeAdmission()
        }
        refresh()
    }

    /// Three different silences, and saying the wrong one is worse than saying nothing: an empty
    /// pane while detection is off reads as "nothing was found", and an empty pane under a filter
    /// reads as "this session has no attachments" when the row you want is one click away.
    private func emptyStateMessage() -> String {
        if !allAttachments.isEmpty, attachments.isEmpty {
            return L10n.format("Nothing here from %@.", filter.title)
        }

        if let kind = ProjectStore.shared.session(withID: sessionID)?.kind,
           !AppSettings.shared.detectsAttachmentReferences(for: kind) {
            return L10n.format(
                """
                Detection of files named in %@'s output is turned off in Settings › General. \
                Images you attach, and ones the agent shows in the panel, still appear here.
                """,
                kind.displayName
            )
        }
        return L10n.string(
            """
            Attachments this session exchanged appear here: images, PDFs, documents, \
            archives, and diagrams you send, and ones the agent shows or names.
            """
        )
    }

    // MARK: - Preview

    private var selectedAttachment: SessionAttachment? {
        let row = tableView.selectedRow
        guard row >= 0, attachments.indices.contains(row) else { return nil }
        return attachments[row]
    }

    /// Every selected row's file, in the list's own order.
    private var selectedAttachments: [SessionAttachment] {
        tableView.selectedRowIndexes.compactMap {
            attachments.indices.contains($0) ? attachments[$0] : nil
        }
    }

    private func showSelected() {
        let performanceSpan = PerformanceRecorder.shared.begin(
            "Attachment Preview Presentation",
            category: "attachments"
        )
        let totalStarted = DispatchTime.now().uptimeNanoseconds
        var timing = SessionAttachmentPreviewTiming()
        previewPresentationCountForTesting += 1
        defer {
            timing.totalNanoseconds = DispatchTime.now().uptimeNanoseconds - totalStarted
            if firstPreviewTimingForTesting == nil {
                firstPreviewTimingForTesting = timing
            }
            latestPreviewTimingForTesting = timing
            performanceSpan.end(metadata: [
                "format": timing.format,
                "metadata_ms": Self.milliseconds(timing.metadataNanoseconds),
                "clear_ms": Self.milliseconds(timing.clearNanoseconds),
                "prepare_ms": Self.milliseconds(timing.prepareNanoseconds),
                "install_ms": Self.milliseconds(timing.installNanoseconds),
                "present_ms": Self.milliseconds(timing.presentNanoseconds),
            ])
        }

        let selection = selectedAttachments
        if selection.count > 1 {
            timing.format = "selection"
            showSelectionSummary(selection)
            return
        }
        guard let attachment = selection.first ?? selectedAttachment else {
            clearPreview()
            return
        }
        timing.format = String(describing: attachment.kind)

        let metadataStarted = DispatchTime.now().uptimeNanoseconds
        selectedRelativePath = attachment.relativePath
        fileLabel.stringValue = attachment.name
        fileLabel.toolTip = attachment.url.path
        pathLabel.stringValue = detail(for: attachment)
        pathLabel.toolTip = attachment.url.path
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        updatePrimaryAction()

        let size = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        timing.metadataNanoseconds = DispatchTime.now().uptimeNanoseconds - metadataStarted
        guard size <= SessionAttachmentsDefaults.maximumPreviewFileBytes else {
            showPreviewMessage(L10n.string("This file is too large to preview here."))
            return
        }

        switch attachment.kind {
        case .image:
            let prepareStarted = DispatchTime.now().uptimeNanoseconds
            guard let image = BoundedImageDecoder.image(
                at: attachment.url,
                policy: .userMedia
            ), image.isValid else {
                timing.prepareNanoseconds = DispatchTime.now().uptimeNanoseconds - prepareStarted
                showPreviewMessage(L10n.string("The image could not be decoded."))
                return
            }
            timing.prepareNanoseconds = DispatchTime.now().uptimeNanoseconds - prepareStarted
            let clearStarted = DispatchTime.now().uptimeNanoseconds
            hideInstalledPreviews()
            timing.clearNanoseconds = DispatchTime.now().uptimeNanoseconds - clearStarted
            let installStarted = DispatchTime.now().uptimeNanoseconds
            let imageView = installedImageView()
            timing.installNanoseconds = DispatchTime.now().uptimeNanoseconds - installStarted
            let presentStarted = DispatchTime.now().uptimeNanoseconds
            imageView.image = image
            imageView.fileURL = attachment.url
            imageView.isHidden = false
            timing.presentNanoseconds = DispatchTime.now().uptimeNanoseconds - presentStarted

        case .pdf, .archive, .document:
            // One surface for all three: PDFKit draws the first, and Quick Look — already
            // contained inside the same named boundary — renders an office document's pages
            // and an archive's icon-and-metadata card, which is what the space bar shows in
            // Finder for the same file.
            let clearStarted = DispatchTime.now().uptimeNanoseconds
            hideInstalledPreviews()
            timing.clearNanoseconds = DispatchTime.now().uptimeNanoseconds - clearStarted
            let installStarted = DispatchTime.now().uptimeNanoseconds
            let documentView = installedDocumentView()
            timing.installNanoseconds = DispatchTime.now().uptimeNanoseconds - installStarted
            guard documentView.display(attachment.url) else {
                timing.prepareNanoseconds = documentView.latestDisplayTimingForTesting
                    .prepareNanoseconds
                timing.installNanoseconds += documentView.latestDisplayTimingForTesting
                    .installNanoseconds
                timing.presentNanoseconds = documentView.latestDisplayTimingForTesting
                    .presentNanoseconds
                showPreviewMessage(
                    attachment.kind == .pdf
                        ? L10n.string("The PDF could not be decoded.")
                        : L10n.string("This file could not be previewed.")
                )
                return
            }
            timing.prepareNanoseconds = documentView.latestDisplayTimingForTesting
                .prepareNanoseconds
            timing.installNanoseconds += documentView.latestDisplayTimingForTesting
                .installNanoseconds
            timing.presentNanoseconds = documentView.latestDisplayTimingForTesting
                .presentNanoseconds
            documentView.isHidden = false

        case .html:
            let clearStarted = DispatchTime.now().uptimeNanoseconds
            hideInstalledPreviews()
            timing.clearNanoseconds = DispatchTime.now().uptimeNanoseconds - clearStarted
            let presentStarted = DispatchTime.now().uptimeNanoseconds
            scheduleHTMLNavigation(
                to: attachment.url,
                readAccessURL: attachment.url.deletingLastPathComponent()
            )
            timing.presentNanoseconds = DispatchTime.now().uptimeNanoseconds - presentStarted

        case .media:
            // The native body first, always: it is cheap, and it is what the pane shows if no
            // extension accepts, if the winner's generation dies, or if the last contribution is
            // removed. Removing an extension never leaves blank chrome here.
            let clearStarted = DispatchTime.now().uptimeNanoseconds
            hideInstalledPreviews()
            timing.clearNanoseconds = DispatchTime.now().uptimeNanoseconds - clearStarted
            showMediaFallback(for: attachment, size: size)
            offerMediaPreview(for: attachment)

        case .diagram:
            // A tighter cap than the general one: this lands in a text view, and a text view
            // handed tens of megabytes is a stall, not a preview.
            let prepareStarted = DispatchTime.now().uptimeNanoseconds
            guard size <= SessionAttachmentsDefaults.maximumSourcePreviewBytes,
                  let data = try? BoundedFileReader.read(
                    attachment.url,
                    maximumBytes: SessionAttachmentsDefaults.maximumSourcePreviewBytes
                  ) else {
                timing.prepareNanoseconds = DispatchTime.now().uptimeNanoseconds - prepareStarted
                showPreviewMessage(L10n.string("This file could not be previewed."))
                return
            }
            let source = String(decoding: data, as: UTF8.self)
            timing.prepareNanoseconds = DispatchTime.now().uptimeNanoseconds - prepareStarted
            let clearStarted = DispatchTime.now().uptimeNanoseconds
            hideInstalledPreviews()
            timing.clearNanoseconds = DispatchTime.now().uptimeNanoseconds - clearStarted
            let installStarted = DispatchTime.now().uptimeNanoseconds
            let sourcePreview = installedSourcePreview()
            timing.installNanoseconds = DispatchTime.now().uptimeNanoseconds - installStarted
            let presentStarted = DispatchTime.now().uptimeNanoseconds
            sourcePreview.textView.string = source
            sourcePreview.isHidden = false
            timing.presentNanoseconds = DispatchTime.now().uptimeNanoseconds - presentStarted
        }
    }

    // MARK: - Media

    /// What Threading itself can say about a document it carries no renderer for.
    ///
    /// Bare UTF-8 shows its source under the existing source-preview ceiling — a JSON Lottie is
    /// readable text, and reading it is better than a shrug. A binary container says plainly that
    /// no preview extension is available, which is a sentence rather than an empty pane.
    private func showMediaFallback(for attachment: SessionAttachment, size: Int) {
        guard size <= SessionAttachmentsDefaults.maximumSourcePreviewBytes,
              let data = try? BoundedFileReader.read(
                  attachment.url,
                  maximumBytes: SessionAttachmentsDefaults.maximumSourcePreviewBytes
              ),
              let source = String(data: data, encoding: .utf8) else {
            showPreviewMessage(L10n.string(
                "No preview extension is available for this file."
            ))
            return
        }
        let sourcePreview = installedSourcePreview()
        sourcePreview.textView.string = source
        sourcePreview.isHidden = false
    }

    /// Asks the installed extensions, in the user's own order, whether any will draw this file.
    private func offerMediaPreview(for attachment: SessionAttachment) {
        previewableAttachment = attachment
        let size = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let context = ExtensionAttachmentContext(
            attachmentID: attachment.id,
            name: attachment.name,
            kind: attachment.kind.rawValue,
            contentHint: Self.publishedContentHint(for: attachment),
            byteSize: size,
            origin: attachment.origin.rawValue,
            sessionID: sessionID.uuidString.lowercased()
        )
        previewOffer.offer(context) { [weak self] outcome in
            guard let self,
                  self.previewableAttachment?.id == attachment.id,
                  let outcome else { return }
            self.installExtensionPreview(outcome, for: attachment)
        }
    }

    private func installExtensionPreview(
        _ outcome: SessionAttachmentPreviewOffer.Outcome,
        for attachment: SessionAttachment
    ) {
        let host: ExtensionNodeHostView
        do {
            host = try ExtensionNodeRenderer.render(
                outcome.content,
                mediaPlayerFactory: { [weak self] document in
                    self?.mediaPlayer(for: document, attachment: attachment)
                },
                onAction: { _ in }
            )
        } catch {
            // An invalid body advances to the native fallback, which is already on screen.
            return
        }
        hideNativePreviews()
        clearExtensionPreview()
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        host.setAccessibilityIdentifier(
            "attachments.extension-preview.\(outcome.extensionIdentifier)"
        )
        installPreviewSurface(host)
        extensionPreviewHost = host
        if let message = outcome.message {
            previewMessage.stringValue = message
            previewMessage.isHidden = false
        }
    }

    private func mediaPlayer(
        for document: ExtensionMediaDocument,
        attachment: SessionAttachment
    ) -> NSView? {
        if let existing = extensionPreviewPlayers[document.id] {
            existing.update(document: document)
            return existing
        }
        let player = MediaDocumentPlayerView(loader: { [weak self] source in
            await MainActor.run {
                // The handle is valid only for the attachment currently being previewed. A
                // package resource still resolves, because the extension owns its own package.
                guard case .sessionAttachment(let id) = source,
                      let self,
                      id == attachment.id,
                      self.previewableAttachment?.id == attachment.id,
                      let data = try? BoundedFileReader.read(
                          attachment.url,
                          maximumBytes: MediaDocumentLimits.default.maximumDocumentBytes
                      ) else {
                    return .failure(.unresolvedSource)
                }
                return .success(data)
            }
        })
        player.update(document: document)
        extensionPreviewPlayers[document.id] = player
        return player
    }

    private func clearExtensionPreview() {
        extensionPreviewHost?.removeFromSuperview()
        extensionPreviewHost = nil
        extensionPreviewPlayers.removeAll()
    }

    /// Several rows at once. The preview cannot show three pictures, so it says the count; the
    /// footer says it too, with the batch's total weight under it, and the action beside them
    /// applies to all — which is the point of a selection, since the rows can now leave
    /// together: dragged to a composer, a terminal, or Finder as one batch.
    private func showSelectionSummary(_ selection: [SessionAttachment]) {
        selectedRelativePath = selection.first?.relativePath
        let title = L10n.format("%lld files selected", Int64(selection.count))
        fileLabel.stringValue = title
        fileLabel.toolTip = nil
        let bytes = selection
            .compactMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        pathLabel.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(bytes),
            countStyle: .file
        )
        // The names still one hover away: the label under a count cannot carry thirty paths.
        pathLabel.toolTip = selection.map(\.relativePath).joined(separator: "\n")
        updatePrimaryAction()
        showPreviewMessage(title)
    }

    private func clearPreview() {
        hideInstalledPreviews()
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        fileLabel.stringValue = ""
        pathLabel.stringValue = ""
    }

    private func showPreviewMessage(_ message: String) {
        hideInstalledPreviews()
        previewMessage.stringValue = message
        previewMessage.isHidden = false
    }

    /// The collection the inspector's arrows and thumbnail rail walk, positioned on `row`.
    ///
    /// An allow-list, not "everything but HTML": the inspector's canvas decodes images, its
    /// document view draws PDFs and its player draws a media document the registry carries, and a
    /// zip paged in between two screenshots would be a rail slot the inspector can only answer
    /// with a blank. `nil` therefore means *this row is not on the rail*, which is also how the
    /// row's own preview key reads it.
    ///
    /// A `.media` row belongs here only when Threading can actually draw it. A registered format
    /// with no renderer is a real row in the pane — an extension previews it — and a rail slot
    /// the lightbox would have nothing to put in.
    func mediaInspectorSelection(forRow row: Int) -> MediaInspectorSelection? {
        guard attachments.indices.contains(row) else { return nil }
        let selectedID = attachments[row].id
        let inspectable = attachments.filter {
            switch $0.kind {
            case .image, .pdf: true
            case .media: Self.inspectableMediaFormat(for: $0) != nil
            case .html, .archive, .document, .diagram: false
            }
        }
        guard let selectedIndex = inspectable.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }
        let items = inspectable.map { attachment in
            MediaInspectorItem(
                url: attachment.url,
                title: attachment.name,
                content: {
                    switch attachment.kind {
                    case .image: .image
                    case .media:
                        Self.inspectableMediaFormat(for: attachment)
                            .map(MediaInspectorItemContent.media) ?? .document
                    default: .document
                    }
                }()
            )
        }
        return MediaInspectorSelection(items: items, selectedIndex: selectedIndex)
    }

    /// The format the host's registry would draw this attachment with, or nil.
    ///
    /// Derived from the row rather than re-probed. A `.media` row that is a `.json` **is** a
    /// Lottie by construction: `json` is a reserved extension no registration may claim, so the
    /// only way one reached the pane is the host's own admission probe recognising the bodymovin
    /// signature. Asking again would put a bounded file read on the main thread once per row per
    /// selection — a hundred-attachment session would re-read a hundred files to draw a rail.
    static func inspectableMediaFormat(
        for attachment: SessionAttachment
    ) -> ExtensionMediaFormat? {
        guard attachment.kind == .media else { return nil }
        let format: ExtensionMediaFormat
        switch attachment.url.pathExtension.lowercased() {
        case "lottie": format = .dotLottie
        case "json": format = .lottie
        case "gif", "apng": format = .animatedImage
        default: return nil
        }
        return MediaDocumentRendererRegistry.supports(format) ? format : nil
    }

    /// The hint published to a preview candidate, derived the same way and for the same reason.
    static func publishedContentHint(
        for attachment: SessionAttachment
    ) -> ExtensionFileContentHint? {
        MediaContentProbe.structuralHint(
            forExtension: attachment.url.pathExtension.lowercased()
        ) ?? (attachment.kind == .media
            && attachment.url.pathExtension.lowercased() == "json" ? .lottie : nil)
    }

    private func installedImageView() -> ThemedImagePreview {
        if let imageView { return imageView }
        let image = ThemedImagePreview()
        image.inspectorSelectionProvider = { [weak self] in
            guard let self else { return nil }
            return self.mediaInspectorSelection(forRow: self.tableView.selectedRow)
        }
        image.isHidden = true
        installPreviewSurface(image)
        imageView = image
        return image
    }

    private func installedDocumentView() -> MediaInspectorDocumentView {
        if let documentView { return documentView }
        let document = MediaInspectorDocumentView()
        document.isHidden = true
        installPreviewSurface(document)
        document.applyTheme()
        documentView = document
        return document
    }

    private func installedHTMLView() -> WKWebView {
        if let htmlView { return htmlView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.underPageBackgroundColor = Design.Surface.ground
        installPreviewSurface(webView)
        htmlView = webView
        return webView
    }

    private func installedSourcePreview() -> ThemedTextScrollView {
        if let sourcePreview { return sourcePreview }
        let scroll = ThemedTextView.scrolling()
        scroll.isHidden = true
        scroll.textView.isEditable = false
        scroll.textView.applyFont(.previewCode)
        scroll.textView.textContainerInset = NSSize(
            width: Design.Spacing.medium,
            height: Design.Spacing.medium
        )
        installPreviewSurface(scroll)
        sourcePreview = scroll
        return scroll
    }

    private func installPreviewSurface(_ surface: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(surface, positioned: .below, relativeTo: previewMessage)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: previewHost.topAnchor),
            surface.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
    }

    /// Takes down everything the previous row put on screen, **and** abandons any offer still in
    /// flight for it.
    private func hideInstalledPreviews() {
        previewOffer.cancel()
        previewableAttachment = nil
        clearExtensionPreview()
        hideNativePreviews()
    }

    /// The view work alone. Split out because an accepted extension body replaces the native
    /// fallback *while the offer that won is still the current one* — clearing the offer there
    /// would revoke the attachment handle the winner is about to resolve.
    private func hideNativePreviews() {
        imageView?.image = nil
        imageView?.isHidden = true
        documentView?.clear()
        documentView?.isHidden = true
        clearHTMLPreview()
        clearSourcePreview()
    }

    private func clearSourcePreview() {
        sourceTextView?.string = ""
        sourcePreview?.isHidden = true
    }

    private func applyPreviewTheme() {
        guard isViewLoaded else { return }
        previewHost.applySurface(fill: Design.Surface.ground, radius: .panel)
        documentView?.applyTheme()
        htmlView?.underPageBackgroundColor = Design.Surface.ground
    }

    private func clearHTMLPreview() {
        pendingHTMLNavigation = nil
        htmlView?.stopLoading()
        htmlView?.isHidden = true
    }

    /// WebKit navigation can synchronously spend a frame launching or reconnecting its content
    /// process even though the actual page load is asynchronous. The pane's list, footer and
    /// loading state are already complete, so let AppKit commit those before asking WebKit to
    /// navigate. A token makes rapid row changes coalesce to the last file rather than loading
    /// content that is no longer selected.
    private func scheduleHTMLNavigation(
        to fileURL: URL,
        readAccessURL: URL
    ) {
        let token = UUID()
        pendingHTMLNavigation = PendingHTMLNavigation(
            token: token,
            fileURL: fileURL,
            readAccessURL: readAccessURL
        )
        latestHTMLRendererInstallNanosecondsForTesting = 0
        latestHTMLNavigationNanosecondsForTesting = 0
        previewMessage.stringValue = L10n.string("Loading…")
        previewMessage.isHidden = false

        DispatchQueue.main.async { [weak self] in
            self?.performPendingHTMLNavigation(token: token)
        }
    }

    private func performPendingHTMLNavigation(token: UUID) {
        guard let pending = pendingHTMLNavigation, pending.token == token else { return }
        pendingHTMLNavigation = nil
        let span = PerformanceRecorder.shared.begin(
            "Attachment HTML Navigation",
            category: "attachments"
        )
        let installStarted = DispatchTime.now().uptimeNanoseconds
        let webView = installedHTMLView()
        latestHTMLRendererInstallNanosecondsForTesting =
            DispatchTime.now().uptimeNanoseconds - installStarted
        let started = DispatchTime.now().uptimeNanoseconds
        webView.loadFileURL(
            pending.fileURL,
            allowingReadAccessTo: pending.readAccessURL
        )
        latestHTMLNavigationNanosecondsForTesting =
            DispatchTime.now().uptimeNanoseconds - started
        span.end(metadata: [
            "install_ms": Self.milliseconds(latestHTMLRendererInstallNanosecondsForTesting),
            "duration_ms": Self.milliseconds(latestHTMLNavigationNanosecondsForTesting)
        ])

        // The token was current at the beginning and this method is main-thread synchronous, so
        // no selection can overtake it. Still check identity: a future renderer replacement must
        // not be made visible by an old scheduled navigation.
        guard htmlView === webView else { return }
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        webView.isHidden = false
    }

    /// The stress fixture separates pane mount from the intentionally deferred WebKit handoff.
    /// Ordinary code never needs to force it; the next main-loop turn performs it naturally.
    @discardableResult
    func flushPendingHTMLNavigationForTesting() -> UInt64 {
        guard let token = pendingHTMLNavigation?.token else { return 0 }
        performPendingHTMLNavigation(token: token)
        return latestHTMLNavigationNanosecondsForTesting
    }

    private func detail(for attachment: SessionAttachment) -> String {
        let size = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(attachment.relativePath) · \(bytes)"
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    // MARK: - Actions

    /// The table's double-click. Deliberately `perform`, never `take`: opening by double-click
    /// is the list's own idiom, not a choice from a menu, and Finder's memory does not move
    /// when a file is double-clicked either.
    @objc private func openSelected() {
        perform(.open, on: selectedAttachments)
    }

    /// Space on a row — Finder's key, answered by the app's own inspector, which Space closes
    /// again. Not `perform`: this opens nothing outside the app and is no more a choice about
    /// what to do with the file than clicking its picture below the fold is, so the footer's
    /// remembered action stays where the user left it.
    ///
    /// Three answers, because the pane previews six kinds and the inspector holds four of them:
    /// an image or a PDF opens *on the rail* with every other one beside it; an archive or an
    /// office document opens alone, through the same contained boundary that already renders it
    /// below the fold; HTML and diagram source decline, since the pane renders those itself —
    /// through a non-persistent web view and a text view — and routing them into the inspector
    /// would hand both to a system previewer instead. Their row's own preview is already on
    /// screen, so declining costs the user nothing.
    @discardableResult
    func inspectAttachment(atRow row: Int) -> Bool {
        guard attachments.indices.contains(row) else { return false }
        if let selection = mediaInspectorSelection(forRow: row) {
            return MediaInspectorPresenter.present(selection, from: tableView)
        }
        let attachment = attachments[row]
        guard attachment.kind == .archive || attachment.kind == .document else { return false }
        return MediaInspectorPresenter.present(
            MediaInspectorItem(url: attachment.url, title: attachment.name, content: .document),
            from: tableView
        )
    }

    /// The footer's press: whatever the menu was last used for, resolved against what the
    /// selection can take right now, applied to every selected row.
    @objc private func performRememberedAction() {
        perform(resolvedPrimaryAction(), on: selectedAttachments)
    }

    /// The chevron's menu — the row's own entries for one file, the batch actions for several.
    private func presentActionsMenu(from button: ThemedIconButton) {
        guard actionMenuSession == nil else { return }
        let entries = actionMenuEntries(for: selectedAttachments)
        guard !entries.isEmpty else { return }
        actionMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: entries,
                minimumWidth: SessionAttachmentsDefaults.menuWidth
            ),
            from: button,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.actionMenuSession = nil }
        )
    }

    /// What the chevron offers. One file gets the row menu's whole vocabulary; a batch keeps
    /// only the actions that mean something said of several files at once — no Open in, no
    /// comparison, no comment, each of which is a decision about *one* thing.
    func actionMenuEntries(for selection: [SessionAttachment]) -> [ThemedMenuEntry] {
        guard selection.count > 1 else {
            return selection.first.map(contextMenuEntries(for:)) ?? []
        }

        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Open"),
                onChoose: { [weak self] in self?.take(.open, on: selection) }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Reveal in Finder"),
                onChoose: { [weak self] in self?.take(.reveal, on: selection) }
            ))
        ]
        if SessionContextHandoff.canReceiveContext(for: sessionID) {
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Add attachments to chat"),
                onChoose: { [weak self] in self?.take(.chat, on: selection) }
            )))
        }
        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Copy Files"),
            onChoose: { [weak self] in self?.take(.copyFile, on: selection) }
        )))
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Copy Path"),
            onChoose: { [weak self] in self?.take(.copyPath, on: selection) }
        )))
        return entries
    }

    /// A choice from either menu is two things at once: the action runs, and it becomes what
    /// the footer's press does next — "last used wins", the header control's rule
    /// (`external-apps.md`). Through `PreferenceStore` because it records a choice the user
    /// made, and app-wide rather than per session because it is a habit about the *user*, not
    /// a fact about a file.
    private func take(_ action: AttachmentAction, on attachments: [SessionAttachment]) {
        PreferenceStore.shared.set(
            action.rawValue,
            forKey: SessionAttachmentsDefaults.lastActionKey
        )
        updatePrimaryAction()
        perform(action, on: attachments)
    }

    private func take(_ action: AttachmentAction, on attachment: SessionAttachment) {
        take(action, on: [attachment])
    }

    private func perform(_ action: AttachmentAction, on attachments: [SessionAttachment]) {
        guard !attachments.isEmpty else { return }
        switch action {
        case .open:
            for attachment in attachments { NSWorkspace.shared.open(attachment.url) }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(attachments.map(\.url))
        case .copyPath:
            // One per line: several paths on one line are a sentence no shell or prompt can
            // take back apart once a name holds a space.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                attachments.map(\.url.path).joined(separator: "\n"),
                forType: .string
            )
        case .copyFile:
            Self.copy(attachments)
        case .chat:
            guard SessionContextHandoff.canReceiveContext(for: sessionID) else { return }
            // One receipt per file, the same shape a batch staged from Git Review takes.
            for attachment in attachments {
                SessionContextHandoff.stage(
                    contextAttachment(for: attachment),
                    fileURL: attachment.url,
                    for: sessionID
                )
            }
        }
    }

    /// The store-relative path, not the machine's own, for exactly the reason the attachment
    /// record keeps one: it is what travels to a transcript and to a paired phone. The real
    /// file goes alongside it as `fileURL`, which only the terminal path reads.
    private func contextAttachment(
        for attachment: SessionAttachment
    ) -> ConversationContextAttachment {
        ConversationContextAttachment(
            kind: .reference,
            source: .attachment,
            title: attachment.name,
            excerpt: attachment.relativePath,
            locator: attachment.relativePath
        )
    }

    /// The two things a session can be handed a file for, in the one place both surfaces read
    /// them from: the footer's action menu and the row's own.
    ///
    /// Empty when nothing is listening — the same question `resolvedPrimaryAction` asks, and the
    /// reason the menu can simply append what comes back without asking it a second time.
    private func chatEntries(for attachment: SessionAttachment) -> [ThemedMenuEntry] {
        guard SessionContextHandoff.canReceiveContext(for: sessionID) else { return [] }

        let context = contextAttachment(for: attachment)
        let fileURL = attachment.url
        let sessionID = self.sessionID
        return [
            .item(ThemedMenuItem(
                title: L10n.string("Add attachment to chat"),
                onChoose: { [weak self] in self?.take(.chat, on: attachment) }
            )),
            // Not rememberable: a comment opens a dialog, and a footer press that raises a
            // question is a press whose outcome depends on a second decision.
            .item(ThemedMenuItem(
                title: L10n.string("Comment on attachment…"),
                onChoose: {
                    ContextCommentAlert.request(on: context, fileURL: fileURL, for: sessionID)
                }
            ))
        ]
    }

    // MARK: - Context Menu

    /// The row's menu, built per click for the row under the pointer.
    ///
    /// The footer's menu says it for the *selected* file; this says the same list for the row
    /// you actually pointed at, and adds the one thing no control under a single preview can:
    /// another row's name. Every item captures the attachment it was built for, so a menu left
    /// open cannot act on a list that changed underneath it — the same rule the file tree's rows
    /// follow.
    @discardableResult
    private func presentContextMenu(forRow row: Int, anchor: ThemedMenuAnchor) -> Bool {
        guard contextMenuSession == nil, attachments.indices.contains(row) else { return false }
        let attachment = attachments[row]

        // The click also selects, and that is not ceremony: the preview under this list is what
        // "this file" means in this pane, so a menu acting on one row while the picture below it
        // shows another is the pane disagreeing with itself in front of the person using it.
        // Unless the row is already inside a wider selection, which a secondary click must not
        // collapse — Finder's rule, and the batch someone just gathered to drag is exactly what
        // a stray right-click would otherwise cost them.
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        // Anchored to the row itself where there is one, so the menu belongs to what it is about
        // rather than to a list that scrolls under it.
        let source = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) ?? tableView
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: contextMenuEntries(for: attachment),
                minimumWidth: SessionAttachmentsDefaults.menuWidth
            ),
            from: source,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }

    /// What that menu holds, for one file. The footer's chevron presents the same list for the
    /// *selected* file, so the two surfaces are one builder and cannot drift apart.
    ///
    /// Apart from the presentation because this is the part with decisions in it — which items a
    /// PDF loses, what a session with no listener loses, what a lone picture cannot be compared
    /// against — and every one of them is a sentence a test can read back. Presenting a real
    /// dropdown needs a key window; the rules do not.
    ///
    /// The typed actions route through `take`, which is what makes choosing one also the answer
    /// to what the footer's press does next; the extras — an Open in submenu, a comparison, a
    /// comment — stay direct, because none of them is a single press's worth of decision.
    func contextMenuEntries(for attachment: SessionAttachment) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Open"),
                onChoose: { [weak self] in self?.take(.open, on: attachment) }
            ))
        ]
        if let openIn = OpenInMenu.submenuEntry(for: .file(attachment.url, line: nil)) {
            entries.append(openIn)
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Reveal in Finder"),
            onChoose: { [weak self] in self?.take(.reveal, on: attachment) }
        )))

        if let comparison = compareEntry(for: attachment) {
            entries.append(.separator)
            entries.append(comparison)
        }

        let chat = chatEntries(for: attachment)
        if !chat.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: chat)
        }

        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: attachment.kind == .image
                ? L10n.string("Copy Image")
                : L10n.string("Copy File"),
            onChoose: { [weak self] in self?.take(.copyFile, on: attachment) }
        )))
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Copy Path"),
            onChoose: { [weak self] in self?.take(.copyPath, on: attachment) }
        )))
        return entries
    }

    /// **Compare with**, naming every other picture the session holds — the pointerless twin of
    /// dragging one row onto another, which is the design system's rule rather than a courtesy.
    ///
    /// Built from the whole list rather than the filtered one: the filter is a convenience about
    /// *provenance*, and "how does the one I sent differ from the one it made" is the question it
    /// would otherwise make unanswerable. Absent, not disabled, when there is nothing to name — a
    /// session holding one picture, or a PDF row, which cannot be a side of a comparison at all.
    private func compareEntry(for attachment: SessionAttachment) -> ThemedMenuEntry? {
        let others = AttachmentComparison.candidates(for: attachment, in: allAttachments)
        guard !others.isEmpty else { return nil }

        return .item(ThemedMenuItem(
            title: L10n.string("Compare with"),
            submenu: others.map { other in
                .item(ThemedMenuItem(
                    title: other.name,
                    onChoose: { [weak self] in self?.compare(attachment, with: other) }
                ))
            }
        ))
    }

    /// The pasteboard answer for one row: the picture where there is one to give, the file
    /// otherwise. `MediaInspector`'s own rule, so the two surfaces that offer this in the same
    /// pane mean the same thing by it. A batch is always files — Finder's answer for several
    /// selected pictures, and the one a paste target can take whole.
    private static func copy(_ attachments: [SessionAttachment]) {
        NSPasteboard.general.clearContents()
        if attachments.count == 1,
           let attachment = attachments.first,
           attachment.kind == .image,
           let image = BoundedImageDecoder.image(
               at: attachment.url,
               policy: .userMedia
           ), image.isValid {
            NSPasteboard.general.writeObjects([image])
            return
        }
        NSPasteboard.general.writeObjects(attachments.map { $0.url as NSURL })
    }

    private static func copy(_ attachment: SessionAttachment) {
        copy([attachment])
    }

    // MARK: - Comparison

    /// Opens the pair in the panel's Compare tab, oldest on the left
    /// (`AttachmentComparison.ordered`).
    ///
    /// The whole list goes with the pair, because two files recorded in one batch share a
    /// timestamp to the microsecond and the list's own order is what settles them.
    private func compare(_ attachment: SessionAttachment, with other: SessionAttachment) {
        let pair = AttachmentComparison.ordered(attachment, other, in: allAttachments)
        onCompare?(pair.old, pair.new)
    }

    /// The other side of a comparison, from whatever a drag was carrying.
    ///
    /// A row of this list is already an attachment and is simply found again. Anything else is
    /// **filed first**, through the same door a picture dropped on a composer goes through, and
    /// that is not incidental: a Compare tab is persisted by path, and a screenshot dragged out of
    /// Preview lives in a temporary directory macOS will reap — so a comparison drawn against a
    /// mere reference would come back empty some morning. Filing it also puts the picture you just
    /// dropped into the list you dropped it on, which is where anyone would look for it next.
    ///
    /// A drag carrying several pictures files all of them and compares against the first that is
    /// not the row it landed on.
    func comparisonSource(
        from pasteboard: NSPasteboard,
        excluding target: SessionAttachment
    ) -> SessionAttachment? {
        let dragged = draggedFiles(in: pasteboard, excluding: target)

        // Already listed, and *still itself*: a referenced row is the file on disk, so the row and
        // the drag name the same current bytes and there is nothing to refresh.
        if let path = dragged.first,
           let listed = allAttachments.first(where: { matches($0, path: path) }),
           listed.sourcePath == listed.url.path {
            return listed
        }

        guard let projectRoot = projectRootProvider() else { return nil }
        // `paths` is what writes a dragged-but-fileless picture to disk, which is why nothing on
        // the validation path may call it: a drag is answered on every frame of the pointer's
        // travel, and this is the one moment there is a drop to answer.
        //
        // A file already listed as a *copy* comes through here rather than being handed back as it
        // stands, and that is the difference between a row and a reference: custody froze the bytes
        // at the moment it took them, so a screenshot regenerated at the same path since would be
        // compared as it was that morning. Re-declaring refreshes the copy in its own slot, which
        // is what the store's dedupe-by-source rule is for.
        let paths = PromptAttachment.paths(from: pasteboard).filter {
            AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: $0)) == .image
        }
        let recorded = PromptAttachment.record(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot
        )
        discardMintedOriginals(of: recorded, whenDragCarriedNoFiles: paths, in: pasteboard)
        return recorded.first { $0.id != target.id } ?? recorded.first
    }

    /// The dragged pictures that could be the other side of a comparison with `target`, resolved
    /// and with the target's own file removed.
    ///
    /// A file cannot be compared with itself, and that is asked of the *file* rather than of the
    /// row index: the same picture dragged in from Finder is the same picture, whichever way it
    /// arrived, and asking once covers a row dragged onto itself as well. Asked of *every* file in
    /// the drag rather than only the first, or a two-picture drag that happened to lead with this
    /// row's own file would be refused while holding a perfectly good other side.
    private func draggedFiles(
        in pasteboard: NSPasteboard,
        excluding target: SessionAttachment
    ) -> [String] {
        AttachmentComparisonDrop.imageURLs(from: pasteboard)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { !matches(target, path: $0) }
    }

    /// Deletes the temporary file a fileless drag was written to, once its bytes are in custody.
    ///
    /// A picture dragged straight out of another app has no path, so `PromptAttachment.paths`
    /// mints one under the temporary directory. The composer keeps that file because a CLI is
    /// about to be handed the path; nothing here is, and the store copied the bytes into its own
    /// directory as it recorded them. Guarded twice — the minted name, and custody actually having
    /// been taken — because the same code path is one step away from deleting a file the user
    /// dragged out of their own Pictures folder.
    private func discardMintedOriginals(
        of recorded: [SessionAttachment],
        whenDragCarriedNoFiles paths: [String],
        in pasteboard: NSPasteboard
    ) {
        guard !AttachmentComparisonDrop.carriesFiles(pasteboard) else { return }
        for attachment in recorded where paths.contains(attachment.sourcePath)
            && attachment.url.path != attachment.sourcePath
            && URL(fileURLWithPath: attachment.sourcePath).lastPathComponent
                .hasPrefix(PromptViewDefaults.attachmentPrefix) {
            try? FileManager.default.removeItem(atPath: attachment.sourcePath)
        }
    }

    /// Whether a drag carrying `pasteboard` would open a comparison against `target`.
    func canDrop(_ pasteboard: NSPasteboard, on target: SessionAttachment) -> Bool {
        guard AttachmentComparison.canCompare(target) else { return false }

        if AttachmentComparisonDrop.carriesFiles(pasteboard) {
            return !draggedFiles(in: pasteboard, excluding: target).isEmpty
        }
        return AttachmentComparisonDrop.canRead(pasteboard)
    }

    /// Raises the drop affordance on one row and lowers it on every other. `-1` clears the list.
    ///
    /// Two surfaces, because the affordance is two things: the *row* carries the wash, so it takes
    /// the same silhouette as the selection it may be sitting beside (`ThemedTableRowView`), and
    /// the *cell* carries the sentence, because the labels are its.
    private func markDropTarget(row: Int) {
        guard isViewLoaded, dropTargetRow != row else { return }
        dropTargetRow = row
        for index in 0..<tableView.numberOfRows {
            let isTarget = index == row
            let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            (rowView as? ThemedTableRowView)?.isDropTarget = isTarget
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            (cell as? SessionAttachmentRowView)?.isDropTarget = isTarget
        }
    }
}

// MARK: - Table Data Source

extension SessionAttachmentsViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        attachments.count
    }

    /// A row *is* its file, so it is dragged as one: onto Finder, onto a composer, onto a message
    /// — and onto another row of this same list, which is where the file URL it carries becomes
    /// the other half of a comparison.
    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard attachments.indices.contains(row) else { return nil }
        return attachments[row].url as NSURL
    }

    /// Every drop here lands **on** a row.
    ///
    /// There is no order to insert into — the list is a chronology, and it is not the user's to
    /// rewrite — so the only question a drop can answer is *which picture, against which*. A
    /// pointer that AppKit puts between two rows is therefore aimed at the nearer of them rather
    /// than refused, which is what makes a 42-point row a target anyone can hit.
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let target = min(max(row, 0), tableView.numberOfRows - 1)
        guard attachments.indices.contains(target),
              canDrop(info.draggingPasteboard, on: attachments[target]) else {
            markDropTarget(row: -1)
            return []
        }
        if dropOperation != .on || target != row {
            tableView.setDropRow(target, dropOperation: .on)
        }
        markDropTarget(row: target)
        // Generic where the source allows it: nothing is being copied *into the list* as far as
        // the person dragging is concerned — they are asking a question about two pictures — and a
        // green `+` badge over a row would promise a filing gesture instead of a comparison.
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        markDropTarget(row: -1)
        guard attachments.indices.contains(row) else { return false }

        // Asked again, not taken on trust from the validation that lit the row up. The list is
        // live: a terminal scan's debounce is a main-queue timer, and event tracking is a common
        // run-loop mode, so an attachment recorded between the last `draggingUpdated` and the
        // release inserts at the top and slides every row down one. The drop would then land on
        // the row *above* the one that said "Drop to compare" — and if that row is a PDF, on the
        // dead-end comparison `canCompare` exists to prevent.
        let target = attachments[row]
        guard canDrop(info.draggingPasteboard, on: target),
              let source = comparisonSource(from: info.draggingPasteboard, excluding: target),
              source.id != target.id else {
            return false
        }
        compare(target, with: source)
        return true
    }
}

// MARK: - Table Delegate

extension SessionAttachmentsViewController: NSTableViewDelegate {

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard attachments.indices.contains(row) else { return nil }
        return SessionAttachmentRowView(attachment: attachments[row])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SessionAttachmentsDefaults.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        showSelected()
    }
}

// MARK: - Row

final class SessionAttachmentRowView: NSView {

    /// A drag is over this row and would open a comparison against it.
    ///
    /// **The row stays the row.** What makes an unfamiliar gesture learnable is the sentence, not
    /// the highlight — a highlight only answers *here*, which the pointer already said. But the
    /// first version of this said the sentence by *replacing* the row: thumbnail and name gave
    /// their place to a saturated accent plate, so the list opened a hole exactly where the
    /// picture you were aiming at had been, and the plate shouted over the window's own selection
    /// two rows above it. Two things were wrong at once — the row stopped being legible, and a
    /// pointer affordance outranked a state the user had chosen.
    ///
    /// So only the *secondary* line changes. The thumbnail and the name stay, because which
    /// picture is under the pointer is the whole question the affordance answers; the path — the
    /// one line nobody is reading mid-drag — becomes what dropping here would do, in the accent
    /// that means "the thing you are aiming at" everywhere else in the window.
    ///
    /// The wash behind it belongs to the **row**, not here (`ThemedTableRowView.isDropTarget`):
    /// this cell is inset within its row, so a plate drawn from these bounds stood as tall as the
    /// selection above it and visibly narrower than it.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            pathLabel?.isHidden = isDropTarget
            dropLabel.isHidden = !isDropTarget
            needsDisplay = true
        }
    }

    /// The line the drop caption takes the place of.
    private var pathLabel: NSView?

    private lazy var dropLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Drop to compare"))
        label.applyFont(.caption)
        label.textColor = Design.Surface.accent
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(attachment: SessionAttachment) {
        super.init(frame: .zero)

        let icon = NSImageView()
        // The picture itself where there is one to show. This list is the panel's visual
        // history now, and a history of identical file-type glyphs is what it replaced — the
        // tab strip's row of `photo` marks under titles that truncated to nothing. A PDF, and
        // anything that will not decode, keeps the file icon rather than showing a blank well.
        icon.image = SessionAttachmentThumbnails.thumbnail(for: attachment)
            ?? NSWorkspace.shared.icon(forFile: attachment.url.path)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: attachment.name)
        name.applyFont(.subheading)
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: attachment.relativePath)
        path.applyFont(.caption)
        path.textColor = Design.Text.tertiary
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false

        // Marked on every row rather than only on the user's, because a mark that appears on one
        // kind makes its absence carry meaning, and absence is exactly what nobody reads.
        let origin = NSTextField(labelWithString: attachment.origin.title)
        origin.applyFont(.caption)
        origin.textColor = Design.Text.quaternary
        origin.setContentCompressionResistancePriority(.required, for: .horizontal)
        origin.setContentHuggingPriority(.required, for: .horizontal)
        origin.translatesAutoresizingMaskIntoConstraints = false

        // When it arrived, in the same quiet voice as the mark it sits above. A chronology whose
        // rows carry no time is a list whose order the reader has to take on trust — and the
        // order is the whole reason the images stopped being tabs.
        let moment = NSTextField(
            labelWithString: AttachmentMoment.description(of: attachment.referencedAt)
        )
        moment.applyFont(.caption)
        moment.textColor = Design.Text.quaternary
        moment.setContentCompressionResistancePriority(.required, for: .horizontal)
        moment.setContentHuggingPriority(.required, for: .horizontal)
        moment.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(name)
        addSubview(path)
        addSubview(origin)
        addSubview(moment)
        addSubview(dropLabel)
        pathLabel = path

        // One element, read as one sentence: four separate labels would be announced as four
        // unrelated strings with no hint that the last two are the provenance and the moment of
        // the first.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            L10n.format(
                "%@, from %@, %@, %@",
                attachment.name,
                attachment.origin.title,
                attachment.relativePath,
                moment.stringValue
            )
        )
        for child in [icon, name, path, origin, moment] {
            child.setAccessibilityElement(false)
        }

        NSLayoutConstraint.activate([
            origin.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.small
            ),
            origin.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
            origin.leadingAnchor.constraint(
                greaterThanOrEqualTo: path.trailingAnchor,
                constant: Design.Spacing.small
            ),

            moment.trailingAnchor.constraint(equalTo: origin.trailingAnchor),
            moment.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SessionAttachmentsDefaults.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SessionAttachmentsDefaults.iconSize),

            name.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: Design.Spacing.small
            ),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: moment.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Design.Spacing.hairline),

            // Exactly where the path it replaces sat, so a row crossed by the pointer reads as
            // the same row saying something else — not as the list shifting under the drag.
            dropLabel.leadingAnchor.constraint(equalTo: path.leadingAnchor),
            dropLabel.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
            dropLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: origin.leadingAnchor,
                constant: -Design.Spacing.small
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Thumbnails

/// The small pictures the rows are made of.
///
/// Two rules make a list of real thumbnails affordable, and both are the point of using ImageIO
/// rather than `NSImage(contentsOf:)`:
///
/// - **The decode is bounded by the row, not by the file.** `CGImageSourceCreateThumbnailAtIndex`
///   with a `MaxPixelSize` reads what it needs for that size, so a 12-megapixel screenshot costs
///   a thumbnail rather than 48 MB of bitmap on the main thread. The same reasoning as
///   `CompareFileClassifier`, which asks `CGImageSource` what a file *is* without loading it.
/// - **A reload re-decodes nothing.** The list reloads on every store change, and a session may
///   hold `SessionAttachmentDefaults.maximumPerSession` files; keyed by path *and* modification
///   date, a regenerated chart still refreshes while the other rows are answered from memory.
///
/// `NSCache` rather than a dictionary because these are reconstructible: the budget is named
/// (`thumbnailCacheCount`) and the system may take them back under pressure.
@MainActor
enum SessionAttachmentThumbnails {

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = SessionAttachmentsDefaults.thumbnailCacheCount
        return cache
    }()

    /// The row's picture, or nil for anything that is not an image Threading can decode — a PDF,
    /// a file that has gone, bytes that are not really a picture. The caller falls back to the
    /// file icon rather than showing an empty well.
    static func thumbnail(for attachment: SessionAttachment) -> NSImage? {
        guard attachment.kind == .image else { return nil }
        return thumbnail(
            for: attachment.url,
            size: SessionAttachmentsDefaults.iconSize
        )
    }

    static func thumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let pixels = Int((size * SessionAttachmentsDefaults.thumbnailScale).rounded())
        // Read through `FileManager` rather than `URL.resourceValues`, which answers from
        // `NSURL`'s own cache: the same `URL` value asked twice reports the date it had the
        // first time, so a chart regenerated in place would keep its old thumbnail forever.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        // The modification date is in the key rather than checked against a stored one: an
        // overwritten file is a different picture at the same path, and this list exists to show
        // the newest of exactly that.
        let key = "\(url.path)|\(modified)|\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let image = BoundedImageDecoder.thumbnail(
            at: url,
            policy: .thumbnail(maximumPixelDimension: pixels)
        ) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Footer Actions

/// The actions the footer can take on the selected file, and the one its button remembers.
///
/// There is no Settings row for a preferred action because the choice is made in the act of
/// taking it — whatever either menu was last used for becomes what the button's press does,
/// which is `external-apps.md`'s "last used wins" said about actions instead of editors. Pure
/// and separate from the pane for the same reason `ExternalApps.resolvePreferred` is: what the
/// stored id names may no longer be on offer, and the rule is assertable while the pane is not.
enum AttachmentAction: String, CaseIterable {
    case open
    case reveal
    case copyPath
    case copyFile
    case chat

    /// The word on the button's face — the footer is a band, not a sentence, so these stay as
    /// terse as the four buttons they replaced. Only the copy changes with what is selected: a
    /// picture offers its pixels, anything else — and any batch — offers the file.
    func buttonTitle(for selection: [SessionAttachment]) -> String {
        switch self {
        case .open: return L10n.string("Open")
        case .reveal: return L10n.string("Finder")
        case .copyPath: return L10n.string("Copy Path")
        case .copyFile:
            if selection.count > 1 { return L10n.string("Copy Files") }
            return selection.first?.kind == .image
                ? L10n.string("Copy Image")
                : L10n.string("Copy File")
        case .chat: return L10n.string("Add to Chat")
        }
    }

    /// What a stored id means today. An unknown or absent id is `.open` — the one action every
    /// file always takes — and a remembered Chat falls back there while nothing is listening,
    /// without the memory being overwritten: the door reopening restores the remembered answer.
    static func resolvePreferred(storedID: String?, canChat: Bool) -> AttachmentAction {
        guard let storedID, let stored = AttachmentAction(rawValue: storedID) else {
            return .open
        }
        if stored == .chat, !canChat { return .open }
        return stored
    }
}

// MARK: - Filter

/// Which side's attachments the pane is showing.
///
/// Three fixed choices with `All` first, which is why this is a segment rather than a chip: the
/// set cannot grow, and the value of seeing `Agent` and `You` sitting there unpicked is the whole
/// point — the question people ask of this pane is "where did the one *I* sent go", and a menu
/// answers it only after you already know to open it.
enum AttachmentFilter: CaseIterable {
    case all
    case agent
    case user

    var title: String {
        switch self {
        case .all: return L10n.string("All")
        case .agent: return SessionAttachment.Origin.agent.title
        case .user: return SessionAttachment.Origin.user.title
        }
    }

    func admits(_ attachment: SessionAttachment) -> Bool {
        switch self {
        case .all: return true
        case .agent: return attachment.origin == .agent
        case .user: return attachment.origin == .user
        }
    }
}

extension SessionAttachment.Origin {

    /// "You" rather than "Ours": in a window where the other party is also working on your
    /// behalf, "ours" names both of them.
    var title: String {
        switch self {
        case .agent: return L10n.string("Agent")
        case .user: return L10n.string("You")
        }
    }
}

// MARK: - Defaults

enum SessionAttachmentsDefaults {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("SessionAttachmentsColumn")
    static let rowHeight: CGFloat = 42

    /// One width for both of this pane's menus — the row's and the footer chevron's — because
    /// they carry the same items and a narrower one under the button would read as a different
    /// menu saying the same thing.
    static let menuWidth: CGFloat = 220
    static let iconSize: CGFloat = 26
    static let maximumPreviewFileBytes = 64 * 1024 * 1024

    /// The diagram-source cap, far under the general one: source lands in a text view, and a
    /// text view is bounded by what it must lay out, not by what the disk can hold. Any real
    /// dot or Mermaid file is kilobytes.
    static let maximumSourcePreviewBytes = 512 * 1024

    /// How many pixels a row's thumbnail is decoded to, as a multiple of the well it sits in:
    /// enough for a Retina row, and nowhere near a full decode of the file behind it.
    static let thumbnailScale: CGFloat = 2
    /// The budget on decoded thumbnails held in memory. Twice a session's own cap, so moving
    /// between two conversations re-decodes neither of them.
    static let thumbnailCacheCount = SessionAttachmentDefaults.maximumPerSession * 2

    /// How much of the pane the list may take before it starts scrolling, until the user says
    /// otherwise. Half: the rows and what they are describing are two halves of the same pane,
    /// and neither may swallow the other on the way to the footer.
    static let listShareOfPane: CGFloat = 0.5

    /// How much of the pane the list may take once the user *has* said otherwise.
    ///
    /// A fold is theirs to place, and this is the part of the bargain the pane keeps: past here,
    /// moving it further is not a reading choice — it is the list becoming the whole pane by
    /// accident.
    ///
    /// An upper bound on the *ask*, not a promise about the result. A share is a fraction, and
    /// four fifths of a short pane is more than what is left after the header, the fold and the
    /// footer — so in a cramped pane the list constraint (`listHeightPriority`, below `required`)
    /// gives way before the footer does and the list lands short of its own ceiling. That is the
    /// order the pane already compresses in; the ceiling only has to stop a *tall* pane from
    /// being handed over whole.
    static let maximumListShareOfPane: CGFloat = 0.8

    /// Below `windowSizeStayPut` (500), and that line is the whole point: AppKit reads a
    /// window's minimum size out of every constraint it finds at 500 and above, so a
    /// content-derived height any higher is not a preference inside the pane — it is the pane
    /// resizing the window. A content-height constraint at `.defaultHigh` once grew the main
    /// window to 3386 points on a 1084-point screen every time a session holding a full-page
    /// screenshot was opened (`MainWindowFrame` is what brings such a window back; this is
    /// what stops it leaving). The preview pane states no height at all now — it fills what
    /// stands between the fold and the footer — so this list constraint is the only
    /// content-derived height left, and a pane too short for everything compresses the preview
    /// first, the list after it, and the footer, whose band height is `required`, never.
    static let listHeightPriority = NSLayoutConstraint.Priority(490)

    /// Where the footer's remembered action lives. `PreferenceStore`, not `.standard`: it
    /// records a choice the user made, and the hosted test suite runs inside the shipping app.
    static let lastActionKey = "attachments.lastAction"
}

// MARK: - Fold Persistence

/// Where the user left the fold between the chronology and what it is pointing at.
///
/// Through `PreferenceStore` for `DisplayPaneWidth`'s reason, and with this bundle's own hazard
/// behind it: a hosted test that drags a divider writes to the shipping app's defaults, so a
/// fixture would otherwise move the fold in the pane the developer is looking at.
///
/// One value app-wide rather than one per session. A fold is how someone wants to *read* their
/// attachments — rows enough to navigate by, room enough for the page a row is pointing at — and
/// that does not change between two conversations. The shell drawer's height makes the same call.
///
/// The stored value is a height in points and is clamped where it is read, never on the way in:
/// see `SessionAttachmentsViewController.listCap(noSmallerThan:)`, which knows the pane it is
/// being read back into.
@MainActor
enum AttachmentsListHeight {
    private static let key = "attachments.listHeight"

    /// The height the user left the list at, or nil while they have never moved the fold — which
    /// is what puts the pane back on its own share of itself.
    static var stored: CGFloat? {
        let saved = PreferenceStore.shared.double(forKey: key)
        guard saved > 0 else { return nil }
        return CGFloat(saved)
    }

    static func record(_ height: CGFloat) {
        PreferenceStore.shared.set(Double(height), forKey: key)
    }

    /// Forgets the fold, so the pane places it again. Called by the double-click on the divider
    /// itself and by `WindowLayoutReset`, which is what makes a window laid out unusably
    /// recoverable without hunting through defaults.
    static func reset() {
        PreferenceStore.shared.removeObject(forKey: key)
    }
}
