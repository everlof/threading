import AppKit

/// A field that captures a key chord: click it, press the combination, and that becomes the
/// binding.
///
/// **It has to swallow key equivalents while recording, and that is the whole difficulty.** The
/// menu bar matches `performKeyEquivalent` before any view sees `keyDown`, so a recorder that
/// only overrode `keyDown` could never capture a chord that is already bound — pressing ⌘N to
/// rebind New Session would simply open a new session. Returning true from
/// `performKeyEquivalent` while armed is what makes the common case (rebinding something that
/// already works) possible at all.
///
/// Escape cancels without changing anything and Delete clears the binding, so the two ways out
/// are the two the platform already teaches.
final class ShortcutRecorderView: ThemedControl {

    enum Presentation {
        case persistent
        /// Quiet shortcut text that reveals its control plate on hover, focus or recording.
        case inline
    }

    // MARK: - Properties

    /// The chord shown when not recording. Setting it redraws but does not report.
    var shortcut: KeyboardShortcut? {
        didSet { needsDisplay = true }
    }

    /// Reports a captured chord, or nil when the user cleared it. Not called for a cancel.
    var onRecord: ((KeyboardShortcut?) -> Void)?

    var onRecordingChange: ((Bool) -> Void)?

    /// Drawn under the chord when the binding collides with another command.
    var conflictText: String? {
        didSet { needsDisplay = true }
    }

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            onRecordingChange?(isRecording)
        }
    }

    private let presentation: Presentation

    // MARK: - Initialization

    init(shortcut: KeyboardShortcut?, presentation: Presentation = .persistent) {
        self.shortcut = shortcut
        self.presentation = presentation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    /// While armed this consumes *everything*, so an already-bound chord reaches `keyDown`
    /// instead of firing its command. Unarmed it defers, so the menu keeps working normally.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return }

        // Escape leaves the binding as it was; Delete removes it. Both end the recording, so
        // there is never a state where the control is armed and the user has stopped looking.
        if raw == "\u{1B}" {
            isRecording = false
            return
        }
        if raw == "\u{7F}" || raw == "\u{8}" {
            isRecording = false
            shortcut = nil
            onRecord?(nil)
            return
        }

        // Lowercased with Shift kept in the mask: a menu key equivalent of "R" already implies
        // Shift, so recording both would double it and the item would never match.
        let candidate = KeyboardShortcut(key: raw.lowercased(), modifiers: event.modifierFlags)
        guard candidate.isValid else { return }

        isRecording = false
        shortcut = candidate
        onRecord?(candidate)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let appearance = surfaceAppearance
        let shape = ThemedSurface.draw(
            bounds,
            fill: appearance.fill,
            border: appearance.border,
            radius: Design.Radius.control
        )

        drawLabel()
        drawKeyboardFocus(around: shape)
    }

    private func drawLabel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = presentation == .inline ? .right : .center
        // Measured and drawn with the same attributes, and told to truncate: a title a hair too
        // wide for its rect otherwise wraps and draws its tail below the control.
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.code(),
            .foregroundColor: labelColor,
            .paragraphStyle: paragraph
        ]

        let text = labelText as NSString
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(
            x: ShortcutRecorderDefaults.textInset,
            y: (bounds.height - size.height) / 2,
            width: max(bounds.width - ShortcutRecorderDefaults.textInset * 2, 0),
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }

    private var labelText: String {
        if isRecording { return ShortcutRecorderStrings.recording }
        return shortcut?.displayString ?? ShortcutRecorderStrings.unbound
    }

    private var labelColor: NSColor {
        if isRecording { return Design.Text.label }
        guard isEnabled else { return Design.Text.quaternary }
        if conflictText != nil { return Design.Status.negative }
        if presentation == .inline, !isHovered, !hasKeyboardFocus {
            return shortcut == nil ? Design.Text.tertiary : Design.Text.secondary
        }
        return shortcut == nil ? Design.Text.tertiary : Design.Text.label
    }

    private var surfaceAppearance: (fill: NSColor, border: NSColor?) {
        if isRecording {
            return (
                Design.Surface.accent.withAlphaComponent(ShortcutRecorderDefaults.armedFill),
                Design.Surface.accent
            )
        }
        if presentation == .inline {
            guard isHovered || hasKeyboardFocus else { return (.clear, nil) }
            return (Design.Surface.controlHover, Design.Surface.border)
        }
        return (Design.Surface.controlResting, Design.Surface.border)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ShortcutRecorderDefaults.width, height: ShortcutRecorderDefaults.height)
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        ShortcutRecorderStrings.accessibilityLabel
    }

    override func accessibilityValue() -> Any? {
        labelText
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }
}

// MARK: - Defaults

enum ShortcutRecorderDefaults {
    static let width: CGFloat = 110
    static let height: CGFloat = 22
    static let textInset: CGFloat = 6

    /// The armed fill is the accent held well back — a recorder waiting for a key should read as
    /// live without becoming the loudest thing on a page of them.
    static let armedFill: CGFloat = 0.18
}

enum ShortcutRecorderStrings {
    static var recording: String { L10n.string("Press keys…") }
    static let unbound = "—"
    static var accessibilityLabel: String { L10n.string("Keyboard shortcut") }
}
