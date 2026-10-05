import AppKit

/// A short block of authored lines that morphs, line by line, into another one.
///
/// The multi-line counterpart to `MorphingTitleLabel`, and it is *lines* rather than a paragraph
/// on purpose: LabelMorph diffs one Core Text line, so a wrapped paragraph has nothing to be
/// diffed against. A block keeps one `MorphingTitleLabel` per line of its value, each morphing
/// into the line that replaces it — and a value that gains a line morphs that line in from
/// nothing rather than having it appear whole.
///
/// Two consequences to know before reaching for it. By default it splits on newlines and **does
/// not wrap**: a line wider than its host truncates the way every other morphing title does, so
/// this is for authored short lines, not prose — `ThemedMultilineTitleLabel` is the paragraph
/// one. A host that has to carry a line it did not write — a theme's greeting — opts into
/// `Wrapping.words`, which breaks the value into lines *before* they are morphed, at the
/// `wrapWidth` the host states; the morph still diffs line against line. And a block's height is
/// a function of its line *count* alone, never of what the lines say, which is what lets the
/// count be animated at all. See `setStringValue(_:animated:)`.
final class MorphingMultilineTitleLabel: NSView, ThemedComponent {

    /// How the block meets a line wider than the room it is given.
    enum Wrapping: Equatable {
        /// Every authored line is one line, truncating past the block's width. The default, and
        /// right wherever the breaks are the author's meaning — the manager's three-line brief.
        case none
        /// A line wider than `wrapWidth` breaks between words onto the next one, and inside a
        /// word only when that word alone is wider than the measure. At most `maximumLines` in
        /// all: the last of them carries the rest of the value and truncates what does not fit.
        case words(maximumLines: Int)
    }

    // MARK: - Properties

    private let lines = NSStackView()
    private var lineLabels: [MorphingTitleLabel] = []
    private var lineHeights: [NSLayoutConstraint] = []

    /// The lines the value is drawn as: its own lines, or the lines wrapping broke them into.
    /// Exactly the leading labels that carry the value; the rest exist but are out of layout.
    private(set) var presentedLines: [String] = []

    private var presentedLineCount: Int { presentedLines.count }

    /// The measure a wrapping block breaks at, whole points. Zero until the host knows its room.
    private var wrapMeasure: CGFloat = 0

    /// Held so a line built later is set in the same face as the ones already up, and so a live
    /// theme switch resizes every slot rather than only re-drawing the glyphs in it.
    private var lineFont = Design.Typography.body()

    /// Holds the block at the wider of the two states while lines swap. See `setStringValue`.
    private var widthFloor: NSLayoutConstraint?

    /// What the block is *worth* to its host while its line count changes, animated from the
    /// count it had to the count it is taking. Nil at rest, where the lines state their own.
    private var heightTravel: NSLayoutConstraint?

    /// Drives the one piece of this component that Auto Layout owns: the block's travelling
    /// height. AppKit's constraint animator runs an `NSAnimation` on a shared worker. If the
    /// window goes away before that animation is flushed, the worker keeps waiting forever;
    /// theme and evidence sweeps eventually exhaust the pool and unrelated async work stops.
    /// A main-run-loop clock has the same visible frames and an owner whose lifetime we control.
    private var heightTravelTimer: Timer?
    private var heightTravelStart = CGFloat.zero
    private var heightTravelTarget = CGFloat.zero
    private var heightTravelStartedAt = TimeInterval.zero
    private var heightTravelDuration = TimeInterval.zero
    private var heightTravelGeneration = 0
    private weak var heightTravelWindow: NSWindow?

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

    /// Whether a line wider than `wrapWidth` breaks onto the next one. `.none` by default.
    var wrapping: Wrapping = .none {
        didSet {
            guard wrapping != oldValue else { return }
            rewrap()
        }
    }

