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

    private var attachments: [SessionAttachment] = []
    private var selectedRelativePath: String?

    private var countLabel: NSTextField!
    private var tableView: ThemedTableView!
    private var scrollView: ThemedScrollView!
    private var previewHost: NSView!
    private var imageView: NSImageView!
    private var pdfView: PDFView!
    private var previewMessage: NSTextField!
    private var fileLabel: NSTextField!
    private var pathLabel: NSTextField!
    private var openButton: ThemedButton!
    private var revealButton: ThemedButton!
    private var copyButton: ThemedButton!
    private var emptyLabel: NSTextField!

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
        countLabel = NSTextField(labelWithString: "")
        countLabel.applyFont(.caption)
        countLabel.textColor = Design.Text.quaternary
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView = ThemedTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.allowsEmptySelection = false

        let column = NSTableColumn(identifier: SessionAttachmentsDefaults.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView = ThemedScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(wrappingLabelWithString:
            L10n.string("Images and PDFs mentioned by this session will appear here.")
        )
        emptyLabel.applyFont(.detail())
        emptyLabel.textColor = Design.Text.tertiary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(countLabel)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
    }

    private func setupPreview() {
        previewHost = NSView()
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.wantsLayer = true

        imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        previewMessage = NSTextField(wrappingLabelWithString: "")
        previewMessage.applyFont(.detail())
        previewMessage.textColor = Design.Text.tertiary
        previewMessage.alignment = .center
        previewMessage.translatesAutoresizingMaskIntoConstraints = false

        previewHost.addSubview(imageView)
        previewHost.addSubview(pdfView)
        previewHost.addSubview(previewMessage)
        view.addSubview(previewHost)

        applyPreviewTheme()
    }

    private func setupActions() {
        fileLabel = NSTextField(labelWithString: "")
        fileLabel.applyFont(.subheading)
        fileLabel.textColor = Design.Text.label
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.applyFont(.compactCode)
        pathLabel.textColor = Design.Text.tertiary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        openButton = ThemedButton(
            title: L10n.string("Open"),
            target: self,
            action: #selector(openSelected)
        )
        revealButton = ThemedButton(
            title: L10n.string("Finder"),
            target: self,
            action: #selector(revealSelected)
        )
        copyButton = ThemedButton(
            title: L10n.string("Copy Path"),
            target: self,
            action: #selector(copySelectedPath)
        )

        for control in [openButton, revealButton, copyButton] {
            control?.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control!)
        }
        view.addSubview(fileLabel)
        view.addSubview(pathLabel)
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            countLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            scrollView.topAnchor.constraint(
                equalTo: countLabel.bottomAnchor,
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
        attachments = SessionAttachmentStore.shared.attachments(for: sessionID)
        countLabel.stringValue = L10n.format(
            "ATTACHMENTS  %lld",
            Int64(attachments.count)
        )
        tableView.reloadData()
        emptyLabel.stringValue = emptyStateMessage()

        let hasAttachments = !attachments.isEmpty
        countLabel.isHidden = !hasAttachments
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

    /// An empty pane while detection is off would read as "nothing was found", which is the
    /// wrong explanation — so the one state names the other.
    private func emptyStateMessage() -> String {
        if let kind = ProjectStore.shared.session(withID: sessionID)?.kind,
           !AppSettings.shared.detectsAttachmentReferences(for: kind) {
            return L10n.format(
                "Attachment detection for %@ is turned off in Settings › General.",
                kind.displayName
            )
        }
        return L10n.string(
            "Images and PDFs mentioned by this session will appear here."
        )
    }

    // MARK: - Preview

    private var selectedAttachment: SessionAttachment? {
        let row = tableView?.selectedRow ?? -1
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
        imageView?.image = nil
        imageView?.isHidden = true
        pdfView?.document = nil
        pdfView?.isHidden = true
        previewMessage?.stringValue = ""
        previewMessage?.isHidden = true
        fileLabel?.stringValue = ""
        pathLabel?.stringValue = ""
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

        addSubview(icon)
        addSubview(name)
        addSubview(path)

        NSLayoutConstraint.activate([
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
            path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Design.Spacing.hairline)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
