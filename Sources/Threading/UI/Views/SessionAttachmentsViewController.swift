import AppKit
import ImageIO

/// A session's visual deliverables: a compact list above an in-place image/PDF preview.
///
/// The controller holds no file bytes. The referenced project file stays authoritative, so a
/// second mention after an overwrite refreshes the preview in place.
final class SessionAttachmentsViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    private let appEvents = AppEventObservations()

    /// Everything recorded for the session, and the subset the filter is showing. Both are kept:
    /// the filter decides whether it belongs on screen at all by looking at the whole list, so a
    /// pane filtered down to nothing must not then read as a session with no attachments.
    private var allAttachments: [SessionAttachment] = []
    private var attachments: [SessionAttachment] = []
    private var filter: AttachmentFilter = .all
    private var selectedRelativePath: String?

    /// The one row a caller has explicitly asked to be looking at, resolved on the next refresh.
    ///
    /// Held rather than acted on immediately for two reasons. A pane belonging to an unselected
    /// session has no loaded view yet — `refresh()` returns early there — so the request has to
    /// survive until `viewDidLoad` asks for the list; and the row may be one the *filter* is
    /// hiding, which is a conflict only `refresh()` is in a position to settle. Cleared as soon
    /// as it has been answered, so a later reload does not keep dragging the selection back.
    private var revealPath: String?

    /// The preview's preferred height — its *content's* height, not the pane's slack.
    ///
    /// Without it the preview was the layout's flexible element between a top-pinned list and a
    /// bottom-pinned footer, so a tall pane stretched it to hundreds of points around a small
    /// picture and put the file's name and buttons at the window's floor, a screen away from
    /// the list — reported as the pane feeling "stretched out, landing at the bottom". Stated
    /// below `required` so a pane *shorter* than the picture still compresses the preview
    /// rather than pushing the footer out of reach; deactivated for a PDF, which reads better
    /// the taller it is (`footerPull` is what stretches it then).
    private var previewHeightConstraint: NSLayoutConstraint?

    /// The list's height — its *rows'* height, capped at its share of the pane.
    ///
    /// It used to be a constant three rows tall, so a session with eight attachments read
    /// through a letterbox while the pane's slack sat below the footer doing nothing; and this
    /// list is becoming the session's whole visual history, which a fixed three rows cannot be.
    /// Stated *above* `previewHeightConstraint` (`listHeightPriority`) and below `required`, so
    /// the order a pane too short for everything gives way in is: the preview first, then the
    /// list, and never the footer — the cap is what makes that safe, since a list that can only
    /// ever ask for half the pane cannot be what pushes the buttons out of reach.
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
        table.allowsEmptySelection = false
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
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        return host
    }()
    private lazy var imageView: ThemedImagePreview = {
        let image = ThemedImagePreview()
        image.inspectorSelectionProvider = { [weak self] in
            guard let self else { return nil }
            let row = self.tableView.selectedRow
            guard self.attachments.indices.contains(row) else { return nil }
            let items = self.attachments.map {
                MediaInspectorItem(url: $0.url, title: $0.name)
            }
            return MediaInspectorSelection(items: items, selectedIndex: row)
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        return image
    }()
    private lazy var pdfView: MediaInspectorDocumentView = {
        let pdf = MediaInspectorDocumentView()
        pdf.translatesAutoresizingMaskIntoConstraints = false
        return pdf
    }()
    private lazy var previewMessage: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private lazy var fileLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.subheading)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private lazy var pathLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.compactCode)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private lazy var openButton = ThemedButton(
        title: L10n.string("Open"),
        target: self,
        action: #selector(openSelected)
    )
    private lazy var revealButton = ThemedButton(
        title: L10n.string("Finder"),
        target: self,
        action: #selector(revealSelected)
    )
    private lazy var copyButton = ThemedButton(
        title: L10n.string("Copy Path"),
        target: self,
        action: #selector(copySelectedPath)
    )
    private lazy var chatButton = ThemedButton(
        title: L10n.string("Chat…"),
        target: self,
        action: #selector(showChatActions)
    )
    private var chatMenuSession: AnyObject?
    private lazy var emptyLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString:
            L10n.string("Images and PDFs mentioned by this session will appear here.")
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
    private lazy var scopeBand = PaneFooterView(
        leading: [scopeLabel],
        trailing: [scopeButton],
        margin: .paneEdge
    )
    private var scopeBandConstraints: [NSLayoutConstraint] = []
    private var actionsToPaneBottom: [NSLayoutConstraint] = []
    private var actionsToScopeBand: [NSLayoutConstraint] = []

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
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyPreviewTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        setupActions()
        setupConstraints()
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
        updateListHeight()
        updatePreviewHeight()
    }

    // MARK: - Setup

    private func setupList() {
        view.addSubview(headerRow)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
    }

    private func setupPreview() {
        previewHost.addSubview(imageView)
        previewHost.addSubview(pdfView)
        previewHost.addSubview(previewMessage)
        view.addSubview(previewHost)

        applyPreviewTheme()
    }

    private func setupActions() {
        for control in [openButton, revealButton, copyButton, chatButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        view.addSubview(fileLabel)
        view.addSubview(pathLabel)
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

            previewHost.topAnchor.constraint(
                equalTo: scrollView.bottomAnchor,
                constant: Design.Spacing.small
            ),
            previewHost.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            previewHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            previewHost.bottomAnchor.constraint(
                equalTo: fileLabel.topAnchor,
                constant: -Design.Spacing.small
            ),

            imageView.topAnchor.constraint(equalTo: previewHost.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),

            pdfView.topAnchor.constraint(equalTo: previewHost.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),

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

            fileLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            fileLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            pathLabel.topAnchor.constraint(
                equalTo: fileLabel.bottomAnchor,
                constant: Design.Spacing.hairline
            ),
            pathLabel.leadingAnchor.constraint(equalTo: fileLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: fileLabel.trailingAnchor),

            openButton.topAnchor.constraint(
                equalTo: pathLabel.bottomAnchor,
                constant: Design.Spacing.small
            ),
            openButton.leadingAnchor.constraint(equalTo: fileLabel.leadingAnchor),
            revealButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            revealButton.leadingAnchor.constraint(
                equalTo: openButton.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            copyButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            copyButton.leadingAnchor.constraint(
                equalTo: revealButton.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            chatButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            chatButton.leadingAnchor.constraint(
                equalTo: copyButton.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            chatButton.trailingAnchor.constraint(lessThanOrEqualTo: fileLabel.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
        ])

        // The floor is a limit, not a home: the footer sits under the preview's content and the
        // pane's slack falls *below* it, empty. Pinned `==` here, a tall pane stretched the
        // preview to fill the difference — see `previewHeightConstraint`. What stretches a PDF to
        // that floor is the gentle pull beneath, which loses deliberately to an image's own
        // height above: "a document fills the room it has", not "a snapshot stretched across it".
        //
        // Stated twice because the floor moves: with the scope band installed the actions stop
        // above it, and one set is active at a time.
        actionsToPaneBottom = Self.floorConstraints(
            for: openButton,
            above: view.safeAreaLayoutGuide.bottomAnchor,
            inset: Design.Spacing.small
        )
        actionsToScopeBand = Self.floorConstraints(
            for: openButton,
            above: scopeBand.topAnchor,
            inset: Design.Spacing.small
        )
        NSLayoutConstraint.activate(actionsToPaneBottom)

        scopeBandConstraints = [
            // Edge to edge, and to the frame rather than the safe area: the band draws the
            // pane's own fold and states its content's inset from the corner-adapted region
            // itself. See `PaneFooterView`.
            scopeBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scopeBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scopeBand.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(scopeBandConstraints)

        let previewHeight = previewHost.heightAnchor.constraint(equalToConstant: 0)
        previewHeight.priority = .defaultHigh
        previewHeightConstraint = previewHeight

        // Always active, unlike the preview's: a list with no rows asks for no height, which is
        // the same sentence said with a zero.
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        listHeight.priority = SessionAttachmentsDefaults.listHeightPriority
        listHeight.isActive = true
        listHeightConstraint = listHeight
        updateListHeight()
    }

    /// A hard floor plus the gentle pull toward it — the pair that has to move together, so a
    /// call site cannot activate one and leave the other pinning the actions to the wrong edge.
    private static func floorConstraints(
        for control: NSView,
        above anchor: NSLayoutYAxisAnchor,
        inset: CGFloat
    ) -> [NSLayoutConstraint] {
        let limit = control.bottomAnchor.constraint(lessThanOrEqualTo: anchor, constant: -inset)
        let pull = control.bottomAnchor.constraint(equalTo: anchor, constant: -inset)
        pull.priority = SessionAttachmentsDefaults.footerPullPriority
        return [limit, pull]
    }

    /// Re-aims `listHeightConstraint` at the rows the list currently holds, capped at its share
    /// of the pane. Called from `refresh()`, because the rows change, and from `viewDidLayout`,
    /// because the cap is a function of the pane's *height* — the same pair of reasons
    /// `updatePreviewHeight()` has for width.
    ///
    /// One row is a one-row-tall list; eight rows in a tall pane are eight visible rows; eight
    /// rows in a short one are the cap, scrolled.
    private func updateListHeight() {
        guard let constraint = listHeightConstraint else { return }

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
        // Before the pane has a height there is nothing to take a share of, so the content
        // stands in and `viewDidLayout` corrects it the moment the height is real.
        let paneHeight = view.bounds.height
        // Never below a single row: a list capped into a sliver is a scroller with nothing
        // legible beside it, and the pane has already lost by then.
        let cap = paneHeight > 0
            ? max(paneHeight * SessionAttachmentsDefaults.listShareOfPane, oneRow)
            : content
        let target = min(content, cap)
        if constraint.constant != target { constraint.constant = target }
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

    /// Re-aims `previewHeightConstraint` at what the preview currently holds. Called when the
    /// selection changes what is shown and from `viewDidLayout`, because an image's fitted
    /// height is a function of the pane's *width*.
    private func updatePreviewHeight() {
        guard let constraint = previewHeightConstraint else { return }

        if !imageView.isHidden, let image = imageView.image {
            // Activated even before the pane has a width — the floor stands in, and the
            // `viewDidLayout` call corrects it the moment the width is real. Returning early
            // here left the constraint inactive for the first pass, which was a whole pane of
            // stretched preview until something else caused a layout.
            let width = previewHost.bounds.width
            let fitted = width > 0
                ? ThemedImagePreview.fittedRect(
                    for: image.size,
                    in: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
                ).height
                : 0
            let target = max(fitted, SessionAttachmentsDefaults.minimumPreviewHeight)
            if constraint.constant != target { constraint.constant = target }
            constraint.isActive = true
        } else if !previewMessage.isHidden {
            constraint.constant = SessionAttachmentsDefaults.messagePreviewHeight
            constraint.isActive = true
        } else {
            constraint.isActive = false
        }
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

        let previous = selectedAttachment?.relativePath ?? selectedRelativePath
        // Before the list is read: widening the scope elsewhere — the Settings page, another
        // window — leaves this session's refused paths in hand, and they are admitted here so
        // the answer the user gave is the answer the pane shows, not the answer it shows next
        // time an agent happens to print the path again.
        if AppSettings.shared.includesAttachmentsOutsideProject,
           !SessionAttachmentStore.shared.withheldReferences(for: sessionID).isEmpty {
            SessionAttachmentStore.shared.admitWithheldFilesOutsideProject(for: sessionID)
        }
        allAttachments = SessionAttachmentStore.shared.attachments(for: sessionID)
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
        updateListHeight()
        emptyLabel.stringValue = emptyStateMessage()
        updateFilterControl()
        updateScopeBand()

        let hasAttachments = !attachments.isEmpty
        headerRow.isHidden = allAttachments.isEmpty
        scrollView.isHidden = !hasAttachments
        previewHost.isHidden = !hasAttachments
        fileLabel.isHidden = !hasAttachments
        pathLabel.isHidden = !hasAttachments
        openButton.isHidden = !hasAttachments
        revealButton.isHidden = !hasAttachments
        copyButton.isHidden = !hasAttachments
        chatButton.isHidden = !hasAttachments
            || AgentRuntime.shared.conversation(for: sessionID) == nil
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
    private func updateScopeBand() {
        let count = SessionAttachmentStore.shared.countOfFilesOutsideProject(for: sessionID)
        let isShowing = AppSettings.shared.includesAttachmentsOutsideProject
        let wasHidden = scopeBand.isHidden

        scopeBand.isHidden = count == 0
        if scopeBand.isHidden != wasHidden {
            NSLayoutConstraint.deactivate(scopeBand.isHidden ? actionsToScopeBand : actionsToPaneBottom)
            NSLayoutConstraint.activate(scopeBand.isHidden ? actionsToPaneBottom : actionsToScopeBand)
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

    /// Flips the app-wide scope, then takes custody of what this session already refused.
    @objc private func toggleScope() {
        let next = !AppSettings.shared.includesAttachmentsOutsideProject
        AppSettings.shared.includesAttachmentsOutsideProject = next
        if next {
            SessionAttachmentStore.shared.admitWithheldFilesOutsideProject(for: sessionID)
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
            Attachments this session exchanged appear here: images and PDFs you send, \
            and ones the agent shows or names.
            """
        )
    }

    // MARK: - Preview

    private var selectedAttachment: SessionAttachment? {
        let row = tableView.selectedRow
        guard row >= 0, attachments.indices.contains(row) else { return nil }
        return attachments[row]
    }

    private func showSelected() {
        guard let attachment = selectedAttachment else {
            clearPreview()
            return
        }

        selectedRelativePath = attachment.relativePath
        fileLabel.stringValue = attachment.name
        fileLabel.toolTip = attachment.url.path
        pathLabel.stringValue = detail(for: attachment)
        pathLabel.toolTip = attachment.url.path
        previewMessage.stringValue = ""
        previewMessage.isHidden = true

        let size = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SessionAttachmentsDefaults.maximumPreviewFileBytes else {
            showPreviewMessage(L10n.string("This file is too large to preview here."))
            return
        }

        switch attachment.kind {
        case .image:
            guard let image = NSImage(contentsOf: attachment.url), image.isValid else {
                showPreviewMessage(L10n.string("The image could not be decoded."))
                return
            }
            pdfView.clear()
            pdfView.isHidden = true
            imageView.image = image
            imageView.fileURL = attachment.url
            imageView.isHidden = false

        case .pdf:
            guard pdfView.display(attachment.url) else {
                showPreviewMessage(L10n.string("The PDF could not be decoded."))
                return
            }
            imageView.image = nil
            imageView.isHidden = true
            pdfView.isHidden = false
        }

        updatePreviewHeight()
    }

    private func clearPreview() {
        imageView.image = nil
        imageView.isHidden = true
        pdfView.clear()
        pdfView.isHidden = true
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        fileLabel.stringValue = ""
        pathLabel.stringValue = ""
        updatePreviewHeight()
    }

    private func showPreviewMessage(_ message: String) {
        imageView.image = nil
        imageView.isHidden = true
        pdfView.clear()
        pdfView.isHidden = true
        previewMessage.stringValue = message
        previewMessage.isHidden = false
        updatePreviewHeight()
    }

    private func applyPreviewTheme() {
        guard isViewLoaded else { return }
        previewHost.applySurface(fill: Design.Surface.ground, radius: .panel)
        pdfView.applyTheme()
    }

    private func detail(for attachment: SessionAttachment) -> String {
        let size = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(attachment.relativePath) · \(bytes)"
    }

    // MARK: - Actions

    @objc private func openSelected() {
        guard let attachment = selectedAttachment else { return }
        NSWorkspace.shared.open(attachment.url)
    }

    @objc private func revealSelected() {
        guard let attachment = selectedAttachment else { return }
        NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
    }

    @objc private func copySelectedPath() {
        guard let attachment = selectedAttachment else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(attachment.url.path, forType: .string)
    }

    @objc private func showChatActions() {
        guard chatMenuSession == nil,
              let attachment = selectedAttachment,
              let conversation = AgentRuntime.shared.conversation(for: sessionID) else { return }
        let context = conversation.attachmentContext(
            path: attachment.url.path,
            displayPath: attachment.relativePath
        )
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Add attachment to chat"),
                onChoose: { [weak conversation] in
                    conversation?.stageContextAttachment(context)
                }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Comment on attachment…"),
                onChoose: { [weak conversation] in
                    conversation?.requestComment(on: context)
                }
            ))
        ]
        chatMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 200),
            from: chatButton,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.chatMenuSession = nil }
        )
    }
}

// MARK: - Table Data Source

extension SessionAttachmentsViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        attachments.count
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
        showSelected()
    }
}

// MARK: - Row

private final class SessionAttachmentRowView: NSView {

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
            labelWithString: SessionAttachmentRowView.description(of: attachment.referencedAt)
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
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Design.Spacing.hairline)
        ])
    }

    /// Terse on purpose: a column of full timestamps is a column of the same date said 32 times.
    /// Today's rows say the time, everything older says the day — which is the distinction the
    /// reader is actually making when they scan for the picture from this morning.
    private static func description(of date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? timeFormatter.string(from: date)
            : dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

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

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let options: [CFString: Any] = [
            // Always: a file's own embedded thumbnail may be absent, stale or a different crop.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }

        // Sized in pixels and scaled down into the row's well, so the picture stays crisp on a
        // Retina display without the row having to know what scale it is drawn at.
        let image = NSImage(
            cgImage: decoded,
            size: NSSize(width: decoded.width, height: decoded.height)
        )
        cache.setObject(image, forKey: key)
        return image
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
    static let iconSize: CGFloat = 26
    static let maximumPreviewFileBytes = 64 * 1024 * 1024

    /// How many pixels a row's thumbnail is decoded to, as a multiple of the well it sits in:
    /// enough for a Retina row, and nowhere near a full decode of the file behind it.
    static let thumbnailScale: CGFloat = 2
    /// The budget on decoded thumbnails held in memory. Twice a session's own cap, so moving
    /// between two conversations re-decodes neither of them.
    static let thumbnailCacheCount = SessionAttachmentDefaults.maximumPerSession * 2

    /// A floor for the image well, so a small mark still gets a quiet panel rather than a
    /// sliver whose corner radius outweighs its height.
    static let minimumPreviewHeight: CGFloat = 96
    /// The well around a sentence — "too large to preview", "could not be decoded".
    static let messagePreviewHeight: CGFloat = 160
    /// Gentle on purpose: it loses to an image's own height (`.defaultHigh`) and wins only
    /// when nothing states one — a PDF, which fills whatever room the pane has.
    static let footerPullPriority = NSLayoutConstraint.Priority(300)

    /// How much of the pane the list may take before it starts scrolling. Half: the rows and
    /// what they are describing are two halves of the same pane, and neither may swallow the
    /// other on the way to the footer.
    static let listShareOfPane: CGFloat = 0.5
    /// Above the preview's `.defaultHigh`, below `required`. A pane too short for everything
    /// therefore compresses the preview first and the list only after it — and the footer's
    /// floor, which is `required`, never.
    static let listHeightPriority = NSLayoutConstraint.Priority(760)
}
