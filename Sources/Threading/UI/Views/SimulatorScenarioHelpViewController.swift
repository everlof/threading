import AppKit

/// The Simulator workspace's Scenario Help panel: what scenarios are, what became of this
/// checkout's file, a reference, a complete example, and the three ways to start: create the file
/// from the example, copy the example, or copy a prompt that hands the integration to an agent.
///
/// The same panel as Device Logs' Bluetooth definitions help, for the same reason: the example is
/// meant to be selected and copied, which a tooltip cannot offer.
@MainActor
final class SimulatorScenarioHelpViewController: NSViewController {
    enum Status: Equatable {
        case noCheckout
        case reading
        case missing(URL)
        case loaded(URL, scenarios: Int, problems: Int)
        case failed(URL, String)

        var fileURL: URL? {
            switch self {
            case .noCheckout, .reading: return nil
            case .missing(let url), .loaded(let url, _, _), .failed(let url, _): return url
            }
        }
    }

    enum Metrics {
        static let width: CGFloat = 540
        static let padding = Design.Spacing.large
        static var contentWidth: CGFloat { width - 2 * padding }
        static let exampleHeight: CGFloat = 220
    }

    enum Identifiers {
        static let content = "simulator-scenarios-help"
        static let status = "simulator-scenarios-status"
        static let primary = "simulator-scenarios-create"
        static let copyExample = "simulator-scenarios-copy-example"
        static let copyPrompt = "simulator-scenarios-copy-prompt"
    }

