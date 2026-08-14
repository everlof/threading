import AppKit

// MARK: - Search Result Row

/// One destination a search turned up, with where it lives: a title line that marks what the
/// query accounts for (`SearchMatchLabel`), over a quiet path line saying where the click will
/// land — the settings sidebar's "Alert sound / Notifications" under the General row.
///
/// A component of its own rather than a taller `ThemedTabItemView`: a tab names a *place* the
/// reader already knows and holds one line forever, while a result names a thing the reader
/// just asked for and owes them the path to it. What the two share — hover plate, press,
/// keyboard activation, focus ring, ink source — they share through `BackdropThemedControl`,
/// not by one of them wearing the other's geometry.
final class SearchResultRowView: BackdropThemedControl {

    private enum Layout {
        /// Rounded rect at the control corner, the tab's own silhouette.
        @MainActor static var radius: CGFloat { Design.Radius.control }
    }

    // MARK: - Properties

    var onSelect: (() -> Void)?

    /// Where the title's leading ink starts, so a host can line results up with the rows above
    /// them — the settings sidebar hands the tab's own title column.
    private let leadingInset: CGFloat

    private let titleLabel: SearchMatchLabel
    private let pathLabel = NSTextField(labelWithString: "")
    private var isPressed = false { didSet { needsDisplay = true } }

    private var title = ""
    private var path: String?

    // MARK: - Initialization

    init(
        title: String,
        path: String?,
        matching query: String,
        leadingInset: CGFloat,
        inkSource: InkSource
    ) {
        self.leadingInset = leadingInset
        self.titleLabel = SearchMatchLabel(role: .controlRegular, ink: { Design.Text.label })
        super.init(frame: .zero, inkSource: inkSource)
        setup()
        show(title: title, path: path, matching: query)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.applyFont(.caption)
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        // One accessible element: the control speaks, its labels do not repeat it.
        pathLabel.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)

        let labels = NSStackView(views: [titleLabel, pathLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    // MARK: - Content

    /// Restates the row for a new query or a reused position. The path line disappears rather
    /// than standing empty when the result has no section to name.
    func show(title: String, path: String?, matching query: String) {
        self.title = title
        self.path = path
        titleLabel.show(title, matching: query)
        pathLabel.stringValue = path ?? ""
        pathLabel.isHidden = path == nil
        setAccessibilityTitle(path.map { "\(title) — \($0)" } ?? title)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func applyInk(_ ink: Design.Ink) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The tab's own ramp, minus selection: a result is never the open page, so it rests
        // quiet and lifts for pointer, press and keyboard focus alike.
        let fill: NSColor = isPressed || isHovered || hasKeyboardFocus ? ink.surface : .clear

        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: nil,
            radius: Layout.radius
        )
        drawKeyboardFocus(around: shape)

        pathLabel.textColor = ink.tertiary
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        guard isEnabled, inside else { return }
        onSelect?()
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }

    /// The labels make no claim on the pointer; the whole row is the target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }

    override func accessibilityTitle() -> String? {
        path.map { "\(title) — \($0)" } ?? title
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}
