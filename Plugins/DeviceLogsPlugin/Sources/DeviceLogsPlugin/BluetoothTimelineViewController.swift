import AppKit
import ThreadingDesignKit

/// The Bluetooth tab's Timelines panel: every try of a procedure the definitions declare — a
/// firmware update above all — newest first, as one readable story each.
///
/// Each try leads with one line that says how it ended and why, in the outcome's colour, so a
/// failure is found without reading. Below it, the facts (firmware before and after, the steps it
/// reached) and the full timeline with offsets from the start. The text is the same text **Copy**
/// puts on the pasteboard and the agent's `timelines` tool returns, so a bug report carries what
/// the panel shows.
@MainActor
final class BluetoothTimelineViewController: NSViewController {
    enum Metrics {
        static let width: CGFloat = 720
        static let padding = Design.Spacing.large
        static var contentWidth: CGFloat { width - 2 * padding }
        static let timelineHeight: CGFloat = 420
    }

    enum Identifiers {
        static let content = "bluetooth-timelines"
        static let text = "bluetooth-timelines-text"
        static let copy = "bluetooth-timelines-copy"
        static let clear = "bluetooth-timelines-clear"
    }

    private(set) var history: BluetoothProcedureHistory
    private let timeline = ThemedTextView.scrolling()
    private let feedback = NSTextField(labelWithString: "")
    private lazy var copyButton = ThemedButton(title: L10n.string("Copy All"), target: self, action: #selector(copyAll))
    private lazy var clearButton = ThemedButton(title: L10n.string("Clear History"), target: self, action: #selector(clearHistory))
    /// Asks the owner to forget every recorded try.
    var onClear: (() -> Void)?

    init(history: BluetoothProcedureHistory) {
        self.history = history
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = FocusableView()
        view = root

        let title = NSTextField(labelWithString: L10n.string("Timelines"))
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.label
        let explanation = NSTextField(wrappingLabelWithString: L10n.string(
            "Every try of a firmware update or other procedure your definitions declare, newest first: how it ended and why, then each step, link event, error and checksum check. Kept on this Mac across captures."
        ))
        explanation.font = Design.Typography.caption()
        explanation.textColor = Design.Text.secondary
        explanation.preferredMaxLayoutWidth = Metrics.contentWidth

        timeline.textView.isEditable = false
        timeline.textView.isSelectable = true
        timeline.textView.drawsBackground = true
        timeline.textView.backgroundColor = Design.Surface.field
        timeline.textView.textContainerInset = NSSize(width: Design.Spacing.small, height: Design.Spacing.small)
        timeline.textView.setAccessibilityIdentifier(Identifiers.text)
        timeline.textView.setAccessibilityLabel(L10n.string("Procedure timelines"))

        copyButton.setAccessibilityIdentifier(Identifiers.copy)
        clearButton.setAccessibilityIdentifier(Identifiers.clear)
        feedback.font = Design.Typography.caption()
        feedback.textColor = Design.Text.secondary
        let actions = NSStackView(views: [copyButton, clearButton, feedback])
        actions.spacing = Design.Spacing.small
        actions.alignment = .centerY

        let stack = NSStackView(views: [title, explanation, timeline, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.setAccessibilityIdentifier(Identifiers.content)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.padding),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.padding),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.padding),
            root.widthAnchor.constraint(equalToConstant: Metrics.width),
            timeline.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
            timeline.heightAnchor.constraint(equalToConstant: Metrics.timelineHeight),
        ])
        show(history)
    }

    /// Replaces what the panel shows, keeping the reader's place when nothing new arrived.
    func show(_ history: BluetoothProcedureHistory) {
        self.history = history
        copyButton.isEnabled = !history.attempts.isEmpty
        clearButton.isEnabled = !history.attempts.isEmpty
        timeline.textView.textStorage?.setAttributedString(Self.rendered(history))
    }

    /// Headlines in their outcome's colour and weight, timeline lines in code type, errors and
    /// warnings tinted: the story is legible at a glance and complete on reading.
    static func rendered(_ history: BluetoothProcedureHistory) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = Design.Typography.compactCode()
        let body: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Design.Text.label]
        // A long line wraps under its own text rather than under the offsets, so the column of
        // times stays a column. The type is monospaced, so a character count is a width.
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        func hanging(_ line: String) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            let offset = line.range(of: " s  ").map { line.distance(from: line.startIndex, to: $0.upperBound) }
            let leading = line.prefix { $0 == " " }.count
            style.headIndent = CGFloat(offset ?? leading + 2) * advance
            return style
        }
        guard !history.attempts.isEmpty else {
            text.append(NSAttributedString(string: L10n.string(
                "Nothing recorded yet. Firmware updates are recorded when the definitions include nordic-dfu or nordic-legacy-dfu, or declare procedures: of their own."
            ), attributes: [.font: Design.Typography.caption(), .foregroundColor: Design.Text.secondary]))
            return text
        }
        for (position, attempt) in history.attempts.reversed().enumerated() {
            if position > 0 { text.append(NSAttributedString(string: "\n\n", attributes: body)) }
            let lines = BluetoothProcedureFormatting.timeline(attempt).components(separatedBy: "\n")
            let outcome: NSColor = switch attempt.outcome {
            case .completed: Design.Status.positive
            case .running: Design.Text.label
            case .unchanged, .abandoned: Design.Status.warning
            case .failed: Design.Status.negative
            }
            text.append(NSAttributedString(string: lines[0], attributes: [
                .font: Design.Typography.compactCode(weight: .semibold), .foregroundColor: outcome,
                .paragraphStyle: hanging(lines[0]),
            ]))
            for line in lines.dropFirst() {
                var attributes = body
                attributes[.paragraphStyle] = hanging(line)
                if line.contains(" ERROR: ") { attributes[.foregroundColor] = Design.Status.negative }
                else if line.contains(" WARNING: ") { attributes[.foregroundColor] = Design.Status.warning }
                else if line.hasPrefix("  started ") || line.hasPrefix("  firmware") { attributes[.foregroundColor] = Design.Text.secondary }
                text.append(NSAttributedString(string: "\n" + line, attributes: attributes))
            }
        }
        return text
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BluetoothProcedureFormatting.all(history), forType: .string)
        feedback.stringValue = L10n.string("Copied.")
    }

    @objc private func clearHistory() {
        onClear?()
        show(BluetoothProcedureHistory())
        feedback.stringValue = L10n.string("History cleared.")
    }
}
