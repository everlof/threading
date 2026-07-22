import AppKit

/// A primary text input: a rounded container holding the field and its submit control.
///
/// Built as a container rather than a bordered `NSTextField` so the submit affordance can sit
/// inside it, which is what makes the whole thing read as one input rather than a form row.
///
/// The field is an `NSTextView`, not an `NSTextField`, for two reasons a single-line field
/// cannot serve: a task worth describing runs past one line, and what is dropped onto a
/// composer is as often an image as it is text. It **grows with its content** up to
/// `Design.Size.inputMaxHeight` and scrolls beyond that, so a long prompt stays visible
/// without the box eating the pane.
final class PromptView: NSView {

    // MARK: - Properties

    private let scrollView = NSScrollView()
    private let textView = PromptTextView()
    private let submitButton = NSButton()

    /// Drives the growth. Held so the height can be recomputed as the text changes.
    private var heightConstraint: NSLayoutConstraint?

    /// Called when the prompt is submitted, by Return or by the button.
    var onSubmit: ((String) -> Void)?

    /// Called on every edit. Exists so what is typed can be kept somewhere it survives the
    /// app, rather than only in this field.
    var onChange: ((String) -> Void)?

    /// Placeholder shown while empty. Set before the view is added.
    var placeholder: String = "" {
        didSet { textView.placeholder = placeholder }
    }

    /// How tall the box is before any text is in it.
    ///
    /// A composer that owns its whole pane opens taller than one docked in a row: the size of
    /// the box is what says how much is expected of it, and a one-line slot in an empty pane
    /// asks for one line.
    var minimumHeight: CGFloat = Design.Size.inputHeight {
        didSet { updateHeight() }
    }

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.needsDisplay = true

            // A restored draft is read from its beginning. Setting the text leaves the view
            // scrolled to the end, which shows the tail of a long prompt and reads as though
            // the start of it had been lost.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

            updateSubmitState()
            updateHeight()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(
            fill: Design.Surface.panel,
            radius: Design.Radius.panel,
            border: Design.Surface.border,
            glow: true
        )

        setupTextView()

        submitButton.image = NSImage(
            systemSymbolName: DesignSymbols.submit,
            accessibilityDescription: "Start session"
        )
        submitButton.isBordered = false
        submitButton.bezelStyle = .inline
        submitButton.contentTintColor = Design.Text.tertiary
        submitButton.target = self
        submitButton.action = #selector(submit)
        submitButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(submitButton)

        let height = heightAnchor.constraint(equalToConstant: minimumHeight)
        height.priority = .defaultHigh
        heightConstraint = height

        NSLayoutConstraint.activate([
            height,

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: PromptViewDefaults.verticalInset),
            scrollView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -PromptViewDefaults.verticalInset
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: submitButton.leadingAnchor,
                constant: -Design.Spacing.inset
            ),

            submitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            // Pinned to the bottom rather than centred: as the box grows the control stays
            // beside the line being typed, which is where the eye already is.
            submitButton.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -PromptViewDefaults.submitBottomInset
            ),
            submitButton.widthAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize),
            submitButton.heightAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize)
        ])
    }

    private func setupTextView() {
        textView.delegate = self
        textView.placeholder = placeholder
        textView.font = Design.Typography.body()
        textView.textColor = Design.Text.label
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // Straight quotes and hyphens: a prompt is read by a CLI as often as by a person, and
        // a smart-quoted path or flag is a different string from the one that was typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onAttach = { [weak self] paths in self?.insertAttachments(paths) }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Layout

    /// Text height depends on the width the box was given, which is not known when the text
    /// is set — a draft restored before layout measured against a container of the wrong
    /// width and opened at the wrong height. Re-measuring here is what makes it right, and
    /// it converges because `updateHeight` only touches the constraint when the value moves.
    override func layout() {
        super.layout()
        updateHeight()
    }

    // MARK: - Public Methods

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Actions

    @objc private func submit() {
        onSubmit?(textView.string)
    }

    /// Puts dropped or pasted files into the prompt as paths, since that is what an agent can
    /// act on: both CLIs read a file named in the text, and neither can see an image that
    /// only ever existed on the pasteboard.
    private func insertAttachments(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let quoted = paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        var addition = quoted.joined(separator: " ")

        let existing = textView.string
        if !existing.isEmpty, !existing.hasSuffix(" "), !existing.hasSuffix("\n") {
            addition = " " + addition
        }

        textView.insertText(addition, replacementRange: textView.selectedRange())
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// The submit control brightens once there is something to send, which is the only cue
    /// that Return will do anything.
    private func updateSubmitState() {
        let hasText = !textView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        submitButton.contentTintColor = hasText ? Design.Surface.accent : Design.Text.tertiary
    }

    /// Sizes the box to its text, between one line and `inputMaxHeight`.
    private func updateHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        let chrome = PromptViewDefaults.verticalInset * 2

        let fitted = min(
            max(textHeight + chrome, minimumHeight),
            max(Design.Size.inputMaxHeight, minimumHeight)
        )

        guard heightConstraint?.constant != fitted else { return }
        heightConstraint?.constant = fitted

        // Past the cap the box stops growing, so the scroller has to take over.
        scrollView.hasVerticalScroller = fitted >= max(Design.Size.inputMaxHeight, minimumHeight)
    }
}

