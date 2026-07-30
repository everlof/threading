import AppKit

/// Theme-owned find-in-page chrome for a live WebKit surface.
final class BrowserFindBar: NSView, ThemedComponent, NSTextFieldDelegate {

    private enum Layout {
        static let height = Design.Size.chipHeight + Design.Spacing.small * 2
        static let minimumFieldWidth: CGFloat = 120
        static let statusFoldThreshold: CGFloat = 430
    }

    let queryField = ThemedTextField()
    let previousButton = ThemedButton(
        symbol: "chevron.up",
        accessibility: L10n.string("Previous Match"),
        target: nil,
        action: nil
    )
    let nextButton = ThemedButton(
        symbol: "chevron.down",
        accessibility: L10n.string("Next Match"),
        target: nil,
        action: nil
    )
    let closeButton = ThemedButton(
        symbol: "xmark",
        accessibility: L10n.string("Close Find in Page"),
        target: nil,
        action: nil
    )

    var onFind: ((_ query: String, _ backwards: Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let stack: NSStackView
    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [
            queryField,
            statusLabel,
            previousButton,
            nextButton,
            closeButton
        ])
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Layout.height)
    }

    private func setup() {
        queryField.placeholderString = L10n.string("Find in page")
        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(findNext)
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let minimumField = queryField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Layout.minimumFieldWidth
        )
        minimumField.priority = .defaultHigh

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previousButton.target = self
        previousButton.action = #selector(findPrevious)
        nextButton.target = self
        nextButton.action = #selector(findNext)
        closeButton.target = self
        closeButton.action = #selector(dismiss)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.small,
            right: Design.Spacing.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            minimumField
        ])
        setAccessibilityElement(false)
        setMatchFound(nil)
    }

    override func layout() {
        super.layout()
        statusLabel.isHidden = bounds.width < Layout.statusFoldThreshold
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.background.setFill()
        bounds.fill()
    }

    func focus() {
        window?.makeFirstResponder(queryField)
        if let editor = queryField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: queryField.stringValue.count)
        }
    }

    func setMatchFound(_ found: Bool?) {
        statusLabel.stringValue = switch found {
        case true: L10n.string("Match found")
        case false: L10n.string("No matches")
        case nil: ""
        }
        previousButton.isEnabled = found == true
        nextButton.isEnabled = found == true || !queryField.stringValue.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = queryField.stringValue
        if query.isEmpty {
            setMatchFound(nil)
        }
        onFind?(query, false)
    }

    @objc private func findPrevious() {
        onFind?(queryField.stringValue, true)
    }

    @objc private func findNext() {
        onFind?(queryField.stringValue, false)
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}
