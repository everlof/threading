import AppKit

/// What is left of the chosen account, shown where the choice is made.
///
/// The toolbar pill answers this once a session exists. By then the decision has been taken —
/// so the composer says it up front, in full: every window as a bar with its pace mark, not a
/// percentage to squint at. There is room for it, because the composer is replaced by the
/// conversation the moment the session starts.
///
/// Takes a reading rather than an account, so it renders whatever it is handed: the composer
/// owns the fetching and the notification, the view owns the drawing.
final class AccountUsagePanelView: NSView {

    // MARK: - Properties

    private let titleLabel = NSTextField(labelWithString: "")
    private let planLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let windowStack = NSStackView()
    private let contentStack = NSStackView()

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
        // Flush, with no surface of its own: a card here would inset its bars from the column
        // everything else is aligned to, and `Surface.panel` is nearly invisible against the
        // pane anyway — so it read as a misalignment rather than as a group.
        titleLabel.font = Design.Typography.caption()
        titleLabel.textColor = .secondaryLabelColor

        planLabel.font = Design.Typography.caption()
        planLabel.textColor = .tertiaryLabelColor

        footerLabel.font = Design.Typography.caption()
        footerLabel.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, planLabel, spacer, footerLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Design.Spacing.small

        windowStack.orientation = .vertical
        windowStack.alignment = .leading
        windowStack.spacing = Design.Spacing.medium

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(windowStack)

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            windowStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    // MARK: - Public Methods

    /// Draws a reading, or hides when there is nothing to say.
    ///
    /// Hiding rather than showing an empty frame is the pill's rule applied here: an account
    /// with no usage source — every shell, and Claude without credentials — is not a thing to
    /// report an absence about.
    func show(accountName: String, usage: AccountUsage?, error: String?) {
        windowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let usage, !usage.windows.isEmpty else {
            isHidden = true
            toolTip = error
            return
        }

        isHidden = false
        titleLabel.stringValue = accountName

        planLabel.stringValue = usage.planLabel ?? ""
        planLabel.isHidden = usage.planLabel == nil

        footerLabel.stringValue = "Updated \(UsageFormat.age(of: usage.observedAt))"
        toolTip = error

        for window in usage.windows {
            let row = UsageWindowRow(window: window)
            row.translatesAutoresizingMaskIntoConstraints = false
            windowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: windowStack.widthAnchor).isActive = true
        }
    }
}
