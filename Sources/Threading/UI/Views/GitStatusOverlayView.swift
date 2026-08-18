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

    /// A menu-like reading needs a column, not a sequence of labels shrink-wrapped into pills.
    /// Three hundred twenty points gives the menu-like rows a readable column and still leaves the
    /// card below the half-pane withdrawal gate in the widths where it is useful.
    static let minWidth: CGFloat = 320

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
    static let rowPadding: CGFloat = Design.Spacing.small

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
    static var rowGap: CGFloat { rowPadding * 2 + Design.Spacing.hairline }
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

    /// Whether a floating card fits wholly in the trailing gutter beside a conversation's
    /// readable column. A conversation can be much wider than the card and still have no free
    /// corner: its user bubbles reach the column's trailing edge, so the ordinary half-pane
    /// rule lets the card cover their ink as soon as the display panel narrows the pane.
    ///
    /// Keep one pane inset between the column and card and another between card and edge. In a
    /// pane narrower than the readable measure, the column yields to its own side insets and
    /// there is deliberately no spare gutter to spend.
    static func hasRoomBesideConversation(
        forCardWidth cardWidth: CGFloat,
        inPaneWidth paneWidth: CGFloat
    ) -> Bool {
        guard paneWidth > 0 else { return true }
        let contentWidth = min(
            Design.Size.readableWidth,
            max(0, paneWidth - Design.Spacing.inset * 2)
        )
        let trailingGutter = max(0, (paneWidth - contentWidth) / 2)
        return cardWidth + Design.Spacing.inset * 2 <= trailingGutter
    }

    /// How far the card lifts while it is off screen.
    ///
    /// Toward the edge it is pinned to, so it tucks away rather than drifting in a direction
    /// nothing else in the pane moves. One step: the motion is punctuation on the fade, and a
    /// card that travels far enough to be watched is a card the eye has to wait for.
    static let withdrawnRise: CGFloat = Design.Spacing.small

    /// The attachments section is a glance into the chronology, not a second copy of its list.
    /// Bound before buttons are configured so a session with thousands of recorded files still
    /// mounts the same fixed number of rows here.
    nonisolated static let maximumAttachmentRows = 3

    /// A hover preview is a glance beside the card, not a second Attachments pane. Its bitmap is
    /// decoded only after the dwell and is capped near the rendered point size rather than at the
    /// media inspector's full-image ceiling.
    static let attachmentPreviewContentWidth: CGFloat = 248
    static let attachmentPreviewMinimumHeight: CGFloat = 96
    static let attachmentPreviewMaximumHeight: CGFloat = 160
    nonisolated static let attachmentThumbnailMaximumPixels = 512
    static let attachmentPreviewPolicy = HoverPopoverScheduler.Policy(
        openDelay: SessionPopoverDefaults.hoverDelay,
        closeGrace: ExtensionDisclosureDefaults.popoverPolicy.closeGrace,
        holdsWhilePointerOnPopover: true
    )
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
    /// the caller wants said here**.
    ///
    /// Which facts those are is decided before the card, and deliberately: a native conversation
    /// passes none, because its own status row carries them directly above the composer, and a
    /// terminal session passes everything its pane can extract. This view is handed a decision
    /// rather than asked to make one, which keeps a runtime-specific rule out of a Git-shaped card.
    ///
    /// A nil field is not "unknown", it is "do not say this" — a caller with nothing to report for
    /// a field leaves it out, and the row shrinks to the facts that are left.
    struct ModelReading: Equatable {
        var name: String?
        /// Already display-named — "Extra High", not "xhigh".
        var effort: String?
        /// Drawn as the bolt the row ends on, and only while it is true. False is not a fact the
        /// card reports: standard speed is what every session runs at unless something says
        /// otherwise, so it earns no ink — see `speedMark`.
        var isFast = false

        var isEmpty: Bool { name == nil && effort == nil && !isFast }
    }

    /// What the card says about the isolated worktree a session was given, when it was given one.
    ///
    /// Read from the durable `ManagedWorkspace` record rather than from Git, because the five
    /// states are Threading's own decisions and no Git command reports them: a detached checkout
    /// on disk cannot say whether it is going to be merged, kept, or published. The one thing Git
    /// *would* answer — that `HEAD` is detached — is the thing that made this session invisible
    /// here in the first place: `GitInfo.currentBranch` returns nil in a managed worktree, so the
    /// branch row goes away and the card said nothing about the checkout at all.
    ///
    /// Nil for every ordinary session, and therefore no row: the overwhelming majority of chats
    /// run in the project's own directory, and a row saying so would be a line spent on the
    /// default.
    struct WorkspaceReading: Equatable {
        let state: ManagedWorkspaceState
        /// The checkout the work came from and, for a local delivery, returns to.
        let targetBranch: String
        let delivery: ManagedWorkspaceDelivery
        let publication: ManagedWorkspacePublication?
        /// The review this workspace already has, once publication has produced one.
        let changeRequestNumber: Int?

        /// Why a finish was refused, carried verbatim.
        ///
        /// It is already a sentence written for a person, and this row is where it stays visible:
        /// the refusal's toast is gone within seconds, and the session it belongs to is still on
        /// screen with a worktree that has not been merged.
        let failureReason: String?

        init(workspace: ManagedWorkspace) {
            state = workspace.state
            targetBranch = workspace.targetBranch
            delivery = workspace.delivery
            publication = workspace.publication
            changeRequestNumber = workspace.changeRequest?.number
            failureReason = workspace.lastError
        }
    }

    /// The provider-neutral remote review facts this compact surface can say without becoming
    /// Git Review itself. The complete workflow and all write actions remain in that pane.
    struct ChangeRequestReading: Equatable {
        let provider: SourceControlProvider
        let number: Int
        let title: String
        let checks: ChangeRequestChecks

        init?(status: ChangeRequestRepositoryStatus) {
            guard let request = status.changeRequest else { return nil }
            provider = status.repository.provider
            number = request.number
            title = request.title
            checks = request.checks
        }
    }

    /// One bounded glimpse into the session's attachment chronology. Identity, not a path, is
    /// retained for the click; the window resolves it again through the store before opening.
    struct AttachmentReading: Equatable {
        struct Item: Equatable {
            let id: String
            let name: String
            let url: URL
            let kind: SessionAttachment.Kind
        }

        let items: [Item]
        let totalCount: Int

        init(attachments: [SessionAttachment]) {
            let ordered = attachments.sorted { $0.referencedAt > $1.referencedAt }
            items = ordered.prefix(GitStatusOverlayDefaults.maximumAttachmentRows).map {
                Item(id: $0.id, name: $0.name, url: $0.url, kind: $0.kind)
            }
            totalCount = attachments.count
        }

        var isEmpty: Bool { totalCount == 0 }
    }

    // MARK: - Properties

    /// Called when the Git portion is clicked; the container routes it to the review tab.
    var onOpen: (() -> Void)?
    /// The usage receipt opens the Info section of the session Overview.
    var onOpenUsage: (() -> Void)?
    /// The child-agent segment is a distinct destination inside the same status card.
    var onOpenSubagents: (() -> Void)?
    /// So is the audience segment, which opens the sharing pane.
    var onOpenSharing: (() -> Void)?
    /// A concrete identity selects that attachment; nil opens the complete chronology.
    var onOpenAttachment: ((String?) -> Void)?

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

    /// The card's rows, top down: the workspace line, the summary line, the counters line, the
    /// agent line, the children line.
    private let content = NSStackView()
    /// The isolated-checkout line: which state this session's managed worktree is in, and what
    /// Threading will do with it. Absent for every session running in its project's own folder.
    private let workspaceRow = NSStackView()
    /// The first row — the mark and whichever sentence leads: branch, plan position, or, on a
    /// detached head, the counters themselves.
    private let summaryRow = NSStackView()
    /// The counters line: how many files, and the two totals a step after the count.
    private let countersRow = NSStackView()
    /// The agent line: which model this session is running, and how, for the facts its own
    /// status line does not already say.
    private let modelRow = NSStackView()
    private let sourceDivider = SeparatorView()
    private let extensionDivider = SeparatorView()
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
    /// A sealed box rather than a second branch mark: this row is about a *place* Threading made
    /// and will take away again, and the row under it is the branch that place came from.
    private let workspaceMark = ThemedFloatingGlyphView(
        systemSymbolName: "shippingbox",
        classicGlyph: .workspace,
        pointSize: GitStatusOverlayDefaults.markPointSize,
        accessibilityDescription: L10n.string("Isolated worktree")
    )
    /// Fast mode, drawn rather than spelled: a bolt after the agent line's words is what the
    /// state *looks* like everywhere else in the app, and the word "Fast" spent a sixth of a
    /// capped row saying what the symbol says at a glance. It is the same `bolt.fill` the
    /// composer's speed chip carries **while it says Fast** — see
    /// `ConversationSpeedPresentation.fastSymbol` — so one fact keeps one mark, and the mark
    /// means the same thing on both surfaces.
    ///
    /// It appears **only when fast mode is on**. Off has no mark, exactly as it has no word: a
    /// dimmed or crossed-out bolt would be a second thing to learn about a state that is simply
    /// the ordinary one. The row still says "Fast" to a reader who hears it — see
    /// `spokenModelText`, since a symbol read aloud is a fact lost rather than a fact shortened.
    private let speedMark = ThemedFloatingGlyphView(
        systemSymbolName: "bolt.fill",
        classicGlyph: .speed,
        pointSize: GitStatusOverlayDefaults.markPointSize,
        accessibilityDescription: L10n.string("Fast")
    )
    private let usageButton: ThemedButton
    private let subagentsButton: ThemedButton
    private let audienceButton: ThemedButton
    private let changeRequestButton: ThemedButton
    private let checksButton: ThemedButton
    private let attachmentButtons: [ThemedButton]
    private let viewAllAttachmentsButton: ThemedButton
    private var workspaceLabel: NSTextField?
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
    private var extensionDividerTopConstraint: NSLayoutConstraint?
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
    private var usageReading: SessionUsageSnapshot.Reading?
    private var subagentCounts = (working: 0, done: 0, tokens: Int64?.none)
    private var modelReading: ModelReading?
    private var workspaceReading: WorkspaceReading?
    private var audienceReading = AudienceReading()
    private var changeRequestReading: ChangeRequestReading?
    private var attachmentReading = AttachmentReading(attachments: [])
    private var hoveredAttachmentIndex: Int?
    private var previewedAttachmentID: String?
    private var attachmentPreviewPopover: ThemedPopover?

    /// One scheduler for the bounded mounted rows. Moving from one attachment to another changes
    /// the index it resolves when the dwell expires; it never creates a timer or decoder per row.
    private lazy var attachmentPreviewScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(
            policy: GitStatusOverlayDefaults.attachmentPreviewPolicy
        )
        scheduler.onPresent = { [weak self] in self?.presentAttachmentPreview() }
        scheduler.onDismiss = { [weak self] in self?.dismissAttachmentPreview() }
        return scheduler
    }()

    private(set) var attachmentPreviewBuildCountForTesting = 0

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
        usageButton = ThemedButton(
            symbol: "chart.bar.xaxis",
            accessibility: L10n.string("Open Session Info"),
            target: nil,
            action: nil
        )
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
        changeRequestButton = ThemedButton(
            symbol: "arrow.triangle.pull",
            accessibility: L10n.string("Open change request in Git Review"),
            target: nil,
            action: nil
        )
        checksButton = ThemedButton(
            symbol: "checkmark.circle",
            accessibility: L10n.string("Open checks in Git Review"),
            target: nil,
            action: nil
        )
        attachmentButtons = (0..<GitStatusOverlayDefaults.maximumAttachmentRows).map { index in
            let button = ThemedButton(
                symbol: "paperclip",
                accessibility: L10n.string("Open attachment"),
                target: nil,
                action: nil
            )
            button.tag = index
            return button
        }
        viewAllAttachmentsButton = ThemedButton(
            symbol: "ellipsis.circle",
            accessibility: L10n.string("View all attachments"),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        toolTip = L10n.string("Open Git Review (⇧⌘R)")
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("git.status.overlay")

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
        configureMark(
            workspaceMark,
            symbol: "shippingbox",
            classicGlyph: .workspace,
            description: L10n.string("Isolated worktree")
        )

        workspaceRow.orientation = .horizontal
        workspaceRow.alignment = .centerY
        workspaceRow.spacing = GitStatusOverlayDefaults.markGap
        workspaceRow.translatesAutoresizingMaskIntoConstraints = false
        workspaceRow.isHidden = true
        workspaceRow.addArrangedSubview(workspaceMark)

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
        // Trailing the words rather than sharing the leading mark column: the bolt is a
        // *qualifier* on this row, and a mark in that column is what the row is. It keeps its own
        // intrinsic width for the same reason — the column's width is the air the leading marks
        // are aligned in, and spending it after a truncating label would open a hole. `rebuild()`
        // inserts the label between the two.
        speedMark.translatesAutoresizingMaskIntoConstraints = false
        speedMark.setContentHuggingPriority(.required, for: .horizontal)
        speedMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        speedMark.isHidden = true
        modelRow.addArrangedSubview(speedMark)

        for button in [changeRequestButton, checksButton] {
            button.target = self
            button.action = #selector(openGitReview)
            button.emphasis = .tertiary
            button.contentAlignment = .leading
            button.applyFont(GitStatusOverlayDefaults.font)
            button.isHidden = true
        }

        // One gap, every row, and the card's own inset around the outside — see `rowGap` for
        // the rhythm this replaced. The children row is the one row that pads itself, and
        // `rebuild()` gives that padding back out of the gap beside it rather than letting the
        // stack count it twice.
        content.orientation = .vertical
        // The card is a small menu-like column. Rows fill that column so their hover and click
        // target cover the cell, not only the words that happened to make the card wide.
        content.alignment = .leading
        content.spacing = GitStatusOverlayDefaults.rowGap
        content.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        content.translatesAutoresizingMaskIntoConstraints = false
        // Above the branch, because it says which *checkout* every row below it is about — and
        // because in a managed worktree the branch row is the one row that cannot appear: a
        // detached head has no branch to name, so without this the card opened on its counters.
        content.addArrangedSubview(workspaceRow)
        content.addArrangedSubview(summaryRow)
        content.addArrangedSubview(countersRow)
        // Under the checkout, over the children: the rows read outward from what this pane *is* —
        // which branch, what changed in it, which agent is working it, who it delegated to.
        content.addArrangedSubview(modelRow)

        usageButton.target = self
        usageButton.action = #selector(openUsage)
        usageButton.setAccessibilityIdentifier("session.status.usage")
        usageButton.emphasis = .tertiary
        usageButton.contentAlignment = .leading
        usageButton.applyFont(GitStatusOverlayDefaults.font)
        usageButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        usageButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageButton.isHidden = true
        content.addArrangedSubview(usageButton)

        content.addArrangedSubview(changeRequestButton)
        content.addArrangedSubview(checksButton)

        subagentsButton.target = self
        subagentsButton.action = #selector(openSubagents)
        subagentsButton.emphasis = .tertiary
        subagentsButton.contentAlignment = .leading
        subagentsButton.applyFont(GitStatusOverlayDefaults.font)
        // No hover fill here: `applyInk` states it after resolving the floating chrome surface.
        subagentsButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subagentsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subagentsButton.isHidden = true
        content.addArrangedSubview(subagentsButton)

        audienceButton.target = self
        audienceButton.action = #selector(openSharing)
        audienceButton.emphasis = .tertiary
        audienceButton.contentAlignment = .leading
        audienceButton.applyFont(GitStatusOverlayDefaults.font)
        audienceButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        audienceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audienceButton.isHidden = true
        // Last, under the children: the rows read outward from the work to the people around it,
        // and who is watching is the outermost fact the card holds.
        content.addArrangedSubview(audienceButton)

        sourceDivider.isHidden = true
        sourceDivider.setAccessibilityIdentifier("git.status.overlay.sources-divider")
        content.addArrangedSubview(sourceDivider)

        for button in attachmentButtons {
            button.target = self
            button.action = #selector(openAttachment(_:))
            button.emphasis = .tertiary
            button.contentAlignment = .leading
            button.applyFont(GitStatusOverlayDefaults.font)
            button.onHoverChange = { [weak self, weak button] hovering in
                guard let self, let button else { return }
                self.attachmentHoverChanged(hovering, at: button.tag)
            }
            button.isHidden = true
            content.addArrangedSubview(button)
        }
        viewAllAttachmentsButton.target = self
        viewAllAttachmentsButton.action = #selector(openAllAttachments)
        viewAllAttachmentsButton.emphasis = .tertiary
        viewAllAttachmentsButton.contentAlignment = .leading
        viewAllAttachmentsButton.applyFont(GitStatusOverlayDefaults.font)
        viewAllAttachmentsButton.isHidden = true
        content.addArrangedSubview(viewAllAttachmentsButton)
        addSubview(content)

        extensionSlotStack.orientation = .vertical
        extensionSlotStack.alignment = .leading
        extensionSlotStack.spacing = GitStatusOverlayDefaults.rowGap
        extensionSlotStack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        extensionSlotStack.translatesAutoresizingMaskIntoConstraints = false
        extensionSlotStack.isHidden = true
        extensionSlotStack.setAccessibilityIdentifier("session.corner-card.slot.top-trailing")
        addSubview(extensionSlotStack)
        extensionDivider.isHidden = true
        extensionDivider.setAccessibilityIdentifier("git.status.overlay.extension-divider")
        addSubview(extensionDivider)

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
            equalTo: extensionDivider.bottomAnchor,
            constant: Design.Spacing.medium
        )
        let subagentsHeight = subagentsButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let usageHeight = usageButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let audienceHeight = audienceButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let changeRequestHeight = changeRequestButton.heightAnchor.constraint(
            equalToConstant: GitStatusOverlayDefaults.rowHeight
        )
        let checksHeight = checksButton.heightAnchor.constraint(
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
        let extensionDividerLeading = extensionDivider.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Design.Spacing.medium
        )
        let extensionDividerTrailing = extensionDivider.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Design.Spacing.medium
        )

        // The children row is a button, and a button carries its own padding around the mark it
        // draws. Insetting the text rows by exactly that much is what puts all three marks in
        // one column — and doing it with the stack's own `edgeInsets` rather than a constraint
        // keeps every row's *frame* at the content edge, so the button never has to hang
        // outside its parent to line up, which would leave its leading edge unclickable.
        let markInset = subagentsButton.opticalHorizontalInset
        for row in [workspaceRow, summaryRow, countersRow, modelRow] {
            row.edgeInsets = NSEdgeInsets(top: 0, left: markInset, bottom: 0, right: markInset)
        }
        contentTopConstraint = contentTop
        collapsedBottomConstraint = collapsedBottom
        expandedBottomConstraint = expandedBottom
        slotTopConstraint = slotTop
        let extensionDividerTop = extensionDivider.topAnchor.constraint(
            equalTo: content.bottomAnchor,
            constant: Design.Spacing.medium
        )
        extensionDividerTopConstraint = extensionDividerTop
        rowHeightConstraints = [
            usageHeight,
            subagentsHeight,
            audienceHeight,
            changeRequestHeight,
            checksHeight
        ] + attachmentButtons.map {
            $0.heightAnchor.constraint(equalToConstant: GitStatusOverlayDefaults.rowHeight)
        } + [
            viewAllAttachmentsButton.heightAnchor.constraint(
                equalToConstant: GitStatusOverlayDefaults.rowHeight
            )
        ]
        horizontalInsetConstraints = [
            contentLeading,
            contentTrailing,
            slotLeading,
            slotTrailing,
            extensionDividerLeading,
            extensionDividerTrailing
        ]

        NSLayoutConstraint.activate([
            // The two control rows take the card's row height rather than the one `ThemedButton`
            // sizes itself to. A plain button pads its title to a hit target it picked without
            // knowing what it would sit under, and here that made it 22 beside text rows whose
            // hover reached 19 — three rows on two rhythms. Constrained, every row is one shape
            // and `childrenRowInset` is a number this file states rather than discovers.
            usageHeight,
            subagentsHeight,
            audienceHeight,
            changeRequestHeight,
            checksHeight,
            widthAnchor.constraint(greaterThanOrEqualToConstant: GitStatusOverlayDefaults.minWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            contentLeading,
            contentTrailing,
            contentTop,
            slotLeading,
            slotTrailing,
            slotTop,
            collapsedBottom
        ])
        NSLayoutConstraint.activate(Array(rowHeightConstraints.dropFirst(5)))

        // The one row whose sentence is routinely longer than the card is wide, held to the
        // column rather than allowed to overflow it.
        //
        // An inequality, and required, because both halves matter: under the cap the row is its
        // own width and the card grows to fit it, exactly like every other row; at the cap the
        // constraint outranks the label's compression resistance, so the words give way and
        // truncate instead of being cut off by the card's bounds mid-glyph. Lowering the label's
        // resistance instead looked like the same fix and was not — nothing then pushed the card
        // out to its ceiling at all, so a sentence that would have fitted in 360 points was
        // shortened to 320.
        workspaceRow.widthAnchor.constraint(
            lessThanOrEqualTo: content.widthAnchor
        ).isActive = true

        // A menu cell is the column, not the words inside it. `NSStackView`'s width alignment
        // equalises intrinsic widths; it does not promise to consume the stack's externally
        // assigned width, which left a short attachment row with a short hover pill. Pin every
        // native control and the section rule to the content column explicitly.
        NSLayoutConstraint.activate(
            ([
                usageButton,
                changeRequestButton,
                checksButton,
                subagentsButton,
                audienceButton,
                viewAllAttachmentsButton
            ] + attachmentButtons).map {
                $0.widthAnchor.constraint(equalTo: content.widthAnchor)
            } + [
                sourceDivider.widthAnchor.constraint(equalTo: content.widthAnchor)
            ]
        )

        NSLayoutConstraint.activate([
            extensionDividerLeading,
            extensionDividerTrailing,
            extensionDividerTop
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

        for mark in [glyph, countersMark, modelMark, speedMark, workspaceMark] {
            mark.setPointSize(GitStatusOverlayDefaults.markPointSize)
        }
        glyph.tintColor = surfaceInk.secondary
        // The same weight as the branch mark under it: both name the place this pane is working
        // in, and one of the two is always the leading row.
        workspaceMark.tintColor = surfaceInk.secondary
        countersMark.tintColor = surfaceInk.tertiary
        modelMark.tintColor = surfaceInk.tertiary
        // Tertiary with the row's other qualifiers: the bolt stands for a word that was set in
        // that weight, and a mark louder than the effort beside it would read as a warning.
        speedMark.tintColor = surfaceInk.tertiary
        // Destinations directly attached to the connected review are the primary receipt, not
        // quiet metadata about it. Their words take label ink; the progress image is authored
        // colour and therefore keeps its green/grey/red slices beside them.
        for button in [changeRequestButton, checksButton] {
            button.contentTintColor = surfaceInk.label
            button.hoverFill = surfaceInk.surfaceHover
        }
        // Supporting destinations stay one tier quieter. The audience row used to be given
        // neither colour, so it drew in AppKit's own label colour and lifted to nothing under
        // the pointer — the one row inert by omission rather than by design.
        for button in [
            usageButton,
            subagentsButton,
            audienceButton,
            viewAllAttachmentsButton
        ] + attachmentButtons {
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
            done: max(0, doneCount),
            tokens: subagentCounts.tokens
        )
        rebuild()
    }

    /// Adds the session-wide token and cost receipt. It is a route into Overview › Info rather
    /// than a second dashboard squeezed into the corner.
    func updateUsage(_ reading: SessionUsageSnapshot.Reading?) {
        guard reading != usageReading else { return }
        usageReading = reading
        rebuild()
    }

    /// Keeps the existing source-compatible call sites while letting the card state delegated
    /// usage beside the child count when a session projection is available.
    func updateSubagents(workingCount: Int, doneCount: Int, tokenCount: Int64?) {
        subagentCounts = (
            working: max(0, workingCount),
            done: max(0, doneCount),
            tokens: tokenCount.map { max(0, $0) }
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

    /// States that this session runs in an isolated worktree, which state that worktree is in,
    /// and what happens to it next. Nil for a session running in its project's own folder.
    func updateWorkspace(_ reading: WorkspaceReading?) {
        guard reading != workspaceReading else { return }
        workspaceReading = reading
        rebuild()
    }

    /// States who can see this chat from outside this Mac, and how many are looking now.
    func updateAudience(_ reading: AudienceReading) {
        guard reading != audienceReading else { return }
        audienceReading = reading
        rebuild()
    }

    /// Adds the connected provider review and its current check summary. Nil removes both rows.
    func updateChangeRequest(_ reading: ChangeRequestReading?) {
        guard reading != changeRequestReading else { return }
        changeRequestReading = reading
        rebuild()
    }

    /// Adds at most three recent attachment rows plus one bounded way into the complete list.
    func updateAttachments(_ reading: AttachmentReading) {
        guard reading != attachmentReading else { return }
        dismissAttachmentPreview()
        attachmentReading = reading
        rebuild()
    }

    func clear() {
        dismissAttachmentPreview()
        lastReading = nil
        isRunActive = false
        runProgress = nil
        usageReading = nil
        subagentCounts = (working: 0, done: 0, tokens: nil)
        modelReading = nil
        workspaceReading = nil
        audienceReading = AudienceReading()
        changeRequestReading = nil
        attachmentReading = AttachmentReading(attachments: [])
        hasGitReceipt = false
        usageButton.isHidden = true
        subagentsButton.isHidden = true
        audienceButton.isHidden = true
        changeRequestButton.isHidden = true
        checksButton.isHidden = true
        sourceDivider.isHidden = true
        attachmentButtons.forEach { $0.isHidden = true }
        viewAllAttachmentsButton.isHidden = true
        modelRow.isHidden = true
        workspaceRow.isHidden = true
        speedMark.isHidden = true
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
            extensionDivider.isHidden = true
            expandedBottomConstraint?.isActive = false
            collapsedBottomConstraint?.isActive = true
        } else {
            extensionDivider.isHidden = false
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
        attachmentPreviewPopover?.reposition()
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

    /// Visible words and marks keep this much air from a section rule. This is deliberately
    /// separate from `rowGap`: a rule is a group boundary, not another reading in the list.
    /// `SeparatorView` converts it to a frame gap using the adjacent control's optical inset.
    private var separatorInkGap: CGFloat {
        floatingStyle.density == .compact
            ? Design.Spacing.small
            : Design.Spacing.medium
    }

    private func applyDensity() {
        content.spacing = rowGap
        extensionSlotStack.spacing = rowGap
        extensionDividerTopConstraint?.constant = separatorInkGap
        slotTopConstraint?.constant = separatorInkGap
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
        let workspace = Self.workspaceText(for: workspaceReading, ink: surfaceInk)
        // The bolt is a row of its own right, not decoration on the words: a session whose only
        // agent fact is its speed still gets the agent line.
        let isFast = modelReading?.isFast ?? false

        hasGitReceipt = head != nil || counters != nil
        let hasSubagents = subagentCounts.working + subagentCounts.done > 0
        let hasUsage = usageReading?.isEmpty == false
        let hasAudience = !audienceReading.isEmpty
        let hasChangeRequest = changeRequestReading != nil
        let hasAttachments = !attachmentReading.isEmpty
        let hasNativeReading = hasGitReceipt || hasUsage || hasSubagents || hasAudience || hasChangeRequest
            || model != nil || isFast || workspace != nil
        guard hasGitReceipt || hasUsage || hasSubagents || hasAudience || hasChangeRequest
            || hasAttachments || model != nil || isFast || workspace != nil else {
            hasContent = false
            applyVisibility(animated: false)
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        for view in [workspaceLabel, summaryLabel, filesLabel, countersLabel, modelLabel] {
            view?.removeFromSuperview()
        }
        workspaceLabel = nil
        summaryLabel = nil
        filesLabel = nil
        countersLabel = nil
        modelLabel = nil

        if let workspace {
            let label = NSTextField.label(attributed: workspace)
            workspaceLabel = label
            workspaceRow.addArrangedSubview(label)
        }
        // The row is the only surface still carrying a refused finish once its toast has gone, and
        // a refusal's reason is a sentence rather than a phrase — so it is also the row most
        // likely to be reading half of itself. The pointer gets the whole thing.
        workspaceRow.toolTip = Self.spokenWorkspaceText(for: workspaceReading)

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
            // After the mark and before the bolt, which are the row's fixed ends.
            modelRow.insertArrangedSubview(label, at: 1)
        }

        workspaceRow.isHidden = workspace == nil
        summaryRow.isHidden = head == nil
        countersRow.isHidden = counters == nil
        modelRow.isHidden = model == nil && !isFast
        speedMark.isHidden = !isFast
        usageButton.isHidden = !hasUsage
        changeRequestButton.isHidden = !hasChangeRequest
        checksButton.isHidden = !hasChangeRequest
        subagentsButton.isHidden = !hasSubagents
        audienceButton.isHidden = !hasAudience
        sourceDivider.isHidden = !hasAttachments || !hasNativeReading
        for (index, button) in attachmentButtons.enumerated() {
            button.isHidden = !attachmentReading.items.indices.contains(index)
        }
        viewAllAttachmentsButton.isHidden = attachmentReading.totalCount <= attachmentReading.items.count

        // A button row draws its own padding — a button pads its title out to something a
        // pointer can hit — so wherever one touches an inset or a gap, that inset or gap gives
        // the padding back and the ink lands on the same rhythm as every other row's. Two of
        // them meeting give it back twice, once for each.
        let childrenInset = childrenRowInset
        let textRows = [workspaceRow, summaryRow, countersRow, modelRow].filter { !$0.isHidden }
        let nativeButtonRows = [
            usageButton,
            changeRequestButton,
            checksButton,
            subagentsButton,
            audienceButton
        ].filter { !$0.isHidden }
        let sourceButtonRows = (attachmentButtons + [viewAllAttachmentsButton]).filter {
            !$0.isHidden
        }
        let buttonRows = nativeButtonRows + sourceButtonRows
        let visibleContentRows: [NSView] = textRows + nativeButtonRows + sourceButtonRows
        let hasButtonRows = !buttonRows.isEmpty
        contentTopConstraint?.constant = textRows.isEmpty
            ? max(0, verticalInset - childrenInset)
            : verticalInset
        let bottomInset = hasButtonRows
            ? max(0, verticalInset - childrenInset)
            : verticalInset
        collapsedBottomConstraint?.constant = bottomInset
        // The extension section has a real rule between it and the native rows. Ask the rule for
        // the frame gap that leaves the stated visible-ink gap above it; the final row can change
        // from bare text to a native or attachment control without this view knowing its type or
        // repeating its padding. Extension rows are host-rendered arbitrary content, so the slot
        // keeps the complete gap below rather than guessing inside their view trees.
        extensionDividerTopConstraint?.constant = visibleContentRows.last.map {
            extensionDivider.frameGap(to: $0, forInkGap: separatorInkGap)
        } ?? separatorInkGap
        slotTopConstraint?.constant = separatorInkGap
        // `NSStackView` retains custom spacing while an arranged view is hidden. Clear every
        // possible neighbour first, then state the rhythm for the rows that are visible now.
        for row in visibleContentRows {
            content.setCustomSpacing(NSStackView.useDefaultSpacing, after: row)
        }
        content.setCustomSpacing(NSStackView.useDefaultSpacing, after: sourceDivider)
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
        for row in nativeButtonRows.dropLast() {
            content.setCustomSpacing(
                max(0, rowGap - 2 * childrenInset),
                after: row
            )
        }
        for row in sourceButtonRows.dropLast() {
            content.setCustomSpacing(
                max(0, rowGap - 2 * childrenInset),
                after: row
            )
        }
        if !sourceDivider.isHidden {
            let nativeRows: [NSView] = textRows + nativeButtonRows
            sourceDivider.applyOpticalSpacing(
                in: content,
                precededBy: nativeRows.last,
                followedBy: sourceButtonRows.first,
                inkGap: separatorInkGap
            )
        }

        if let usageReading, hasUsage {
            usageButton.title = SessionUsageFormat.compact(usageReading)
            usageButton.setAccessibilityHelp(L10n.string("Open Session Info"))
        }
        if hasSubagents {
            let working = subagentCounts.working
            let done = subagentCounts.done
            let workingText = L10n.format("%lld working", Int64(working))
            let doneText = L10n.format("%lld done", Int64(done))
            var parts = [working > 0 ? "\(workingText) · \(doneText)" : doneText]
            if let tokens = subagentCounts.tokens, tokens > 0 {
                parts.append(L10n.format("%@ tokens", UsageFormat.tokens(tokens)))
            }
            subagentsButton.title = parts.joined(separator: " · ")
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
        if let request = changeRequestReading {
            changeRequestButton.title = "#\(request.number) · \(request.title)"
            changeRequestButton.setAccessibilityHelp(
                L10n.format("Open %@ in Git Review", request.provider.changeRequestName)
            )
            checksButton.title = Self.checksText(request.checks)
            checksButton.image = ThemedStatusProgressRing.image(
                positive: request.checks.passed,
                pending: request.checks.pending,
                negative: request.checks.failed
            )
            checksButton.setAccessibilityHelp(L10n.string("Open checks in Git Review"))
        }
        for (index, item) in attachmentReading.items.enumerated() {
            guard attachmentButtons.indices.contains(index) else { break }
            let button = attachmentButtons[index]
            button.title = item.name
            button.setAccessibilityHelp(L10n.string("Open attachment in Attachments"))
        }
        if hasAttachments {
            viewAllAttachmentsButton.title = L10n.format(
                "View all %lld attachments",
                Int64(attachmentReading.totalCount)
            )
            viewAllAttachmentsButton.setAccessibilityHelp(
                L10n.string("Open the Attachments pane")
            )
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
                model: modelReading,
                workspace: workspaceReading
            ))
            toolTip = L10n.string("Open Git Review (⇧⌘R)")
        } else {
            setAccessibilityRole(.group)
            var parts: [String] = []
            if let spoken = Self.spokenWorkspaceText(for: workspaceReading) {
                parts.append(spoken)
            }
            if hasSubagents {
                parts.append(L10n.format("Subagents: %@", subagentsButton.title))
            }
            if hasUsage, let usageReading {
                parts.append(L10n.format("Usage: %@", SessionUsageFormat.compact(usageReading)))
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

    /// The agent line's **words**: the model leading, then how it is running. Speed is not among
    /// them — it is `speedMark`, the bolt this row ends on.
    ///
    /// The name takes `secondary` and its qualifiers `tertiary` — the same split the counters row
    /// makes between the file count and its totals, and what keeps a three-part line reading as
    /// one fact with detail rather than three of equal weight.
    ///
    /// Nil when there are no words at all, which includes a reading whose only fact is its speed:
    /// the row is then the mark and the bolt, and `rebuild()` keeps it open on `isFast` rather
    /// than on this. Each part is independently optional — a session may know its effort and not
    /// its model, or the reverse. The bolt follows both, so the row reads model → how it thinks →
    /// how fast.
    private static func modelText(
        for reading: ModelReading?,
        ink: Design.Ink
    ) -> NSAttributedString? {
        guard let reading else { return nil }
        let font = GitStatusOverlayDefaults.font.resolved()
        let text = NSMutableAttributedString()

        if let name = reading.name {
            text.append(NSAttributedString(string: name, attributes: [
                .font: font,
                .foregroundColor: ink.secondary
            ]))
        }

        if let effort = reading.effort {
            text.append(NSAttributedString(
                string: text.length == 0 ? effort : " · \(effort)",
                attributes: [.font: font, .foregroundColor: ink.tertiary]
            ))
        }

        return text.length == 0 ? nil : text
    }

    /// The isolated-checkout row as two parts: what this worktree **is** right now, and what
    /// Threading does with it **next**.
    ///
    /// Both halves are the point. The state alone leaves the question the row exists to answer —
    /// a person watching an agent work in a checkout they cannot see wants to know where the
    /// commits are going to end up, and the answer was chosen once, in a composer they closed an
    /// hour ago. The transition is therefore stated while it is still pending and replaced by its
    /// outcome once it has happened, so the row is never a promise about something already done.
    ///
    /// **Tense carries the timing, so no words have to.** A pending transition is present simple
    /// ("merges into master") and a settled one is past ("Merged into master"), which is what let
    /// "when it finishes" go: the card is 360 points wide at most, and that clause was four words
    /// spent restating what the two halves already say — it also pushed the commonest state of
    /// all, an ordinary isolated session, past the ceiling and into an ellipsis.
    ///
    /// Publication outranks delivery while active because that is the order the finish handshake
    /// takes them in: a workspace with a publication never reaches the local delivery path.
    private static func workspaceWords(
        for reading: WorkspaceReading
    ) -> (state: String, next: String?) {
        switch reading.state {
        case .active:
            let next: String
            switch reading.publication {
            case .draft:
                next = L10n.string("opens a draft change request")
            case .ready:
                next = L10n.string("opens a change request")
            case nil:
                switch reading.delivery {
                case .mergeAndCleanUp:
                    next = L10n.format("merges into %@", reading.targetBranch)
                case .keepForReview:
                    next = L10n.string("stays for review")
                }
            }
            return (L10n.string("Isolated worktree"), next)

        case .integrated:
            return (
                L10n.format("Merged into %@", reading.targetBranch),
                L10n.string("worktree removed")
            )

        case .kept:
            return (
                L10n.string("Worktree kept"),
                L10n.format("not merged into %@", reading.targetBranch)
            )

        case .published:
            let state = reading.changeRequestNumber
                .map { L10n.format("Published as #%lld", Int64($0)) }
                ?? L10n.string("Published for review")
            return (state, L10n.string("worktree removed"))

        case .needsAttention:
            // The reason is passed through rather than reworded. It is written for a person, it
            // is the only thing on screen that says what to repair, and the toast carrying it
            // was gone seconds after the finish was refused.
            return (L10n.string("Needs attention"), reading.failureReason)
        }
    }

    /// The isolated-checkout row's words: the state leading, then what happens to the worktree.
    ///
    /// Nil for an ordinary session, which is what removes the row. The split follows the agent
    /// line's: the state takes `secondary` and the transition `tertiary`, so one fact reads as a
    /// fact with a detail rather than two of equal weight. A refused finish is the exception and
    /// takes `label` — the loudest role the card has, and the one state here that is not simply
    /// how things are going.
    private static func workspaceText(
        for reading: WorkspaceReading?,
        ink: Design.Ink
    ) -> NSAttributedString? {
        guard let reading else { return nil }
        let font = GitStatusOverlayDefaults.font.resolved()
        let words = workspaceWords(for: reading)
        // Truncation lives in the string, not on the cell. A cell asked to draw an *attributed*
        // value takes its line breaking from that string's paragraph style and ignores its own
        // `lineBreakMode`, so the row that outgrew the card was cut mid-word with no ellipsis to
        // say anything had been dropped — while every assertion about its text passed, because
        // the label's value was the whole sentence the whole time. It is stated on both runs: the
        // style applies where the layout manager finds it, which is wherever the line ends up
        // breaking.
        //
        // Tail, unlike the branch line's middle: the state leads the row and what happens next
        // follows it, so the half that must survive a narrow pane is the half at the front.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: words.state, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: reading.state == .needsAttention ? ink.label : ink.secondary
        ])
        if let next = words.next {
            text.append(NSAttributedString(string: " · \(next)", attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: ink.tertiary
            ]))
        }
        return text
    }

    /// The isolated-checkout row as one spoken phrase, or nil when the card has no such row.
    private static func spokenWorkspaceText(for reading: WorkspaceReading?) -> String? {
        guard let reading else { return nil }
        let words = workspaceWords(for: reading)
        return [words.state, words.next].compactMap { $0 }.joined(separator: " · ")
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

    /// Every non-zero check bucket, shortened into one complete row. The overall state alone
    /// loses useful information — a pending run may already have five green checks — and the
    /// sliced ring beside this text is deliberately the same three-part reading.
    private static func checksText(_ checks: ChangeRequestChecks) -> String {
        switch checks.state {
        case .unavailable:
            return L10n.string("Checks unavailable")
        case .none:
            return L10n.string("No checks")
        case .pending, .passing, .failing:
            var parts: [String] = []
            if checks.passed > 0 {
                parts.append(L10n.format("%lld passed", Int64(checks.passed)))
            }
            if checks.pending > 0 {
                parts.append(L10n.format("%lld pending", Int64(checks.pending)))
            }
            if checks.failed > 0 {
                parts.append(L10n.format("%lld failed", Int64(checks.failed)))
            }
            return parts.isEmpty ? L10n.string("No checks") : parts.joined(separator: " · ")
        }
    }

    /// The agent line as one spoken phrase, or nil when the card has no agent row.
    ///
    /// Fast is a **word** here and a bolt on screen, in the same last place. A symbol is the
    /// faster read for an eye and nothing at all for a reader who hears the card, so the row is
    /// drawn short and spoken whole.
    private static func spokenModelText(for reading: ModelReading?) -> String? {
        guard let reading, !reading.isEmpty else { return nil }
        var parts: [String] = []
        if let name = reading.name { parts.append(name) }
        if let effort = reading.effort { parts.append(effort) }
        if reading.isFast { parts.append(L10n.string("Fast")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every row the card is showing, as one sentence, for the reader who hears it rather than
    /// sees it: exact counts, and a separator where the eye sees a line break.
    private static func spokenText(
        for reading: GitChangeMonitor.Reading?,
        isRunActive: Bool,
        progress: RunProgress?,
        model: ModelReading?,
        workspace: WorkspaceReading?
    ) -> String {
        var parts: [String] = []
        if let spoken = spokenWorkspaceText(for: workspace) { parts.append(spoken) }
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
        dismissAttachmentPreview()
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

    @objc private func openUsage() {
        onOpenUsage?()
    }

    @objc private func openSharing() {
        onOpenSharing?()
    }

    @objc private func openGitReview() {
        onOpen?()
    }

    private func attachmentHoverChanged(_ hovering: Bool, at index: Int) {
        guard attachmentReading.items.indices.contains(index) else { return }
        if hovering {
            hoveredAttachmentIndex = index
            attachmentPreviewScheduler.pointerEntered()
        } else if hoveredAttachmentIndex == index {
            hoveredAttachmentIndex = nil
            attachmentPreviewScheduler.pointerExited()
        }
    }

    private func presentAttachmentPreview() {
        guard let index = hoveredAttachmentIndex,
              attachmentReading.items.indices.contains(index),
              attachmentButtons.indices.contains(index)
        else { return }
        let button = attachmentButtons[index]
        let item = attachmentReading.items[index]
        guard !button.isHidden, button.window != nil else { return }

        if attachmentPreviewPopover?.isShown == true {
            guard previewedAttachmentID != item.id else { return }
            attachmentPreviewPopover?.close()
        }
        guard let controller = makeAttachmentPreviewSurface(
            forAttachmentAt: index,
            onHoverChange: { [weak self] hovering in
                self?.attachmentPreviewScheduler.popoverHoverChanged(hovering)
            }
        ) else { return }

        let popover = HostPopoverFactory.make(.sessionCornerCardAttachment)
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.onClose = { [weak self, weak popover] in
            guard let self, self.attachmentPreviewPopover === popover else { return }
            self.attachmentPreviewScheduler.cancelPendingWork()
            self.attachmentPreviewPopover = nil
            self.previewedAttachmentID = nil
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        guard popover.isShown else { return }
        attachmentPreviewPopover = popover
        previewedAttachmentID = item.id
    }

    private func dismissAttachmentPreview() {
        attachmentPreviewScheduler.cancelPendingWork()
        attachmentPreviewPopover?.close()
        attachmentPreviewPopover = nil
        previewedAttachmentID = nil
        hoveredAttachmentIndex = nil
    }

    /// Builds the hover body separately from presentation so it can be rendered and asserted
    /// without ordering a child window. This is also the scaling boundary: `updateAttachments`
    /// stores three lightweight references, and the bounded thumbnail decode happens only here,
    /// after the hover dwell has asked for one concrete row.
    func makeAttachmentPreviewSurface(
        forAttachmentAt index: Int,
        onHoverChange: @escaping (Bool) -> Void = { _ in }
    ) -> NSViewController? {
        guard attachmentReading.items.indices.contains(index) else { return nil }
        attachmentPreviewBuildCountForTesting += 1
        let item = attachmentReading.items[index]

        let preview: NSView?
        let previewHeight: CGFloat
        if item.kind == .image,
           let image = BoundedImageDecoder.thumbnail(
               at: item.url,
               policy: .thumbnail(
                   maximumPixelDimension:
                       GitStatusOverlayDefaults.attachmentThumbnailMaximumPixels
               )
           ), image.isValid {
            let imageView = ThemedImagePreview()
            imageView.image = image
            imageView.fileURL = item.url
            imageView.setAccessibilityIdentifier("git.status.attachment-preview.image")
            preview = imageView
            previewHeight = Self.attachmentPreviewHeight(for: image.size)
        } else {
            preview = nil
            previewHeight = 0
        }

        let copyTitle = item.kind == .image
            ? L10n.string("Copy Image")
            : L10n.string("Copy File")
        let copySymbol = item.kind == .image ? "photo.on.rectangle" : "doc.on.doc"
        let entries: [ThemedActionPopoverEntry] = [
            .action(ThemedActionPopoverAction(
                title: copyTitle,
                systemSymbolName: copySymbol,
                onChoose: { [weak self] in self?.copyAttachment(item) }
            )),
            .action(ThemedActionPopoverAction(
                title: L10n.string("Copy Path"),
                systemSymbolName: "folder",
                onChoose: { [weak self] in self?.copyAttachmentPath(item) }
            )),
            .separator,
            .action(ThemedActionPopoverAction(
                title: L10n.string("Open in Attachments"),
                systemSymbolName: "paperclip",
                onChoose: { [weak self] in self?.openAttachmentFromPreview(item) }
            )),
            .action(ThemedActionPopoverAction(
                title: L10n.string("Reveal in Finder"),
                systemSymbolName: "magnifyingglass",
                onChoose: { [weak self] in self?.revealAttachment(item) }
            ))
        ]
        return ThemedActionPopoverViewController(
            preview: preview,
            previewHeight: previewHeight,
            entries: entries,
            contentWidth: GitStatusOverlayDefaults.attachmentPreviewContentWidth,
            onHoverChange: onHoverChange
        )
    }

    private static func attachmentPreviewHeight(for imageSize: NSSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return GitStatusOverlayDefaults.attachmentPreviewMinimumHeight
        }
        let fitted = GitStatusOverlayDefaults.attachmentPreviewContentWidth
            * imageSize.height / imageSize.width
        return min(
            GitStatusOverlayDefaults.attachmentPreviewMaximumHeight,
            max(GitStatusOverlayDefaults.attachmentPreviewMinimumHeight, fitted.rounded(.up))
        )
    }

    private func copyAttachment(_ item: AttachmentReading.Item) {
        dismissAttachmentPreview()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if item.kind == .image,
           let image = BoundedImageDecoder.image(at: item.url, policy: .userMedia),
           image.isValid {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects([item.url as NSURL])
        }
    }

    private func copyAttachmentPath(_ item: AttachmentReading.Item) {
        dismissAttachmentPreview()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.url as NSURL])
        pasteboard.setString(item.url.path, forType: .string)
    }

    private func openAttachmentFromPreview(_ item: AttachmentReading.Item) {
        dismissAttachmentPreview()
        onOpenAttachment?(item.id)
    }

    private func revealAttachment(_ item: AttachmentReading.Item) {
        dismissAttachmentPreview()
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func openAttachment(_ sender: ThemedButton) {
        guard attachmentReading.items.indices.contains(sender.tag) else { return }
        dismissAttachmentPreview()
        onOpenAttachment?(attachmentReading.items[sender.tag].id)
    }

    @objc private func openAllAttachments() {
        dismissAttachmentPreview()
        onOpenAttachment?(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissAttachmentPreview() }
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
        // A position under an open dropdown is the menu's, not the card's — see
        // `NSView.uncoveredPointerLocation(in:)`.
        guard let point = uncoveredPointerLocation(in: event) else { return }
        updateGitHover(at: point)
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
