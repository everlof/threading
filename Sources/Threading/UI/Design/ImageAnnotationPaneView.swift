import AppKit

/// The complete annotation sidecar: title, bounded note list, saved state, and explicit chat
/// publication. The inspector supplies pixels and mutations; this component owns the layout.
final class ImageAnnotationPaneView: NSView, ThemedComponent {

    var onNoteChange: ((ImageAnnotation.ID, String) -> Void)? {
        didSet { rail.onNoteChange = onNoteChange }
    }
    var onRemove: ((ImageAnnotation.ID) -> Void)? {
        didSet { rail.onRemove = onRemove }
    }
    var onFocus: ((ImageAnnotation.ID) -> Void)? {
        didSet { rail.onFocus = onFocus }
    }
    var onShare: (() -> Void)?
    var onRemoveFromChat: (() -> Void)?

    var selectedAnnotationID: ImageAnnotation.ID? {
        get { rail.selectedAnnotationID }
        set { rail.selectedAnnotationID = newValue }
    }

    private let surface = ThemedSurfaceView()
    private let titleLabel = NSTextField(labelWithString: ImageAnnotationStrings.caption.uppercased())
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let rail = ImageAnnotationRailView()
    private let scrollView = ThemedScrollView()
    private var annotationIDs: [ImageAnnotation.ID] = []
    private var contentConstraints: [NSLayoutConstraint] = []
    private var isCollapsed = false
    /// A new document must begin at its first row on the first frame. `NSScrollView` otherwise
    /// preserves the old document origin while Auto Layout grows a zero-height document, which
    /// placed a reopened multi-note list below the viewport until collection navigation caused
    /// a second layout pass.
    private var needsInitialTopAnchor = false
    private lazy var shareButton = ThemedButton(
        title: L10n.string("Add to chat"),
        target: self,
        action: #selector(sharePressed)
    )
    private lazy var removeButton = ThemedButton(
        title: L10n.string("Remove"),
        target: self,
        action: #selector(removePressed)
    )
    private lazy var header = PaneHeaderView(
        leading: [titleLabel],
        trailing: [countLabel],
        margin: .paneEdge
    )
    private lazy var footer = PaneFooterView(
        leading: [statusLabel],
        trailing: [removeButton, shareButton],
        margin: .paneEdge,
        outerEdgeAlignment: .controlFrame
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        surface.applySurface(fill: Design.Surface.panel, radius: .fixed(0))

        titleLabel.applyFont(.caption)
        titleLabel.textColor = Design.Text.secondary
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.applyFont(.numericDetail())
        countLabel.textColor = Design.Text.tertiary
        countLabel.alignment = .right

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.tertiary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shareButton.emphasis = .primary
        removeButton.emphasis = .tertiary
        shareButton.setAccessibilityIdentifier(ImageAnnotationIdentifiers.share)
        removeButton.setAccessibilityIdentifier(ImageAnnotationIdentifiers.removeFromChat)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier(ImageAnnotationIdentifiers.rail)
        // The host inspector is constrained after its model is loaded. Give the document its
        // known column width now so adding several rows never asks Auto Layout to compress them
        // into the scroll view's construction-time zero-width autoresizing constraint.
        rail.frame = NSRect(
            x: 0,
            y: 0,
            width: Design.Size.mediaInspectorAnnotationColumnWidth,
            height: max(1, rail.intrinsicContentSize.height)
        )
        scrollView.documentView = rail
        rail.translatesAutoresizingMaskIntoConstraints = true
        rail.setAccessibilityLabel(ImageAnnotationStrings.caption)

        for view in [surface, header, scrollView, footer] { addSubview(view) }
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        contentConstraints = [
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(contentConstraints)
    }

    override func layout() {
        super.layout()
        guard !isCollapsed, bounds.width > 0 else { return }
        let viewport = scrollView.contentSize
        rail.frame = NSRect(
            x: 0,
            y: 0,
            width: viewport.width,
            height: max(viewport.height, rail.intrinsicContentSize.height)
        )
        rail.layoutSubtreeIfNeeded()
        if needsInitialTopAnchor {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            needsInitialTopAnchor = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        titleLabel.textColor = Design.Text.secondary
        countLabel.textColor = Design.Text.tertiary
        statusLabel.textColor = Design.Text.tertiary
    }

    func setAnnotations(
        _ annotations: [ImageAnnotation],
        sharingState: ImageAnnotationSharingState,
        showsChatActions: Bool,
        canShare: Bool
    ) {
        let ids = annotations.map(\.id)
        // A different image is a different document and begins at its own first note. Mutating
        // the current list keeps its scroll position because the two id sets still overlap.
        if !ids.isEmpty, Set(ids).isDisjoint(with: annotationIDs) {
            needsInitialTopAnchor = true
        }
        annotationIDs = ids
        rail.setAnnotations(annotations)
        countLabel.stringValue = "\(annotations.count) / \(ImageAnnotationDefaults.maximumCount)"
        removeButton.isHidden = !showsChatActions || sharingState != .currentInChat
        shareButton.isHidden = !showsChatActions
        shareButton.isEnabled = !annotations.isEmpty
            && canShare
            && sharingState != .currentInChat
        shareButton.title = actionTitle(for: sharingState)
        statusLabel.stringValue = status(
            for: sharingState,
            showsChatActions: showsChatActions,
            canShare: canShare
        )
        needsLayout = true
    }

    func focusNote(for id: ImageAnnotation.ID) {
        rail.focusNote(for: id)
    }

    /// A hidden annotation column is constrained to zero width by its inspector. Deactivating
    /// the interior layout at the same time prevents AppKit from first crushing a full header,
    /// footer, and document into that zero-width box and repairing them when the pane reopens.
    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        let content: [NSView] = [header, scrollView, footer]
        if collapsed {
            NSLayoutConstraint.deactivate(contentConstraints)
            content.forEach { $0.isHidden = true }
        } else {
            content.forEach { $0.isHidden = false }
            NSLayoutConstraint.activate(contentConstraints)
        }
        needsLayout = true
    }

    @objc private func sharePressed() { onShare?() }
    @objc private func removePressed() { onRemoveFromChat?() }

    private func actionTitle(for state: ImageAnnotationSharingState) -> String {
        switch state {
        case .changedInChat: return L10n.string("Update chat")
        case .changedSinceShared: return L10n.string("Add update")
        case .local, .shared, .currentInChat: return L10n.string("Add to chat")
        }
    }

    private func status(
        for state: ImageAnnotationSharingState,
        showsChatActions: Bool,
        canShare: Bool
    ) -> String {
        guard showsChatActions else { return L10n.string("Saved with this report") }
        switch state {
        case .local:
            return canShare
                ? L10n.string("Saved")
                : L10n.string("Chat unavailable")
        case .currentInChat: return L10n.string("In chat")
        case .changedInChat: return L10n.string("Update ready")
        case .shared: return L10n.string("Shared")
        case .changedSinceShared: return L10n.string("New changes")
        }
    }
}