    private(set) var status: Status
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(labelWithString: "")
    private lazy var primaryButton = ThemedButton(title: "", target: self, action: #selector(primaryAction))
    private lazy var copyExampleButton = ThemedButton(
        title: L10n.string("Copy Example"), target: self, action: #selector(copyExample)
    )
    private lazy var copyPromptButton = ThemedButton(
        title: L10n.string("Copy Agent Prompt"), target: self, action: #selector(copyPrompt)
    )
    /// Asks the owner to read the file again after this panel wrote it.
    var onFileCreated: (() -> Void)?
    /// Opens a file; a seam so a test never launches an editor.
    var openFile: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(status: Status) {
        self.status = status
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = ScenarioHelpRootView()
        view = root

        let title = NSTextField(labelWithString: L10n.string("Scenarios"))
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.label

        let explanation = Self.wrapping(SimulatorScenarioGuide.explanation, width: Metrics.contentWidth)
        statusLabel.applyFont(.caption)
        // The popover sizes itself from `fittingSize` before the panel exists; a wrapping label
        // without a layout width measures as one line and the panel comes out short.
        statusLabel.preferredMaxLayoutWidth = Metrics.contentWidth
        statusLabel.setAccessibilityIdentifier(Identifiers.status)

        let terms = SimulatorScenarioGuide.reference.map { line in
            let term = NSTextField(labelWithString: line.term)
            term.applyFont(.subheading)
            term.textColor = Design.Text.tertiary
            return term
        }
        let termWidth = ceil(terms.map(\.intrinsicContentSize.width).max() ?? 0)
        let detailWidth = Metrics.contentWidth - termWidth - Design.Spacing.medium
        let reference = NSGridView(views: zip(terms, SimulatorScenarioGuide.reference).map { term, line in
            [term, Self.wrapping(line.detail, width: detailWidth)]
        })
        reference.rowSpacing = Design.Spacing.tight
        reference.columnSpacing = Design.Spacing.medium
        reference.column(at: 0).width = termWidth
        reference.column(at: 0).xPlacement = .leading
        reference.rowAlignment = .firstBaseline

        let exampleTitle = NSTextField(labelWithString: L10n.format("Example: %@", SimulatorScenarioDefaults.relativePath))
        exampleTitle.applyFont(.subheading)
        exampleTitle.textColor = Design.Text.tertiary
        let example = ThemedTextView.scrolling()
        example.textView.isEditable = false
        example.textView.isSelectable = true
        example.textView.applyFont(.compactCode)
        example.textView.textColor = Design.Text.label
        example.textView.string = SimulatorScenarioGuide.example
        // A well, so the example reads as a file rather than more of the panel's prose.
        example.textView.drawsBackground = true
        example.textView.backgroundColor = Design.Surface.field
        example.textView.textContainerInset = NSSize(width: Design.Spacing.small, height: Design.Spacing.small)
        example.textView.setAccessibilityLabel(L10n.string("Example scenario file"))

        primaryButton.emphasis = .primary
        primaryButton.setAccessibilityIdentifier(Identifiers.primary)
        copyExampleButton.setAccessibilityIdentifier(Identifiers.copyExample)
        copyPromptButton.setAccessibilityIdentifier(Identifiers.copyPrompt)
        feedback.applyFont(.caption)
        feedback.textColor = Design.Text.secondary
        let actions = NSStackView(views: [primaryButton, copyExampleButton, copyPromptButton, feedback])
        actions.spacing = Design.Spacing.small
        actions.alignment = .centerY

        let stack = NSStackView(views: [title, explanation, statusLabel, reference, exampleTitle, example, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.tight, after: exampleTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Metrics.width),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.padding),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.padding),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.padding),
            // A vertical stack aligned .leading gives each view its fitting width; say the width.
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reference.widthAnchor.constraint(equalTo: stack.widthAnchor),
            example.widthAnchor.constraint(equalTo: stack.widthAnchor),
            example.heightAnchor.constraint(equalToConstant: Metrics.exampleHeight),
        ])
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(L10n.string("Scenarios"))
        root.setAccessibilityIdentifier(Identifiers.content)
        apply(status)
    }

    func apply(_ status: Status) {
        self.status = status
        guard isViewLoaded else { return }
        switch status {
        case .noCheckout:
            statusLabel.stringValue = L10n.string("This Simulator tab belongs to a session without a checkout, so there is no file to read.")
            primaryButton.title = L10n.string("Create File")
            primaryButton.isEnabled = false
        case .reading:
            statusLabel.stringValue = L10n.string("Reading the checkout…")
            primaryButton.title = L10n.string("Create File")
            primaryButton.isEnabled = false
        case .missing(let url):
            statusLabel.stringValue = L10n.format("Not created yet. Threading looks for %@", url.path)
            primaryButton.title = L10n.string("Create File")
            primaryButton.isEnabled = true
        case .loaded(let url, let scenarios, let problems):
            statusLabel.stringValue = problems == 0
                ? L10n.format("Loaded %@: %lld scenarios.", url.path, Int64(scenarios))
                : L10n.format("Loaded %@: %lld scenarios, %lld with problems listed in the Scenarios menu.",
                              url.path, Int64(scenarios), Int64(problems))
            primaryButton.title = L10n.string("Open File")
            primaryButton.isEnabled = true
        case .failed(let url, let message):
            statusLabel.stringValue = L10n.format("%1$@: %2$@", url.path, message)
            primaryButton.title = L10n.string("Open File")
            primaryButton.isEnabled = true
        }
        let problem: Bool
        switch status {
        case .failed: problem = true
        case .loaded(_, _, let problems): problem = problems > 0
        default: problem = false
        }
        statusLabel.textColor = problem ? Design.Status.warning : Design.Text.secondary
    }

    var feedbackForTesting: String { feedback.stringValue }
    var statusTextForTesting: String { statusLabel.stringValue }
    var primaryButtonForTesting: ThemedButton { primaryButton }
    func copyPromptForTesting() { copyPrompt() }

    // MARK: - Actions

    @objc private func primaryAction() {
        switch status {
        case .missing(let url):
            createFile(at: url)
        case .loaded(let url, _, _), .failed(let url, _):
            openFile(url)
        case .noCheckout, .reading:
            break
        }
    }

    @objc private func copyExample() {
        copy(SimulatorScenarioGuide.example, feedback: L10n.string("Example copied."))
    }

    @objc private func copyPrompt() {
        let path = status.fileURL?.path ?? SimulatorScenarioDefaults.relativePath
        copy(SimulatorScenarioGuide.agentPrompt(path: path),
             feedback: L10n.string("Prompt copied. Paste it into an agent session in this project."))
    }

    private func copy(_ text: String, feedback message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback.stringValue = message
    }

    private func createFile(at url: URL) {
        primaryButton.isEnabled = false
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    // Never overwrite: the file may have appeared since the status was read.
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try Data(SimulatorScenarioGuide.example.utf8).write(to: url, options: .withoutOverwriting)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            if let failure {
                self.feedback.stringValue = L10n.format("Could not create the file: %@", failure)
                self.primaryButton.isEnabled = true
                return
            }
            self.feedback.stringValue = L10n.string("Created from the example. Edit it to match your app.")
            self.onFileCreated?()
            self.openFile(url)
        }
    }

    private static func wrapping(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// Takes the keyboard so Escape has somewhere to arrive from and focus can return.
private final class ScenarioHelpRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
