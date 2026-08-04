import AppKit

/// Measurements and keys the expanded comparison owns. Its band height is `Design.Size`'s, so a
/// media inspector and a comparison open at the same height.
enum CompareInspectorDefaults {
    /// Escape, which every transient surface here gives a meaning.
    static let escapeKeyCode: UInt16 = 53
}

// MARK: - Model

/// What an expanded comparison is opened with: the same two sides the inline surface holds, and
/// the place the user had already scrubbed to.
struct CompareInspectorContent {
    let old: ImageCompareView.Side?
    let new: ImageCompareView.Side?
    var mode: ImageCompareMode = .wipeHorizontal
    var fraction: CGFloat = 0.5

    /// The pair, named the way the difference mode names it — one line for a header that is
    /// about *both* sides, rather than two titles the captions inside already carry.
    var title: String {
        switch (old, new) {
        case let (.some(old), .some(new)): return "\(old.title) → \(new.title)"
        case let (.some(side), nil), let (nil, .some(side)): return side.title
        case (nil, nil): return ""
        }
    }
}

/// What the expanded comparison was showing when it closed, so the surface it was opened from
/// carries on from there instead of snapping back.
struct CompareInspectorResult {
    let mode: ImageCompareMode
    let fraction: CGFloat
}

// MARK: - Presentation

/// Presents one expanded comparison per window, inside that window's themed content hierarchy —
/// `MediaInspectorPresenter`'s rule, for the same reasons.
///
/// No panel is involved: the surface follows the current theme live, does not take key-window
/// status away from the session behind it, and hands focus back to whatever opened it. One
/// session per window, because a second one would be a comparison the user cannot see under a
/// comparison they cannot leave.
@MainActor
enum CompareInspectorPresenter {

    private static var sessions: [ObjectIdentifier: CompareInspectorSession] = [:]

    /// Opens `content`, answering whether it opened. False means there was nothing to show or
    /// nowhere to show it — a surface with no window, or a pair with no sides.
    @discardableResult
    static func present(
        _ content: CompareInspectorContent,
        from source: NSView,
        onClose: ((CompareInspectorResult) -> Void)? = nil
    ) -> Bool {
        guard content.old != nil || content.new != nil else { return false }
        guard let window = source.window, window.contentView != nil else { return false }

        let key = ObjectIdentifier(window)
        sessions[key]?.close()

        let session = CompareInspectorSession(
            content: content,
            source: source,
            window: window,
            onResult: onClose,
            onClose: { sessions.removeValue(forKey: key) }
        )
        sessions[key] = session
        return true
    }

    static func dismiss(in window: NSWindow?) {
        guard let window else { return }
        sessions[ObjectIdentifier(window)]?.close()
    }

    static func isPresenting(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return sessions[ObjectIdentifier(window)] != nil
    }
}

@MainActor
private final class CompareInspectorSession {

    private weak var source: NSView?
    private weak var window: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private let inspector: CompareInspectorView
    private let onResult: ((CompareInspectorResult) -> Void)?
    private let onClose: () -> Void
    private var isClosed = false
    /// The surface and its scrim, held as the one thing so neither can be taken away alone.
    private var presentation: InWindowOverlay.Presentation?

    init(
        content: CompareInspectorContent,
        source: NSView,
        window: NSWindow,
        onResult: ((CompareInspectorResult) -> Void)?,
        onClose: @escaping () -> Void
    ) {
        self.source = source
        self.window = window
        previousFirstResponder = window.firstResponder
        self.onResult = onResult
        self.onClose = onClose
        inspector = CompareInspectorView(content: content)

        inspector.onDismiss = { [weak self] in self?.close() }
        // Below the window's own chrome, never over it — see `InWindowOverlay`. The scrim under
        // it dims what stays visible above, and clicking it closes exactly as the button does,
        // scrub and mode handed back the same way.
        presentation = InWindowOverlay.install(
            inspector,
            in: window,
            onDismiss: { [weak self] in self?.close() }
        )
        window.makeFirstResponder(inspector.preferredFirstResponder)
        NSAccessibility.post(element: inspector, notification: .layoutChanged)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let result = inspector.result
        presentation?.remove()
        presentation = nil
        restoreFocus()
        onResult?(result)
        onClose()
    }

    /// Focus goes back where it came from, and to the window itself if neither the source nor
    /// the responder before it will take it — a comparison switched to a mode with nothing to
    /// scrub declines first responder, and leaving the removed inspector holding it would strand
    /// every key press in a view that is no longer in the tree.
    private func restoreFocus() {
        guard let window else { return }
        if let source, source.window === window, window.makeFirstResponder(source) { return }
        if let previousFirstResponder, window.makeFirstResponder(previousFirstResponder) { return }
        window.makeFirstResponder(nil)
    }
}

