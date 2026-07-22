import AppKit

/// Toolbar content naming the project and session currently shown.
///
/// Lives in the window's toolbar rather than inside the terminal pane, so it stays aligned
/// with the traffic lights whether the sidebar is open or collapsed.
final class SessionTitleItemView: NSView {

    // MARK: - Properties

    private let iconView = NSImageView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let separatorLabel = NSTextField(labelWithString: SessionTitleDefaults.separator)
    private let sessionLabel = NSTextField(labelWithString: "")

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        iconView.image = NSImage(
            systemSymbolName: SessionTitleDefaults.symbolName,
            accessibilityDescription: nil
        )
        iconView.contentTintColor = Design.Text.secondary
        iconView.translatesAutoresizingMaskIntoConstraints = false

        projectLabel.font = .systemFont(ofSize: SessionTitleDefaults.fontSize, weight: .semibold)
        projectLabel.textColor = Design.Text.label
        projectLabel.lineBreakMode = .byTruncatingTail

        separatorLabel.font = .systemFont(ofSize: SessionTitleDefaults.fontSize)
        separatorLabel.textColor = Design.Text.tertiary

        sessionLabel.font = .systemFont(ofSize: SessionTitleDefaults.fontSize)
        sessionLabel.textColor = Design.Text.secondary
        sessionLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [iconView, projectLabel, separatorLabel, sessionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = SessionTitleDefaults.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SessionTitleDefaults.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: SessionTitleDefaults.iconSize)
        ])
    }

    // MARK: - Public Methods

    /// Shows the project and session names, or clears them when nothing is selected.
    func configure(project: Project?, session: AgentSession?) {
        guard let project else {
            projectLabel.stringValue = ""
            sessionLabel.stringValue = ""
            separatorLabel.isHidden = true
            iconView.isHidden = true
            return
        }

        iconView.isHidden = false
        projectLabel.stringValue = project.name

        if let session {
            sessionLabel.stringValue = session.displayTitle
            sessionLabel.isHidden = false
            separatorLabel.isHidden = false
        } else {
            sessionLabel.isHidden = true
            separatorLabel.isHidden = true
        }
    }

    /// Names a pane not tied to a project or session, such as Settings.
    func configure(title: String) {
        iconView.isHidden = true
        projectLabel.stringValue = title
        sessionLabel.stringValue = ""
        sessionLabel.isHidden = true
        separatorLabel.isHidden = true
    }
}

// MARK: - Session Title Defaults

enum SessionTitleDefaults {
    static let fontSize: CGFloat = 13
    static let iconSize: CGFloat = 14
    static let spacing: CGFloat = 6
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 520
    static let symbolName = "folder"
    static let separator = "—"
}
