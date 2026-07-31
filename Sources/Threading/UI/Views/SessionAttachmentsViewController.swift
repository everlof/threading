import AppKit
import PDFKit

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
    private lazy var imageView: NSImageView = {
        let image = NSImageView()
        image.imageAlignment = .alignCenter
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        return image
    }()
    private lazy var pdfView: PDFView = {
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.displaysPageBreaks = true
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
        for control in [openButton, revealButton, copyButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        view.addSubview(fileLabel)
        view.addSubview(pathLabel)
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
            scrollView.heightAnchor.constraint(equalToConstant: SessionAttachmentsDefaults.listHeight),

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
            copyButton.trailingAnchor.constraint(lessThanOrEqualTo: fileLabel.trailingAnchor),
            openButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Design.Spacing.small
            ),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
        ])
    }

    // MARK: - Public Methods

    func refresh() {
        guard isViewLoaded else { return }

        let previous = selectedAttachment?.relativePath ?? selectedRelativePath
        allAttachments = SessionAttachmentStore.shared.attachments(for: sessionID)
        attachments = allAttachments.filter(filter.admits)
        countLabel.stringValue = L10n.format(
            "ATTACHMENTS  %lld",
            Int64(attachments.count)
        )
        tableView.reloadData()
        emptyLabel.stringValue = emptyStateMessage()
        updateFilterControl()

        let hasAttachments = !attachments.isEmpty
        headerRow.isHidden = allAttachments.isEmpty
        scrollView.isHidden = !hasAttachments
        previewHost.isHidden = !hasAttachments
        fileLabel.isHidden = !hasAttachments
        pathLabel.isHidden = !hasAttachments
        openButton.isHidden = !hasAttachments
        revealButton.isHidden = !hasAttachments
        copyButton.isHidden = !hasAttachments
        emptyLabel.isHidden = hasAttachments

        guard hasAttachments else {
            selectedRelativePath = nil
            clearPreview()
            return
        }

        let index = previous.flatMap { path in
            attachments.firstIndex { $0.relativePath == path }
        } ?? 0
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        showSelected()
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
            pdfView.document = nil
            pdfView.isHidden = true
            imageView.image = image
            imageView.isHidden = false

        case .pdf:
            guard let document = PDFDocument(url: attachment.url) else {
                showPreviewMessage(L10n.string("The PDF could not be decoded."))
                return
            }
            imageView.image = nil
            imageView.isHidden = true
            pdfView.document = document
            pdfView.isHidden = false
        }
    }

    private func clearPreview() {
        imageView.image = nil
        imageView.isHidden = true
        pdfView.document = nil
        pdfView.isHidden = true
        previewMessage.stringValue = ""
        previewMessage.isHidden = true
        fileLabel.stringValue = ""
        pathLabel.stringValue = ""
    }

    private func showPreviewMessage(_ message: String) {
        imageView.image = nil
        imageView.isHidden = true
        pdfView.document = nil
        pdfView.isHidden = true
        previewMessage.stringValue = message
        previewMessage.isHidden = false
    }

    private func applyPreviewTheme() {
        guard isViewLoaded else { return }
        previewHost.applySurface(fill: Design.Surface.ground, radius: .panel)
        pdfView.backgroundColor = Design.Surface.ground
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
        icon.image = NSWorkspace.shared.icon(forFile: attachment.url.path)
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

        addSubview(icon)
        addSubview(name)
        addSubview(path)
        addSubview(origin)

        // One element, read as one sentence: three separate labels would be announced as three
        // unrelated strings with no hint that the last one is the provenance of the first.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            L10n.format(
                "%@, from %@, %@",
                attachment.name,
                attachment.origin.title,
                attachment.relativePath
            )
        )
        for child in [icon, name, path, origin] {
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

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SessionAttachmentsDefaults.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SessionAttachmentsDefaults.iconSize),

            name.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: Design.Spacing.small
            ),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.small
            ),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Design.Spacing.hairline)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    static let listHeight: CGFloat = 136
    static let rowHeight: CGFloat = 42
    static let iconSize: CGFloat = 26
    static let maximumPreviewFileBytes = 64 * 1024 * 1024
}
