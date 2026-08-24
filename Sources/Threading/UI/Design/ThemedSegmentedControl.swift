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
final class ThemedSegmentedControl: NSView, TextBaselineProviding {

    // MARK: - Properties

    /// A one-glyph state mark after a segment's title, so a choice you are *not* on still says
    /// where it stands.
    ///
    /// A run of segments hides everything but the selected panel, which is the whole point of
    /// using one — and also the whole risk: a person who switched a way in on and moved to
    /// another segment has no way to see that the first one came up. A glyph rather than a
    /// coloured dot, because status must survive Differentiate Without Colour, and a spoken name
    /// beside it because it must survive not being looked at.
    enum SegmentMark: Equatable {
        /// Doing what it says on the tin.
        case ready
        /// On, and not carrying what it promised.
        case attention
        /// Off, or nothing to report.
        case idle

        var glyph: String {
            switch self {
            case .ready: return "\u{2713}"
            case .attention: return "!"
            case .idle: return "\u{2013}"
            }
        }

        @MainActor
        var tint: NSColor {
            switch self {
            case .ready: return Design.Status.positive
            case .attention: return Design.Status.warning
            case .idle: return Design.Text.tertiary
            }
        }

        var spokenName: String {
            switch self {
            case .ready: return L10n.string("ready")
            case .attention: return L10n.string("needs attention")
            case .idle: return L10n.string("off")
            }
        }
    }

    /// Titles in the order they are shown; the host localizes them.
    private(set) var titles: [String] = []

    /// The state mark beside each title, when the run's choices have one. Empty everywhere the
    /// choice is only a choice.
    private(set) var marks: [SegmentMark?] = []

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

    /// Where the segment titles' shared baseline sits. The run's children centre one control-
    /// font line in the track, so its public baseline has to state that same geometry; `NSView`'s
    /// default answer is the frame edge and makes any correctly baseline-aligned sibling wrong.
    override var firstBaselineOffsetFromTop: CGFloat {
        let font = Design.Typography.control()
        return (intrinsicContentSize.height - Design.Typography.lineHeight(of: font)) / 2
            + NSLayoutManager().defaultBaselineOffset(for: font)
    }

