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

        /// A *chord* this button answers to, and draws on its face — `⌘↩` beside "Send".
        ///
        /// Separate from `keyEquivalent` because the two match differently: a key equivalent
        /// answers its character whatever is held with it, which is what a sheet's Return and
        /// Escape want, and exactly wrong for a sheet that offers Return and ⌘Return as two
        /// different answers. Setting this on any button therefore restates the plain Return
        /// as an exact-match chord too — see `makeButtonRow`.
        var shortcut: KeyboardShortcut?

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

    @discardableResult
    func addButton(withTitle title: String) -> Button {
        let button = Button(title: title)
        if buttons.isEmpty { button.keyEquivalent = "\r" }
        buttons.append(button)
        return button
    }

    /// What each button ends up answering to once the sheet is read as a whole.
    ///
    /// **Return stops being a key equivalent the moment ⌘Return is also an answer.**
    /// `ThemedButton.keyEquivalent` matches its character whatever is held with it, so a sheet
    /// offering both "Add to Chat" (↩) and "Send" (⌘↩) would answer both chords with whichever
    /// button the view tree reached first — the accelerated one is unreachable, or the default
    /// one is, depending on subview order. Where a sibling carries a modifier-bearing chord on
    /// the same key, the plain one is restated as an exact-match `shortcut`, which also puts
    /// `↩` on its face beside the sibling's `⌘↩`: a pair is only findable if both are drawn.
    ///
    /// A whole-sheet answer rather than a per-button one, and public so it can be read without
    /// running a modal.
    static func resolvedChords(
        for buttons: [Button]
    ) -> [(keyEquivalent: String, shortcut: KeyboardShortcut?)] {
        let acceleratedKeys = Set(buttons.compactMap { model -> String? in
            guard let shortcut = model.shortcut, !shortcut.modifiers.isEmpty else { return nil }
            return shortcut.key
        })
        return buttons.map { model in
            guard !model.keyEquivalent.isEmpty,
                  acceleratedKeys.contains(model.keyEquivalent) else {
                return (model.keyEquivalent, model.shortcut)
            }
            return ("", KeyboardShortcut(key: model.keyEquivalent, modifiers: []))
        }
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

    /// Ends the presentation without a button having been chosen.
    ///
    /// Exists for callers whose dialog can be *overtaken* — a software-update stage that
    /// Sparkle moves past, a progress sheet whose work finished — where waiting for a click
    /// would leave a dead sheet describing a state that no longer exists. Answers `.abort`
    /// (or the caller's stated response) through the ordinary completion path, and does
    /// nothing when nothing is presented.
    func dismiss(with response: NSApplication.ModalResponse = .abort) {
        guard presentedWindow != nil else { return }
        finish(with: response)
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

    /// Workbench's DiskCopy requester documents left-Amiga+V for Continue and left-Amiga+B for
    /// Cancel. On macOS the Amiga key is the Command modifier; keeping the mapping here lets the
    /// panel consume only those two source-backed chords while every other period requester
    /// retains its ordinary Return/Escape contract.
    static func workbenchShortcutIndex(for key: String) -> Int? {
        switch key.lowercased() {
        case "v": return 0
        case "b": return 1
        default: return nil
        }
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
        panel.onWorkbenchShortcut = { [weak self] key in
            self?.finishWorkbenchShortcut(key) ?? false
        }
        panel.appearance = parentWindow?.appearance ?? NSApp.keyWindow?.appearance
        presentedWindow = panel
        return panel
    }

    private func finishWorkbenchShortcut(_ key: String) -> Bool {
        let material = AppThemePalette.current.material(for: NSApp.effectiveAppearance)
        guard material.menuAppearance == .amiga,
              let index = Self.workbenchShortcutIndex(for: key),
              index < buttons.count,
              buttons[index].isEnabled else { return false }
        finish(with: Self.response(forButtonAt: index))
        return true
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
    var onWorkbenchShortcut: ((String) -> Bool)?

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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           onWorkbenchShortcut?(key) == true {
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
    private let requesterTitleBand: ThemedAlertRequesterTitleBandView
    private let iconView = NSImageView()
    private var buttonControls: [ThemedButton] = []
    private var checkbox: ThemedCheckbox?
    private var requesterMessageWell: ThemedAlertRequesterMessageWellView?
    private weak var sectionStack: NSStackView?
    private var modernStackTopConstraint: NSLayoutConstraint?
    private var requesterStackTopConstraint: NSLayoutConstraint?
    private let appEvents = AppEventObservations()

    /// Period requester materials do not carry the modern status-symbol heading. Their source
    /// dialogs are compact, square, and text-led; the same popover grammar that drives their
    /// transient cards is the data-backed signal for this presentation.
    private var usesClassicRequester: Bool {
        AppThemePalette.current
            .material(for: effectiveAppearance)
            .popoverStyle
            .glyphStyle == .classic
    }

    /// Indigo Magic's measured logout requester is still a square classic requester, but unlike
    /// Workbench it carries a bright green question mark field beside the message well.
    private var usesIRIXRequester: Bool {
        AppThemePalette.current
            .material(for: effectiveAppearance)
            .menuAppearance == .irix
    }

    var preferredFirstResponder: NSResponder? {
        alert.initialFirstResponder
            ?? buttonControls.first(where: { $0.answersReturn && $0.isEnabled })
            ?? buttonControls.first(where: \.isEnabled)
    }

    init(alert: ThemedAlert, choose: @escaping (Int) -> Void) {
        self.alert = alert
        self.choose = choose
        titleLabel = NSTextField(wrappingLabelWithString: alert.messageText)
        messageLabel = NSTextField(wrappingLabelWithString: alert.informativeText)
        requesterTitleBand = ThemedAlertRequesterTitleBandView(title: alert.messageText)
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
        titleLabel.applyFont(usesClassicRequester ? .controlRegular : .heading)
        titleLabel.isHidden = usesClassicRequester
        titleLabel.maximumNumberOfLines = 0
        titleLabel.preferredMaxLayoutWidth = Layout.maximumTextWidth

        messageLabel.applyFont(usesClassicRequester ? .controlRegular : .body)
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

        let messageSection = ThemedAlertRequesterMessageWellView(contentView: heading)
        requesterMessageWell = messageSection
        var sections: [NSView] = [messageSection]
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
        sectionStack = stack
        requesterTitleBand.isHidden = !usesClassicRequester
        addSubview(requesterTitleBand)
        addSubview(stack)

        let modernTop = stack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: Design.Spacing.large
        )
        let requesterTop = stack.topAnchor.constraint(
            equalTo: requesterTitleBand.bottomAnchor,
            constant: Design.Spacing.small
        )
        modernTop.isActive = !usesClassicRequester
        requesterTop.isActive = usesClassicRequester
        modernStackTopConstraint = modernTop
        requesterStackTopConstraint = requesterTop

        NSLayoutConstraint.activate([
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.large),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.large),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumContentWidth),
            messageSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            requesterTitleBand.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            requesterTitleBand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            requesterTitleBand.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            requesterTitleBand.heightAnchor.constraint(
                equalToConstant: WindowChromeAppearance.resolve()?.bandHeight ?? 18
            )
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
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        let defaultIndex = alert.buttons.firstIndex(where: { $0.keyEquivalent == "\r" }) ?? 0

        // **A destructive confirmation has no primary.** Prominence normally follows Return,
        // which is right where the default *is* the action — a grant, an ordinary OK. It is
        // wrong here, because `ConfirmationAlert.applyDefaultButton` deliberately moves Return
        // to Cancel for an `.irreversible` prompt: the accent fill then landed on Cancel, and
        // on a theme whose accent is its negative colour — Swiss Minimalist is `#D6180B` for
        // both — the loudest, reddest thing in a delete dialog was the button that does not
        // delete, beside a Delete drawn as the quiet one.
        //
        // Filling the *action* instead was the other candidate and is worse: it makes the
        // irreversible button the most clickable thing on a sheet whose whole purpose is to
        // slow the user down. So neither is filled. What is left says it plainly: Delete is the
        // only red thing, and the ring says Return is on Cancel.
        //
        // This once carried a second reason — that two secondaries also came out the same size,
        // where a filled one read 4pt shorter than the bordered button beside it. That was the
        // focus ring eating the edge of its own fill, it was never a property of destructive
        // dialogs, and it is fixed in `ThemedButton` now. The rule above rests on what the
        // colours mean, which is the only thing it ever should have rested on.
        let hasDestructiveAction = alert.buttons.contains(where: \.hasDestructiveAction)

        // See `ThemedAlert.resolvedChords` for why a plain Return is sometimes restated.
        let chords = ThemedAlert.resolvedChords(for: alert.buttons)

        // AppKit's modern sheet convention places the last-added Cancel at the leading edge
        // after this row's spacer. Workbench's requester figure is the opposite: Continue is
        // the leading gadget and Cancel bookends the trailing edge. The same compact requester
        // grammar is used by the other indexed/classic materials, so their authored action order
        // remains visible instead of inheriting the modern sheet reversal.
        let indices = usesClassicRequester
            ? Array(alert.buttons.indices)
            : Array(alert.buttons.indices.reversed())
        for index in indices {
            let model = alert.buttons[index]
            let button = ThemedButton(title: model.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = index
            button.isEnabled = model.isEnabled
            button.keyEquivalent = chords[index].keyEquivalent
            button.shortcut = chords[index].shortcut
            button.emphasis = !hasDestructiveAction && index == defaultIndex ? .primary : .secondary
            if model.hasDestructiveAction {
                button.contentTintColor = Design.Status.negative
            }
            row.addArrangedSubview(button)
            buttonControls.append(button)
        }
        // Modern sheets keep the whole row trailing. A classic requester uses the same spare
        // width as the source figure: its first action is leading and its cancellation gadget is
        // trailing, with the empty rail between them.
        if usesClassicRequester {
            row.insertArrangedSubview(spacer, at: min(1, row.arrangedSubviews.count))
        } else {
            row.insertArrangedSubview(spacer, at: 0)
        }
        return row
    }

    @objc private func buttonPressed(_ sender: ThemedButton) {
        choose(sender.tag)
    }

    private func applyTheme() {
        if usesClassicRequester {
            titleLabel.applyFont(.controlRegular)
            messageLabel.applyFont(.controlRegular)
            titleLabel.isHidden = true
            iconView.isHidden = !usesIRIXRequester
            titleLabel.textColor = Design.Text.label
            messageLabel.textColor = Design.Text.label
            if usesIRIXRequester {
                iconView.image = Self.irixQuestionImage()
                iconView.contentTintColor = nil
            } else {
                iconView.image = nil
            }
        } else {
            titleLabel.applyFont(.heading)
            messageLabel.applyFont(.body)
            titleLabel.isHidden = false
            iconView.isHidden = false
            titleLabel.textColor = Design.Text.label
            messageLabel.textColor = Design.Text.secondary
            iconView.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(Design.Symbol.configuration(Layout.iconSize, weight: .medium))
            iconView.contentTintColor = symbolColor
        }
        requesterTitleBand.isHidden = !usesClassicRequester
        // Constraint activation is not atomic. Deactivate the outgoing top edge before enabling
        // the incoming one so a live theme change never briefly asks the stack to sit at both
        // the modern inset and below the requester band. That transient overlap was enough for
        // AppKit to break the requester's required band-height constraint while the gallery
        // cycled between classic and modern materials.
        if usesClassicRequester {
            modernStackTopConstraint?.isActive = false
            requesterStackTopConstraint?.isActive = true
        } else {
            requesterStackTopConstraint?.isActive = false
            modernStackTopConstraint?.isActive = true
        }
        sectionStack?.spacing = usesClassicRequester ? Design.Spacing.small : Design.Spacing.large
        needsDisplay = true
        window?.invalidateShadow()
    }

    /// The source crop is a 30px square green field with a one-pixel black rule and a one-bit
    /// question mark. It is made as an indexed-looking image here instead of borrowing a modern
    /// SF Symbol, whose rounded outline and anti-aliased fill would erase the measured grammar.
    private static func irixQuestionImage() -> NSImage {
        let size = NSSize(width: 30, height: 30)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(false)

        let face = NSRect(x: 1, y: 1, width: 28, height: 28)
        // A measured stock-artwork pixel, not the theme's semantic positive role. Conflating
        // them made the IRIX theme fail the same contrast contract authored themes must pass:
        // #55D555 is almost indistinguishable from its gray application ground.
        NSColor(hex: "#55D555")!.setFill()
        face.fill()
        Design.Surface.border.setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: 29, height: 29))
        border.lineWidth = 1
        border.stroke()

        let font = Design.Typography.classicRequesterMark()
        let mark = NSAttributedString(
            string: "?",
            attributes: [.font: font, .foregroundColor: Design.Text.label]
        )
        let measured = mark.size()
        mark.draw(at: NSPoint(
            x: floor(size.width / 2 - measured.width / 2),
            y: floor(size.height / 2 - measured.height / 2) - 1
        ))
        return image
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
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        let popover = material.popoverStyle
        // Anchored Help Tags and modal alerts share the presentation model but not their
        // semantic surface. Aqua's Help Tag is pale yellow; an Empty Trash sheet remains the
        // authored floating gray/white sheet, so alerts always consume floatingSurface here.
        let fill = AppThemePalette.color(.floatingSurface)
        let edge: NSColor? = popover.edge == .none ? nil : Design.Surface.border
        let bevel: SurfaceBevel = popover.edge == .material
            ? .automatic
            : .none
        ThemedSurface.draw(
            bounds,
            fill: fill,
            border: edge,
            radius: Design.Radius.panel,
            bevel: bevel
        )
    }
}

