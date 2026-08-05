import AppKit
import ThreadingExtensionKit

// MARK: - Defaults

@MainActor
enum GitStatusOverlayDefaults {

    /// The one role every row of the card is set in — branch, counters, agent line and both
    /// button rows — so a stack of readings holds one line box and one column.
    ///
    /// It is the **control** size rather than the detail size it started at. The card is a glance
    /// surface floating over a terminal at whatever size the user set *that* to, and at 11pt its
    /// rows read as a footnote about the pane rather than as the pane's own status. The role also
    /// carries monospaced digits, which is what keeps the counters from reflowing as they count.
    static let font = Design.FontRole.numericControl(weight: .medium)

    /// One line of the card, and the whole card when the checkout is clean and the session has
    /// no children. Every further fact adds a row beneath it rather than words beside it.
    ///
    /// Not a band the rows are laid into — `verticalInset` around one line of the card's own type
    /// *is* this number, which is why a one-row card comes out at the pill height whichever row it
    /// holds. **Derived rather than stated**: it was a literal 26 that matched an 11-point line,
    /// so it was already a point or two out for anyone running the app's text scale above 100%,
    /// and moving the card's type by one step would have left the pill radius measuring the old one.
    static var height: CGFloat { verticalInset * 2 + textRowHeight }

    /// The height of a row that is just words — a label at the card's font, which is its line box
    /// and nothing else.
    static var textRowHeight: CGFloat {
        ceil(font.resolved().boundingRectForFont.height)
    }

    /// Marks are set at the size of the words beside them, so the pair reads as one line rather
    /// than as a symbol with a caption.
    static var markPointSize: CGFloat { font.resolved().pointSize }

    static let maxWidth: CGFloat = 360

    /// From the card's edge to the first and last row.
    ///
    /// A step up from `small`: with the rows on `small` and the edges on `small` too, a
    /// three-fact card read as text pressed against its own border — called out as "too tight
    /// vertically" twice. The single-row pill grows with it, deliberately: one geometry,
    /// whichever row count the card holds, is the rule the whole file is built on.
    static let verticalInset: CGFloat = Design.Spacing.inset

    /// The air a row keeps around its own words — what the hover wash paints, and what the two
    /// button rows are sized to, so all four rows are one shape.
    ///
    /// The card used to have no such number, and it showed the moment the pointer was on it: a
    /// text row's line box is 15pt, the wash could grow by whatever `rowGap` left over, and
    /// `rowGap` left 2 — a 19pt wash around 15pt of words, beside a children button that pads
    /// itself to 22. The wash was *shorter* than the button it sat above, and read as shrink-wrap
    /// on the text rather than as a row lighting up.
    static let rowPadding: CGFloat = Design.Spacing.tight

    /// One row of the card: its words, and `rowPadding` above and below them.
    ///
    /// Every row is this tall — the text rows because the wash says so, the button rows because
    /// they are constrained to it. That is what makes `childrenRowInset` exactly `rowPadding`
    /// rather than whatever height `ThemedButton` happened to pick for itself.
    static var rowHeight: CGFloat { textRowHeight + rowPadding * 2 }
    /// Between one reading and the next. Tighter than the inset, so the rows read as a list
    /// inside a card rather than as three cards sharing a border.
    ///
    /// **Uniform, and that is the whole point.** The card used to centre its leading row in a
    /// 26-point band and leave every row below it bare with the stack spaced at zero, so the
    /// gap under the first line was the band's own half-padding and the gaps under the rest
    /// were nothing. Three facts came out at 6 / 0 / 0 — the branch floating alone and the
    /// counters and the agent line stuck together underneath it. `tight` fixed the rhythm and
    /// still read cramped; `small` is the step that gives each fact its own line of air while
    /// staying inside the inset.
    /// Wide enough for two washes to sit in it and still leave a hairline of ground between
    /// them: `rowPadding` grows each row's wash toward its neighbour, so the gap has to carry
    /// both of them plus the line that keeps them from fusing into one block. At `small` it
    /// could not, and the wash was clamped to 2pt to compensate — the gap was setting the
    /// padding, which is backwards.
    static let rowGap: CGFloat = Design.Spacing.medium
    /// Quiet at rest, per the design system; full under the pointer.
    ///
    /// Carried by the card's **contents** rather than by the card. On the view it also thinned
    /// the fill, and a fill that thins over a conversation is a card with the agent's own text
    /// running through it.
    static let restingContentAlpha: CGFloat = 0.85

    /// Every row leads with a mark, and the marks share one column, so a stack of readings
    /// reads as a list rather than as three sentences that happen to start at the same margin.
    /// The column is the one a titled `ThemedButton` already draws its symbol in, because one
    /// of the rows *is* one — the children line.
    static let markSlot = ThemedButton.markSlotWidth
    static let markGap = ThemedButton.markTitleGap

    /// The most of the pane's width the card may take before it withdraws on its own.
    ///
    /// The card floats **over** the terminal rather than beside it, so what it costs is the text
    /// underneath. At a comfortable width that is a corner; on a pane dragged narrow the same
    /// card is a lid, and the agent's output runs behind it.
    ///
    /// A share rather than a minimum width, because the card's width is the *branch name's* —
    /// a long name on a middling pane is exactly as tight as a short name on a narrow one, and
    /// one rule answers both. Half is where a floating card stops reading as an annotation on
    /// the pane and starts reading as a second column of it.
    static let maximumPaneShare: CGFloat = 0.5

    /// Whether a card that wants `cardWidth` may show in a pane `paneWidth` wide.
    ///
    /// Stated here rather than inline at the one call site so the rule can be read, and asserted,
    /// without a window and a session behind it.
    ///
    /// A pane with no width has not been laid out yet rather than being narrow, and answering
    /// "no room" there would hide the card for the whole of the first layout pass.
    static func hasRoom(forCardWidth cardWidth: CGFloat, inPaneWidth paneWidth: CGFloat) -> Bool {
        guard paneWidth > 0 else { return true }
        return cardWidth <= paneWidth * maximumPaneShare
    }

    /// How far the card lifts while it is off screen.
    ///
    /// Toward the edge it is pinned to, so it tucks away rather than drifting in a direction
    /// nothing else in the pane moves. One step: the motion is punctuation on the fade, and a
    /// card that travels far enough to be watched is a card the eye has to wait for.
    static let withdrawnRise: CGFloat = Design.Spacing.small
}

// MARK: - View