    /// Every segment has one title line, so its last baseline is the same line from the far edge.
    override var lastBaselineOffsetFromBottom: CGFloat {
        intrinsicContentSize.height - firstBaselineOffsetFromTop
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
    func configure(
        titles: [String],
        marks: [SegmentMark?] = [],
        selectedIndex: Int = 0
    ) {
        self.titles = titles
        self.marks = Self.padded(marks, to: titles.count)

        for view in segmentViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        segmentViews = titles.enumerated().map { index, title in
            let segment = SegmentView(title: title, mark: self.marks[index])
            segment.onActivate = { [weak self] in self?.choose(index) }
            segment.onMove = { [weak self] offset, event in
                self?.move(from: index, by: offset, focusEvent: event)
            }
            stack.addArrangedSubview(segment)
            return segment
        }

        self.selectedIndex = titles.indices.contains(selectedIndex) ? selectedIndex : 0
        updateSelection()
    }

    /// Repaints the state marks without rebuilding the run.
    ///
    /// Separate from `configure` because the two change on completely different clocks: the
    /// titles are a compile-time set, and the marks move every time the network does. Rebuilding
    /// three controls to change three glyphs is how a run starts flickering under a network that
    /// is settling.
    func setMarks(_ marks: [SegmentMark?]) {
        self.marks = Self.padded(marks, to: titles.count)
        for (index, segment) in segmentViews.enumerated() {
            segment.mark = self.marks.indices.contains(index) ? self.marks[index] : nil
        }
    }

    private static func padded(_ marks: [SegmentMark?], to count: Int) -> [SegmentMark?] {
        guard marks.count != count else { return marks }
        return (0..<count).map { marks.indices.contains($0) ? marks[$0] : nil }
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
    private func move(from index: Int, by offset: Int, focusEvent: NSEvent?) {
        let target = index + offset
        guard segmentViews.indices.contains(target) else { return }
        choose(target)
        window?.makeFirstResponder(segmentViews[target])
        // A fixture may call `keyDown` directly, where `NSApp.currentEvent` is nil, and AppKit
        // may move focus after the key has left the event queue. The key that moved the choice
        // is still the honest origin of the new segment's focus.
        segmentViews[target].focusArrived(from: focusEvent)
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
    var onMove: ((Int, NSEvent?) -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The state mark after the title. Nil takes the label out of the run's layout entirely, so a
    /// choice with nothing to report is drawn exactly as it was before marks existed.
    var mark: ThemedSegmentedControl.SegmentMark? {
        didSet {
            guard mark != oldValue else { return }
            applyMark()
            needsDisplay = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let markLabel = NSTextField(labelWithString: "")
    private var focusOrigin = KeyboardFocusOrigin()
    private var titleWidthFloor: NSLayoutConstraint?

    /// A pointer press keeps this segment as first responder so the next arrow key can continue
    /// the choice, but the accent ring is keyboard guidance rather than a second selection mark.
    private var showsKeyboardFocusRing: Bool {
        hasKeyboardFocus && focusOrigin.isFromKeyboard
    }

    init(title: String, mark: ThemedSegmentedControl.SegmentMark? = nil) {
        self.mark = mark
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.applyFont(.control)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        // The segment is the accessibility element; its labels would otherwise be announced as
        // second, unrelated objects inside it.
        titleLabel.setAccessibilityElement(false)
        // A title yields to the segment's required margins when the run is genuinely narrow, but
        // not to a fitting pass rounding a fractional intrinsic width down by half a point — that
        // made "Agent" ellipsize inside a 140-point segment. Required-minus-one preserves both.
        titleLabel.setContentCompressionResistancePriority(.required - 1, for: .horizontal)
        // `NSTextField` can report a half-point intrinsic width that `NSStackView` rounds down
        // before clipping the field's alignment overhang. Keep the visible slot on the next
        // whole point; priority 999 still yields to the segment's required margins when narrow.
        let titleWidthFloor = titleLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ceil(titleLabel.intrinsicContentSize.width)
        )
        titleWidthFloor.priority = .required - 1
        titleWidthFloor.isActive = true
        self.titleWidthFloor = titleWidthFloor
        markLabel.applyFont(.control)
        markLabel.alignment = .center
        markLabel.setAccessibilityElement(false)
        markLabel.setContentHuggingPriority(.required, for: .horizontal)
        markLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // A stack rather than two pins: the mark is *after* the title, and where it sits is the
        // run's business rather than each segment's arithmetic. Hidden, it leaves the layout, so
        // a run with no marks is drawn exactly as it was before they existed.
        let content = NSStackView(views: [titleLabel, markLabel])
        content.orientation = .horizontal
        content.alignment = .firstBaseline
        content.distribution = .fill
        content.spacing = Design.Spacing.small
        content.setHuggingPriority(.required, for: .horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // The pair is centred and stays together: a mark pinned to the segment's trailing edge
        // would sit half a run away from the name it qualifies. The margins are required and the
        // centring is not, so a title too long for its share truncates around a mark that stays.
        let centred = content.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            centred
        ])
        applyMark()
    }

    private func applyMark() {
        markLabel.stringValue = mark?.glyph ?? ""
        markLabel.isHidden = mark == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Design.Size.chipHeight)
    }

    override func layout() {
        let ceiledWidth = ceil(titleLabel.intrinsicContentSize.width)
        if titleWidthFloor?.constant != ceiledWidth {
            titleWidthFloor?.constant = ceiledWidth
        }
        super.layout()
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

        if showsKeyboardFocusRing {
            drawKeyboardFocus(
                around: ThemedSurface.Shape(
                    rect: bounds,
                    radius: Design.Radius.pill(height: bounds.height)
                )
            )
        }

        titleLabel.textColor = foreground
        // The mark keeps its own meaning under the selection plate: it is saying what the way in
        // is doing, not whether this is the segment you are on.
        markLabel.textColor = mark?.tint
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusArrived(from: NSApp.currentEvent) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusOrigin.resigned()
            needsDisplay = true
        }
        return resigned
    }

    /// Internal to the component so an arrow can carry the event that moved focus to its target.
    func focusArrived(from event: NSEvent?) {
        focusOrigin.arrived(from: event)
        needsDisplay = true
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        // `makeFirstResponder` is a no-op when this segment already owns focus, so explicitly
        // replace a preceding keyboard origin. The selection plate remains; only the ring leaves.
        focusArrived(from: event)
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        focusArrived(from: event)
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            onMove?(-1, event)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            onMove?(1, event)
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

    /// The mark is a fact about the choice rather than about the selection, so it is spoken as
    /// help rather than folded into the title or the value. Colour alone would not have carried
    /// it, and neither would a glyph nobody can hear.
    override func accessibilityHelp() -> String? { mark?.spokenName }
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
