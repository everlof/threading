import AppKit

/// The active sidebar destination rendered as a compact toolbar tab.
///
/// Lives in the window's toolbar rather than inside the terminal pane, so it stays aligned
/// with the traffic lights whether the sidebar is open or collapsed.
final class SessionTitleItemView: BackdropOverlay {

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = MorphingTitleLabel()
    private let closeButton = ToolbarButtonView(
        symbolName: "xmark",
        accessibility: "Close active page",
        buttonSize: NSSize(
            width: SessionTitleDefaults.closeButtonSize,
            height: SessionTitleDefaults.closeButtonSize
        )
    )
    private let contentStack = NSStackView()
    private var representedSessionID: SessionID?

    var onClose: (() -> Void)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        isHidden = true

        iconView.image = NSImage(
            systemSymbolName: SessionTitleDefaults.projectSymbolName,
            accessibilityDescription: nil
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Design.Typography.emphasizedBody()
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        closeButton.toolTip = "Close Active Page"
        closeButton.onPress = { [weak self] in self?.onClose?() }

        [iconView, titleLabel, closeButton].forEach(
            contentStack.addArrangedSubview
        )
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = SessionTitleDefaults.spacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SessionTitleDefaults.height),
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SessionTitleDefaults.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SessionTitleDefaults.horizontalInset
            ),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SessionTitleDefaults.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: SessionTitleDefaults.iconSize)
        ])
    }

    // MARK: - Ink

    /// Every colour here comes from the backdrop, none from `Design.Text` — see
    /// `BackdropOverlay`.
    override func applyInk(_ ink: Design.Ink) {
        iconView.contentTintColor = ink.secondary
        titleLabel.textColor = ink.label
        needsDisplay = true
    }

    /// The selected sidebar destination is the toolbar's active page tab.
    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: ink.surface,
            border: nil,
            radius: Design.Radius.pill(height: bounds.height)
        )
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(
            titleLabel.stringValue.size(
                withAttributes: [.font: titleLabel.font as Any]
            ).width
        )
        let closeWidth = closeButton.isHidden
            ? 0
            : SessionTitleDefaults.spacing + SessionTitleDefaults.closeButtonSize
        let width = SessionTitleDefaults.horizontalInset * 2
            + SessionTitleDefaults.iconSize
            + SessionTitleDefaults.spacing
            + titleWidth
            + closeWidth
        return NSSize(
            width: min(
                max(width, SessionTitleDefaults.minWidth),
                SessionTitleDefaults.maxWidth
            ),
            height: SessionTitleDefaults.height
        )
    }

    // MARK: - Public Methods

    /// Shows a selected session, or a non-closable project label when used outside page navigation.
    func configure(project: Project?, session: AgentSession?) {
        guard let project else {
            isHidden = true
            titleLabel.setStringValue("", animated: false)
            representedSessionID = nil
            iconView.isHidden = true
            closeButton.isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        isHidden = false
        iconView.isHidden = false

        if let session {
            iconView.image = session.kind.icon
            let isRename = representedSessionID == session.id
            titleLabel.setStringValue(session.displayTitle, animated: isRename)
            representedSessionID = session.id
            closeButton.isHidden = false
            toolTip = "\(project.name) — \(session.displayTitle)"
        } else {
            iconView.image = NSImage(
                systemSymbolName: SessionTitleDefaults.projectSymbolName,
                accessibilityDescription: nil
            )
            titleLabel.setStringValue(project.name, animated: false)
            representedSessionID = nil
            closeButton.isHidden = true
            toolTip = project.name
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Names a pane not tied to a project or session, such as a Settings page.
    func configure(title: String, symbolName: String, showsClose: Bool) {
        isHidden = false
        iconView.isHidden = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        titleLabel.setStringValue(title, animated: false)
        representedSessionID = nil
        closeButton.isHidden = !showsClose
        toolTip = title
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

// MARK: - Session Title Defaults

enum SessionTitleDefaults {
    static let fontSize: CGFloat = 13
    static let iconSize: CGFloat = 14
    static let height: CGFloat = 28
    static let horizontalInset: CGFloat = 12
    static let spacing: CGFloat = 6
    static let closeButtonSize: CGFloat = 18
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 360
    static let projectSymbolName = "folder"
}