/// The title strip on an indexed requester is part of the dialog, not the host window. Keeping it
/// as a design component lets the alert carry the Workbench depth gadget and one-bit caption even
/// when it is rendered into a borderless sheet panel.
@MainActor
private final class ThemedAlertRequesterTitleBandView: NSView, ThemedComponent {
    private let title: String
    private let depthButton = WindowChromeButton(role: .depth)
    private let appEvents = AppEventObservations()

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        depthButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(depthButton)
        NSLayoutConstraint.activate([
            depthButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            depthButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            depthButton.widthAnchor.constraint(equalToConstant: 18),
            depthButton.heightAnchor.constraint(equalToConstant: 16)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
            self?.depthButton.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let resolved = WindowChromeAppearance.resolve()
        let gradient = resolved?.activeGradient
        if let gradient,
           gradient.colors.count >= 2,
           !gradient.colors.dropFirst().allSatisfy({ $0 == gradient.colors[0] }),
           let drawn = NSGradient(
               colors: gradient.colors,
               atLocations: gradient.locations,
               colorSpace: .sRGB
           ) {
            drawn.draw(in: bounds, angle: 90 - gradient.angleDegrees)
        } else {
            (gradient?.colors.first ?? Design.Surface.controlResting).setFill()
            bounds.fill()
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current else { return }
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)

        let base = resolved?.glyphStyle == .irix
            ? Design.Typography.detail(weight: .bold)
            : Design.Typography.controlRegular()
        let sized = resolved?.titleFontSize.flatMap {
            NSFont(descriptor: base.fontDescriptor, size: $0)
        } ?? base
        let font = resolved?.titleFontStyle == .italic
            ? NSFontManager.shared.convert(sized, toHaveTrait: .italicFontMask)
            : sized
        let ink = resolved?.ink ?? Design.Text.label
        let attributed = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: ink]
        )
        let measured = attributed.size()
        let origin = NSPoint(
            x: 4,
            y: floor(bounds.midY - measured.height / 2)
        )
        attributed.draw(at: origin)

        Design.Surface.border.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }
}

/// The framed copy well inside a Workbench requester. It owns only the indexed field relief;
/// the contained heading stack keeps AppKit's text/accessory semantics from the modern alert.
@MainActor
private final class ThemedAlertRequesterMessageWellView: NSView, ThemedComponent {
    private let contentView: NSView
    private lazy var topInset = contentView.topAnchor.constraint(equalTo: topAnchor, constant: 4)
    private lazy var bottomInset = contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
    private lazy var leadingInset = contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
    private lazy var trailingInset = contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
    private let appEvents = AppEventObservations()

    private var usesClassicRequester: Bool {
        AppThemePalette.current
            .material(for: effectiveAppearance)
            .popoverStyle
            .glyphStyle == .classic
    }

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([topInset, bottomInset, leadingInset, trailingInset])
        applyTheme()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }

    private func applyTheme() {
        let inset: CGFloat = usesClassicRequester ? 4 : 0
        topInset.constant = inset
        bottomInset.constant = -inset
        leadingInset.constant = inset
        trailingInset.constant = -inset
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesClassicRequester else { return }
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.field,
            border: Design.Surface.border,
            radius: 0,
            bevel: .sunken
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
