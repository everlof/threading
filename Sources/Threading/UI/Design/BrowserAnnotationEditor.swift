import AppKit

/// One native, nonmodal note editor. The browser owns the draft and its page identity; no note
/// text crosses into WebKit. Only this fixed-size form exists, regardless of the number of pins.
final class BrowserAnnotationEditor: NSView, ThemedComponent, ThemeDerivedContent, NSTextFieldDelegate {
    let noteField = ThemedTextField()
    let saveButton = ThemedButton(title: L10n.string("Save"), target: nil, action: nil)
    let deleteButton = ThemedButton(title: L10n.string("Delete Annotation"), target: nil, action: nil)
    let cancelButton = ThemedIconButton(symbolName: "xmark", accessibility: L10n.string("Cancel"), target: .inline)
    private let titleLabel = NSTextField(labelWithString: "")
    private let surface = BrowserAnnotationSurfaceView(frame: .zero)
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?

    var note: String { noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(identifier: Int, note: String, isExisting: Bool) {
        super.init(frame: .zero)
        titleLabel.stringValue = L10n.format("Annotation %@", String(identifier))
        titleLabel.applyFont(.detail(weight: .semibold))
        titleLabel.textColor = Design.Text.label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteField.stringValue = note
        noteField.placeholderString = L10n.string("What should the agent notice?")
        noteField.setAccessibilityLabel(noteField.placeholderString)
        noteField.setAccessibilityIdentifier("browser.annotation.note")
        noteField.delegate = self
        noteField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        noteField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.emphasis = .primary
        deleteButton.target = self
        deleteButton.action = #selector(deleteNote)
        deleteButton.isHidden = !isExisting
        cancelButton.onPress = { [weak self] in self?.onCancel?() }
        saveButton.isEnabled = !self.note.isEmpty

        let header = NSStackView(views: [titleLabel, NSView(), cancelButton])
        let actions = NSStackView(views: [deleteButton, NSView(), saveButton])
        for row in [header, actions] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Design.Spacing.small
        }
        let stack = NSStackView(views: [header, noteField, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.medium),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noteField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rederiveThemedContent()
    }

    func rederiveThemedContent() {
        titleLabel.textColor = Design.Text.label
        superview?.needsLayout = true
    }

    func focusNote() {
        window?.makeFirstResponder(noteField)
        noteField.currentEditor()?.selectedRange = NSRange(location: noteField.stringValue.utf16.count, length: 0)
    }

    func controlTextDidChange(_ notification: Notification) {
        saveButton.isEnabled = !note.isEmpty
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { save(); return true }
        return false
    }

    @objc private func save() { if !note.isEmpty { onSave?() } }
    @objc private func deleteNote() { onDelete?() }
}
