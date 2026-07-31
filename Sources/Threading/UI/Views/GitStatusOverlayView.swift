import AppKit
import ThreadingExtensionKit

// MARK: - Defaults

@MainActor
enum GitStatusOverlayDefaults {
    /// One line of the card, and the whole card when the checkout is clean and the session has
    /// no children. Every further fact adds a row beneath it rather than words beside it.
    static let height: CGFloat = 26
    static let fontSize: CGFloat = 11
    static let maxWidth: CGFloat = 360
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

    /// The card's rows, top down: the summary line, the counters line, the agent line, the
    /// children line.
    private let content = NSStackView()
    /// The first row — the mark and whichever sentence leads: branch, plan position, or, on a
    /// detached head, the counters themselves.
    private let summaryRow = NSStackView()
    /// The counters line: how many files, and the two totals held to the trailing edge.
    private let countersRow = NSStackView()
    /// The agent line: which model this session is running, and how, for the facts its own
    /// status line does not already say.
    private let modelRow = NSStackView()
    private let glyph = NSImageView()
    private let countersMark = NSImageView()
    private let modelMark = NSImageView()
    private let subagentsButton: ThemedButton
    private var summaryLabel: NSTextField?
    private var filesLabel: NSTextField?
    private var countersGap: NSView?
    private var countersLabel: NSTextField?
    private var modelLabel: NSTextField?
    /// Whether there is a Git sentence to click through to Git Review with.
    private var hasGitReceipt = false

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
    private var collapsedBottomConstraint: NSLayoutConstraint?
    private var expandedBottomConstraint: NSLayoutConstraint?
    private var slotTopConstraint: NSLayoutConstraint?
    private var summaryRowHeightConstraint: NSLayoutConstraint?
    private var countersRowHeightConstraint: NSLayoutConstraint?
    private var modelRowHeightConstraint: NSLayoutConstraint?
    private var slotRowWidthConstraints: [NSLayoutConstraint] = []

    /// Held so a backdrop change can rebuild the label, which carries its colours inside an
    /// attributed string and cannot be re-inked in place.
    private var lastReading: GitChangeMonitor.Reading?
    private var isRunActive = false
    private var runProgress: RunProgress?
    private var subagentCounts = (working: 0, done: 0)
    private var modelReading: ModelReading?

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
        // third one in the corner was the same sentence three times — and the only one of the
        // three sitting on the terminal's own palette, where an accent it never chose reads as
        // a stray colour rather than as a state.
        configureMark(glyph, symbol: "arrow.triangle.branch", description: L10n.string("Branch"))
        configureMark(countersMark, symbol: "plusminus", description: L10n.string("Changes"))
        // The same symbol the composer and the conversation's status row already use for the
        // model chip, so one fact keeps one mark wherever it is shown.
        configureMark(modelMark, symbol: "cpu", description: L10n.string("Model"))

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

        // No spacing between rows: the summary band and the children button are each a
        // 26-point band with their own text centred in it, so the padding is already there.
        // A spacing token here would be counted twice and the lines would drift apart.
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
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
        subagentsButton.applyFont(.numericDetail(weight: .medium))
        // No hoverFill here: this is a BackdropOverlay, and `applyInk` states it from the
        // ink measured against the terminal's backdrop — a chrome role would be wrong by
        // exactly the amount the two palettes differ.
        subagentsButton.setContentHuggingPriority(.required, for: .horizontal)
        subagentsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        subagentsButton.isHidden = true
        content.addArrangedSubview(subagentsButton)
        addSubview(content)

        extensionSlotStack.orientation = .vertical
        extensionSlotStack.alignment = .leading
        extensionSlotStack.spacing = Design.Spacing.tight
        extensionSlotStack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        extensionSlotStack.translatesAutoresizingMaskIntoConstraints = false
        extensionSlotStack.isHidden = true
        extensionSlotStack.setAccessibilityIdentifier("session.corner-card.slot.top-trailing")
        addSubview(extensionSlotStack)

