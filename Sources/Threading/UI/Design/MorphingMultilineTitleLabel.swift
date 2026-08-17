import AppKit

/// A short block of authored lines that morphs, line by line, into another one.
///
/// The multi-line counterpart to `MorphingTitleLabel`, and it is *lines* rather than a paragraph
/// on purpose: LabelMorph diffs one Core Text line, so a wrapped paragraph has nothing to be
/// diffed against. A block keeps one `MorphingTitleLabel` per line of its value, each morphing
/// into the line that replaces it — and a value that gains a line morphs that line in from
/// nothing rather than having it appear whole.
///
/// Two consequences to know before reaching for it. It splits on newlines and **does not wrap**:
/// a line wider than its host truncates the way every other morphing title does, so this is for
/// authored short lines, not prose — `ThemedMultilineTitleLabel` is the wrapping one. And a
/// block's height is a function of its line *count* alone, never of what the lines say, which is
/// what lets the count be animated at all. See `setStringValue(_:animated:)`.
final class MorphingMultilineTitleLabel: NSView, ThemedComponent {

    // MARK: - Properties

    private let lines = NSStackView()
    private var lineLabels: [MorphingTitleLabel] = []
    private var lineHeights: [NSLayoutConstraint] = []

    /// How many leading labels currently carry the value. The rest exist but are out of layout.
    private var presentedLineCount = 0

    /// Held so a line built later is set in the same face as the ones already up, and so a live
    /// theme switch resizes every slot rather than only re-drawing the glyphs in it.
    private var lineFont = Design.Typography.body()

    /// Holds the block at the wider of the two states while lines swap. See `setStringValue`.
    private var widthFloor: NSLayoutConstraint?

    /// What the block is *worth* to its host while its line count changes, animated from the
    /// count it had to the count it is taking. Nil at rest, where the lines state their own.
    private var heightTravel: NSLayoutConstraint?

    /// Tells the end of the morph now running from the end of the one it interrupted, which
    /// would otherwise put the interrupted transition's lines away.
    private var transitionGeneration = 0

    /// Stated the way `MorphingTitleLabel` states them — as rules to be re-asked — and kept here
    /// as well so a line built after the host set them is built holding the same two rules.
    private var inkProvider: (() -> NSColor)?
    private var groundProvider: (() -> NSColor)?

    private(set) var stringValue = ""

    var alignment: NSTextAlignment = .center {
        didSet {
            guard alignment != oldValue else { return }
            lineLabels.forEach { $0.alignment = alignment }
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        lines.orientation = .vertical
        // Each line is pinned to the block's own width below, so this only states which edge a
        // line is measured from; the leading it needs between rows is inside the slot heights.
        lines.alignment = .centerX
        lines.spacing = 0
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)

        // **The bottom pin is the one the block may break**, and it is what a growing or
        // shrinking block is measured against. At rest it is what gives the block the height of
        // its lines. While the count is travelling, `heightTravel` states a height between the
        // two counts and outranks it, so the stack keeps every line at its full slot and simply
        // reaches past the block's own bounds — a line on its way out can be seen leaving,
        // rather than being taken out of layout the instant it stops being part of the value.
        let bottom = lines.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: topAnchor),
            bottom,
            lines.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    // MARK: - Public Methods