    /// The widest a wrapped line may draw, stated by the host from the room it has — the role a
    /// text field's `preferredMaxLayoutWidth` plays. Read from the host's own geometry, never
    /// from this block's frame: the block is as wide as its widest line, so wrapping at its own
    /// width would ratchet narrower with every pass.
    ///
    /// Held in whole points and compared before anything else happens, so a host may restate it
    /// on every layout pass: only a width that moves the measure re-breaks the value, and only
    /// lines that come out different are laid out again. Ignored under `.none`; zero (the
    /// default) means the room is not known yet, and the value's own lines stand until it is.
    var wrapWidth: CGFloat {
        get { wrapMeasure }
        set {
            let whole = max(0, newValue.rounded(.down))
            guard whole != wrapMeasure else { return }
            wrapMeasure = whole
            guard wrapping != .none else { return }
            rewrap()
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
    ///
    /// A wrapping block breaks the value into its lines here, before any of that: the morph is
    /// between the lines on screen and the lines the new value wraps to, so a wrapped greeting
    /// morphs into a one-line one exactly as a two-line value would.
    func setStringValue(_ value: String, animated: Bool) {
        guard value != stringValue else { return }
        stringValue = value
        // The value is one sentence however it happens to wrap, so it is read as written.
        setAccessibilityLabel(value.replacingOccurrences(of: "\n", with: ". "))
        present(layoutLines(of: value), animated: animated)
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

    /// The lines `value` is drawn as under the rule and measure in force.
    private func layoutLines(of value: String) -> [String] {
        guard case .words(let maximumLines) = wrapping, wrapMeasure > 0 else {
            return value.components(separatedBy: "\n")
        }
        return MorphingLineBreaker(font: lineFont, width: wrapMeasure)
            .lines(of: value, maximumLines: maximumLines)
    }

    /// Lays the value out again after something it is measured against moved — the measure, the
    /// face, or the rule itself.
    ///
    /// Lands directly rather than morphing: a re-break is the same words in a new shape, which a
    /// text field resizing does not animate either, and a window being resized would otherwise
    /// start a morph on every step. Nothing happens unless the lines actually come out
    /// different, so a measure that moves within a line's slack costs one break and no layout.
    private func rewrap() {
        guard !presentedLines.isEmpty else { return }
        let target = layoutLines(of: stringValue)
        guard target != presentedLines else { return }
        present(target, animated: false)
    }

    /// Puts `target` up, morphing each line into the line that takes its place.
    private func present(_ target: [String], animated: Bool) {
        let previous = presentedLineCount

        // The same three conditions `MorphingLabel.setText` applies, asked before the fact: a
        // block off-window or under Reduce Motion lands its lines directly, and must therefore
        // not hold layout open for an animation that will never run.
        let morphs = animated && !Design.Motion.reducesMotion && window != nil
        let span = max(target.count, previous)
        ensureLines(count: span)

        transitionGeneration += 1
        let generation = transitionGeneration

        guard morphs else {
            presentedLines = target
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

        presentedLines = target
        for index in 0..<span {
            lineLabels[index].setStringValue(
                index < target.count ? target[index] : "",
                animated: true
            )
        }
        travelHeight(to: target.count, over: settle, generation: generation)
    }

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
        let candidates = target + presentedLines
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
        heightTravelTimer?.invalidate()
        heightTravelStart = travel.constant
        heightTravelTarget = height(ofLines: count)
        heightTravelStartedAt = ProcessInfo.processInfo.systemUptime
        heightTravelDuration = Design.Motion.reducesMotion ? 0 : settle
        heightTravelGeneration = generation

        stopObservingHeightTravelWindow()
        if let window {
            heightTravelWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(heightTravelWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        guard heightTravelDuration > 0, window != nil else {
            travel.constant = heightTravelTarget
            window?.layoutIfNeeded()
            endTransition(generation)
            return
        }

        let timer = Timer(
            timeInterval: 1 / 60,
            target: self,
            selector: #selector(stepHeightTravel(_:)),
            userInfo: nil,
            repeats: true
        )
        heightTravelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func heightTravelWindowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === heightTravelWindow,
              transitionGeneration == heightTravelGeneration,
              let travel = heightTravel else { return }
        travel.constant = heightTravelTarget
        endTransition(heightTravelGeneration)
    }

    private func stopObservingHeightTravelWindow() {
        if let heightTravelWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: heightTravelWindow
            )
        }
        heightTravelWindow = nil
    }

    /// Advances the layout-owned part of a line morph without handing an unbounded lifetime to
    /// AppKit. Closing the window completes the model immediately; there are no visible frames
    /// left to preserve and, critically, no animation worker left behind.
    @objc private func stepHeightTravel(_ timer: Timer) {
        guard timer === heightTravelTimer else {
            timer.invalidate()
            return
        }
        guard transitionGeneration == heightTravelGeneration, let travel = heightTravel else {
            timer.invalidate()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - heightTravelStartedAt
        let phase = min(max(CGFloat(elapsed / heightTravelDuration), 0), 1)
        let eased = standardEaseInOut(phase)
        travel.constant = heightTravelStart + (heightTravelTarget - heightTravelStart) * eased
        window?.layoutIfNeeded()

        if phase >= 1 || window == nil {
            travel.constant = heightTravelTarget
            window?.layoutIfNeeded()
            endTransition(heightTravelGeneration)
        }
    }

    /// The standard Core Animation `.easeInEaseOut` curve, evaluated for a clock we own. Its
    /// control points are (0.42, 0) and (0.58, 1); solve x for the curve parameter, then read y.
    private func standardEaseInOut(_ progress: CGFloat) -> CGFloat {
        func coordinate(_ parameter: CGFloat, _ first: CGFloat, _ second: CGFloat) -> CGFloat {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * first
                + 3 * inverse * parameter * parameter * second
                + parameter * parameter * parameter
        }

        var lower = CGFloat.zero
        var upper = CGFloat(1)
        for _ in 0..<12 {
            let parameter = (lower + upper) / 2
            if coordinate(parameter, 0.42, 0.58) < progress {
                lower = parameter
            } else {
                upper = parameter
            }
        }
        return coordinate((lower + upper) / 2, 0, 1)
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
        heightTravelTimer?.invalidate()
        heightTravelTimer = nil
        stopObservingHeightTravelWindow()
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
        // A wrapped value was broken against the face it is leaving; a larger one may need
        // another line and a smaller one may give one back.
        if wrapping != .none { rewrap() }
    }
}

// MARK: - Line Breaking

/// Breaks a value into the lines a wrapping `MorphingMultilineTitleLabel` draws it as.
///
/// Measured the way LabelMorph sets a line — the same face, ligatures off — so a line this calls
/// a fit is one the label draws whole. The breaks are Core Text's own word-wrapping suggestion
/// (`CTTypesetterSuggestLineBreak`), which hangs the space a line breaks at and breaks between
/// characters only for a word wider than the measure on its own, and the line at the cap is
/// tail-truncated between characters the way every other morphing title is.
///
/// Bounded by what is shown rather than by the value: lines are taken one at a time and the
/// breaking stops at the cap, where the last line gathers what follows only until it overflows.
/// A value far longer than the block therefore costs about one line of measuring past the cap.
struct MorphingLineBreaker {

    private enum Defaults {
        /// The single character a truncated line ends with — LabelMorph's own, so a line cut
        /// here reads exactly like one the label cut itself.
        static let ellipsis = "\u{2026}"

        /// Kept back from the measure when deciding what fits. The label reports its width
        /// rounded *up* to a whole point, so a line breaking at the measure itself could come
        /// back a fraction over it — and a block one point wider than its host is squeezed by
        /// that point, which makes LabelMorph truncate a line this said fitted.
        static let roundingSlack: CGFloat = 1
    }

    let font: NSFont
    let width: CGFloat

    /// The room a line may take, after the slack for the label's rounding.
    private var limit: CGFloat { width - Defaults.roundingSlack }

    /// Each authored line broken to the measure, at most `maximumLines` in all.
    func lines(of value: String, maximumLines: Int) -> [String] {
        var pieces = Pieces(value: value, breaker: self)
        var lines: [String] = []
        while lines.count < max(1, maximumLines) - 1, let piece = pieces.next() {
            lines.append(piece.shown)
        }
        guard let last = pieces.next() else { return lines }
        guard let following = pieces.next() else { return lines + [last.shown] }

        // The line at the cap carries the rest, joined as one run of words: an authored break
        // past the cap is a space here, since there is no line left for it to start.
        var rest = last.raw
        var atAuthoredBreak = last.endsAuthoredLine
        func append(_ piece: Piece) {
            guard !piece.raw.isEmpty else {
                atAuthoredBreak = true
                return
            }
            rest += (atAuthoredBreak && !rest.isEmpty ? " " : "") + piece.raw
            atAuthoredBreak = piece.endsAuthoredLine
        }
        append(following)
        while advance(of: rest) <= limit, let next = pieces.next() {
            append(next)
        }
        return lines + [truncated(rest)]
    }

    // MARK: - Private Methods

    /// `text` as one line, or its head with an ellipsis when it is wider than the measure.
    private func truncated(_ text: String) -> String {
        let whole = Self.droppingTrailingWhitespace(text)
        guard advance(of: whole) > limit else { return whole }
        let budget = limit - advance(of: Defaults.ellipsis)
        guard budget > 0 else { return Defaults.ellipsis }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text))
        let characters = text as NSString
        var cut = CTTypesetterSuggestClusterBreak(typesetter, 0, Double(budget))
        // Core Text's answer knows nothing of the ellipsis' own kerning, so the candidate is
        // measured and stepped back by whole composed characters until it genuinely fits —
        // normally not at all.
        while cut > 0 {
            let head = Self.droppingTrailingWhitespace(characters.substring(to: cut))
            if !head.isEmpty, advance(of: head + Defaults.ellipsis) <= limit {
                return head + Defaults.ellipsis
            }
            cut = characters.rangeOfComposedCharacterSequence(at: cut - 1).location
        }
        return Defaults.ellipsis
    }

    private func advance(of text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed(text))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// LabelMorph's attributes for a line: the face, and no ligatures, since each character is
    /// a slot of its own there.
    fileprivate func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .ligature: 0])
    }

    fileprivate static func droppingTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return String(trimmed)
    }

    /// One line's worth of an authored line.
    fileprivate struct Piece {
        /// The characters as written, including the whitespace a break hangs.
        let raw: String
        /// Whether the authored line ends here, rather than wrapping on.
        let endsAuthoredLine: Bool

        /// What the line draws: a wrapped line without the space it broke at, which would
        /// otherwise push a centred line off centre; an authored line exactly as written.
        var shown: String {
            endsAuthoredLine ? raw : MorphingLineBreaker.droppingTrailingWhitespace(raw)
        }
    }

    /// The value's lines broken one at a time, so a caller can stop as soon as it has enough.
    fileprivate struct Pieces {
        private let authored: [String]
        private let breaker: MorphingLineBreaker
        private var index = 0
        private var current: (text: NSString, typesetter: CTTypesetter)?
        private var position = 0

        init(value: String, breaker: MorphingLineBreaker) {
            authored = value.components(separatedBy: "\n")
            self.breaker = breaker
        }

        mutating func next() -> Piece? {
            if current == nil {
                guard index < authored.count else { return nil }
                let text = authored[index]
                index += 1
                guard !text.isEmpty else { return Piece(raw: "", endsAuthoredLine: true) }
                current = (
                    text as NSString,
                    CTTypesetterCreateWithAttributedString(breaker.attributed(text))
                )
                position = 0
            }
            guard let line = current else { return nil }
            let text = line.text

            // Never zero: a measure narrower than a single character still takes that
            // character, or the value would never be used up.
            let suggested = CTTypesetterSuggestLineBreak(
                line.typesetter,
                position,
                Double(breaker.limit)
            )
            let length = suggested > 0
                ? suggested
                : text.rangeOfComposedCharacterSequence(at: position).length
            let raw = text.substring(with: NSRange(location: position, length: length))
            position += length
            let ends = position >= text.length
            if ends { current = nil }
            return Piece(raw: raw, endsAuthoredLine: ends)
        }
    }
}