/// The floating card at the session pane's top-right corner: branch and uncommitted work while
/// idle; plan position, changed files and live line totals while the agent is working.
///
/// The pane's surfaces answer "what is the agent saying"; this answers what changed in the
/// checkout and whether delegated agents are active. It stays a summary because both full
/// answers already have surfaces: Git Review and the Subagents display-pane tab.
///
/// **One row per fact.** The card is pinned to the pane's trailing edge and capped at 360
/// points, so every fact added to the line took its width from the branch name — the one thing
/// that says which checkout this is, and the one truncated first. Stacked, each fact keeps the
/// full width and the card grows into the direction it has room in, the same way its extension
/// slot already does.
final class GitStatusOverlayView: BackdropOverlay {

    // MARK: - Types

    /// What the card should say about the agent this session runs, **already reduced to the facts
    /// its own status line does not show**.
    ///
    /// The filtering happens before the card, and deliberately: for a terminal session it is
    /// `ClaudeStatusLineCoverage` that decides — by running the account's `statusLine` and looking
    /// for values Threading already holds — and a native conversation has no status line to
    /// complement, so it passes everything. Either way this view is handed a decision rather than
    /// asked to make one, which is what keeps a Claude-specific rule out of a Git-shaped card.
    ///
    /// A nil field is not "unknown", it is "do not say this". A caller that wants the model shown
    /// puts it here; a caller whose status line already prints it leaves it out.
    struct ModelReading: Equatable {
        var name: String?
        /// Already display-named — "Extra High", not "xhigh".
        var effort: String?
        var isFast = false

        var isEmpty: Bool { name == nil && effort == nil && !isFast }
    }

    // MARK: - Properties

    /// Called when the Git portion is clicked; the container routes it to the review tab.
    var onOpen: (() -> Void)?
    /// The child-agent segment is a distinct destination inside the same status card.
    var onOpenSubagents: (() -> Void)?
    /// So is the audience segment, which opens the sharing pane.
    var onOpenSharing: (() -> Void)?

    /// What the card says about who can see this chat from outside this Mac.
    ///
    /// Both halves are here because the row appears for either: somebody watching is the live
    /// fact, and a link nobody has used yet is the standing one. A chat that is reachable and
    /// unwatched looks exactly like a private chat without this — which is the reason the row
    /// is not gated on `following > 0`.
    struct AudienceReading: Equatable {
        var following = 0
        var isShared = false
        var focusedControllerName: String?

        var isEmpty: Bool { following == 0 && !isShared && focusedControllerName == nil }
    }

    /// The card's rows, top down: the summary line, the counters line, the agent line, the
    /// children line.
    private let content = NSStackView()
    /// The first row — the mark and whichever sentence leads: branch, plan position, or, on a
    /// detached head, the counters themselves.
    private let summaryRow = NSStackView()
    /// The counters line: how many files, and the two totals a step after the count.
    private let countersRow = NSStackView()
    /// The agent line: which model this session is running, and how, for the facts its own
    /// status line does not already say.
    private let modelRow = NSStackView()
    private let glyph = ThemedFloatingGlyphView(
        systemSymbolName: "arrow.triangle.branch",
        classicGlyph: .branch,
        pointSize: GitStatusOverlayDefaults.markPointSize,
        accessibilityDescription: L10n.string("Branch")
    )
    private let countersMark = ThemedFloatingGlyphView(
        systemSymbolName: "plusminus",
        classicGlyph: .changes,
        pointSize: GitStatusOverlayDefaults.markPointSize,
        accessibilityDescription: L10n.string("Changes")
    )
    private let modelMark = ThemedFloatingGlyphView(
        systemSymbolName: "cpu",
        classicGlyph: .model,
        pointSize: GitStatusOverlayDefaults.markPointSize,
        accessibilityDescription: L10n.string("Model")
    )
    private let subagentsButton: ThemedButton
    private let audienceButton: ThemedButton
    private var summaryLabel: NSTextField?
    private var filesLabel: NSTextField?
    private var countersLabel: NSTextField?
    private var modelLabel: NSTextField?
    /// Whether there is a Git sentence to click through to Git Review with.
    private var hasGitReceipt = false

    /// Whether the card has anything to say at all — any row survived the last rebuild.
    ///
    /// One of the **two** answers that decide whether the card is on screen, and deliberately
    /// separate from the other: a card with no branch is absent because there is nothing to
    /// show, and a card the user switched off is absent because they said so. Only the second
    /// is a transition anybody watches, so only the second animates.
    private var hasContent = false

    /// Whether the pane is willing to carry the card: the user's standing choice, and whether
    /// there is width to spend on it. Set from the pane, which is the only thing that knows.
    private var isAllowedOnScreen = true

    /// The applied answer, so a change that does not move the card animates nothing. `isHidden`
    /// cannot serve as this: it lands at the *end* of a vanish, and a second toggle arriving
    /// mid-flight would read the card as still shown and do nothing.
    private var isShowing = false

    /// Which transition is in flight, so a completion cannot land on a card that has since been
    /// asked for the opposite. Toggling twice inside `Motion.vanish` did exactly that, and the
    /// card came back and then hid itself a tenth of a second later.
    private var visibilityGeneration = 0

    /// The `session.corner-card@1` `top-trailing` slot: extension rows under the summary line.
    ///
    /// The slot ID names the corner, not the content — a future leading card becomes a
    /// `top-leading` slot on the same contract. The card grows downward when rows exist and
    /// keeps its exact single-line geometry when they do not.
    private let extensionSlotStack = NSStackView()
    /// The host requires a container, but this contract is slot-only — no hook, no
    /// replacement — so the container never joins the hierarchy and composes nothing.
    private let customizationContainer = ComponentContentContainer(defaultContent: NSView())
    private var customizationHost: ComponentCustomizationHost?
    private var contentTopConstraint: NSLayoutConstraint?
    private var collapsedBottomConstraint: NSLayoutConstraint?
    private var expandedBottomConstraint: NSLayoutConstraint?
    private var slotTopConstraint: NSLayoutConstraint?
    private var rowHeightConstraints: [NSLayoutConstraint] = []
    private var horizontalInsetConstraints: [NSLayoutConstraint] = []
    private var slotRowWidthConstraints: [NSLayoutConstraint] = []