    /// Replaces the block, morphing each line into the line that takes its place.
    ///
    /// **Every line either value uses stays in layout for the length of the morph**, and what
    /// travels instead is the block's own height — from the count it had to the count it is
    /// taking, over the same clock the characters move on. That is the whole of why this reads
    /// as one motion. A block one line tall is centred in its host differently from a block
    /// three lines tall, so a line count that changes moves the lines that stay; resolved up
    /// front the block snaps to its new shape and the line it lost is gone before it can be seen
    /// going, and resolved afterwards everything jumps once the animation has finished, which
    /// reads as a defect however good the animation was. Travelling, the lines that stay glide,
    /// the lines that arrive fade up in the room being made for them, and the lines that leave
    /// dissolve in the room being taken back.
    ///
    /// The block is also held at the wider of the two states while the lines swap. They share
    /// one width, so without the floor the second line's morph would resize the first one
    /// mid-flight — and a `MorphingLabel` whose bounds change re-lays its glyphs out where they
    /// will end up, under animations still carrying them there.
    func setStringValue(_ value: String, animated: Bool) {
        guard value != stringValue else { return }

        let target = value.components(separatedBy: "\n")
        let previous = presentedLineCount
        stringValue = value
        setAccessibilityLabel(value.replacingOccurrences(of: "\n", with: ". "))

        // The same three conditions `MorphingLabel.setText` applies, asked before the fact: a
        // block off-window or under Reduce Motion lands its lines directly, and must therefore
        // not hold layout open for an animation that will never run.
        let morphs = animated && !Design.Motion.reducesMotion && window != nil
        let span = max(target.count, previous)
        ensureLines(count: span)

        transitionGeneration += 1
        let generation = transitionGeneration

        guard morphs else {
            presentedLineCount = target.count
            for (index, label) in lineLabels.enumerated() {
                label.setStringValue(index < target.count ? target[index] : "", animated: false)
            }
            endTransition(generation)
            return
        }

        // A morph's duration is a function of both ends of it, so this is asked while each line
        // still holds the line it is leaving.
        let settle = (0..<span).reduce(TimeInterval.zero) { longest, index in
            max(longest, lineLabels[index].morphSettleDuration(
                to: index < target.count ? target[index] : ""
            ))
        }

        holdWidth(across: target)
        holdHeight(at: previous)
        for index in 0..<span {
            lineLabels[index].isHidden = false
            lineHeights[index].isActive = true
        }
        // Resolves the reveal without moving anything: the block is pinned to the height it
        // already had, so the lines that have just joined take their slots past its bottom edge
        // rather than pushing it open. They need those bounds before they can animate inside
        // them — the package refuses to morph a label with none.
        window?.layoutIfNeeded()

        presentedLineCount = target.count
        for index in 0..<span {
            lineLabels[index].setStringValue(
                index < target.count ? target[index] : "",
                animated: true
            )
        }
        travelHeight(to: target.count, over: settle, generation: generation)
    }

    /// States the ink as a rule to be re-asked rather than a colour to be kept — see
    /// `MorphingTitleLabel.setTextColor(_:)`, which every line here holds its own copy of.
    func setTextColor(_ provider: @escaping () -> NSColor) {
        inkProvider = provider
        lineLabels.forEach { $0.setTextColor(provider) }
    }

    /// The surface the glyphs are smoothed against, for a block drawn on something other than
    /// the app's structural ground.
    func setRasterizationGround(_ provider: @escaping () -> NSColor) {
        groundProvider = provider
        lineLabels.forEach { $0.setRasterizationGround(provider) }
    }

    func refreshTextColor() {
        lineLabels.forEach { $0.refreshTextColor() }
    }

    /// Whether a change of line count is still travelling.
    ///
    /// For a test waiting on the arrival: a block that has *gained* lines is already laying all
    /// of them out on the first pass, so counting them says nothing about whether the height has
    /// finished running to meet them.
    var isTravellingForTesting: Bool { heightTravel != nil }

    // MARK: - Private Methods

    /// Builds the labels a value of `count` lines needs, and leaves them out of layout until it
    /// has them.
    private func ensureLines(count: Int) {
        while lineLabels.count < count {
            let label = MorphingTitleLabel()
            label.alignment = alignment
            label.font = lineFont
            // One block, one thing to read. Each line reports itself by default, which would
            // hand VoiceOver three unrelated fragments where the value is one sentence.
            label.setAccessibilityElement(false)
            // A line yields at priority 1 by default so a host with a slot can truncate it. The
            // lines here have no slot of their own — they share the block's, and the block's
            // width *is* the widest line. Left at 1 the shared width settled on the shortest
            // line's hugging instead, and every longer line drew as an ellipsis.
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            if let inkProvider { label.setTextColor(inkProvider) }
            if let groundProvider { label.setRasterizationGround(groundProvider) }
            label.isHidden = true
            lines.addArrangedSubview(label)

            // Every line is drawn in a slot of the font's own line height rather than at the
            // height of the characters it happens to hold. LabelMorph centres a line in the
            // bounds it is given, so a fixed slot places the glyphs identically whatever the
            // text — including when there is none, which is what a line morphing in from
            // nothing needs. Measured per line and not once for the block, so a theme switch
            // resizes each of them through the one path that owns their font.
            let height = label.heightAnchor.constraint(
                equalToConstant: Design.Typography.lineHeight(of: lineFont)
            )
            height.isActive = false
            lineHeights.append(height)

            // The shared width, stated where it is read: a centred line is centred in the
            // block, and an empty one still has somewhere to animate into.
            label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            lineLabels.append(label)
        }
    }

