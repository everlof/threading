import AppKit
import ThreadingDesignKit

/// The Bluetooth tab's "?" panel: what packet definitions are, where this project's file goes and
/// what became of it, a reference, a complete example, and the three ways to start — create the
/// file from the example, copy the example, or copy a prompt that hands the job to an agent.
///
/// A panel rather than a tooltip for the reason `HelpPopoverButton` gives: the example is meant
/// to be selected and copied, which a tooltip cannot offer.
@MainActor
final class BluetoothDefinitionsHelpViewController: NSViewController {
    enum Metrics {
        /// The whole panel. ThemedPopover insets its content by a hairline only, so the padding
        /// is the panel's own.
        static let width: CGFloat = 540
        static let padding = Design.Spacing.large
        static var contentWidth: CGFloat { width - 2 * padding }
        static let exampleHeight: CGFloat = 220
    }

    enum Identifiers {
        static let content = "bluetooth-definitions-help"
        static let status = "bluetooth-definitions-status"
        static let primary = "bluetooth-definitions-create"
        static let copyExample = "bluetooth-definitions-copy-example"
        static let copyPrompt = "bluetooth-definitions-copy-prompt"
    }

    private(set) var status: BluetoothDefinitionStatus
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(labelWithString: "")
    private lazy var primaryButton = ThemedButton(title: "", target: self, action: #selector(primaryAction))
    private lazy var copyExampleButton = ThemedButton(
        title: L10n.string("Copy Example"), target: self, action: #selector(copyExample)
    )
    private lazy var copyPromptButton = ThemedButton(
        title: L10n.string("Copy Agent Prompt"), target: self, action: #selector(copyPrompt)
    )
    /// Asks the owner to load the file again after this panel wrote it.
    var onFileCreated: (() -> Void)?

    init(status: BluetoothDefinitionStatus) {
        self.status = status
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = FocusableView()
        view = root

        let title = NSTextField(labelWithString: L10n.string("App packet definitions"))
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.label

        let explanation = Self.wrapping(BluetoothDefinitionsGuide.explanation, width: Metrics.contentWidth)
        statusLabel.font = Design.Typography.caption()
        // The popover sizes itself from `fittingSize` before the panel exists, and a wrapping
        // label without a layout width measures as one line: the panel came out short and AppKit
        // clipped its top. Every wrapping label states the width it will wrap at.
        statusLabel.preferredMaxLayoutWidth = Metrics.contentWidth
        statusLabel.setAccessibilityIdentifier(Identifiers.status)

        let terms = BluetoothDefinitionsGuide.reference.map { line in
            let term = NSTextField(labelWithString: line.term)
            term.applyFont(.subheading)
            term.textColor = Design.Text.tertiary
            return term
        }
        let termWidth = ceil(terms.map(\.intrinsicContentSize.width).max() ?? 0)
        let detailWidth = Metrics.contentWidth - termWidth - Design.Spacing.medium
        let reference = NSGridView(views: zip(terms, BluetoothDefinitionsGuide.reference).map { term, line in
            [term, Self.wrapping(line.detail, width: detailWidth)]
        })
        reference.rowSpacing = Design.Spacing.tight
        reference.columnSpacing = Design.Spacing.medium
        reference.column(at: 0).width = termWidth
        reference.column(at: 0).xPlacement = .leading
        reference.rowAlignment = .firstBaseline

        let exampleTitle = NSTextField(labelWithString: L10n.string("Example — .threading/bluetooth.yaml"))
        exampleTitle.applyFont(.subheading)
        exampleTitle.textColor = Design.Text.tertiary
        let example = ThemedTextView.scrolling()
        example.textView.isEditable = false
        example.textView.isSelectable = true
        example.textView.font = Design.Typography.compactCode()
        example.textView.textColor = Design.Text.label
        example.textView.string = BluetoothDefinitionsGuide.example
        // A well, so the example reads as a file rather than as more of the panel's prose. The
        // role is a dynamic colour and follows a live theme change.
        example.textView.drawsBackground = true
        example.textView.backgroundColor = Design.Surface.field
        example.textView.textContainerInset = NSSize(width: Design.Spacing.small, height: Design.Spacing.small)
        example.textView.setAccessibilityLabel(L10n.string("Example packet definitions"))

        primaryButton.emphasis = .primary
        primaryButton.setAccessibilityIdentifier(Identifiers.primary)
        copyExampleButton.setAccessibilityIdentifier(Identifiers.copyExample)
        copyPromptButton.setAccessibilityIdentifier(Identifiers.copyPrompt)
        feedback.font = Design.Typography.caption()
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
        root.setAccessibilityLabel(L10n.string("App packet definitions"))
        root.setAccessibilityIdentifier(Identifiers.content)
        apply(status)
    }

    func apply(_ status: BluetoothDefinitionStatus) {
        self.status = status
        guard isViewLoaded else { return }
        switch status {
        case .noCheckout:
            statusLabel.stringValue = L10n.string("This Device Logs tab is not attached to a project checkout, so there is no file to read. Open Device Logs from a project's session.")
            primaryButton.title = L10n.string("Create File")
            primaryButton.isEnabled = false
        case .missing(let url):
            statusLabel.stringValue = L10n.format("Not created yet. Threading looks for %@", url.path)
            primaryButton.title = L10n.string("Create File")
            primaryButton.isEnabled = true
        case .loaded(let url, let characteristics, let types):
            statusLabel.stringValue = L10n.format("Loaded %@ — %d characteristics, %d types.", url.path, characteristics, types)
            primaryButton.title = L10n.string("Open File")
            primaryButton.isEnabled = true
        case .failed(let url, let message):
            statusLabel.stringValue = url.path + " " + message
            primaryButton.title = L10n.string("Open File")
            primaryButton.isEnabled = true
        }
        statusLabel.textColor = status.isFailure ? Design.Status.warning : Design.Text.secondary
    }

    // MARK: Actions

    @objc private func primaryAction() {
        switch status {
        case .missing(let url):
            createFile(at: url)
        case .loaded(let url, _, _), .failed(let url, _):
            NSWorkspace.shared.open(url)
        case .noCheckout:
            break
        }
    }

    @objc private func copyExample() {
        copy(BluetoothDefinitionsGuide.example, feedback: L10n.string("Example copied."))
    }

    @objc private func copyPrompt() {
        let path = status.url?.path ?? BluetoothPacketDefinitions.relativePaths[0]
        copy(BluetoothDefinitionsGuide.agentPrompt(path: path),
             feedback: L10n.string("Prompt copied — paste it into an agent session in this project."))
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
                        try Data(BluetoothDefinitionsGuide.example.utf8).write(to: url, options: .withoutOverwriting)
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
            NSWorkspace.shared.open(url)
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
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
