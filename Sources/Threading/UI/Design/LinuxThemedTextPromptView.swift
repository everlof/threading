#if os(Linux)
import AppKit

/// The Linux presentation of the shared text prompt or confirmation alert. The host supplies
/// modal event dispatch; this component uses the same content constraints and Design controls
/// as `ThemedAlert`/`TextPromptAlert` on macOS.
@MainActor
final class LinuxThemedTextPromptView: NSView {
    let inputField = ThemedTextField(frame: .zero)
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let mark = LinuxAlertMark(frame: .zero)
    private let cancelButton = ThemedButton()
    private let confirmButton = ThemedButton()
    private let clearButton = ThemedButton()
    private let suppressionButton: ThemedCheckbox?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?
    private let showsField: Bool
    var initialResponder: NSView { showsField ? inputField : confirmButton }
    var cancelFrame: NSRect { cancelButton.convert(cancelButton.bounds, to: self) }
    var confirmFrame: NSRect { confirmButton.convert(confirmButton.bounds, to: self) }
    var clearFrame: NSRect? {
        clearButton.isHidden ? nil : clearButton.convert(clearButton.bounds, to: self)
    }
    var suppressionChecked: Bool { suppressionButton?.state == .on }
    var suppressionFrame: NSRect? {
        suppressionButton.map { $0.convert($0.bounds, to: self) }
    }
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }
    var messageFrame: NSRect? {
        messageLabel.isHidden ? nil : messageLabel.convert(messageLabel.bounds, to: self)
    }

    func focusKind(in window: NSWindow) -> Int32 {
        if window.firstResponder === cancelButton { return 1 }
        if window.firstResponder === confirmButton { return 2 }
        if window.firstResponder === clearButton { return 3 }
        if window.firstResponder === suppressionButton { return 4 }
        return 0
    }

    init(title: String, message: String, placeholder: String,
         confirmTitle: String, cancelTitle: String,
         current: String = "", clearTitle: String? = nil,
         showsField: Bool = true, warning: Bool = false,
         suppressionTitle: String? = nil) {
        self.showsField = showsField
        suppressionButton = suppressionTitle.map { title in
            ThemedCheckbox(title: title) { _ in }
        }
        titleLabel = NSTextField(wrappingLabelWithString: title)
        messageLabel = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAppliedSurface(fill: LinuxTheme.color("floatingSurface"),
                          radius: Design.Radius.panel, border: Design.Surface.border)
        titleLabel.font = Design.Typography.heading()
        titleLabel.textColor = Design.Text.label
        titleLabel.maximumNumberOfLines = 0
        titleLabel.preferredMaxLayoutWidth = ThemedAlertLayout.minimumCopyWidth
        messageLabel.font = Design.Typography.body()
        messageLabel.textColor = Design.Text.secondary
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = ThemedAlertLayout.minimumCopyWidth
        messageLabel.isHidden = message.isEmpty
        mark.warning = warning
        inputField.isHidden = !showsField
        inputField.isEditable = true
        inputField.stringValue = current
        inputField.font = Design.Typography.body()
        inputField.textColor = Design.Text.label
        inputField.placeholderString = placeholder
        inputField.setAccessibilityLabel(placeholder)
        inputField.action = { [weak self] in self?.onConfirm?() }

        cancelButton.title = cancelTitle
        cancelButton.emphasis = .secondary
        cancelButton.action = { [weak self] in self?.onCancel?() }
        confirmButton.title = confirmTitle
        confirmButton.emphasis = .primary
        confirmButton.action = { [weak self] in self?.onConfirm?() }
        clearButton.isHidden = clearTitle == nil
        clearButton.title = clearTitle ?? ""
        clearButton.emphasis = .secondary
        clearButton.action = { [weak self] in self?.onClear?() }
        inputField.nextKeyView = cancelButton
        cancelButton.nextKeyView = clearTitle == nil ?
            (suppressionButton ?? confirmButton) : clearButton
        clearButton.nextKeyView = confirmButton
        confirmButton.nextKeyView = showsField ? inputField : cancelButton
        suppressionButton?.nextKeyView = confirmButton

        let copy = ThemedAlertLayout.copyStack(title: titleLabel, message: messageLabel)
        let heading = ThemedAlertLayout.heading(icon: mark, copy: copy)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, clearButton, confirmButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        var sectionViews: [NSView] = [heading]
        if showsField { sectionViews.append(inputField) }
        if let suppressionButton { sectionViews.append(suppressionButton) }
        sectionViews.append(actions)
        let sections = ThemedAlertLayout.sectionStack(sectionViews)
        addSubview(sections)
        NSLayoutConstraint.activate(
            ThemedAlertLayout.iconConstraints(mark)
            + [ThemedAlertLayout.modernTopConstraint(sections, in: self)]
            + ThemedAlertLayout.contentConstraints(sections, in: self,
                widthPeers: sectionViews))
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class LinuxAlertMark: NSView {
    var warning = false

    override func draw(_ dirtyRect: NSRect) {
        if warning {
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: bounds.midX, y: bounds.maxY - 2))
            triangle.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + 2))
            triangle.line(to: NSPoint(x: bounds.minX + 1, y: bounds.minY + 2))
            triangle.close()
            Design.Status.warning.setFill()
            triangle.fill()
            drawMark("!", on: Design.Status.warning)
            return
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        Design.Surface.accent.setFill()
        circle.fill()
        drawMark("i", on: Design.Surface.accent)
    }

    private func drawMark(_ character: String, on ground: NSColor) {
        let mark = NSAttributedString(string: character, attributes: [
            .font: Design.Typography.informationalMark(),
            .foregroundColor: Design.Ink(on: ground).label
        ])
        let size = mark.size()
        mark.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2 - 1))
    }
}
#endif