// MARK: - Inspector

/// The expanded comparison: the pair named once at the top, and `ImageCompareView` given the
/// whole window under it.
///
/// The surface here is the *same component* the row or the pane holds, not a second
/// implementation of a wipe — which is the point. Inline it is inside somebody else's height,
/// capped so one tall screenshot does not become the page; opened, it fits the window and the
/// mode chip is the same chip, so switching to difference and back is one control the user has
/// already used.
final class CompareInspectorView: NSView, ThemedComponent {

    private let compare = ImageCompareView(frame: .zero)
    private let headerSeparator = SeparatorView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()

    var onDismiss: (() -> Void)?

    private lazy var closeButton = ThemedIconButton(
        symbolName: "xmark",
        accessibility: L10n.string("Close comparison"),
        target: .toolbar,
        inkSource: .chrome
    )

    init(content: CompareInspectorContent) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
        setup(content: content)

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    /// The scrub is what this surface is for, so it opens holding it.
    var preferredFirstResponder: NSView { compare.preferredFirstResponder }

    var mode: ImageCompareMode { compare.mode }
    var fraction: CGFloat { compare.fraction }

    var result: CompareInspectorResult {
        CompareInspectorResult(mode: compare.mode, fraction: compare.fraction)
    }

    // MARK: - Private Methods

    private func setup(content: CompareInspectorContent) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.format("Comparison, %@", content.title))

        titleLabel.applyFont(.subheading)
        titleLabel.stringValue = content.title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.applyFont(.caption)
        detailLabel.stringValue = Self.detail(for: content)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.onPress = { [weak self] in self?.onDismiss?() }

        compare.translatesAutoresizingMaskIntoConstraints = false
        // The one place the affordance would offer to open what is already open.
        compare.allowsExpansion = false
        compare.configure(old: content.old, new: content.new)
        compare.mode = content.mode
        compare.fraction = content.fraction

        for view in [titleLabel, detailLabel, headerSeparator, closeButton, compare] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Design.Spacing.large
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -Design.Spacing.medium
            ),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor, constant: Design.Spacing.hairline
            ),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Design.Spacing.inset
            ),
            closeButton.centerYAnchor.constraint(
                equalTo: topAnchor, constant: Design.Size.inspectorHeaderHeight / 2
            ),

            headerSeparator.topAnchor.constraint(
                equalTo: topAnchor, constant: Design.Size.inspectorHeaderHeight
            ),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The captions live inside the compare surface's own bounds, so it keeps a margin
            // from the window's edges rather than running to them the way a plain image would.
            compare.topAnchor.constraint(
                equalTo: headerSeparator.bottomAnchor, constant: Design.Spacing.large
            ),
            compare.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Design.Spacing.large
            ),
            compare.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Design.Spacing.large
            ),
            compare.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Design.Spacing.large
            )
        ])

        applyTheme()
    }

    /// What the header says besides the names: the two pixel grids, and only when they differ —
    /// the surface itself already notes a size change, and repeating it twice would make the one
    /// interesting case look like boilerplate.
    private static func detail(for content: CompareInspectorContent) -> String {
        let oldSize = content.old.map { ImageCompareCanvas.pixelSize(of: $0.image) }
        let newSize = content.new.map { ImageCompareCanvas.pixelSize(of: $0.image) }
        switch (oldSize, newSize) {
        case let (.some(old), .some(new)) where old != new:
            return "\(measure(old)) → \(measure(new))"
        case let (.some(size), _), let (_, .some(size)):
            return measure(size)
        default:
            return ""
        }
    }

    private static func measure(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    private func applyTheme() {
        titleLabel.textColor = Design.Text.label
        detailLabel.textColor = Design.Text.tertiary
        needsDisplay = true
    }

    // MARK: - Drawing

    /// `elevated`, not `ground`: the ground is what the window behind this surface is already
    /// filled with, so the expanded comparison and the window it covered shared one tone and read
    /// as one surface. The scrim under it supplies the rest of the separation — see
    /// `Design.Surface.overlayScrim`.
    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.elevated.setFill()
        bounds.fill()
    }

    // MARK: - Interaction

    override func keyDown(with event: NSEvent) {
        if event.keyCode == CompareInspectorDefaults.escapeKeyCode {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    /// Escape belongs to the transient surface, not to whichever child holds focus — the canvas
    /// keeps the arrow keys, the chip keeps its menu, and Escape still closes from either.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == CompareInspectorDefaults.escapeKeyCode else {
            return super.performKeyEquivalent(with: event)
        }
        onDismiss?()
        return true
    }
}