    /// Holds the block at the wider of the state it is leaving and the one it is entering, for
    /// the length of the morph.
    ///
    /// Below `.required` on purpose: a host narrower than the widest line must still win and
    /// break this rather than its own edge. Above hugging, so nothing shrinks under it while it
    /// stands.
    private func holdWidth(across target: [String]) {
        // Any line measures for all of them: they are one block set in one font.
        guard let measure = lineLabels.first else { return }
        let candidates = target + lineLabels.prefix(presentedLineCount).map(\.stringValue)
        let width = candidates.reduce(CGFloat.zero) { widest, line in
            max(widest, measure.naturalWidth(of: line))
        }

        let floor = widthFloor ?? {
            let constraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            constraint.priority = .defaultHigh
            constraint.isActive = true
            widthFloor = constraint
            return constraint
        }()
        floor.constant = max(floor.constant, width)
    }

    /// Pins the block to the height `count` lines are worth, so revealing the lines the value is
    /// about to gain makes no room and hiding none takes any back.
    private func holdHeight(at count: Int) {
        if let travel = heightTravel {
            // A transition interrupted mid-travel carries on from where the block actually is,
            // rather than snapping to the count the interrupted one was heading for.
            travel.constant = frame.height
        } else {
            let constraint = heightAnchor.constraint(
                equalToConstant: height(ofLines: count)
            )
            constraint.isActive = true
            heightTravel = constraint
        }
        window?.layoutIfNeeded()
    }

    /// Runs the block's height to what `count` lines are worth, on the morph's own clock.
    ///
    /// This is the movement: the host re-centres the block continuously as it resizes, so every
    /// line travels with it — the ones that stay, the ones fading up in the room being made, and
    /// the ones dissolving in the room being taken back.
    private func travelHeight(to count: Int, over settle: TimeInterval, generation: Int) {
        guard let travel = heightTravel else { return }
        NSAnimationContext.runAnimationGroup { context in
            // The morph's own clock, so the block arrives as its characters do. Stated against
            // `Design.Motion` all the same: this is only ever reached with motion on, and a
            // duration that reads its own settle is exactly the shape the lint exists to catch.
            context.duration = Design.Motion.reducesMotion ? 0 : settle
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            travel.animator().constant = height(ofLines: count)
        }

        // The end of the transition is put on the clock rather than on the animation's own
        // completion handler. That handler is a Core Animation transaction's, and a transaction
        // belonging to a window that is never flushed — one still off screen, or closed while a
        // line was arriving — is not one to hang the block's layout state on. What is waiting on
        // it is not the look but the release: a block whose height stayed pinned and whose
        // dropped lines stayed in layout would be stuck at the shape it was passing through.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            self?.endTransition(generation)
        }
    }

    /// Puts the block back on its own lines: the ones the value no longer has leave layout, and
    /// the two holds are released.
    ///
    /// Nothing moves here, which is the point of doing it last. The lines being put away have
    /// already dissolved to nothing and the height they are giving up is the height the travel
    /// has just arrived at, so the block's own lines state exactly what it is already drawn at.
    /// The width is given back from both sides at once, since the block is centred and so is
    /// every line in it — and it is given back rather than kept, because a block still reserving
    /// the widest line it ever carried makes a narrow host truncate against a measure nothing on
    /// screen is using.
    private func endTransition(_ generation: Int) {
        guard transitionGeneration == generation else { return }
        for (index, label) in lineLabels.enumerated() {
            let isPresented = index < presentedLineCount
            label.isHidden = !isPresented
            lineHeights[index].isActive = isPresented
        }
        widthFloor?.isActive = false
        widthFloor = nil
        heightTravel?.isActive = false
        heightTravel = nil
    }

    private func height(ofLines count: Int) -> CGFloat {
        CGFloat(count) * Design.Typography.lineHeight(of: lineFont)
    }
}

// MARK: - FontRoleApplying

extension MorphingMultilineTitleLabel: FontRoleApplying {

    var appliedRoleFont: NSFont? { lineFont }

    /// The block is the one that records the role, and it sets its lines' fonts directly rather
    /// than through `applyFont`. The app-theme sweep visits every view that recorded one, so a
    /// line recording its own would be re-fonted by the sweep without the block ever hearing
    /// about it — and the slot heights it holds are a function of that font.
    func applyRoleFont(_ font: NSFont) {
        lineFont = font
        let height = Design.Typography.lineHeight(of: font)
        for (label, constraint) in zip(lineLabels, lineHeights) {
            label.font = font
            constraint.constant = height
        }
    }
}
