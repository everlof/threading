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
        titleLabel.applyFont(.caption)
        titleLabel.textColor = Design.Text.secondary

        planLabel.applyFont(.caption)
        planLabel.textColor = Design.Text.tertiary

        footerLabel.applyFont(.caption)
        footerLabel.textColor = Design.Text.tertiary

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
    func show(accountName: String, usage: AccountUsage?, error: String?, account: AgentAccount? = nil) {
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

        for window in usage.windows + usage.modelWindows {
            let row = UsageWindowRow(window: window)
            row.translatesAutoresizingMaskIntoConstraints = false
            windowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: windowStack.widthAnchor).isActive = true
        }

        footerLabel.stringValue = footer(for: usage, account: account)
    }

    /// The footer carries what the bars cannot: banked resets and any credit balance.
    ///
    /// Resets matter precisely when a window is spent — that is the moment the user is deciding
    /// whether to stop for the day, and "you have three of these" changes the answer. They are
    /// stated only when there are any, so an account without them says nothing.
    private func footer(for usage: AccountUsage, account: AgentAccount?) -> String {
        var parts: [String] = []

        // The projection leads when there is one: "85% spent" is a level, and the question a
        // level provokes is whether it will last, which only a rate can answer.
        if let account, let peak = usage.peakWindow(),
           let line = UsageFormat.forecast(
               UsageHistoryStore.shared.forecast(for: account, window: peak),
               window: peak
           ) {
            parts.append(line)
        }

        parts.append("Updated \(UsageFormat.age(of: usage.observedAt))")

        if let credits = usage.resetCredits, credits > 0 {
            parts.append(UsageFormat.resetCredits(credits))
        }
        if let balance = usage.creditBalance {
            parts.append("\(balance) credits")
        }

        return parts.joined(separator: UsageDefaults.segmentSeparator)
    }
}
