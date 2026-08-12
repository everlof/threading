import AppKit

/// A run of two or three fixed choices with all of them on screen.
///
/// The counterpart to `ChipView`, and the line between the two is the *option set*, not the look.
/// A chip's choices come from data and change while the app runs — accounts, models, branches,
/// review modes — so they belong behind a menu that can be any length. A segment's choices are
/// decided at compile time, there are two or three of them, and seeing the ones you are not on is
/// part of using it. `GitReviewMode` has six cases and `ImageCompareMode` five: both stay chips
/// for exactly that reason, and a fourth segment is the sign that a set has outgrown this control.
///
/// Built as a container of small controls rather than as one control drawing N segments, which is
/// `ThemedTabStripView`'s shape for the same reason: each segment then inherits hover, keyboard
/// focus and its accessibility role from `ThemedControl`, instead of one element re-deriving all
/// three for parts of itself that are not views.
///
/// The track is what makes this a segmented control rather than three tabs — it is the thing
/// saying the choices are one choice — so the fills step up from it rather than starting at
/// nothing: the track rests at `controlResting` and the selected segment lifts to `controlHover`.
/// An unselected segment under the pointer answers in *ink* instead of taking a third fill step,
/// because the design system has two control fills and inventing a third here is how a scale
/// stops being a scale.
final class ThemedSegmentedControl: NSView {

    // MARK: - Properties

    /// Titles in the order they are shown; the host localizes them.
    private(set) var titles: [String] = []

    /// Which segment is on, reported back by index. Setting it does not call `onSelect` —
    /// a host restoring a stored choice is not the user making one.
    var selectedIndex: Int = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            updateSelection()
        }
    }

    /// Answered when the user picks a segment that was not already selected.
    var onSelect: ((Int) -> Void)?

    private var segmentViews: [SegmentView] = []
    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?

    /// The height a `ControlRowView` this run stands in has stated. Nil everywhere else, where
    /// the run keeps the constant a chip used to be.
    private var rowHeight: CGFloat?

    /// What this run is actually drawn at — its height, and the pill radius derived from it.
    private var controlHeight: CGFloat { rowHeight ?? Design.Size.chipHeight }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: controlHeight)
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        applySurface(
            fill: Design.Surface.controlResting,
            radius: .pill(height: controlHeight)
        )

        stack.orientation = .horizontal
        stack.alignment = .centerY
        // Equal widths so the selected pill keeps one size as the choice moves along the run.
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let height = heightAnchor.constraint(equalToConstant: controlHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            height
        ])

        // The run is one choice, so it reads as one group with the segments as its buttons.
        setAccessibilityRole(.radioGroup)
    }

    // MARK: - Public Methods

    /// Replaces what the control offers. Selection is kept by index when the new run is at least
    /// as long, so a host re-configuring with the same choices does not silently move the user.
    func configure(titles: [String], selectedIndex: Int = 0) {
        self.titles = titles

        for view in segmentViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        segmentViews = titles.enumerated().map { index, title in
            let segment = SegmentView(title: title)
            segment.onActivate = { [weak self] in self?.choose(index) }
            segment.onMove = { [weak self] offset in self?.move(from: index, by: offset) }
            stack.addArrangedSubview(segment)
            return segment
        }

        self.selectedIndex = titles.indices.contains(selectedIndex) ? selectedIndex : 0
        updateSelection()
    }

    /// The segment at an index, for tests and for a host that needs to point at one.
    func segment(at index: Int) -> NSView? {
        segmentViews.indices.contains(index) ? segmentViews[index] : nil
    }

    // MARK: - Private Methods

    private func choose(_ index: Int) {
        guard segmentViews.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Arrow keys walk the run and take the selection with them, which is what a radio group does
    /// on this platform. The ends do not wrap: a run of three is short enough that wrapping reads
    /// as the selection jumping rather than moving.
    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard segmentViews.indices.contains(target) else { return }
        choose(target)
        window?.makeFirstResponder(segmentViews[target])
    }

    private func updateSelection() {
        for (index, segment) in segmentViews.enumerated() {
            segment.isSelected = index == selectedIndex
        }
    }
}

// MARK: - Segment

/// One choice in the run. Private because a host hands this control titles, never segments —
/// there is no call site for a segment on its own, and offering one is how a run of three
/// becomes three loose controls that happen to sit together.
private final class SegmentView: ThemedControl {

    var onActivate: (() -> Void)?
    var onMove: ((Int) -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.applyFont(.control)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        // The segment is the accessibility element; its label would otherwise be announced as a
        // second, unrelated object inside it.
        titleLabel.setAccessibilityElement(false)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Design.Size.chipHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor

        if isSelected {
            foreground = Design.Text.label
            // Inset inside the track, so the pill reads as sitting *in* the run rather than as a
            // block of it: the track showing all the way around is what groups the three.
            let inset = SegmentDefaults.selectionInset
            let rect = bounds.insetBy(dx: inset, dy: inset)
            ThemedSurface.draw(
                rect,
                // Selection is the lifted step above the shared resting track. Using the
                // track colour again made flat materials (notably Cyberpunk) communicate the
                // active choice through text contrast alone.
                fill: Design.Surface.controlHover,
                radius: Design.Radius.pill(height: rect.height)
            )
        } else {
            // No third fill: an unselected segment answers the pointer by lifting its ink to the
            // label tier, which is legible without adding a step the scale does not have.
            foreground = isHovered || hasKeyboardFocus ? Design.Text.label : Design.Text.secondary
        }

        drawKeyboardFocus(
            around: ThemedSurface.Shape(
                rect: bounds,
                radius: Design.Radius.pill(height: bounds.height)
            )
        )

        titleLabel.textColor = foreground
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            onMove?(-1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            onMove?(1)
        default:
            super.keyDown(with: event)
        }
    }

    override func performPrimaryAction() -> Bool {
        onActivate?()
        return true
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityTitle() -> String? { titleLabel.stringValue }
    override func accessibilityValue() -> Any? { isSelected }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}

// MARK: - ControlRowMember

extension ThemedSegmentedControl: ControlRowMember {

    /// The track is a pill, so its radius is a function of its height — a run that resized
    /// without restating the surface would keep the silhouette of the size it used to be.
    func adopt(_ metrics: ControlRowMetrics) {
        guard rowHeight != metrics.height else { return }
        rowHeight = metrics.height
        heightConstraint?.constant = metrics.height
        applySurface(
            fill: Design.Surface.controlResting,
            radius: .pill(height: metrics.height)
        )
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

// MARK: - Defaults

private enum SegmentDefaults {
    /// How much of the track stays visible around the selected pill.
    static let selectionInset = Design.Spacing.hairline
}