    /// This view sits over the terminal, but owns an opaque chrome surface of its own. The
    /// terminal therefore chooses what surrounds the card; the app theme chooses the card.
    private var floatingStyle: AppTheme.Material.PopoverStyle = .system
    private var surfaceInk: Design.Ink = .chrome
    /// Paired with `surfaceInk` above rather than named as a chrome role: both are placeholders
    /// until `applyInk` resolves the real floating chrome, and an overlay that names
    /// `Design.Surface` is reading a ground it is not drawn on.
    private var surfaceFill: NSColor = Design.Ink.chrome.surface

    /// Held so a backdrop change can rebuild the label, which carries its colours inside an
    /// attributed string and cannot be re-inked in place.
    private var lastReading: GitChangeMonitor.Reading?
    private var isRunActive = false
    private var runProgress: RunProgress?
    private var subagentCounts = (working: 0, done: 0)
    private var modelReading: ModelReading?
    private var audienceReading = AudienceReading()

    /// Lifts the card's *contents* to full strength under the pointer. The surface behind them
    /// does not move: it is what keeps the pane's text out of the card.
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            let alpha = isHovered ? 1 : GitStatusOverlayDefaults.restingContentAlpha
            content.alphaValue = alpha
            extensionSlotStack.alphaValue = alpha
        }
    }

    /// Which Git row the pointer is on — not merely *whether* it is on one.
    ///
    /// The card is **not one button**, and lifting all of it under the pointer said it was: the
    /// Git rows open Git Review, the children row opens the Subagents tab, the audience row opens
    /// sharing, and the agent line and any extension row are readings that do nothing at all. The
    /// two button rows have lit their own words since they were controls; this is what gives the
    /// third destination — the one drawn as text — the same answer.
    ///
    /// Held as the row rather than as a flag because branch and counters share that destination
    /// and still only one of them is under the pointer. Lighting both answered a question nobody
    /// asked — a hover reports where the pointer *is*, and the destination is what the click is
    /// for. Weak, so a rebuilt card cannot keep drawing under a row it no longer holds.
    private weak var hoveredGitRow: NSView? {
        didSet {
            guard hoveredGitRow !== oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - Initialization

    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        subagentsButton = ThemedButton(
            symbol: "person.2",
            accessibility: L10n.string("Open Subagents"),
            target: nil,
            action: nil
        )
        // An eye rather than a person: the row is about being *looked at*, and `person.2` is
        // already the children row two lines above it.
        audienceButton = ThemedButton(
            symbol: "eye",
            accessibility: L10n.string("Open Sharing"),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        toolTip = L10n.string("Open Git Review (⇧⌘R)")
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.cornerCurve = .continuous

        // The summary row's mark says what the row is: the checkout while the card is a branch
        // card, the plan while a run replaces that line. There is deliberately **no spinner
        // here**. A terminal session's CLI draws its own a few lines below, and a native
        // conversation has one beside its status (`ConversationViewController.orbView`), so a
        // third one in the corner was the same sentence three times.
        configureMark(
            glyph,
            symbol: "arrow.triangle.branch",
            classicGlyph: .branch,
            description: L10n.string("Branch")
        )
        configureMark(
            countersMark,
            symbol: "plusminus",
            classicGlyph: .changes,
            description: L10n.string("Changes")
        )
        // The same symbol the composer and the conversation's status row already use for the
        // model chip, so one fact keeps one mark wherever it is shown.
        configureMark(
            modelMark,
            symbol: "cpu",
            classicGlyph: .model,
            description: L10n.string("Model")
        )

        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = GitStatusOverlayDefaults.markGap
        summaryRow.translatesAutoresizingMaskIntoConstraints = false
        summaryRow.addArrangedSubview(glyph)

        countersRow.orientation = .horizontal
        countersRow.alignment = .centerY
        countersRow.spacing = GitStatusOverlayDefaults.markGap
        countersRow.translatesAutoresizingMaskIntoConstraints = false
        countersRow.isHidden = true
        countersRow.addArrangedSubview(countersMark)

        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = GitStatusOverlayDefaults.markGap
        modelRow.translatesAutoresizingMaskIntoConstraints = false
        modelRow.isHidden = true
        modelRow.addArrangedSubview(modelMark)

        // One gap, every row, and the card's own inset around the outside — see `rowGap` for
        // the rhythm this replaced. The children row is the one row that pads itself, and
        // `rebuild()` gives that padding back out of the gap beside it rather than letting the
        // stack count it twice.
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = GitStatusOverlayDefaults.rowGap
        content.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(summaryRow)
        content.addArrangedSubview(countersRow)
        // Under the checkout, over the children: the rows read outward from what this pane *is* —
        // which branch, what changed in it, which agent is working it, who it delegated to.
        content.addArrangedSubview(modelRow)

        subagentsButton.target = self
        subagentsButton.action = #selector(openSubagents)
        subagentsButton.emphasis = .tertiary
        subagentsButton.applyFont(GitStatusOverlayDefaults.font)
        // No hover fill here: `applyInk` states it after resolving the floating chrome surface.
        subagentsButton.setContentHuggingPriority(.required, for: .horizontal)
        subagentsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        subagentsButton.isHidden = true
        content.addArrangedSubview(subagentsButton)

        audienceButton.target = self
        audienceButton.action = #selector(openSharing)
        audienceButton.emphasis = .tertiary
        audienceButton.applyFont(GitStatusOverlayDefaults.font)
        audienceButton.setContentHuggingPriority(.required, for: .horizontal)
        audienceButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        audienceButton.isHidden = true
        // Last, under the children: the rows read outward from the work to the people around it,
        // and who is watching is the outermost fact the card holds.
        content.addArrangedSubview(audienceButton)
        addSubview(content)

        extensionSlotStack.orientation = .vertical
        extensionSlotStack.alignment = .leading
        extensionSlotStack.spacing = GitStatusOverlayDefaults.rowGap
        extensionSlotStack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        extensionSlotStack.translatesAutoresizingMaskIntoConstraints = false
        extensionSlotStack.isHidden = true
        extensionSlotStack.setAccessibilityIdentifier("session.corner-card.slot.top-trailing")
        addSubview(extensionSlotStack)

        // The card is padded rather than banded: the rows sit at their own heights and the
        // three constants below are the air around and between them. One row of 14-point text
        // inset top and bottom is exactly `height`, so a single-line card is still the pill
        // the render tests measure — and it is that whichever of the four rows is the one
        // showing, which the band could only manage by moving from row to row.
        //
        // `rebuild()` sets the constants, because the children row pads itself and the gap
        // beside it has to give that padding back.
        let contentTop = content.topAnchor.constraint(
            equalTo: topAnchor,
            constant: GitStatusOverlayDefaults.verticalInset
        )
        let collapsedBottom = bottomAnchor.constraint(
            equalTo: content.bottomAnchor,
            constant: GitStatusOverlayDefaults.verticalInset
        )
        let expandedBottom = bottomAnchor.constraint(
            equalTo: extensionSlotStack.bottomAnchor,
            constant: GitStatusOverlayDefaults.verticalInset
        )
        let slotTop = extensionSlotStack.topAnchor.constraint(
            equalTo: content.bottomAnchor,
            constant: GitStatusOverlayDefaults.rowGap
        )
        let subagentsHeight = subagentsButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let audienceHeight = audienceButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let contentLeading = content.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Design.Spacing.medium
        )
        let contentTrailing = content.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Design.Spacing.medium
        )
        let slotLeading = extensionSlotStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Design.Spacing.medium
        )
        let slotTrailing = extensionSlotStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Design.Spacing.medium
        )

        // The children row is a button, and a button carries its own padding around the mark it
        // draws. Insetting the text rows by exactly that much is what puts all three marks in
        // one column — and doing it with the stack's own `edgeInsets` rather than a constraint
        // keeps every row's *frame* at the content edge, so the button never has to hang
        // outside its parent to line up, which would leave its leading edge unclickable.
        let markInset = subagentsButton.opticalHorizontalInset
        for row in [summaryRow, countersRow, modelRow] {
            row.edgeInsets = NSEdgeInsets(top: 0, left: markInset, bottom: 0, right: markInset)
        }
        contentTopConstraint = contentTop
        collapsedBottomConstraint = collapsedBottom
        expandedBottomConstraint = expandedBottom
        slotTopConstraint = slotTop
        rowHeightConstraints = [subagentsHeight, audienceHeight]
        horizontalInsetConstraints = [
            contentLeading, contentTrailing, slotLeading, slotTrailing
        ]

        NSLayoutConstraint.activate([
            // The two control rows take the card's row height rather than the one `ThemedButton`
            // sizes itself to. A plain button pads its title to a hit target it picked without
            // knowing what it would sit under, and here that made it 22 beside text rows whose
            // hover reached 19 — three rows on two rhythms. Constrained, every row is one shape
            // and `childrenRowInset` is a number this file states rather than discovers.
            subagentsHeight,
            audienceHeight,
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            contentLeading,
            contentTrailing,
            contentTop,
            slotLeading,
            slotTrailing,
            slotTop,
            collapsedBottom
        ])

        customizationHost = ComponentCustomizationHost(
            target: .sessionCornerCard(),
            contentContainer: customizationContainer,
            slots: ["top-trailing": extensionSlotStack],
            lookup: customizationLookup,
            imageResolver: ExtensionComponentResourceResolver.image,
            onResolution: { [weak self] _ in self?.needsLayout = true }
        )
        // Detached until the container binds a real session; family-wide publications must not
        // decorate a card that is not anyone's checkout yet.
        customizationHost?.deactivate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// The terminal owns the ground around this card; the app theme owns the opaque floating
    /// surface and every mark on it. That distinction is why a Windows 98 window gets an
    /// infotip-like corner card even above a green terminal, rather than a modern dark pill.
    ///
    /// `+N −M` stays green and red — those two are semantic rather than decorative, and a green
    /// that stopped meaning added would cost more than the contrast it bought — but it is the
    /// theme's green *measured against this card* (`Design.Diff.on(_:)`), which keeps the hue and
    /// moves only the lightness when the card is too close to it. The surface role is flattened
    /// against the theme's ground, so a translucent authored role cannot reveal terminal text.
    override func applyInk(_: Design.Ink) {
        // Backdrop changes still arrive here because the terminal owns what surrounds the card.
        let chrome = ThemedFloatingSurfaceChrome.current(for: effectiveAppearance)
        floatingStyle = chrome.style
        surfaceInk = chrome.ink
        surfaceFill = chrome.fill
        chrome.apply(to: self)

        for mark in [glyph, countersMark, modelMark] {
            mark.setPointSize(GitStatusOverlayDefaults.markPointSize)
        }
        glyph.tintColor = surfaceInk.secondary
        countersMark.tintColor = surfaceInk.tertiary
        modelMark.tintColor = surfaceInk.tertiary
        // Both button rows, the same way. The audience row used to be given neither, so it drew
        // in AppKit's own label colour and lifted to nothing under the pointer — the one row of
        // the card that was inert by omission rather than by design.
        for button in [subagentsButton, audienceButton] {
            button.contentTintColor = surfaceInk.secondary
            button.hoverFill = surfaceInk.surfaceHover
        }
        applyDensity()
        needsDisplay = true
        rebuild()
    }

    // MARK: - Public Methods

    func update(with reading: GitChangeMonitor.Reading) {
        lastReading = reading
        rebuild()
    }

    /// Promotes the ordinary branch card into the live run receipt shown in the same place.
    ///
    /// The checkout monitor continues feeding `update(with:)`, so file and line totals move
    /// independently of plan updates. There is no spinner in this promotion: the plan position
    /// *is* the receipt, and whichever surface the session actually uses already animates one.
    func updateRunState(isActive: Bool, progress: RunProgress?) {
        isRunActive = isActive
        runProgress = isActive ? progress : nil
        rebuild()
    }

    /// Adds the session's child-agent receipt to the same top-right card as branch and diff.
    ///
    /// It is its own hit target: the rest of the card still opens Git Review, while this
    /// segment opens the Subagents tab in the display pane.
    func updateSubagents(workingCount: Int, doneCount: Int) {
        subagentCounts = (
            working: max(0, workingCount),
            done: max(0, doneCount)
        )
        rebuild()
    }

    /// States which agent facts the card is responsible for, or nil to say none.
    ///
    /// Nil and an all-nil reading mean the same thing here — no agent line — because the caller
    /// that has nothing to add and the caller whose status line already says everything both want
    /// the row gone.
    func updateModel(_ reading: ModelReading?) {
        modelReading = (reading?.isEmpty ?? true) ? nil : reading
        rebuild()
    }

    /// States who can see this chat from outside this Mac, and how many are looking now.
    func updateAudience(_ reading: AudienceReading) {
        guard reading != audienceReading else { return }
        audienceReading = reading
        rebuild()
    }

    func clear() {
        lastReading = nil
        isRunActive = false
        runProgress = nil
        subagentCounts = (working: 0, done: 0)
        modelReading = nil
        audienceReading = AudienceReading()
        hasGitReceipt = false
        subagentsButton.isHidden = true
        audienceButton.isHidden = true
        modelRow.isHidden = true
        hasContent = false
        applyVisibility(animated: false)
    }

    /// Whether the pane will carry the card — the user's toggle, and whether the pane is wide
    /// enough to spend the room on it.
    ///
    /// Animated, unlike the content answer: this is a change the user either asked for or
    /// caused with a divider, and both are worth watching land. A card with nothing to say
    /// stays hidden either way; this only ever decides whether one that *has* something is
    /// allowed to show it.
    func setAllowedOnScreen(_ allowed: Bool, animated: Bool) {
        guard allowed != isAllowedOnScreen else { return }
        isAllowedOnScreen = allowed
        applyVisibility(animated: animated)
    }

    /// Binds the extension slot to the session on screen, or detaches it between sessions.
    ///
    /// Extension rows ride the card's own visibility: a pane with no checkout reading shows
    /// no card, so a bound slot on a hidden card renders nothing the user can see.
    func showSession(_ sessionID: String?) {
        if let sessionID {
            customizationHost?.updateTarget(.sessionCornerCard(sessionID: sessionID))
        } else {
            customizationHost?.deactivate()
        }
    }

    // MARK: - Layout

    /// Keeps the card in step with whatever the customization host just rendered into the
    /// slot: each row stretches to the card's width so a flexible spacer can hold name and
    /// state apart, and the bottom edge tracks the last row only while rows exist — with the
    /// slot empty the collapsed constraint reproduces the original single-line height exactly.
    override func layout() {
        let rows = extensionSlotStack.arrangedSubviews
        if rows.isEmpty {
            expandedBottomConstraint?.isActive = false
            collapsedBottomConstraint?.isActive = true
        } else {
            collapsedBottomConstraint?.isActive = false
            expandedBottomConstraint?.isActive = true
        }

        let tracked = slotRowWidthConstraints.compactMap { $0.firstItem as? NSView }
        if tracked != rows {
            NSLayoutConstraint.deactivate(slotRowWidthConstraints)
            slotRowWidthConstraints = rows.map {
                $0.widthAnchor.constraint(equalTo: extensionSlotStack.widthAnchor)
            }
            NSLayoutConstraint.activate(slotRowWidthConstraints)
        }
        super.layout()

        // A row appearing or leaving moves the rows that act, under a pointer that has not
        // moved and a cursor rect the window still believes.
        refreshGitHover()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Private Methods

    private var verticalInset: CGFloat {
        floatingStyle.density == .compact
            ? Design.Spacing.small
            : GitStatusOverlayDefaults.verticalInset
    }

    private var rowPadding: CGFloat {
        floatingStyle.density == .compact
            ? Design.Spacing.hairline
            : GitStatusOverlayDefaults.rowPadding
    }

    private var rowGap: CGFloat {
        floatingStyle.density == .compact
            ? Design.Spacing.small
            : GitStatusOverlayDefaults.rowGap
    }

    private var horizontalInset: CGFloat {
        floatingStyle.density == .compact
            ? Design.Spacing.small
            : Design.Spacing.medium
    }

    private func applyDensity() {
        content.spacing = rowGap
        extensionSlotStack.spacing = rowGap
        expandedBottomConstraint?.constant = verticalInset
        for constraint in rowHeightConstraints {
            constraint.constant = GitStatusOverlayDefaults.textRowHeight + rowPadding * 2
        }
        for (index, constraint) in horizontalInsetConstraints.enumerated() {
            constraint.constant = index.isMultiple(of: 2) ? horizontalInset : -horizontalInset
        }
    }

    private func rebuild() {
        // The counters sit on the card, not on the terminal backdrop around it.
        let diff = Design.Diff.on(surfaceFill)
        let head = Self.headText(
            for: lastReading,
            isRunActive: isRunActive,
            progress: runProgress,
            ink: surfaceInk
        )
        let counters = Self.countersText(for: lastReading, ink: surfaceInk, diff: diff)

        let model = Self.modelText(for: modelReading, ink: surfaceInk)

        hasGitReceipt = head != nil || counters != nil
        let hasSubagents = subagentCounts.working + subagentCounts.done > 0
        let hasAudience = !audienceReading.isEmpty
        guard hasGitReceipt || hasSubagents || hasAudience || model != nil else {
            hasContent = false
            applyVisibility(animated: false)
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        for view in [summaryLabel, filesLabel, countersLabel, modelLabel] {
            view?.removeFromSuperview()
        }
        summaryLabel = nil
        filesLabel = nil
        countersLabel = nil
        modelLabel = nil

        if let head {
            let label = NSTextField.label(attributed: head)
            label.cell?.lineBreakMode = .byTruncatingMiddle
            summaryLabel = label
            summaryRow.addArrangedSubview(label)
            glyph.setSymbol(
                isRunActive ? "checklist" : "arrow.triangle.branch",
                classicGlyph: isRunActive ? .plan : .branch,
                accessibilityDescription: isRunActive ? L10n.string("Plan") : L10n.string("Branch")
            )
        }
        if let counters {
            let files = NSTextField.label(attributed: counters.files)
            files.cell?.lineBreakMode = .byTruncatingTail
            filesLabel = files
            countersRow.addArrangedSubview(files)

            let totals = NSTextField.label(attributed: counters.totals)
            totals.setContentHuggingPriority(.required, for: .horizontal)
            totals.setContentCompressionResistancePriority(.required, for: .horizontal)
            countersLabel = totals
            countersRow.addArrangedSubview(totals)
            // A step wider than the gap after a mark, and no wider: the totals are a second
            // reading on the same line, not a second column.
            //
            // They used to be held to the card's trailing edge by a flexible spacer. The card
            // is only as wide as its longest row, so on a long branch name that spacer opened a
            // hole halfway across the counters line and nowhere else — one stretched gap in a
            // card whose every other row starts and ends on its own ink.
            countersRow.setCustomSpacing(
                floatingStyle.density == .compact ? Design.Spacing.small : Design.Spacing.medium,
                after: files
            )
        }
        if let model {
            let label = NSTextField.label(attributed: model)
            label.cell?.lineBreakMode = .byTruncatingTail
            modelLabel = label
            modelRow.addArrangedSubview(label)
        }

        summaryRow.isHidden = head == nil
        countersRow.isHidden = counters == nil
        modelRow.isHidden = model == nil
        subagentsButton.isHidden = !hasSubagents
        audienceButton.isHidden = !hasAudience

        // A button row draws its own padding — a button pads its title out to something a
        // pointer can hit — so wherever one touches an inset or a gap, that inset or gap gives
        // the padding back and the ink lands on the same rhythm as every other row's. Two of
        // them meeting give it back twice, once for each.
        let childrenInset = childrenRowInset
        let textRows = [summaryRow, countersRow, modelRow].filter { !$0.isHidden }
        let buttonRows = [subagentsButton, audienceButton].filter { !$0.isHidden }
        let hasButtonRows = !buttonRows.isEmpty
        contentTopConstraint?.constant = textRows.isEmpty
            ? max(0, verticalInset - childrenInset)
            : verticalInset
        let bottomInset = hasButtonRows
            ? max(0, verticalInset - childrenInset)
            : verticalInset
        collapsedBottomConstraint?.constant = bottomInset
        // Extension rows continue the same list, so they join it on the same gap.
        slotTopConstraint?.constant = hasButtonRows
            ? max(0, rowGap - childrenInset)
            : rowGap
        for row in textRows.dropLast() {
            content.setCustomSpacing(NSStackView.useDefaultSpacing, after: row)
        }
        if let above = textRows.last {
            content.setCustomSpacing(
                hasButtonRows
                    ? max(0, rowGap - childrenInset)
                    : NSStackView.useDefaultSpacing,
                after: above
            )
        }
        for row in buttonRows.dropLast() {
            content.setCustomSpacing(
                max(0, rowGap - 2 * childrenInset),
                after: row
            )
        }

        if hasSubagents {
            let working = subagentCounts.working
            let done = subagentCounts.done
            let workingText = L10n.format("%lld working", Int64(working))
            let doneText = L10n.format("%lld done", Int64(done))
            subagentsButton.title = working > 0 ? "\(workingText) · \(doneText)" : doneText
            // A titled `ThemedButton` deliberately exposes its visible title to accessibility.
            // Put the destination in help instead of trying to replace that truthful title.
            subagentsButton.setAccessibilityHelp(L10n.string("Open Subagents"))
        }
        if hasAudience {
            audienceButton.title = Self.audienceText(audienceReading)
            audienceButton.setAccessibilityHelp(L10n.string("Open Sharing"))
            audienceButton.toolTip = audienceReading.following > 0
                ? L10n.string("Somebody has this chat open from another device")
                : L10n.string("This chat has been shared. Nobody is watching it right now.")
        }
        // The agent line rides whichever label the card already spoke: it is a row of the same
        // card, and a row nobody hears is a row that is not there for half the readers. It does
        // not make the card *clickable* — only a Git receipt does that, so the role still follows
        // `hasGitReceipt` and a model-only card stays a group.
        if hasGitReceipt {
            setAccessibilityRole(.button)
            setAccessibilityLabel(Self.spokenText(
                for: lastReading,
                isRunActive: isRunActive,
                progress: runProgress,
                model: modelReading
            ))
            toolTip = L10n.string("Open Git Review (⇧⌘R)")
        } else {
            setAccessibilityRole(.group)
            var parts: [String] = []
            if hasSubagents {
                parts.append(L10n.format("Subagents: %@", subagentsButton.title))
            }
            if hasAudience {
                parts.append(Self.audienceText(audienceReading))
            }
            if let spoken = Self.spokenModelText(for: modelReading) {
                parts.append(spoken)
            }
            setAccessibilityLabel(parts.joined(separator: "  ·  "))
            toolTip = nil
        }
        hasContent = true
        applyVisibility(animated: false)
    }

    /// The vertical air a button row draws inside its own frame.
    ///
    /// It is the one row that is a control rather than a line of text: its title sits inboard of
    /// its frame by this much at the top and the bottom, while every other row is a bare label
    /// whose frame is its line box. Wherever the two meet — a gap, the card's own inset — that
    /// space gives the padding back so the ink lands on one rhythm.
    ///
    /// Stated rather than measured off `intrinsicContentSize`, now that the button rows are
    /// constrained to `rowHeight`: asking the control what height it chose was asking the wrong
    /// party, and the answer (22 against a 15pt line) was the number the card then had to work
    /// around instead of the number it wanted.
    private var childrenRowInset: CGFloat { rowPadding }

    /// The height of a row that is just words — an `NSTextField.label` at the card's font, which
    /// is its line box and nothing else.
    private static var textRowHeight: CGFloat { GitStatusOverlayDefaults.textRowHeight }

    /// One mark, sized and centred in the column every row's mark shares.
    private func configureMark(
        _ view: ThemedFloatingGlyphView,
        symbol: String,
        classicGlyph: ThemedFloatingGlyphView.ClassicGlyph,
        description: String
    ) {
        view.setSymbol(
            symbol,
            classicGlyph: classicGlyph,
            accessibilityDescription: description
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.widthAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.markSlot
        ).isActive = true
    }

    /// The card's leading line: the plan position while a run is in flight, the branch otherwise.
    ///
    /// Nil for a detached head with no run, which leaves the counters row — which has a mark of
    /// its own — to lead, and nil with nothing at all, which is the caller's cue to hide the card.
    private static func headText(
        for reading: GitChangeMonitor.Reading?,
        isRunActive: Bool,
        progress: RunProgress?,
        ink: Design.Ink
    ) -> NSAttributedString? {
        let font = GitStatusOverlayDefaults.font.resolved()
        if isRunActive {
            return NSAttributedString(
                string: progress?.label ?? "Working…",
                attributes: [.font: font, .foregroundColor: ink.label]
            )
        }
        guard let branch = reading?.branch else { return nil }
        return NSAttributedString(
            string: branch,
            attributes: [.font: font, .foregroundColor: ink.secondary]
        )
    }

    /// The counters line: how many files, then `+N −M` a step after it.
    ///
    /// The file count is no longer a run-only extra. It is the label the row wants beside its
    /// totals, and one presentation is one thing to learn — the card used to say it during a run
    /// and drop it the moment the turn ended, which is the sort of mode nobody asked for.
    ///
    /// **The totals are abbreviated** — `+4.2K` — in the notation the reader's locale uses.
    /// The card is a glance surface under a 360-point ceiling floating over the pane's own
    /// content, and the exact figure is one click away in Git Review, whose changed-files pill
    /// abbreviates the same diff the same way. `spokenText` keeps the exact counts: an
    /// abbreviation read aloud is a number lost rather than a number shortened.
    private static func countersText(
        for reading: GitChangeMonitor.Reading?,
        ink: Design.Ink,
        diff: Design.DiffInk
    ) -> (files: NSAttributedString, totals: NSAttributedString)? {
        guard let reading, !reading.summary.isClean else { return nil }
        let font = GitStatusOverlayDefaults.font.resolved()

        let files = NSAttributedString(
            string: Self.fileCount(reading.summary.files),
            attributes: [.font: font, .foregroundColor: ink.secondary]
        )
        let totals = NSMutableAttributedString()
        totals.append(NSAttributedString(string: "+\(compact(reading.summary.added))", attributes: [
            .font: font,
            .foregroundColor: diff.added
        ]))
        totals.append(NSAttributedString(string: " −\(compact(reading.summary.removed))", attributes: [
            .font: font,
            .foregroundColor: diff.removed
        ]))
        return (files, totals)
    }

    /// The agent line: the model leading, then how it is running.
    ///
    /// The name takes `secondary` and its qualifiers `tertiary` — the same split the counters row
    /// makes between the file count and its totals, and what keeps a three-part line reading as
    /// one fact with detail rather than three of equal weight.
    ///
    /// Nil when there is nothing to say, which is the caller's cue to hide the row. Each part is
    /// independently optional because the caller has already dropped whatever the session's own
    /// status line prints: a line of just "Fast" is the correct output for an account whose status
    /// line names the model and effort but not the speed.
    private static func modelText(
        for reading: ModelReading?,
        ink: Design.Ink
    ) -> NSAttributedString? {
        guard let reading, !reading.isEmpty else { return nil }
        let font = GitStatusOverlayDefaults.font.resolved()
        let text = NSMutableAttributedString()

        if let name = reading.name {
            text.append(NSAttributedString(string: name, attributes: [
                .font: font,
                .foregroundColor: ink.secondary
            ]))
        }

        var details: [String] = []
        if reading.isFast { details.append(L10n.string("Fast")) }
        if let effort = reading.effort { details.append(effort) }
        guard !details.isEmpty else { return text }

        let joined = details.joined(separator: " · ")
        text.append(NSAttributedString(
            string: text.length == 0 ? joined : " · \(joined)",
            attributes: [.font: font, .foregroundColor: ink.tertiary]
        ))
        return text
    }

    /// The audience row's words.
    ///
    /// A count while somebody is here, because the number is the fact; the bare state otherwise,
    /// because "0 following" is a row spent saying nothing. What the row is *for* in that second
    /// case is that the chat is reachable at all.
    private static func audienceText(_ reading: AudienceReading) -> String {
        let following = reading.following > 0
            ? L10n.format("%lld following", Int64(reading.following))
            : nil
        if let controller = reading.focusedControllerName {
            let control = L10n.format("%@ controlling", controller)
            return [control, following].compactMap { $0 }.joined(separator: " · ")
        }
        return following ?? L10n.string("Shared")
    }

    /// The agent line as one spoken phrase, or nil when the card has no agent row.
    private static func spokenModelText(for reading: ModelReading?) -> String? {
        guard let reading, !reading.isEmpty else { return nil }
        var parts: [String] = []
        if let name = reading.name { parts.append(name) }
        if reading.isFast { parts.append(L10n.string("Fast")) }
        if let effort = reading.effort { parts.append(effort) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every row the card is showing, as one sentence, for the reader who hears it rather than
    /// sees it: exact counts, and a separator where the eye sees a line break.
    private static func spokenText(
        for reading: GitChangeMonitor.Reading?,
        isRunActive: Bool,
        progress: RunProgress?,
        model: ModelReading?
    ) -> String {
        var parts: [String] = []
        if isRunActive {
            parts.append(progress?.label ?? "Working…")
        } else if let branch = reading?.branch {
            parts.append(branch)
        }

        if let reading, !reading.summary.isClean {
            parts.append(
                fileCount(reading.summary.files)
                    + " +\(formatted(reading.summary.added))"
                    + " −\(formatted(reading.summary.removed))"
            )
        }

        if let spoken = spokenModelText(for: model) { parts.append(spoken) }

        return parts.joined(separator: "  ·  ")
    }

    private static func fileCount(_ files: Int) -> String {
        files == 1 ? L10n.string("1 file") : L10n.format("%lld files", Int64(files))
    }

    /// Counts follow the user's locale: `8,349`, `8 349`, and their equivalents are the same
    /// number rendered in the notation the rest of the system uses.
    private static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    /// The same number at a glance, in the reader's own notation: `4.2K` in English, `4,2 tn`
    /// in Swedish. Below a thousand this is the exact count, so short diffs are untouched.
    private static func compact(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    // MARK: - Visibility

    /// Puts the card on screen, or takes it off, in the app's own tempo.
    ///
    /// The fade is what carries it; the lift is punctuation. Both are needed: alpha alone on a
    /// card that floats over live terminal text reads as the text brightening rather than as a
    /// card leaving, because the thing arriving underneath is moving too.
    ///
    /// Arriving eases *out* and leaving eases *in*, at `Motion.appear` and `Motion.vanish` —
    /// the asymmetry every other surface here uses, since arriving is information the eye
    /// follows and leaving is a decision already made.
    private func applyVisibility(animated: Bool) {
        let shouldShow = hasContent && isAllowedOnScreen
        guard shouldShow != isShowing else { return }
        isShowing = shouldShow
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        // `reducesMotion` is checked here rather than left to the zero durations below, because
        // a zero-length animation still defers its completion by a run-loop turn — and the end
        // state is what a caller under Reduce Motion is entitled to have *now*.
        guard animated, !Design.Motion.reducesMotion else {
            settleVisibility(shouldShow)
            return
        }

        if shouldShow {
            isHidden = false
            alphaValue = 0
            layer?.transform = withdrawnTransform
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shouldShow ? Design.Motion.appear : Design.Motion.vanish
            context.timingFunction = CAMediaTimingFunction(
                name: shouldShow ? .easeOut : .easeIn
            )
            context.allowsImplicitAnimation = true
            animator().alphaValue = shouldShow ? 1 : 0
            layer?.transform = shouldShow ? CATransform3DIdentity : withdrawnTransform
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                self.settleVisibility(shouldShow)
            }
        })
    }

    /// Where the card rests while it is off screen: lifted toward the edge it hangs from.
    ///
    /// A layer transform rather than the constraint that positions it, because this is not a
    /// change of layout — the card's place in the pane is the same place while it is away, and
    /// a constraint animated here would be a second opinion about it that outlives the fade.
    private var withdrawnTransform: CATransform3D {
        CATransform3DMakeTranslation(0, GitStatusOverlayDefaults.withdrawnRise, 0)
    }

    /// The end state, with nothing in flight between here and it.
    private func settleVisibility(_ shown: Bool) {
        isHidden = !shown
        alphaValue = shown ? 1 : 0
        layer?.transform = CATransform3DIdentity
        guard !shown else { return }
        // No exit is delivered to a view hidden out from under the pointer, so a card that left
        // lit would come back lit — and come back lit on whichever row the pointer happened to
        // be over when it went.
        isHovered = false
        hoveredGitRow = nil
    }

    // MARK: - Interaction

    /// The part of the card that opens Git Review, or nil when there is nothing to open.
    ///
    /// It is the checkout's own rows and not the whole card. The card carries three destinations
    /// and two facts, and while the pointer lit all five equally the only way to find out which
    /// was which was to click: the agent line and an extension row do nothing, and the two button
    /// rows go somewhere else entirely.
    ///
    /// This union is the **hit target and cursor rect only** — the wash is drawn under the single
    /// row the pointer is on, see `washRect(for:)`. The target stays one rect so the gap between
    /// the two rows is not a dead zone a click can fall through; grown by the children row's own
    /// padding so a pointer lands on it as easily as on the button below.
    private var gitRegion: NSRect? {
        let rows = gitRows.map(\.frame)
        guard var union = rows.first else { return nil }
        for row in rows.dropFirst() { union = union.union(row) }
        return convert(union, from: content).insetBy(dx: 0, dy: -childrenRowInset)
    }

    /// The rows that open Git Review, top down and only while they are on screen.
    private var gitRows: [NSView] {
        guard hasGitReceipt else { return [] }
        return [summaryRow, countersRow].filter { !$0.isHidden }
    }

    /// The wash under one Git row — its own line, never the pair's union.
    ///
    /// Branch and counters as one solid block read as one *fact*, and they are two, so the rect
    /// is a row's line box grown to `rowHeight`: the same shape the button rows below it hold,
    /// which is what makes a lit text row and a lit control row read as the same kind of thing.
    ///
    /// The `min` is a guard, not the rule. `rowGap` is chosen to carry both neighbouring washes
    /// and the hairline between them, and the clamp is what says so out loud — two washes fusing
    /// across the gap would put the pair back to the single block this whole shape avoids.
    private func washRect(for row: NSView) -> NSRect {
        let breathing = min(
            rowPadding,
            (rowGap - Design.Spacing.hairline) / 2
        )
        return convert(row.frame, from: content).insetBy(dx: 0, dy: -breathing)
    }

    /// Draws the wash under the one row the pointer is on.
    ///
    /// On the card rather than in a control of its own, because the rows *are* the card's own
    /// layout — the marks share one column with the children row's, and a wrapper around two of
    /// the four rows would have to reproduce the whole rhythm to keep it. The fill is the weight
    /// the children row already lifts to (`surfaceInk.surfaceHover`), measured against the
    /// floating card the theme owns.
    override func draw(_ dirtyRect: NSRect) {
        guard let row = hoveredGitRow, !row.isHidden else { return }
        ThemedSurface.draw(washRect(for: row), fill: surfaceInk.surfaceHover)
    }

    override func mouseDown(with event: NSEvent) {
        // Asked before the event is read: `hasGitReceipt` is false for a card that is only an
        // agent line, and the location of an event that never came from a mouse is not a point.
        guard hasGitReceipt, let region = gitRegion else { return }
        if region.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    /// A card with a Git sentence calls itself a button, and a button that cannot be pressed is
    /// a label wearing the wrong role. VoiceOver reaches the same destination the pointer does.
    override func accessibilityPerformPress() -> Bool {
        guard hasGitReceipt, let onOpen else { return false }
        onOpen()
        return true
    }

    @objc private func openSubagents() {
        onOpenSubagents?()
    }

    @objc private func openSharing() {
        onOpenSharing?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // The card is pinned to the pane's trailing edge, so opening a panel slides it out from
        // under a pointer that never moved and no exit is delivered — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
        // The same staleness one level in: the card grows and loses rows while the pointer rests
        // on it, so the region under the pointer can change without the pointer moving at all.
        refreshGitHover()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshGitHover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoveredGitRow = nil
    }

    override func mouseMoved(with event: NSEvent) {
        updateGitHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Where the pointer is *now*, rather than where an event last said it was — which is the
    /// question to ask when the card moved and the pointer did not.
    private func refreshGitHover() {
        guard isHovered else {
            hoveredGitRow = nil
            return
        }
        // No window, no pointer to measure against: keep the event stream's last answer. A
        // fixture card has no window, and its layout pass ran through here and erased the
        // hover the test had just delivered — the wash the assertions then looked for was
        // drawn once and repainted away before the capture.
        guard let window else { return }
        updateGitHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Which row the wash belongs to for a pointer at `point`.
    ///
    /// The hit target is the pair's union and the washes are the two lines inside it, so the
    /// union is wider and taller than they are: the gap they leave between them, the padding
    /// grown past it, and — since the rows are as wide as their own words — the ground beside
    /// the shorter of the two. A pointer there clicks through to Git Review, so it lights the
    /// row it is nearest rather than nothing at all; anywhere else on the card lights nothing.
    private func updateGitHover(at point: NSPoint) {
        guard let region = gitRegion, region.contains(point) else {
            hoveredGitRow = nil
            return
        }
        let rows = gitRows
        if let under = rows.first(where: { washRect(for: $0).contains(point) }) {
            hoveredGitRow = under
            return
        }
        hoveredGitRow = rows.min {
            abs(point.y - washRect(for: $0).midY) < abs(point.y - washRect(for: $1).midY)
        }
    }

    /// The pointing hand belongs to the rows that act, and to nothing else on the card. It used
    /// to cover the whole of it — including a card holding no Git sentence, where a click did
    /// nothing at all and the cursor had already promised otherwise.
    override func resetCursorRects() {
        guard let region = gitRegion else { return }
        addCursorRect(region, cursor: .pointingHand)
    }
}