// MARK: - NSTextViewDelegate

extension PromptView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        updateSubmitState()
        updateHeight()
        onChange?(textView.string)
    }
}

// MARK: - Prompt Text View

/// The editable surface inside a `PromptView`.
///
/// Exists for three behaviours `NSTextView` does not have: a placeholder, Return meaning
/// *submit* rather than *newline*, and files arriving by drag or paste becoming paths in the
/// text instead of being refused (images) or pasted as an attachment cell (files).
private final class PromptTextView: NSTextView {

    // MARK: - Properties

    var placeholder: String = "" { didSet { needsDisplay = true } }

    /// Return, without a modifier.
    var onSubmit: (() -> Void)?

    /// Paths for whatever was dropped or pasted, already written to disk.
    var onAttach: (([String]) -> Void)?

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Design.Typography.body(),
            .foregroundColor: NSColor.placeholderTextColor
        ]

        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    // MARK: - Key Handling

    /// Return submits; Shift-Return and Option-Return insert a newline. This is the shape
    /// every chat composer has, and the reason the field can be multi-line without costing
    /// the one-key send.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == PromptViewDefaults.returnKeyCode
        let wantsNewline = event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.option)

        if isReturn, !wantsNewline {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Drag and Paste

    /// Both drops and pastes arrive here, so one implementation serves the pointer and the
    /// keyboard alike.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let paths = PromptAttachment.paths(from: pboard)

        guard !paths.isEmpty else {
            return super.readSelection(from: pboard, type: type)
        }

        onAttach?(paths)
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.acceptableDragTypes
    }
}

// MARK: - Prompt Attachment

/// Turns whatever is on a pasteboard into file paths an agent can open.
enum PromptAttachment {

    /// Paths for the pasteboard's contents: dropped files as they are, and raw image data
    /// written out first, since a screenshot on the pasteboard has no path of its own.
    static func paths(from pasteboard: NSPasteboard) -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL).map(\.path)
        }

        guard let data = imageData(from: pasteboard), let path = write(data) else { return [] }
        return [path]
    }

    // MARK: - Private Methods

    /// PNG as offered, else whatever the image is re-encoded as PNG — one format on disk
    /// keeps the extension honest.
    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }

        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        return bitmap.representation(using: .png, properties: [:])
    }

    /// Written to the temporary directory, which is where the agent CLIs put their own
    /// pasted images: the file only has to outlive the turn that names it.
    private static func write(_ data: Data) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(PromptViewDefaults.attachmentPrefix)\(UUID().uuidString)")
            .appendingPathExtension(PromptViewDefaults.attachmentExtension)

        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            SkalmanLogger.session.error(
                "Failed to write dropped image: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Prompt View Defaults

enum PromptViewDefaults {
    static let submitSize: CGFloat = 18

    /// Keeps a one-line prompt vertically centred in `Design.Size.inputHeight`.
    static let verticalInset: CGFloat = 13
    static let submitBottomInset: CGFloat = 13

    static let returnKeyCode: UInt16 = 36

    static let attachmentPrefix = "skalman-attachment-"
    static let attachmentExtension = "png"
}
