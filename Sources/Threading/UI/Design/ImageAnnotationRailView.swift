import AppKit

// MARK: - Image Annotation Rail

/// One field per mark, numbered to match the pins on the picture beside it.
///
/// **The rail and the picture are two views of one list**, which is why neither owns it: the host
/// holds the annotations, the picture reports clicks, and this reports typing, focus and removal.
/// A rail that owned the array would have to be told about every pin dropped in the fullscreen
/// inspector, and the inspector would have to know a rail exists.
///
/// Focus is the tie. A field taking the caret reports itself, the host lights that mark, and the
/// picture redraws its pin — so "which one is this?" is answered by looking rather than by
/// counting discs. The badge in the rail lights with it, because the answer has to be visible
/// from whichever end the eye started at.
final class ImageAnnotationRailView: NSView, ThemedComponent, NSTextFieldDelegate {

    // MARK: - Properties

    var onNoteChange: ((ImageAnnotation.ID, String) -> Void)?
    var onRemove: ((ImageAnnotation.ID) -> Void)?
    var onFocus: ((ImageAnnotation.ID) -> Void)?

    var selectedAnnotationID: ImageAnnotation.ID? {
        didSet {
            guard selectedAnnotationID != oldValue else { return }
            for row in rows { row.isSelected = row.id == selectedAnnotationID }
        }
    }

    private let stack = NSStackView()
    private let emptyHint = NSTextField(labelWithString: ImageAnnotationStrings.addHint)
    private var rows: [Row] = []
    /// A colour assigned to a label freezes onto it exactly as a `CGColor` freezes onto a layer.
    /// The sweep re-resolves a recorded *font role* and cannot reach an assigned `textColor`, so
    /// the hint is repainted on the same events every themed component listens to.
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)

        emptyHint.applyFont(.caption)
        applyTheme()
        emptyHint.lineBreakMode = .byWordWrapping
        emptyHint.maximumNumberOfLines = 2
        emptyHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        stack.addArrangedSubview(emptyHint)
        emptyHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - Theme

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// Re-resolves every ink this view assigned rather than drew. `restyle()` reaches here
    /// through `ThemeRedraw`, and the badges repaint themselves because they draw in `draw(_:)`.
    private func applyTheme() {
        emptyHint.textColor = Design.Text.tertiary
        for row in rows { row.applyTheme() }
        needsDisplay = true
    }

    // MARK: - Public Methods

    /// Rebuilds the rows when the *list* changed, and only re-reads text into fields nobody is
    /// typing in.
    ///
    /// Both halves matter. A wholesale rebuild on every keystroke would take the caret away
    /// mid-word — the note field would drop a character and lose focus, which is a field that
    /// cannot be typed into. And skipping the rebuild when the ids are the same is what keeps a
    /// note arriving from the fullscreen inspector from being written over by this rail's own
    /// stale copy.
    ///
    /// Whole-stack construction is deliberate and bounded: `ImageAnnotationDefaults.maximumCount`
    /// caps the list at twenty, which is a small fixed form in the
    /// [Scaling Gate](../../../CLAUDE.md#scaling-gate) sense. The host stops offering to add
    /// beyond it rather than letting a rail grow to a size that would need virtualizing.
    func setAnnotations(_ annotations: [ImageAnnotation]) {
        let ids = annotations.map(\.id)
        guard ids != rows.map(\.id) else {
            for (index, annotation) in annotations.enumerated() where index < rows.count {
                rows[index].setNoteIfIdle(annotation.note)
            }
            return
        }

        for row in rows { row.removeFromSuperview() }
        rows = annotations.enumerated().map { index, annotation in
            let row = Row(id: annotation.id, index: index, note: annotation.note)
            row.field.delegate = self
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            row.isSelected = annotation.id == selectedAnnotationID
            return row
        }

        emptyHint.isHidden = !rows.isEmpty
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Puts the caret in one mark's field — the click-a-pin half of the tie.
    func focusNote(for id: ImageAnnotation.ID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        window?.makeFirstResponder(row.field)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        onNoteChange?(row.id, field.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        selectedAnnotationID = row.id
        onFocus?(row.id)
    }
}

// MARK: - Row

private extension ImageAnnotationRailView {

    /// One mark: its number, the sentence, and the way to take it back.
    final class Row: NSView {

        let id: ImageAnnotation.ID
        let field = ThemedTextField()
        var onRemove: ((ImageAnnotation.ID) -> Void)?

        var isSelected: Bool = false {
            didSet {
                guard isSelected != oldValue else { return }
                badge.isSelected = isSelected
            }
        }

        private let badge: BadgeView

        init(id: ImageAnnotation.ID, index: Int, note: String) {
            self.id = id
            badge = BadgeView(index: index)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            field.stringValue = note
            field.placeholderString = ImageAnnotationStrings.notePlaceholder(index: index)
            field.setAccessibilityIdentifier(
                ImageAnnotationIdentifiers.note(index: index)
            )
            field.setAccessibilityLabel(ImageAnnotationStrings.accessibilityLabel(index: index))

            let remove = ThemedIconButton(
                symbolName: "xmark",
                accessibility: ImageAnnotationStrings.removeTitle,
                target: .inline
            )
            remove.onPress = { [weak self] in
                guard let self else { return }
                self.onRemove?(self.id)
            }

            let row = NSStackView(views: [badge, field, remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Design.Spacing.small
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func applyTheme() {
            badge.needsDisplay = true
        }

        /// Takes an updated note only when the caret is somewhere else. See `setAnnotations`.
        func setNoteIfIdle(_ note: String) {
            guard field.currentEditor() == nil, field.stringValue != note else { return }
            field.stringValue = note
        }
    }

    /// The rail's own copy of the pin, drawn by the same code that draws it on the picture so
    /// the two cannot drift into being two different marks.
    final class BadgeView: NSView {

        private let index: Int
        private var themeRedraw: ThemeRedraw?

        var isSelected: Bool = false {
            didSet {
                guard isSelected != oldValue else { return }
                needsDisplay = true
            }
        }

        init(index: Int) {
            self.index = index
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            themeRedraw = ThemeRedraw(self)
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: ImageAnnotationDefaults.pinDiameter),
                heightAnchor.constraint(equalToConstant: ImageAnnotationDefaults.pinDiameter)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { false }

        /// Decorative: the field beside it carries the accessible name, and a second element
        /// announcing "1" would make every annotation two stops in the rotor.
        override func isAccessibilityElement() -> Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            ImageAnnotationMarks.draw(
                label: ImageAnnotationMarks.label(forIndex: index),
                at: NSPoint(x: bounds.midX, y: bounds.midY),
                isSelected: isSelected
            )
        }
    }
}

// MARK: - Identifiers

enum ImageAnnotationIdentifiers {
    static func note(index: Int) -> String { "annotation.note.\(index)" }
    static let rail = "annotation.rail"
    static let image = "annotation.image"
}

// MARK: - Inspector Strings

enum MediaInspectorAnnotationStrings {
    static var toggle: String { L10n.string("Mark up this image") }
}
