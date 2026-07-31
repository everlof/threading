import AppKit

/// App-owned, themed alert presentation.
///
/// Its small API intentionally mirrors the subset the app used: title and message, ordered
/// buttons, an optional accessory, a suppression choice, modal or sheet presentation, and the
/// ordinary alert response values. The visual surface is ours; AppKit still owns sheet
/// attachment, modal dispatch, focus, windows, and assistive-technology transport.
@MainActor
final class ThemedAlert {

    enum Style {
        case informational
        case warning
        case critical
    }

    /// AppKit's documented first-button response value, kept here so callers reason in button
    /// indexes instead of coupling themselves to system alert chrome.
    static let firstButtonResponse = NSApplication.ModalResponse(rawValue: 1_000)

    final class Button {
        var title: String
        var isEnabled = true
        var hasDestructiveAction = false
        var keyEquivalent = ""

        init(title: String) { self.title = title }
    }

    final class SuppressionButton {
        var title = ""
        var state: NSControl.StateValue = .off
    }

    var messageText = ""
    var informativeText = ""
    var alertStyle: Style = .warning
    var accessoryView: NSView?
    var initialFirstResponder: NSResponder?

    private(set) var buttons: [Button] = []
    private(set) var suppressionButton: SuppressionButton?
    var showsSuppressionButton = false {
        didSet {
            if showsSuppressionButton, suppressionButton == nil {
                suppressionButton = SuppressionButton()
            } else if !showsSuppressionButton {
                suppressionButton = nil
            }
        }
    }

    private(set) var presentedWindow: NSWindow?
    private weak var parentWindow: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private var sheetCompletion: ((NSApplication.ModalResponse) -> Void)?
    private var isModal = false

    init() {}

    convenience init(error: Error) {
        self.init()
        alertStyle = .critical
        messageText = error.localizedDescription
        let nsError = error as NSError
        informativeText = nsError.localizedFailureReason
            ?? nsError.localizedRecoverySuggestion
            ?? ""
    }

    func addButton(withTitle title: String) {
        let button = Button(title: title)
        if buttons.isEmpty { button.keyEquivalent = "\r" }
        buttons.append(button)
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        prepareDefaultButtonIfNeeded()
        let panel = makePanel()
        isModal = true
        previousKeyWindow = NSApp.keyWindow
        previousFirstResponder = previousKeyWindow?.firstResponder

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        focusInitialResponder(in: panel)
        NSAccessibility.post(element: panel, notification: .created)
        let response = NSApp.runModal(for: panel)
        cleanup(panel: panel, restoring: previousKeyWindow)
        return response
    }

    func beginSheetModal(
        for window: NSWindow,
        completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        prepareDefaultButtonIfNeeded()
        parentWindow = window
        previousFirstResponder = window.firstResponder
        sheetCompletion = completionHandler
        let panel = makePanel()

        window.beginSheet(panel) { [weak self, weak panel] response in
            guard let self, let panel else { return }
            let completion = self.sheetCompletion
            self.sheetCompletion = nil
            self.cleanup(panel: panel, restoring: window)
            completion?(response)
        }
        focusInitialResponder(in: panel)
        NSAccessibility.post(element: panel, notification: .created)
    }

    /// Builds the actual themed dialog tree without presenting it, for gallery and behavior tests.
    func makeContentView() -> NSView {
        prepareDefaultButtonIfNeeded()
        return ThemedAlertContentView(alert: self) { [weak self] index in
            self?.finish(with: Self.response(forButtonAt: index))
        }
    }

    static func response(forButtonAt index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(
            rawValue: firstButtonResponse.rawValue + index
        )
    }

    private func prepareDefaultButtonIfNeeded() {
        if buttons.isEmpty { addButton(withTitle: L10n.string("OK")) }
    }

    private func makePanel() -> ThemedAlertPanel {
        if let existing = presentedWindow as? ThemedAlertPanel { return existing }
        let content = makeContentView()
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)

        let panel = ThemedAlertPanel(contentSize: size)
        panel.contentView = content
        panel.onCancel = { [weak self] in self?.finish(with: .abort) }
        panel.appearance = parentWindow?.appearance ?? NSApp.keyWindow?.appearance
        presentedWindow = panel
        return panel
    }

    private func focusInitialResponder(in panel: NSWindow) {
        let responder = initialFirstResponder
            ?? (panel.contentView as? ThemedAlertContentView)?.preferredFirstResponder
        if let responder { panel.makeFirstResponder(responder) }
    }

    private func finish(with response: NSApplication.ModalResponse) {
        guard let panel = presentedWindow else { return }
        if isModal {
            NSApp.stopModal(withCode: response)
            panel.orderOut(nil)
        } else if let parentWindow {
            parentWindow.endSheet(panel, returnCode: response)
        } else {
            panel.orderOut(nil)
            cleanup(panel: panel, restoring: previousKeyWindow)
            let completion = sheetCompletion
            sheetCompletion = nil
            completion?(response)
        }
    }

    private func cleanup(panel: NSWindow, restoring window: NSWindow?) {
        panel.orderOut(nil)
        presentedWindow = nil
        parentWindow = nil
        isModal = false

        guard let window else { return }
        window.makeKey()
        if let responder = previousFirstResponder,
           responder.isResponder(in: window) {
            window.makeFirstResponder(responder)
        }
    }
}

