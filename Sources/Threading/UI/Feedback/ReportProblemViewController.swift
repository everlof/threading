import AppKit

/// Help ▸ Report a Problem: a private report raised from anywhere in the app, without a capture.
///
/// The inspector's sheet files what the app *measured*; this one files what the user *noticed* —
/// including the half of reports that are not defects at all, which is why the first control is
/// the kind. An inbox where every report arrives labelled `bug` is an inbox whose labels mean
/// nothing, and asking once at the top costs a click that triage would otherwise pay for later.
///
/// The user-authored description and the content-free diagnostic journal go to Threading's
/// private support inbox. Nothing is published to GitHub, and no raw local log is attached.
final class ReportProblemViewController: NSViewController {

    // MARK: - Properties

    private let kindControl = ThemedSegmentedControl()
    private let titleField = ThemedTextField()
    private let detailField = PromptView()
    private let statusView = SubmissionStatusView()
    /// The same control the inspector's sheet uses. This sheet has no Copy Report — it is a form
    /// rather than a capture, so there is nothing collected to carry anywhere — which means a
    /// Release build has exactly one action and the control draws no chevron for it.
    private lazy var actionsControl: DeveloperReportSubmitControl = {
        var available: [DeveloperReportAction] = [.send]
#if DEBUG
        available.append(.chat)
#endif
        let control = DeveloperReportSubmitControl(available: available)
        control.onPerform = { [weak self] action in self?.perform(action) }
        return control
    }()

    private var kind: DeveloperIssueReportKind = .problem
    private var isSubmitting = false

    /// Called when the sheet is done, however it was closed.
    var onDone: (() -> Void)?

    /// Sends the reviewed report. Injected so a render/behavior test needs no network or app
    /// composition root.
    var onSubmitReport: ((DeveloperIssueReportDraft) async -> DeveloperIssueReportSubmission)?

#if DEBUG
    /// Opens a chat on the same reviewed report. There is no capture here, so what a chat gets
    /// is exactly what the inbox would have got — which is the whole of what this sheet knows.
    /// See `DeveloperReportChat`.
    var onSendToChat: ((DeveloperReportChatRequest) -> DeveloperReportChatOutcome)?

#endif

    // MARK: - Public Methods