        // The summary keeps its exact 26-point band — top-pinned now instead of centred, so
        // the card can grow downward under further rows without moving a pixel of the line
        // the render tests measure. With one row and an empty slot the collapsed bottom
        // reproduces the original fixed height.
        //
        // The two constants are the padding a *bare* last row does not carry itself, set in
        // `rebuild()`: a band-shaped row (the summary line, the children button) already ends
        // in its own half-band, while the counters line is a label and would otherwise sit on
        // the card's edge.
        let collapsedBottom = bottomAnchor.constraint(equalTo: content.bottomAnchor)
        let expandedBottom = bottomAnchor.constraint(
            equalTo: extensionSlotStack.bottomAnchor,
            constant: Design.Spacing.small
        )
        let slotTop = extensionSlotStack.topAnchor.constraint(equalTo: content.bottomAnchor)
        let summaryRowHeight = summaryRow.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.height
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
        let countersRowHeight = countersRow.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.height
        )
        countersRowHeight.isActive = false
        // Whichever row leads carries the card's top padding, and only a band does — so every
        // row that *can* lead needs the band available to it. The agent line leads a card with no
        // checkout sentence and no counters, which is a detached head with a clean tree.
        let modelRowHeight = modelRow.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.height
        )
        modelRowHeight.isActive = false
        collapsedBottomConstraint = collapsedBottom
        expandedBottomConstraint = expandedBottom
        slotTopConstraint = slotTop
        summaryRowHeightConstraint = summaryRowHeight
        countersRowHeightConstraint = countersRowHeight
        modelRowHeightConstraint = modelRowHeight

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            content.topAnchor.constraint(equalTo: topAnchor),
            summaryRowHeight,
            // Full width, so the totals sit at the card's trailing edge rather than trailing the
            // file count — the two columns a list of readings is made of.
            countersRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            extensionSlotStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            extensionSlotStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
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

    /// This card floats on the *terminal's* background, not on the chrome's ground — see
    /// `BackdropOverlay`. Its surface and its label both come from there.
    ///
    /// `+N −M` stays green and red — those two are semantic rather than decorative, and a green
    /// that stopped meaning added would cost more than the contrast it bought — but it is the
    /// theme's green *measured against this card* (`Design.Diff.on(_:)`), which keeps the hue and
    /// moves only the lightness when the card is too close to it. The card's colour comes from
    /// the terminal's palette, so the app theme cannot know what its own green will land on.
    /// **The card is opaque**, which the roles it draws from are not. It floats over the pane's
    /// live content — a conversation, or the terminal itself — rather than over an empty stretch
    /// of backdrop, so `ink.surface` at 14% let the text underneath run straight through the
    /// branch name. Flattening against the ground keeps exactly the colour the role asks for and
    /// loses only the see-through; `WindowBackdrop.opaque` carries the reasoning.
    ///
    /// The border flattens against the *card*, not the ground, because that is what is behind it.
    override func applyInk(_ ink: Design.Ink) {
        layer?.cornerRadius = Design.Radius.pill(height: GitStatusOverlayDefaults.height)
        let surface = WindowBackdrop.opaque(ink.surface)
        applyLayerBackground(surface)
        layer?.borderWidth = Design.Radius.border
        applyLayerBorder(ink.border.composited(over: surface))
        glyph.contentTintColor = ink.secondary
        countersMark.contentTintColor = ink.tertiary
        modelMark.contentTintColor = ink.tertiary
        subagentsButton.contentTintColor = ink.secondary
        subagentsButton.hoverFill = ink.surfaceHover
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

    func clear() {
        lastReading = nil
        isRunActive = false
        runProgress = nil
        subagentCounts = (working: 0, done: 0)
        modelReading = nil
        hasGitReceipt = false
        subagentsButton.isHidden = true
        modelRow.isHidden = true
        isHidden = true
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
    }

    // MARK: - Private Methods

    private func rebuild() {
        // The counters sit on the card, not on the backdrop the card floats over.
        let diff = Design.Diff.on(WindowBackdrop.opaque(ink.surface))
        let head = Self.headText(
            for: lastReading,
            isRunActive: isRunActive,
            progress: runProgress,
            ink: ink
        )
        let counters = Self.countersText(for: lastReading, ink: ink, diff: diff)

        let model = Self.modelText(for: modelReading, ink: ink)

        hasGitReceipt = head != nil || counters != nil
        let hasSubagents = subagentCounts.working + subagentCounts.done > 0
        guard hasGitReceipt || hasSubagents || model != nil else {
            isHidden = true
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        for view in [summaryLabel, filesLabel, countersLabel, countersGap, modelLabel] {
            view?.removeFromSuperview()
        }
        summaryLabel = nil
        filesLabel = nil
        countersGap = nil
        countersLabel = nil
        modelLabel = nil

        if let head {
            let label = NSTextField.label(attributed: head)
            label.cell?.lineBreakMode = .byTruncatingMiddle
            summaryLabel = label
            summaryRow.addArrangedSubview(label)
            glyph.image = NSImage(
                systemSymbolName: isRunActive ? "checklist" : "arrow.triangle.branch",
                accessibilityDescription: isRunActive
                    ? L10n.string("Plan")
                    : L10n.string("Branch")
            )
        }
        if let counters {
            let files = NSTextField.label(attributed: counters.files)
            files.cell?.lineBreakMode = .byTruncatingTail
            filesLabel = files
            countersRow.addArrangedSubview(files)

            // Held apart, so the totals land on the card's trailing edge rather than trailing
            // the file count: two columns, which is what makes a stack of readings a list.
            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            countersGap = gap
            countersRow.addArrangedSubview(gap)

            let totals = NSTextField.label(attributed: counters.totals)
            totals.setContentHuggingPriority(.required, for: .horizontal)
            totals.setContentCompressionResistancePriority(.required, for: .horizontal)
            countersLabel = totals
            countersRow.addArrangedSubview(totals)
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
        summaryRowHeightConstraint?.isActive = head != nil
        // Whichever row leads carries the card's top padding, and only a band does. On a
        // detached head the counters lead, so the band moves to them — and with a clean tree as
        // well, the agent line leads and it moves again.
        countersRowHeightConstraint?.isActive = head == nil && counters != nil
        modelRowHeightConstraint?.isActive = head == nil && counters == nil && model != nil
        subagentsButton.isHidden = !hasSubagents

        // Only a bare label needs the card to end below it; the bands end below themselves. The
        // last row is the children button when there is one, then the agent line, then the
        // counters — and either of the latter two is a band instead when it happens to lead.
        let endsOnBareLabel: Bool
        if hasSubagents {
            endsOnBareLabel = false
        } else if model != nil {
            endsOnBareLabel = modelRowHeightConstraint?.isActive != true
        } else {
            endsOnBareLabel = counters != nil
                && countersRowHeightConstraint?.isActive != true
        }
        let bottomInset = endsOnBareLabel ? Design.Spacing.small : 0
        collapsedBottomConstraint?.constant = bottomInset
        slotTopConstraint?.constant = bottomInset

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
            if let spoken = Self.spokenModelText(for: modelReading) {
                parts.append(spoken)
            }
            setAccessibilityLabel(parts.joined(separator: "  ·  "))
            toolTip = nil
        }
        isHidden = false
    }

    /// One mark, sized and centred in the column every row's mark shares.
    private func configureMark(_ view: NSImageView, symbol: String, description: String) {
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        view.symbolConfiguration = .init(
            pointSize: GitStatusOverlayDefaults.fontSize,
            weight: .medium
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
        let font = Design.Typography.numericDetail(weight: .medium)
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

    /// The counters line, in the two columns a list of readings is made of: how many files at
    /// the leading edge, `+N −M` held to the trailing one.
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
        let font = Design.Typography.numericDetail(weight: .medium)

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
        let font = Design.Typography.numericDetail(weight: .medium)
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

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if hasGitReceipt { onOpen?() }
    }

    @objc private func openSubagents() {
        onOpenSubagents?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // The card is pinned to the pane's trailing edge, so opening a panel slides it out from
        // under a pointer that never moved and no exit is delivered — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