// MARK: - Panel

@MainActor
private final class ThemedAlertPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .documentWindow
        setAccessibilitySubrole(.dialog)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Escape belongs to the dialog even while its field editor is first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1b}" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Content

@MainActor
private final class ThemedAlertContentView: NSView, ThemedComponent {
    private enum Layout {
        static let minimumContentWidth: CGFloat = 360
        static let maximumTextWidth: CGFloat = 500
        static let iconSize: CGFloat = 30
        static let checkboxHeight: CGFloat = Design.Size.chipHeight
    }

    private let alert: ThemedAlert
    private let choose: (Int) -> Void
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let iconView = NSImageView()
    private var buttonControls: [ThemedButton] = []
    private var checkbox: ThemedCheckbox?
    private let appEvents = AppEventObservations()

    var preferredFirstResponder: NSResponder? {
        alert.initialFirstResponder
            ?? buttonControls.first(where: { $0.keyEquivalent == "\r" && $0.isEnabled })
            ?? buttonControls.first(where: \.isEnabled)
    }

    init(alert: ThemedAlert, choose: @escaping (Int) -> Void) {
        self.alert = alert
        self.choose = choose
        titleLabel = NSTextField(wrappingLabelWithString: alert.messageText)
        messageLabel = NSTextField(wrappingLabelWithString: alert.informativeText)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }

    private func setup() {
        titleLabel.applyFont(.heading)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.preferredMaxLayoutWidth = Layout.maximumTextWidth

        messageLabel.applyFont(.body)
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = Layout.maximumTextWidth
        messageLabel.isHidden = alert.informativeText.isEmpty

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize)
        ])

        let copy = NSStackView(views: [titleLabel, messageLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = Design.Spacing.small
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSStackView(views: [iconView, copy])
        heading.orientation = .horizontal
        heading.alignment = .top
        heading.spacing = Design.Spacing.inset

        var sections: [NSView] = [heading]
        if let accessory = alert.accessoryView {
            sections.append(wrappedAccessory(accessory))
        }
        if let suppression = alert.suppressionButton {
            let checkbox = ThemedCheckbox(
                title: suppression.title,
                state: suppression.state
            ) { state in
                suppression.state = state
            }
            self.checkbox = checkbox
            sections.append(checkbox)
        }
        sections.append(makeButtonRow())

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.large),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.large),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.large),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumContentWidth),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for section in sections.dropFirst() {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        setAccessibilityRole(.group)
        setAccessibilityLabel(alert.messageText)
        applyTheme()
    }

    private func wrappedAccessory(_ accessory: NSView) -> NSView {
        let size = NSSize(
            width: max(1, accessory.frame.width > 0 ? accessory.frame.width : accessory.fittingSize.width),
            height: max(1, accessory.frame.height > 0 ? accessory.frame.height : accessory.fittingSize.height)
        )
        let wrapper = NSView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.topAnchor.constraint(equalTo: wrapper.topAnchor),
            accessory.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            accessory.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            wrapper.widthAnchor.constraint(greaterThanOrEqualToConstant: size.width),
            wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: size.height)
        ])
        return wrapper
    }

    private func makeButtonRow() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        let defaultIndex = alert.buttons.firstIndex(where: { $0.keyEquivalent == "\r" }) ?? 0
        for index in alert.buttons.indices.reversed() {
            let model = alert.buttons[index]
            let button = ThemedButton(title: model.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = index
            button.isEnabled = model.isEnabled
            button.keyEquivalent = model.keyEquivalent
            button.emphasis = index == defaultIndex ? .primary : .secondary
            if model.hasDestructiveAction, index != defaultIndex {
                button.contentTintColor = Design.Status.negative
            }
            row.addArrangedSubview(button)
            buttonControls.append(button)
        }
        return row
    }

    @objc private func buttonPressed(_ sender: ThemedButton) {
        choose(sender.tag)
    }

    private func applyTheme() {
        titleLabel.textColor = Design.Text.label
        messageLabel.textColor = Design.Text.secondary
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Layout.iconSize, weight: .medium))
        iconView.contentTintColor = symbolColor
        needsDisplay = true
        window?.invalidateShadow()
    }

    private var symbolName: String {
        switch alert.alertStyle {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    private var symbolColor: NSColor {
        switch alert.alertStyle {
        case .critical: Design.Status.negative
        case .warning: Design.Status.warning
        default: Design.Surface.accent
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.elevated,
            border: Design.Surface.border,
            radius: Design.Radius.panel
        )
    }
}

private extension NSResponder {
    @MainActor
    func isResponder(in window: NSWindow) -> Bool {
        if self === window { return true }
        return (self as? NSView)?.window === window
    }
}