    /// Opens the sheet with a report already written, for a failure Threading captured itself.
    ///
    /// The evidence is put in the **editable** field rather than carried alongside as an
    /// attachment the user cannot see. Captured terminal output is arbitrary program text — it
    /// is whatever the agent printed — so the one rule this sheet enforces about it is that
    /// nobody can send it without having been shown it, and the way to guarantee that is to make
    /// it the thing they are looking at and free to cut.
    func prefill(title: String, detail: String) {
        // `loadViewIfNeeded()` is macOS 14; touching `view` is the same guarantee on 13.
        _ = view
        titleField.stringValue = title
        detailField.stringValue = detail
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: ReportProblemLayout.sheetWidth,
            height: ReportProblemLayout.sheetHeight
        ))
        setupViews()

        // Sized to its content, for the reason the inspector's sheet is: slack in a stack
        // pinned top and bottom becomes gaps between the fields.
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(
            width: ReportProblemLayout.sheetWidth,
            height: view.fittingSize.height
        ))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: - Setup

    private func setupViews() {
        view.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )

        let headingLabel = NSTextField(labelWithString: ReportProblemStrings.heading)
        headingLabel.applyFont(.heading)
        headingLabel.textColor = Design.Text.label

        let subheadingLabel = NSTextField(labelWithString: ReportProblemStrings.subheading)
        subheadingLabel.applyFont(.subheading)
        subheadingLabel.textColor = Design.Text.secondary
        subheadingLabel.lineBreakMode = .byWordWrapping
        subheadingLabel.maximumNumberOfLines = 2
        subheadingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        let content: [NSView] = [
            headings,
            makeKindControl(),
            makeTitleField(),
            makeDetailField(),
            makeEnvironmentNote(),
            statusView,
            makeFooter()
        ]

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.setAccessibilityIdentifier(ReportProblemIdentifiers.status)

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])

        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeKindControl() -> NSView {
        kindControl.configure(
            titles: [ReportProblemStrings.problemTitle, ReportProblemStrings.improvementTitle],
            selectedIndex: 0
        )
        kindControl.onSelect = { [weak self] index in
            self?.kind = index == 0 ? .problem : .improvement
        }
        kindControl.setAccessibilityIdentifier(ReportProblemIdentifiers.kind)

        return section(caption: ReportProblemStrings.kindCaption, content: kindControl)
    }

    private func makeTitleField() -> NSView {
        titleField.placeholderString = ReportProblemStrings.titlePlaceholder
        titleField.setAccessibilityIdentifier(ReportProblemIdentifiers.title)
        return section(caption: ReportProblemStrings.titleCaption, content: titleField)
    }

    private func makeDetailField() -> NSView {
        detailField.placeholder = ReportProblemStrings.detailPlaceholder
        detailField.submitPlacement = .outside
        detailField.minimumHeight = ReportProblemLayout.detailHeight
        detailField.onSubmit = { [weak self] _ in self?.submitIssue() }
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.setAccessibilityIdentifier(ReportProblemIdentifiers.detail)

        let hint = NSTextField(labelWithString: ReportProblemStrings.detailHint)
        hint.applyFont(.caption)
        hint.textColor = Design.Text.tertiary
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [detailField, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        detailField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return section(caption: ReportProblemStrings.detailCaption, content: stack)
    }

    /// Shown rather than promised: the line names the exact three values that will be in the
    /// report, in the form they will appear there.
    ///
    /// It wraps and yields rather than holding its width. Under a theme whose type is a wide
    /// monospace this one sentence is ~690 points long, and a label that will not compress
    /// makes the *sheet* that wide — which it cannot be, so AppKit breaks a pin instead and
    /// every control runs off the right edge. Seen in the cyberpunk render, not in System.
    private func makeEnvironmentNote() -> NSView {
        let label = NSTextField(labelWithString: L10n.format(
            "Included with the report: %@",
            DeveloperIssueReportComposer.environment()
        ))
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier(ReportProblemIdentifiers.environment)
        return label
    }

    private func section(caption: String, content: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary

        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func makeFooter() -> NSView {
        let cancelButton = ThemedButton(
            title: ReportProblemStrings.cancelTitle,
            target: self,
            action: #selector(cancel)
        )
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, cancelButton, actionsControl])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    private func perform(_ action: DeveloperReportAction) {
        switch action {
        case .send:
            submitIssue()
        case .copy:
            break
        case .chat:
#if DEBUG
            sendToChat()
#else
            break
#endif
        }
    }

    // MARK: - Actions

    @objc func submitIssue() {
        guard !isSubmitting, let onSubmitReport else { return }

        // A report with no words in it wastes the reader's time, and the reader is a person.
        guard !draftIsEmpty else {
            statusView.show(ReportProblemStrings.emptyWarning, tone: .failed)
            view.window?.makeFirstResponder(titleField)
            return
        }

        let draft = reportDraft()
        isSubmitting = true
        actionsControl.setBusy(true, title: ReportProblemStrings.submittingTitle)
        statusView.show(ReportProblemStrings.submittingStatus, tone: .working)

        Task { @MainActor [weak self] in
            let outcome = await onSubmitReport(draft)
            self?.finishSubmitting(outcome)
        }
    }

#if DEBUG
    /// The same empty-report guard the private route applies, for the same reason: the reader
    /// is a person either way, and an agent handed a blank report answers by asking what it is.
    @objc func sendToChat() {
        guard !isSubmitting, let onSendToChat else { return }
        guard !draftIsEmpty else {
            statusView.show(ReportProblemStrings.emptyWarning, tone: .failed)
            view.window?.makeFirstResponder(titleField)
            return
        }

        let draft = reportDraft()
        statusView.show(DeveloperReportChatStrings.startingStatus, tone: .working)
        switch onSendToChat(
            DeveloperReportChatRequest(title: draft.title, report: draft.description)
        ) {
        case .started(let projectName):
            statusView.show(DeveloperReportChatStrings.started(projectName: projectName), tone: .done)
            onDone?()
        case .failed(let message):
            statusView.show(message, tone: .failed)
        }
    }
#endif

    @objc private func cancel() {
        onDone?()
    }

    // MARK: - Public Methods

    var draftIsEmpty: Bool {
        titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && detailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What gets filed. The typed title wins when there is one; otherwise the first line of the
    /// description becomes it, which is how people write when a form does not insist.
    func reportDraft() -> DeveloperIssueReportDraft {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == .problem
            ? ReportProblemStrings.untitledProblem
            : ReportProblemStrings.untitledImprovement

        return DeveloperIssueReportDraft(
            kind: kind,
            title: typed.isEmpty
                ? DeveloperIssueReportComposer.title(
                    fromNote: detailField.stringValue,
                    fallback: fallback
                )
                : String(typed.prefix(DeveloperIssueReportComposer.maximumTitleCharacters)),
            details: detailField.stringValue
        )
    }

    /// What the sheet is showing, for tests driving a submission without a network.
    var statusMessage: String { statusView.message }

    // MARK: - Private Methods

    private func finishSubmitting(_ outcome: DeveloperIssueReportSubmission) {
        isSubmitting = false
        actionsControl.setBusy(false)

        switch outcome {
        case .delivered(let reference):
            statusView.show(ReportProblemStrings.received(reference: reference), tone: .done)
        case .saved(let records):
            statusView.show(ReportProblemStrings.saved(records: records), tone: .done)
        case .queued:
            statusView.show(ReportProblemStrings.queued, tone: .working)
        case .failed(let message):
            statusView.show(message, tone: .failed)
        }
    }
}

// MARK: - Layout

enum ReportProblemLayout {
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 520
    static let detailHeight: CGFloat = 140
}

enum ReportProblemIdentifiers {
    static let kind = "report.problem.kind"
    static let title = "report.problem.title"
    static let detail = "report.problem.detail"
    static let environment = "report.problem.environment"
    static let status = "report.problem.status"
    static let submit = "report.problem.submit"
#if DEBUG
    static let chat = "report.problem.chat"
#endif
}

// MARK: - Strings

enum ReportProblemStrings {
    static var heading: String { L10n.string("Report a Problem") }
    static var subheading: String {
        L10n.string("Sends a private report to Threading. Nothing is sent until you press Send.")
    }
    static var kindCaption: String { L10n.string("Kind") }
    static var problemTitle: String { L10n.string("Problem") }
    static var improvementTitle: String { L10n.string("Improvement") }
    static var titleCaption: String { L10n.string("Title") }
    static var titlePlaceholder: String { L10n.string("One line naming it") }
    static var detailCaption: String { L10n.string("Details") }
    static var detailPlaceholder: String {
        L10n.string("What happened, what you expected, and how to see it again")
    }
    static var detailHint: String {
        L10n.string("⌘Return sends the report · Return adds a line")
    }
    static var submittingTitle: String { L10n.string("Sending…") }
    static var submittingStatus: String { L10n.string("Sending to Threading’s private inbox…") }
    static var cancelTitle: String { L10n.string("Cancel") }
    static var emptyWarning: String { L10n.string("Write a title or some details first.") }
    static var untitledProblem: String { L10n.string("Problem reported from Threading") }
    static var untitledImprovement: String { L10n.string("Improvement suggested from Threading") }

    static func received(reference: String) -> String {
        L10n.format("Report received. Reference: %@", reference)
    }
    static func saved(records: Int) -> String {
        L10n.format("Saved to your outbox (%lld).", records)
    }

    static var queued: String {
        L10n.string("Report saved securely and queued for retry when Threading is active.")
    }
}
