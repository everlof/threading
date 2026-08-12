import AppKit
import ThreadingExtensionKit

/// Shown when a project is selected: choose how a session should start, then start it.
///
/// A project has no terminal of its own, so selecting one offers the decisions that are only
/// made once — agent, account, model, which checkout — rather than an empty pane.
final class SessionComposerViewController: NSViewController {

    // MARK: - Properties

    private(set) var projectID: ProjectID?

    /// Whether `show(projectID:)` has configured this composer at all yet.
    ///
    /// Told apart from "already showing that project" because the first show can legitimately
    /// be `nil` — the choose-a-project mode a store with no projects opens onto — and that one
    /// still has to configure the chips and the greeting rather than return early.
    private var hasBeenShown = false

    /// The hero: the mark above a greeting that knows what day it is. It fills the room the
    /// bottom-flush composer leaves, and hides when a short pane leaves none.
    private let heroMark = ThreadingMarkView()
    private let greetingLabel = MorphingTitleLabel()
    private let heroStack = NSStackView()
    private let heroRegion = NSLayoutGuide()
    private var hasPlayedHeroDrawIn = false

    /// Where the session runs: the project, and the checkout inside it.
    private let locationChip = ChipView()

    /// Who it runs as: the agent, and the login inside it.
    private let identityChip = ChipView()

    private let modelChip = ChipView()
    private let effortChip = ChipView()
    private let speedChip = ChipView()
    private let surfaceChip = ChipView()
    private let modeChip = ChipView()

    /// The only managed-workspace control present until the feature is explicitly enabled.
    /// Its dependent controls are inserted into, and removed from, the stack rather than merely
    /// hidden so an ordinary draft has no workspace settings in its view or accessibility tree.
    lazy var managedWorkspaceCheckbox = ThemedCheckbox(
        title: L10n.string("Run in an isolated managed worktree"),
        changed: { [weak self] state in
            self?.setManagedWorkspaceEnabled(state == .on)
        }
    )
    private let managedWorkspaceDeliveryChip = ChipView()
    private lazy var managedWorkspacePublicationCheckbox = ThemedCheckbox(
        title: L10n.string("Open a change request when finished"),
        changed: { [weak self] state in
            self?.setManagedWorkspacePublicationEnabled(state == .on)
        }
    )
    private let managedWorkspacePublicationChip = ChipView()
    private lazy var managedWorkspaceOutcomeRow: NSStackView = {
        let row = NSStackView(views: [managedWorkspaceDeliveryChip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        return row
    }()
    private lazy var managedWorkspaceOptions: NSStackView = {
        let column = NSStackView(views: [managedWorkspaceOutcomeRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        column.setAccessibilityIdentifier("composer.session-start.managed-workspace.options")
        return column
    }()
    private lazy var importButton = ThemedButton(
        symbol: ComposerDefaults.importSymbol,
        accessibility: L10n.string("Import conversation"),
        target: self,
        action: #selector(importTapped)
    )

    /// The one thing this screen is for, stated as a button rather than as a glyph in the box.
    ///
    /// A brief is several lines — often a pasted paragraph — so Return belongs to the text and
    /// the send has to live somewhere Return is not. Out here it can also carry `⌘↩` on its
    /// face, which is the whole reason the chord is findable; a glyph has nowhere to write one
    /// and had to promise it on a tooltip nobody reads before pressing Return.
    ///
    /// See `PromptView.SubmitPlacement.outside`.
    private lazy var startButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Start session"),
            target: self,
            action: #selector(startTapped)
        )
        button.emphasis = .primary
        button.shortcut = ComposerDefaults.startShortcut
        button.setAccessibilityIdentifier("composer.session-start.submit")
        return button
    }()

    /// The row under the box: the action at its trailing end, the other way in at its leading
    /// one. Two offers of unequal weight, one at each edge, rather than a pair the eye has to
    /// rank — pressing Start is what this screen is for, and adopting a conversation that
    /// already exists is the other way to arrive at the same place.
    ///
    /// The row exists to place the import button by its **ink**: a plain button's frame carries
    /// the padding its hover surface needs, so aligned by frame its first letter sits inside
    /// every other row in the column. The row subtracts what the button itself states
    /// (`OpticalInsetProviding`) rather than a number of its own. The primary opposite it needs
    /// no such correction — a filled shape's ink *is* its frame.
    ///
    /// The row itself never hides now that it carries the send; the import button is what
    /// appears once discovery finds something.
    private lazy var actionRow: NSView = {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("composer.session-start.actions")
        importButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.translatesAutoresizingMaskIntoConstraints = false
        scheduleButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(importButton)
        row.addSubview(scheduleButton)
        row.addSubview(startButton)

        // "The offer yields first" — stated in the constraint below and, until now, only there.
        // A `lessThanOrEqualTo` says the import button *may* stop short of what is beside it; it
        // does not say the button's own title is what gives when the row runs out of room, so
        // the row simply grew past the pane instead. The rule bit once a third control joined
        // the row and the fixture had a project to discover conversations in — which is why it
        // only ever failed in a full suite, where earlier tests leave projects behind.
        importButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inset = importButton.opticalHorizontalInset
        NSLayoutConstraint.activate([
            importButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: -inset),
            importButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            // Both buttons stand at the same height, which is a statement about the *row* rather
            // than about either button. A plain button asks for the height its mark and its
            // padding need — 4pt shorter than a bordered one — and at rest that is invisible,
            // because it draws nothing. Under the pointer it raises a surface, and a hover pill
            // visibly shorter than the primary it sits opposite reads as two rows pretending to
            // be one. The height is the row's to state; the ink stays where it was.
            importButton.heightAnchor.constraint(equalTo: startButton.heightAnchor),

            // The offer yields first: it is one line of quiet text, and the action beside it is
            // the thing that must stay readable when the pane is narrow.
            importButton.trailingAnchor.constraint(
                lessThanOrEqualTo: scheduleButton.leadingAnchor,
                constant: -Design.Spacing.medium
            ),

            scheduleButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // `small`, where everything else on this row is `medium` apart. The two are one
            // decision offered two ways — send it now, send it later — and the tighter gap is
            // how that is said without a plate around them, which is the same ranking
            // `SplitIconButtonView` draws for the pair it welds. A plate is not on offer here:
            // this press is the accent-filled primary, and `SplitButtonView` welds neutral
            // pairs only — a shared plate under an accent press would hold a permanent colour
            // seam, so the spread form *is* the primary's split control. It is also what keeps the row
            // inside a 560-point pane: at `medium` the row's minimum ran three points past what
            // `ComposerWindowFitTests` allows the column, and an icon button's width is a
            // required constraint that no compression priority will yield.
            scheduleButton.trailingAnchor.constraint(
                equalTo: startButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),

            startButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            startButton.topAnchor.constraint(equalTo: row.topAnchor),
            startButton.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }()

    /// Start it later: the same offers the reply box's chevron makes, one message earlier.
    ///
    /// Disabled with its reason on the tooltip when there is nothing to schedule — and when
    /// images are attached, because a pasted screenshot is a file in a temporary directory and a
    /// path recorded now can name nothing by Monday. `DraftStore` already refuses to draft them
    /// for that reason; scheduling is the same hazard with a longer fuse.
    /// Deliberately an icon button rather than a `ChipView`.
    ///
    /// A chip out here would join the row above the box in the one test that counts them, and
    /// that row answers *where* and *who* and nothing else. In the box's own footer it would
    /// claim to be something the session runs *with*, which scheduling is not. An icon that
    /// opens a menu is the same gesture the reply box's chevron makes, in the place the send
    /// already is — which is where a decision about sending belongs.
    lazy var scheduleButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: ComposerDefaults.scheduleSymbol,
            accessibility: L10n.string("Start this session later"),
            target: .besidePrimary
        )
        button.presentsMenu = true
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            self.presentScheduleMenu(from: button)
        }
        // Never a reason for the column to be wider than the pane. The row it joins is measured
        // against the composer's own width, and a member that resisted compression there is how
        // an addition to this row becomes a failure in `ComposerWindowFitTests`.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier("composer.session-start.schedule")
        return button
    }()

    /// What is already waiting to start in this project.
    lazy var scheduledStrip = ScheduledMessageStripView()

    /// Conversations found on disk for the current project, once discovery has finished.
    ///
    /// Scanning a busy project takes a couple of seconds, so it runs when the composer is
    /// shown and the chip stays hidden until there is something to offer.
    private var importable: [ImportableSession] = []

    /// Whether the next session is rendered by Threading rather than shown as a terminal.
    /// Experimental, and offered only for agents with a structured headless transport.
    var usesNativeUI = false
    let promptView = PromptView()
    private lazy var promptContentContainer = ComponentContentContainer(defaultContent: promptView)
    private lazy var activityBeamView = AgentActivityBeamView()
    private lazy var promptCustomizationHost = ComponentCustomizationHost(
        target: .sessionStartComposer(),
        contentContainer: promptContentContainer,
        lookup: customizationLookup,
        imageResolver: ExtensionComponentResourceResolver.image,
        onAction: { [weak self] action in
            guard let self else { return }
            if let onCustomizationAction {
                onCustomizationAction(action)
            } else {
                ComponentCustomizationProviderSlot.shared.perform(action)
            }
        }
    )
    private let customizationLookup: ComponentCustomizationHost.Lookup

    /// Invoked for semantic actions in extension-provided prompt accessories.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    /// The box the composer-to-conversation handoff animates.
    ///
    /// The container rather than the `PromptView` inside it: an extension may have composed
    /// accessories around the native prompt, and what moves has to be the whole box the user was
    /// typing in. Read by the pane that swaps this composer for the conversation it becomes.
    var promptHandoffView: NSView { promptContentContainer }

    /// What is left of the account the chips currently name, as one line inside the box.
    ///
    /// The same compact reading the toolbar's usage pill draws
    /// (`AccountUsage.compactSummary`), so the number a session is started on is the number the
    /// pill goes on showing. The detail this replaced a whole panel with is on the tooltip.
    private let usageLabel = NSTextField(labelWithString: "")

    /// The composer's own column, bottom-flush in the pane.
    private let stack = NSStackView()
    private let appEvents = AppEventObservations()

    // Not private: `SessionComposerScheduling` freezes exactly these decisions into a
    // `ScheduledSessionPlan`. A start that happens later has to be the start that was
    // chosen, so the plan is a copy of this state rather than a second reading of it.
    var selectedAgent: AgentKind = AgentDefaults.defaultKind
    var selectedAccountHandle: AccountHandle = .standard
    var selectedModel: String?
    var selectedReasoningEffort: String?
    /// Nil follows General, while false and true pin Standard or Fast for this conversation.
    var selectedFastMode: Bool?
    var selectedBranch: String?

    /// How much the session may do before it has to ask. Nil follows
    /// `AppSettings.defaultPermissionMode`, and the CLI's own configuration beyond that.
    var selectedPermissionMode: AgentPermissionMode?
    var selectedManagedWorkspacePlan: ManagedWorkspacePlan?

    weak var delegate: SessionComposerViewControllerDelegate?

    // MARK: - Initialization

    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        self.customizationLookup = customizationLookup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        greetingLabel.applyFont(.heading)
        greetingLabel.alignment = .center
        // The label wrapper yields at priority 1 so hosts with slots can truncate it. This
        // host has no slot — the hero's width *is* the greeting's — and without this the
        // vertical stack resolved its ambiguous width to the mark's 40 points and cut the
        // greeting to one glyph and an ellipsis.
        greetingLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        heroMark.setAccessibilityElement(false)
        heroStack.orientation = .vertical
        heroStack.alignment = .centerX
        heroStack.spacing = Design.Spacing.inset
        heroStack.addArrangedSubview(heroMark)
        heroStack.addArrangedSubview(greetingLabel)
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        // The quietest tier there is. With the primary gone from this screen, a bordered import
        // would be the loudest thing left in the column and would read as the action to take —
        // when it is the alternative to the one the box already offers.
        importButton.emphasis = .tertiary
        importButton.setAccessibilityIdentifier("composer.session-start.import")

        // The row's slack belongs *after* the last chip, not inside it. The column states its
        // own measure now, so for the first time the row is wider than its chips — and a chip
        // hugs its content loosely enough that the leftover width was shared out among them,
        // drawing an agent's name in a pill three times its length. The spacer hugs less than
        // any of them, so it takes the remainder instead.
        let chipSpacer = NSView()
        chipSpacer.setContentHuggingPriority(ComposerDefaults.spacerPriority, for: .horizontal)
        chipSpacer.setContentCompressionResistancePriority(
            ComposerDefaults.spacerPriority,
            for: .horizontal
        )

        // Where, and who — two chips for the two questions, not four for their parts. A project
        // and a checkout are one place; an agent and a login are one identity, and read as four
        // separate answers the reader had to reassemble. What the session *runs with* is not
        // here at all: it belongs to the words being written, so it sits on the prompt box's own
        // bottom row (see `wirePrompt`). Placement is what carries the meaning now — above the
        // box is who and where, inside it is what with.
        let chips = NSStackView(views: [locationChip, identityChip, chipSpacer])
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = Design.Spacing.small

        locationChip.setAccessibilityIdentifier("composer.session-start.location")
        identityChip.setAccessibilityIdentifier("composer.session-start.identity")
        managedWorkspaceCheckbox.setAccessibilityIdentifier(
            "composer.session-start.managed-workspace"
        )
        managedWorkspaceDeliveryChip.setAccessibilityIdentifier(
            "composer.session-start.managed-workspace.delivery"
        )
        managedWorkspacePublicationCheckbox.setAccessibilityIdentifier(
            "composer.session-start.managed-workspace.publish"
        )
        managedWorkspacePublicationChip.setAccessibilityIdentifier(
            "composer.session-start.managed-workspace.publication"
        )

        // The identity is the stable trailing answer and keeps its natural width. The location
        // is deliberately the pressure valve: its full value is already in the tooltip and it
        // widens on hover. If both chips resist at `.required`, their honest intrinsic widths
        // can overrule the pane's required edge pins at compact window sizes and make the prompt
        // wider than the pane. Keep this below the column's optional measurement so the title
        // truncates before any outer geometry breaks.
        locationChip.setContentCompressionResistancePriority(
            ComposerDefaults.locationChipCompressionPriority,
            for: .horizontal
        )
        identityChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The one chip made to shorten: a long location truncates before it can push the
        // identity out of the row. A hard cap rather than a lowered priority, because a chip's
        // width comes from its internal label's required edge pins — both labels resist
        // equally, so under pressure the engine squeezed the *sibling* to a bare icon while the
        // long name kept every character.
        //
        // The tail is what goes, which costs the checkout rather than the project name. Per-half
        // truncation would mean budgeting characters against a width in points, on a single
        // label that draws its own ellipsis — a guess dressed as a rule. Hovering the chip
        // widens it to its full contents (`ChipView`), and the tooltip states the whole answer.
        locationChip.widthAnchor.constraint(
            lessThanOrEqualToConstant: ComposerDefaults.locationChipMaxWidth
        ).isActive = true

        wirePrompt()
        setupPromptCustomization()
        wireManagedWorkspace()

        // Three things, evenly spaced: where this runs, what to say, and what to do about it.
        // The column used to need two different steps because it held a usage block as well;
        // with that folded into the box there is one rhythm to keep.
        stack.setViews(
            [chips, managedWorkspaceCheckbox, promptContentContainer, actionRow],
            in: .leading
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(heroStack)
        view.addLayoutGuide(heroRegion)

        // The column fills the pane up to its cap, rather than inheriting its width from
        // whichever row happens to be widest. It used to inherit it, and the widest row was the
        // chips — so moving three of them into the box would have quietly narrowed the box they
        // moved into.
        //
        // Stated against the *pane* rather than as 720, which matters more than it looks: a
        // constant width would also become the pane's minimum, since a fitting size honours an
        // optional constraint wherever nothing opposes it, and the window would have refused to
        // narrow past a number that is a maximum. Read from the pane it says only "as wide as
        // there is room for", and the `contentWidth` cap beside it is what stops it there.
        let measure = stack.widthAnchor.constraint(
            equalTo: view.widthAnchor,
            constant: -Design.Spacing.pane * 2
        )
        measure.priority = ComposerDefaults.columnMeasurePriority

        // `setHuggingPriority`, not `setContentHuggingPriority`: a stack view hugs its content
        // through its **own** property, and the content one it inherits from `NSView` leaves
        // that untouched at its default 250. That is above the measurement, so the column went
        // on hugging its widest row and the measurement never applied — the box sat at 415
        // points in a 1454-point pane, with the chips inside it crushed against each other,
        // while every constraint here read as though it were filling the pane.
        stack.setHuggingPriority(
            ComposerDefaults.columnHuggingPriority,
            for: .horizontal
        )

        // The composer hangs from the pane's bottom edge — the shape every chat product has
        // taught: input below, room above. The prompt grows upward from here.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            measure,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: ComposerDefaults.contentWidth),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            promptContentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // The action row spans the column, which is what puts the send on the same edge the
            // box ends at rather than wherever its own two buttons happen to end.
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),

            // The hero floats in whatever room the composer leaves above itself.
            heroRegion.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            heroRegion.bottomAnchor.constraint(equalTo: stack.topAnchor),
            heroRegion.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heroRegion.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heroStack.centerXAnchor.constraint(equalTo: heroRegion.centerXAnchor),
            heroStack.centerYAnchor.constraint(equalTo: heroRegion.centerYAnchor),
            heroStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            heroStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            heroMark.widthAnchor.constraint(equalToConstant: ComposerDefaults.heroMarkSide),
            heroMark.heightAnchor.constraint(equalToConstant: ComposerDefaults.heroMarkSide)
        ])

        wireChips()
        observeUsage()
        installActivityBeam()
        // Nothing has been discovered yet, so the offer starts absent rather than as an
        // untitled button holding a row open until the first scan comes back.
        refreshImportOffer()
    }

    /// A pane too short to float the greeting shows the composer alone — half a hero peeking
    /// from behind the prompt reads as a defect, an absent one as a compact window.
    ///
    /// Nothing else is fitted here any more. The column is bounded by construction — a chip row,
    /// a box capped at `Design.Size.inputMaxHeight`, and a one-line import offer — so there is
    /// no part of it that has to be told what room it may take. What used to need telling was
    /// the usage panel, which drew one bar per rate-limit window and grew the *window* with them
    /// (see `window-chrome.md`); its reading is one line inside the box now.
    override func viewDidLayout() {
        super.viewDidLayout()
        heroStack.isHidden = heroRegion.frame.height
            < heroStack.fittingSize.height + ComposerDefaults.heroMinimumClearance
    }

    /// Places the protected native prompt behind the generic around-hook host. The contract only
    /// accepts horizontal hooks containing exactly one `.proceed`, so this container can gain
    /// leading/trailing accessories but can never lose the text field.
    private func setupPromptCustomization() {
        promptContentContainer.setAccessibilityIdentifier("composer.session-start.content")
        // A family-wide patch must not appear before the composer has a real project context.
        promptCustomizationHost.deactivate()
    }

    /// Rings the prompt with the ambient agent-activity beam. A sibling pinned over the
    /// container rather than a subview of it, so an extension swapping the composed content
    /// cannot take the ring with it; the view is decorative and swallows no events.
    private func installActivityBeam() {
        view.addSubview(activityBeamView)
        NSLayoutConstraint.activate([
            activityBeamView.leadingAnchor.constraint(equalTo: promptContentContainer.leadingAnchor),
            activityBeamView.trailingAnchor.constraint(equalTo: promptContentContainer.trailingAnchor),
            activityBeamView.topAnchor.constraint(equalTo: promptContentContainer.topAnchor),
            activityBeamView.bottomAnchor.constraint(equalTo: promptContentContainer.bottomAnchor)
        ])
        activityBeamView.update(workload: AgentWorkloadMonitor.shared.workload)
        appEvents.observe(AgentWorkloadDidChange.self) { [weak self] event in
            self?.activityBeamView.update(workload: event.workload)
        }
    }

    /// A reading arriving after the composer is on screen redraws the line in place, rather
    /// than waiting for the next time an account is picked.
    private func observeUsage() {
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    private func wirePrompt() {
        promptView.showsImageAttachments = true
        promptView.placeholder = ComposerDefaults.promptPlaceholder
        promptView.minimumHeight = ComposerDefaults.promptHeight
        // Return belongs to the text here; `startButton` sends. The box still carries the
        // control row the conversation's reply box has — the row comes from `setFooterControls`
        // below, not from where the send sits. See `PromptView.SubmitPlacement`.
        promptView.submitPlacement = .outside

        usageLabel.applyFont(.subheading)
        usageLabel.textColor = Design.Text.tertiary
        usageLabel.lineBreakMode = .byTruncatingTail
        usageLabel.isHidden = true
        usageLabel.setAccessibilityIdentifier("composer.session-start.usage")
        // The one thing on the row that may lose characters. The chips beside it name choices
        // and are unreadable half-drawn; a reading truncated from its tail still says which
        // window is tightest, which is the part that decides anything.
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The chips are the row's other pressure valve, and they give way in a stated order
        // rather than all at once — see `ComposerDefaults.modelChipCompressionPriority`. None
        // of them may be required: a required chip is a hidden minimum width on the whole
        // column, and the column is what has to fit the pane.
        for (chip, priority) in [
            (modelChip, ComposerDefaults.modelChipCompressionPriority),
            (surfaceChip, ComposerDefaults.surfaceChipCompressionPriority),
            (speedChip, ComposerDefaults.speedChipCompressionPriority),
            (effortChip, ComposerDefaults.effortChipCompressionPriority),
            (modeChip, ComposerDefaults.modeChipCompressionPriority)
        ] {
            chip.setContentCompressionResistancePriority(priority, for: .horizontal)
        }
        modelChip.setAccessibilityIdentifier("composer.session-start.model")
        modeChip.setAccessibilityIdentifier("composer.session-start.mode")
        effortChip.setAccessibilityIdentifier("composer.session-start.effort")
        speedChip.setAccessibilityIdentifier("composer.session-start.speed")
        surfaceChip.setAccessibilityIdentifier("composer.session-start.surface")

        // What the session will be run *with* on the leading side, what it has left to spend on
        // the trailing side beside the send — the reply composer's arrangement, because it is
        // the same question asked one message earlier.
        // The schedule offer sits **inside the box**, on the row that already carries what the
        // session will be sent with. Two reasons, and the second is the stronger: the row above
        // the box answers where and who and nothing else — a third chip there would be a third
        // question in a place that deliberately asks two — and *when this goes* belongs to the
        // message, exactly as the reply box's own chevron does. Beside the send either way.
        promptView.setFooterControls(
            leading: [modelChip, modeChip, effortChip, speedChip],
            trailing: [usageLabel, surfaceChip]
        )

        promptView.onSubmit = { [weak self] prompt in
            self?.start(with: prompt)
        }

        // Kept on disk as it is typed. Until the session starts, this text exists nowhere
        // else — no transcript, no terminal, no shell history — so an unexpected quit is
        // otherwise the end of it.
        promptView.onChange = { [weak self] text in
            guard let self, let projectID = self.projectID else { return }
            DraftStore.shared.setDraft(text, for: projectID)
            // The chip's own menu is rebuilt on open, but whether it is *usable* changes with
            // every keystroke — an empty brief has nothing to schedule.
            self.refreshScheduleChip()
        }

        wireScheduledStrip()
        appEvents.observe(ScheduledMessagesDidChange.self) { [weak self] _ in
            self?.refreshScheduledStrip()
        }
        refreshScheduleChip()
        refreshScheduledStrip()
    }

    /// Whether the chip may be pressed at all, with its reason on the tooltip rather than left
    /// to be discovered by pressing it.
    func refreshScheduleChip() {
        let refusal = scheduleRefusalReason()
        scheduleButton.isEnabled = refusal == nil
        scheduleButton.toolTip = refusal ?? L10n.string("Start this session later")
    }

    /// Each chip rebuilds its menu when opened, so a change of agent is reflected everywhere.
    private func wireChips() {
        // One control, two verbs — see `locationItems()` for why they are not the same act and
        // must not be one list. The represented value says which was chosen.
        locationChip.itemsProvider = { [weak self] in self?.locationItems() ?? [] }
        locationChip.onSelect = { [weak self] item in
            guard let self else { return }
            switch item.representedValue {
            case let selection as CheckoutSelection:
                switch selection {
                case .thisCheckout:
                    self.selectedBranch = nil
                case .checkout(let branch):
                    self.selectedBranch = branch
                case .newWorktree:
                    // Leaves the selection alone: creating a worktree adds a project and moves
                    // the composer to it, so this composer's branch never applies.
                    self.createWorktree()
                }
                self.refreshChips()
            case let id as ProjectID:
                guard id != self.projectID else { return }
                self.delegate?.sessionComposer(self, didSelectProject: id)
            case let action as ProjectAction:
                switch action {
                case .addExisting:
                    self.delegate?.sessionComposerDidRequestAddFolder(self)
                case .createNew:
                    self.delegate?.sessionComposerDidRequestNewFolder(self)
                }
            default:
                break
            }
        }

        identityChip.itemsProvider = { [weak self] in self?.identityItems() ?? [] }
        identityChip.onSelect = { [weak self] item in
            guard let self, let identity = item.representedValue as? ComposerIdentity else {
                return
            }
            self.selectedAgent = identity.agent
            // A runtime row names no login, so it takes the one that runtime prefers — which is
            // not necessarily the standard handle, since that may be the account the user
            // switched off.
            self.selectedAccountHandle = identity.account
                ?? AgentAccountDiscovery.preferredHandle(for: identity.agent)
            // Everything the login decided is reset, whether or not the runtime changed: a model
            // pinned on one account is not necessarily offered on another, and an effort is a
            // property of the model's own published catalog.
            self.selectedModel = nil
            self.selectedReasoningEffort = nil
            self.selectedFastMode = nil
            self.refreshChips()
        }

        modelChip.itemsProvider = { [weak self] in self?.modelItems() ?? [] }
        modelChip.onSelect = { [weak self] item in
            guard let self else { return }
            self.selectedModel = item.representedValue as? String
            self.discardUnsupportedEffort()
            self.discardUnsupportedFastMode()
            self.refreshChips()
        }

        effortChip.itemsProvider = { [weak self] in self?.effortItems() ?? [] }
        effortChip.onSelect = { [weak self] item in
            // Nil is the explicit first row: let the account or model choose.
            self?.selectedReasoningEffort = item.representedValue as? String
            self?.refreshChips()
        }

        speedChip.itemsProvider = { [weak self] in self?.speedItems() ?? [] }
        speedChip.onSelect = { [weak self] item in
            guard let choice = item.representedValue as? ConversationSpeedChoice else { return }
            self?.selectedFastMode = choice.fastMode
            self?.refreshChips()
        }

        modeChip.itemsProvider = { [weak self] in self?.permissionModeItems() ?? [] }
        modeChip.onSelect = { [weak self] item in
            // Nil is a real answer here — the row marked as the default, or Use Agent's
            // Setting where there is none — so this reads "not a mode" as inherit rather than
            // falling back to one.
            self?.selectedPermissionMode = item.representedValue as? AgentPermissionMode
            self?.refreshChips()
        }

        surfaceChip.itemsProvider = { [weak self] in self?.surfaceItems() ?? [] }
        surfaceChip.onSelect = { [weak self] item in
            self?.usesNativeUI = (item.representedValue as? Bool) ?? false
            self?.refreshChips()
        }
    }

    private func wireManagedWorkspace() {
        managedWorkspaceDeliveryChip.itemsProvider = { [weak self] in
            self?.managedWorkspaceDeliveryItems() ?? []
        }
        managedWorkspaceDeliveryChip.onSelect = { [weak self] item in
            guard let self,
                  let delivery = item.representedValue as? ManagedWorkspaceDelivery else { return }
            guard var plan = self.selectedManagedWorkspacePlan else { return }
            plan.delivery = delivery
            self.selectedManagedWorkspacePlan = plan
            self.refreshManagedWorkspaceControls()
        }
        managedWorkspacePublicationChip.itemsProvider = { [weak self] in
            self?.managedWorkspacePublicationItems() ?? []
        }
        managedWorkspacePublicationChip.onSelect = { [weak self] item in
            guard let self,
                  var plan = self.selectedManagedWorkspacePlan,
                  let publication = item.representedValue as? ManagedWorkspacePublication
            else { return }
            plan.publication = publication
            self.selectedManagedWorkspacePlan = plan
            self.refreshManagedWorkspaceControls()
        }
        refreshManagedWorkspaceControls()
    }

    // MARK: - Public Methods

    /// Points the composer at a project — or at none, which is a real mode: the way in when
    /// nothing exists yet. Every choice resets either way.
    ///
    /// Being pointed at the project it already holds is a *return* to it, not a change of
    /// project: the chips, the half-written prompt and the attached images are all left exactly
    /// as they were. Looking at a session and coming back is the same kind of detour as opening
    /// Settings over it, and neither is a reason to undo a decision the user is in the middle of
    /// making. This is why a session that has started clears the prompt itself (`start(with:)`) —
    /// nothing else does it any more.
    func show(projectID: ProjectID?) {
        if hasBeenShown, projectID == self.projectID {
            refreshDerivedState()
            return
        }
        hasBeenShown = true

        // Words typed before a project was chosen are the user's work: they follow the
        // composer into the project that is chosen next, unless that project already holds a
        // draft of its own.
        let carriedPrompt = self.projectID == nil ? promptView.stringValue : nil

        self.projectID = projectID
        updatePromptCustomization(for: projectID)

        selectedAgent = AppSettings.shared.defaultAgentKind
        // The login this agent offers rather than the standard handle: the standard one may be
        // exactly the account the user switched off, and a composer that still starts there
        // would launch on it while naming it in the chip.
        selectedAccountHandle = AgentAccountDiscovery.preferredHandle(for: selectedAgent)
        selectedModel = nil
        selectedReasoningEffort = nil
        selectedFastMode = nil
        selectedBranch = nil
        selectedPermissionMode = nil
        selectedManagedWorkspacePlan = nil
        managedWorkspaceCheckbox.state = .off
        setManagedWorkspaceOptionsAttached(false)

        promptView.clearAttachments()

        // Warmed as the composer appears, not as the identity menu opens: a fetch started on
        // the click lands after the menu has been read and dismissed.
        AccountUsageMenu.prefetch()
        refreshGreeting()

        if !hasPlayedHeroDrawIn, !Design.Motion.reducesMotion {
            hasPlayedHeroDrawIn = true
            heroMark.playDrawIn()
        }

        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            // No project: the prompt is live, the send is not, and the location chip is the ask.
            // Words typed here stay; a draft belonging to the project just left does not.
            promptView.stringValue = carriedPrompt ?? ""
            importable = []
            refreshImportOffer()
            refreshChips()
            return
        }

        // The choices reset per project; what was typed does not. A half-written prompt is
        // the user's work, and it is restored whether it was left behind by switching
        // projects or by the app going away underneath it.
        let draft = DraftStore.shared.draft(for: projectID)
        if let carriedPrompt, !carriedPrompt.isEmpty, draft.isEmpty {
            promptView.stringValue = carriedPrompt
            DraftStore.shared.setDraft(carriedPrompt, for: projectID)
        } else {
            promptView.stringValue = draft
        }

        refreshChips()
        discoverImportable(for: project)
    }

    /// A fresh line each time the composer is pointed somewhere, morphing in place when a
    /// greeting is already up.
    private func refreshGreeting() {
        let message = ComposerGreeting.message()
        guard message != greetingLabel.stringValue else { return }
        greetingLabel.setStringValue(message, animated: !greetingLabel.stringValue.isEmpty)
    }

    /// Puts the caret in the prompt.
    ///
    /// The pane hands focus to whatever it puts on screen — a terminal takes it in `attach`, a
    /// native conversation's prompt in `attachConversation` — and this is the same surface for a
    /// session that does not exist yet. Arriving here by ⌘N or by selecting a project, the only
    /// thing being asked for is what to type, so the field should not have to be clicked first.
    ///
    /// Skipped when an extension has replaced the prompt: the native editor is hidden then, and
    /// AppKit answers `makeFirstResponder` for a hidden view by clearing the window's instead.
    func focusPrompt() {
        guard !promptView.isHiddenOrHasHiddenAncestor else { return }
        promptView.focusAtEnd()
    }

    /// Re-reads everything the chips *derive* — the app-wide defaults they name, the account
    /// they resolve, what is left of it — while leaving every choice and the prompt untouched.
    ///
    /// For a composer coming back into view without having been re-configured. Settings is
    /// where those defaults are changed, and a session can be looked at for long enough for a
    /// usage reading to age out, so a composer returned to must state them again.
    func refreshDerivedState() {
        refreshChips()
    }

    /// Keeps component targeting separate from project lookup so the shell can be exercised
    /// without manufacturing persisted project state. Product navigation calls it through
    /// `show(projectID:)`.
    func updatePromptCustomization(for projectID: ProjectID?) {
        guard let projectID else {
            promptCustomizationHost.deactivate()
            return
        }
        promptCustomizationHost.updateTarget(
            .sessionStartComposer(projectID: projectID.uuidString.lowercased())
        )
    }

    /// Looks for conversations this project could adopt, revealing the chip if any are found.
    ///
    /// The result is checked against the project it was requested for: scanning takes long
    /// enough that the user can select another project before it finishes.
    private func discoverImportable(for project: Project) {
        importable = []
        refreshImportOffer()

        SessionImporter.discover(for: project) { [weak self] found in
            guard let self, self.projectID == project.id else { return }

            self.importable = found
            self.refreshImportOffer()
        }
    }

    /// The offer appears once discovery has found something to offer. Only the button hides —
    /// the row it is on carries the send, so it stands whatever discovery answers.
    private func refreshImportOffer() {
        importButton.isHidden = importable.isEmpty
        importButton.title = ComposerDefaults.importTitle(count: importable.count)
    }

    // MARK: - Chip State

    /// Puts the scheduled strip into the column, or takes it out again.
    ///
    /// See `refreshScheduledStrip` for why it leaves rather than hides: the column's width is
    /// measured against the pane, and a member with nothing in it still took part in that.
    func setScheduledStripAttached(_ isAttached: Bool) {
        let isPresent = stack.arrangedSubviews.contains(scheduledStrip)
        guard isAttached != isPresent else { return }

        if isAttached {
            stack.insertArrangedSubview(scheduledStrip, at: 1)
        } else {
            stack.removeArrangedSubview(scheduledStrip)
            scheduledStrip.removeFromSuperview()
        }
    }

    func refreshChips() {
        let project = projectID.flatMap { ProjectStore.shared.project(withID: $0) }
        let checkout = project.flatMap(checkoutBranch(of:))

        locationChip.configure(
            symbolName: ComposerDefaults.locationSymbol,
            title: ComposerDefaults.locationTitle(project: project?.name, branch: checkout)
        )
        // The folder was the old subheading; as a tooltip it still answers "where", without
        // spending a line of the pane on a path that rarely matters. `configure` puts the title
        // on the tooltip, so this has to come after it.
        locationChip.toolTip = locationDetail(project: project, branch: checkout)

        // A session cannot start nowhere. The prompt stays live — words first, place second —
        // but the send keeps the promise honest, and says why rather than sitting there dimmed
        // with nothing to explain itself.
        promptView.isSubmissionEnabled = project != nil
        promptView.submissionDisabledReason = project == nil
            ? ComposerDefaults.chooseProjectFirstReason
            : nil
        // The disabled reason has to be visible without hovering or invoking VoiceOver. The
        // prompt deliberately remains editable before a project is chosen, so its placeholder
        // is the one stable place that can connect the location chip to the disabled send.
        promptView.placeholder = project == nil
            ? ComposerDefaults.chooseProjectFirstReason
            : ComposerDefaults.promptPlaceholder
        startButton.isEnabled = project != nil
        startButton.toolTip = project == nil ? ComposerDefaults.chooseProjectFirstReason : nil

        let accounts = availableAccounts
        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil

        // The login is named only where there is a choice of one — the same threshold that used
        // to decide whether an account chip appeared at all. A single-login agent would
        // otherwise spend half of this chip stating something nobody can act on.
        identityChip.configure(
            icon: selectedAgent.icon,
            title: ComposerDefaults.identityTitle(
                agent: selectedAgent.displayName,
                account: accounts.count < 2 ? nil : account.map(AccountName.display)
            )
        )

        let models = AgentModels.available(for: selectedAgent, account: account)
        modelChip.isHidden = models.isEmpty
        modelChip.configure(
            symbolName: ComposerDefaults.modelSymbol,
            title: modelChipTitle(for: account)
        )

        // Effort is a property of the selected model's published catalog, not an assumption
        // about the provider. No catalog means no chip and no value sent to the runtime.
        discardUnsupportedEffort(account: account)
        let model = modelIdentifierToLaunch(on: account)
        let effortOption = ReasoningEffortPresentation.option(
            kind: selectedAgent,
            model: model,
            account: account
        )
        effortChip.isHidden = effortOption == nil
        effortChip.configure(
            symbolName: ReasoningEffortPresentation.symbol,
            title: ReasoningEffortPresentation.title(
                selected: selectedReasoningEffort,
                kind: selectedAgent,
                model: model,
                account: account
            )
        )

        // Speed is offered only where the selected model publishes a usable Fast mechanism.
        // Standard and Fast remain per-conversation values; nil follows the provider-specific
        // startup choice in General, and then the agent's own settings.
        discardUnsupportedFastMode(account: account)
        speedChip.isHidden = !AgentModels.supportsFastMode(
            kind: selectedAgent,
            model: model,
            account: account
        )
        speedChip.configure(
            symbolName: ConversationSpeedPresentation.symbol,
            title: ConversationSpeedPresentation.chipTitle(
                selected: selectedFastMode,
                kind: selectedAgent,
                model: model,
                account: account,
                projectDirectory: executionDirectory(of: project)
            )
        )

        // Names the mode that will actually apply, not only the one chosen here. Nothing runs
        // while the composer is open, so the observed source cannot answer — but the app-wide
        // default, the agent's own settings and what this login last ran in all can, which is
        // every case but a login that has never run this agent at all.
        modeChip.isHidden = !selectedAgent.supportsPermissionModes
        let inheritedMode = inheritedPermissionMode(account: account, project: project)
        modeChip.configure(
            symbolName: PermissionModePresentation.symbol,
            title: PermissionModePresentation.chipTitle(
                selected: selectedPermissionMode,
                inherited: inheritedMode
            )
        )
        // `configure` puts the title on the tooltip, so whose value it is has to be said after.
        if let tooltip = PermissionModePresentation.chipTooltip(
            selected: selectedPermissionMode,
            inherited: inheritedMode
        ) {
            modeChip.toolTip = tooltip
        }

        // Offered only where there is a choice to make: a runtime whose conversation Threading
        // can render *and* whose own terminal shows that same conversation. Cursor has the first
        // half and not the second — its TUI and its ACP server keep separate chats — so its
        // sessions are Native with nothing to pick. See `AgentCapabilities.terminalUI`.
        surfaceChip.isHidden = !SessionSurfaceTogglePresentation.canSwitchSurface(selectedAgent)
        usesNativeUI = AgentSession.resolvedNativeSurface(usesNativeUI, for: selectedAgent)
        surfaceChip.configure(
            symbolName: ComposerDefaults.surfaceSymbol,
            title: usesNativeUI ? ComposerDefaults.nativeTitle : selectedAgent.originalUITitle
        )

        refreshUsage(account: account)
        refreshManagedWorkspaceControls(project: project)
    }

    /// Turns the isolated path on without inventing a name or publishing anything. Turning it
    /// off discards every subordinate choice and removes the options row altogether.
    private func setManagedWorkspaceEnabled(_ enabled: Bool) {
        if enabled {
            selectedManagedWorkspacePlan = selectedManagedWorkspacePlan ?? ManagedWorkspacePlan()
        } else {
            selectedManagedWorkspacePlan = nil
        }
        refreshManagedWorkspaceControls()
    }

    private func setManagedWorkspacePublicationEnabled(_ enabled: Bool) {
        guard var plan = selectedManagedWorkspacePlan else { return }
        plan.publication = enabled ? (plan.publication ?? .draft) : nil
        selectedManagedWorkspacePlan = plan
        refreshManagedWorkspaceControls()
    }

    private func refreshManagedWorkspaceControls(project: Project? = nil) {
        guard isViewLoaded else { return }
        let resolvedProject = project
            ?? projectID.flatMap { ProjectStore.shared.project(withID: $0) }
        let isGitProject = resolvedProject.map(ManagedGitWorkspace.canProvision(from:)) ?? false
        let supportsFinish = ManagedWorkspaceEligibility.supportsFinishHandshake(
            kind: selectedAgent,
            usesNativeUI: usesNativeUI
        )
        let isAvailable = isGitProject && supportsFinish
        let supportsPublication = isAvailable
            && (resolvedProject.map(ManagedWorkspaceEligibility.supportsPublication(from:)) ?? false)
        let changeRequestProvider = changeRequestProvider(for: resolvedProject)

        managedWorkspaceCheckbox.isEnabled = isAvailable
        if !isGitProject {
            managedWorkspaceCheckbox.toolTip = L10n.string(
                "Managed workspaces require a Git project."
            )
        } else if !supportsFinish {
            managedWorkspaceCheckbox.toolTip = L10n.string(
                "Managed workspaces require an agent surface with Threading session tools."
            )
        } else {
            managedWorkspaceCheckbox.toolTip = L10n.string(
                "Run in an isolated managed worktree"
            )
        }

        if !isAvailable {
            selectedManagedWorkspacePlan = nil
            managedWorkspaceCheckbox.state = .off
        } else {
            if !supportsPublication, selectedManagedWorkspacePlan?.publication != nil {
                selectedManagedWorkspacePlan?.publication = nil
            }
            managedWorkspaceCheckbox.state = selectedManagedWorkspacePlan == nil ? .off : .on
        }

        let delivery = selectedManagedWorkspacePlan?.delivery ?? .mergeAndCleanUp
        managedWorkspaceDeliveryChip.configure(
            symbolName: ComposerDefaults.managedWorkspaceSymbol,
            title: ComposerDefaults.managedWorkspaceDeliveryTitle(delivery)
        )
        let publication = selectedManagedWorkspacePlan?.publication
        managedWorkspacePublicationCheckbox.state = publication == nil ? .off : .on
        managedWorkspacePublicationChip.configure(
            symbolName: ComposerDefaults.managedWorkspacePublicationSymbol,
            title: ComposerDefaults.managedWorkspacePublicationTitle(
                publication ?? .draft,
                provider: changeRequestProvider ?? .github
            )
        )
        setManagedWorkspacePublicationOfferAttached(supportsPublication)
        setManagedWorkspaceOutcome(isPublication: publication != nil)
        setManagedWorkspaceOptionsAttached(selectedManagedWorkspacePlan != nil && isAvailable)
    }

    /// Local delivery and remote publication are two different outcomes. Only the chosen one's
    /// settings belong to the hierarchy; showing both would falsely promise a local merge before
    /// a provider change request.
    private func setManagedWorkspaceOutcome(isPublication: Bool) {
        let desired = isPublication
            ? managedWorkspacePublicationChip
            : managedWorkspaceDeliveryChip
        for view in managedWorkspaceOutcomeRow.arrangedSubviews where view !== desired {
            managedWorkspaceOutcomeRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !managedWorkspaceOutcomeRow.arrangedSubviews.contains(desired) else { return }
        managedWorkspaceOutcomeRow.addArrangedSubview(desired)
    }

    private func setManagedWorkspacePublicationOfferAttached(_ attached: Bool) {
        let present = managedWorkspaceOptions.arrangedSubviews.contains(
            managedWorkspacePublicationCheckbox
        )
        guard attached != present else { return }
        if attached {
            // The publication choice owns the Draft/Ready setting, so it must read before the
            // setting it reveals. Local delivery occupies the same outcome row while this is
            // off; turning it on swaps that row in place below the checkbox.
            managedWorkspaceOptions.insertArrangedSubview(
                managedWorkspacePublicationCheckbox,
                at: 0
            )
        } else {
            managedWorkspaceOptions.removeArrangedSubview(managedWorkspacePublicationCheckbox)
            managedWorkspacePublicationCheckbox.removeFromSuperview()
        }
    }

    /// Dynamic options leave the hierarchy when isolation is off. `isHidden` would still leave
    /// a managed-workspace surface discoverable to hierarchy and accessibility inspection.
    private func setManagedWorkspaceOptionsAttached(_ attached: Bool) {
        let present = stack.arrangedSubviews.contains(managedWorkspaceOptions)
        guard attached != present else { return }
        if attached {
            guard let checkboxIndex = stack.arrangedSubviews.firstIndex(of: managedWorkspaceCheckbox)
            else { return }
            stack.insertArrangedSubview(managedWorkspaceOptions, at: checkboxIndex + 1)
        } else {
            stack.removeArrangedSubview(managedWorkspaceOptions)
            managedWorkspaceOptions.removeFromSuperview()
        }
    }

    private func managedWorkspaceDeliveryItems() -> [ThemedMenuEntry] {
        let selected = selectedManagedWorkspacePlan?.delivery ?? .mergeAndCleanUp
        return ManagedWorkspaceDelivery.allCases.map { delivery in
            .item(ThemedMenuItem(
                title: ComposerDefaults.managedWorkspaceDeliveryTitle(delivery),
                representedValue: delivery,
                isSelected: delivery == selected
            ))
        }
    }

    private func managedWorkspacePublicationItems() -> [ThemedMenuEntry] {
        let selected = selectedManagedWorkspacePlan?.publication ?? .draft
        let project = projectID.flatMap { ProjectStore.shared.project(withID: $0) }
        let provider = changeRequestProvider(for: project) ?? .github
        return ManagedWorkspacePublication.allCases.map { publication in
            .item(ThemedMenuItem(
                title: ComposerDefaults.managedWorkspacePublicationTitle(
                    publication,
                    provider: provider
                ),
                representedValue: publication,
                isSelected: publication == selected
            ))
        }
    }

    private func changeRequestProvider(for project: Project?) -> SourceControlProvider? {
        guard let project,
              let remote = GitInfo.remoteOriginURL(for: project.folderPath),
              case .supported(let repository) = ChangeRequestRepository.detect(remote: remote)
        else { return nil }
        return repository.provider
    }

    /// The logins this agent offers, and none at all for a runtime without account routing
    /// (`AgentKind.supportsAccounts`) — asked in one place because the chip's title, its menu
    /// and the usage line all have to agree about how many there are.
    private var availableAccounts: [AgentAccount] {
        selectedAgent.supportsAccounts ? AgentAccountDiscovery.accounts(for: selectedAgent) : []
    }

    /// The branch a session started now would run on, or nil where the folder is not a
    /// repository and "which checkout" is not a question.
    private func checkoutBranch(of project: Project) -> String? {
        guard GitInfo.repositoryRoot(for: project.folderPath) != nil else { return nil }
        return selectedBranch ?? GitInfo.currentBranch(for: project.folderPath)
    }

    /// Where the session will actually run, said the way the shell would say it.
    ///
    /// The *destination* folder, not necessarily this project's: choosing a sibling checkout
    /// routes the session into that project
    /// (`ProjectStore.checkout(onBranch:inRepositoryOf:)`) while the chip goes on naming this
    /// project's repository, which is the reading a breadcrumb wants. The path is the one place
    /// the two can be told apart, so it is what the tooltip answers with.
    private func locationDetail(project: Project?, branch: String?) -> String? {
        guard let project else { return nil }

        let path = abbreviatedPath(executionDirectory(of: project) ?? project.folderPath)
        guard let branch else { return path }
        return "\(path) \(ComposerDefaults.breadcrumbSeparator) \(branch)"
    }

    /// The folder the session will start in, which is what a project-scoped settings layer is
    /// read relative to. A sibling checkout carries its own `.claude` directory, so resolving
    /// the destination here is what keeps the permission-mode chip naming the settings the
    /// session will actually be launched under.
    private func executionDirectory(of project: Project?) -> String? {
        guard let project else { return nil }

        let destination = selectedBranch
            .flatMap { ProjectStore.shared.checkout(onBranch: $0, inRepositoryOf: project.id) }
            .flatMap { ProjectStore.shared.project(withID: $0) } ?? project
        return destination.folderPath
    }

    /// What a session started from this composer would inherit if it pinned no mode of its own.
    private func inheritedPermissionMode(
        account: AgentAccount?,
        project: Project?
    ) -> ResolvedPermissionMode {
        ResolvedPermissionMode.inherited(
            for: selectedAgent,
            account: account,
            projectDirectory: executionDirectory(of: project)
        )
    }

    /// Writes the chosen account's usage onto the box's own row, fetching when the reading has
    /// aged out.
    ///
    /// The account is passed in when the caller has already resolved it, since resolving one
    /// scans the filesystem and `refreshChips` runs on every chip change.
    ///
    /// The line is the toolbar pill's own reading, metered by the model this session would
    /// launch on — the same string, from the same formatter, so the number a user reads here is
    /// the number the pill goes on showing once the session exists. Hidden outright when there
    /// is nothing to say: an account with no usage source is not a thing to report an absence
    /// about, which is the rule the pill already keeps.
    private func refreshUsage(account: AgentAccount? = nil) {
        let account = account ?? AgentAccountDiscovery.account(
            for: selectedAgent,
            handle: selectedAccountHandle
        )

        guard let account else {
            clearUsage()
            return
        }

        AccountUsageService.shared.refresh(account)

        let now = Date()
        guard let usage = AccountUsageService.shared.usage(for: account),
              let reading = usage.compactSummary(
                at: now,
                metering: modelToLaunch(on: account, for: selectedAgent)
              )
        else {
            clearUsage()
            return
        }

        usageLabel.stringValue = reading
        usageLabel.toolTip = usageDetail(
            accountName: AccountName.display(for: account),
            usage: usage,
            at: now
        )
        usageLabel.isHidden = false
    }

    private func clearUsage() {
        usageLabel.stringValue = ""
        usageLabel.toolTip = nil
        usageLabel.isHidden = true
    }

    /// Everything the panel this replaced spent a block of the pane on: whose account it is,
    /// what each window stands at and when it comes back, and how old the reading is.
    ///
    /// A tooltip rather than a column, because the detail is what a user reaches for once —
    /// while the line beside the send is what they glance at every time.
    private func usageDetail(accountName: String, usage: AccountUsage, at now: Date) -> String {
        var lines = [
            [accountName, usage.planLabel ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: UsageDefaults.segmentSeparator)
        ].filter { !$0.isEmpty }

        for window in usage.windows + usage.modelWindows {
            var parts = ["\(window.compactName) \(AccountUsage.value(of: window, at: now))"]
            if let resetsAt = window.resetsAt, !window.isExpired(at: now) {
                parts.append(UsageFormat.resets(until: resetsAt, from: now))
            }
            lines.append(parts.joined(separator: UsageDefaults.segmentSeparator))
        }

        lines.append(ComposerDefaults.updatedTitle(UsageFormat.age(of: usage.observedAt, at: now)))
        return lines.joined(separator: "\n")
    }

    /// A folder said the way the shell would say it.
    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Menus

    /// Where this session runs, and — under a line of its own — where to go instead.
    ///
    /// Two questions in one control, deliberately kept in two sections, because they are not
    /// the same act. Choosing a checkout **routes this session**: the composer stays exactly
    /// where it is, and the half-written brief, the agent and the model all survive it.
    /// Choosing a project **navigates**: the composer is pointed somewhere else and every
    /// choice in it resets. Flattened into one list they would read as one list of places, and
    /// the first mis-click on a project row would take a paragraph of context with it.
    ///
    /// `New Worktree…` closes the run-here section rather than opening the other one, because
    /// it is the single row that does both: it makes a place and then goes there.
    ///
    /// The nesting exists only where there is something to keep the projects apart *from*. With
    /// no project chosen, or a folder that is not a repository, there is no run-here section at
    /// all — and a menu whose only row is a submenu is a hover in the way of the answer.
    private func locationItems() -> [ThemedMenuEntry] {
        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            return projectItems()
        }

        let checkouts = checkoutItems(for: project)
        guard !checkouts.isEmpty else { return projectItems() }

        return checkouts + [
            .separator,
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.switchProjectTitle,
                    submenu: projectItems()
                )
            )
        ]
    }

    /// Where the session will run: this checkout, another checkout already added, or one
    /// created now.
    ///
    /// Only checkouts are listed, not branches. A branch with nothing standing on it is not a
    /// place a session can run — offering the repository's whole `git branch` output invited
    /// picking one that resolved to nothing, and the session then ran here anyway while its
    /// record claimed otherwise.
    ///
    /// Empty outside a repository, which is what withholds the section: a plain folder is one
    /// place, and a section offering the one place already in the chip answers nothing.
    private func checkoutItems(for project: Project) -> [ThemedMenuEntry] {
        guard GitInfo.repositoryRoot(for: project.folderPath) != nil else { return [] }

        let current = GitInfo.currentBranch(for: project.folderPath)

        var items: [ThemedMenuEntry] = [
            .item(
                ThemedMenuItem(
                    title: current.map { "\($0)\(ComposerDefaults.thisCheckoutSuffix)" }
                        ?? project.name,
                    representedValue: CheckoutSelection.thisCheckout,
                    isSelected: selectedBranch == nil
                )
            )
        ]

        items += ProjectStore.shared.siblingCheckouts(of: project.id).map { sibling in
            .item(
                ThemedMenuItem(
                    title: sibling.branch,
                    representedValue: CheckoutSelection.checkout(sibling.branch),
                    isSelected: sibling.branch == selectedBranch
                )
            )
        }
        items.append(.separator)
        items.append(
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.newWorktreeTitle,
                    representedValue: CheckoutSelection.newWorktree
                )
            )
        )
        return items
    }

    /// Who this session runs as: every login of every runtime, in one list.
    ///
    /// This was two sections — the selected runtime's logins, then the other runtimes — and
    /// reaching another runtime's login therefore cost two trips through the menu: one to change
    /// runtime, another to pick the login inside it, with a launch-on-the-wrong-account moment in
    /// between. There is only one decision here ("who does this session run as"), so there is one
    /// list, and a row answers it completely.
    ///
    /// A runtime appears as a row of its own only where it offers no login to name — one that
    /// routes no accounts at all, or one whose accounts have not been discovered yet. Such a row
    /// gets no header, because a heading over a single row repeating its own name is furniture.
    ///
    /// **Its logins are filed under a section head.** They used to write the runtime into each
    /// row's own subtitle — `Claude Code · Max · 5h 27% · …` — which said it three times over on
    /// three Claude rows and, being the longest segment on the line, was what pushed the reading
    /// past the panel's width cap until the countdown lost its digits. A head says it once. This
    /// costs no navigation: a header is not a submenu, so reaching another runtime's login is
    /// still the one press it became when this stopped being two sections.
    ///
    /// The readings on the account rows are the cached ones. `show(projectID:)` warms them as
    /// the composer appears (`AccountUsageMenu.prefetch`) for every agent's logins, not only
    /// the selected one — which is exactly what a list spanning every runtime needs, since a
    /// fetch started when a menu opens lands after that menu has been read and dismissed.
    private func identityItems() -> [ThemedMenuEntry] {
        var grouped: [ThemedMenuEntry] = []
        var bare: [ThemedMenuEntry] = []

        for kind in AgentKind.allCases {
            let accounts = kind.supportsAccounts ? AgentAccountDiscovery.accounts(for: kind) : []
            if accounts.isEmpty {
                bare.append(.item(runtimeItem(for: kind)))
            } else {
                grouped.append(.header(kind.displayName))
                grouped += accountItems(for: kind, accounts: accounts)
            }
        }

        // The login-less runtimes go last, behind a rule. Left in runtime order they landed
        // directly under the final group's logins with the same indent and no head of their
        // own, which reads as that runtime having four logins — the last two named Grok and
        // OpenCode. The rule costs no trip through the menu, which is the property the flat
        // list exists to keep; what it collapsed was a runtime chooser standing between the
        // pointer and a login, and this is not that.
        guard !bare.isEmpty else { return grouped }
        return grouped.isEmpty ? bare : grouped + [.separator] + bare
    }

    /// A runtime with no login to offer: the whole row *is* the choice, so it carries the plain
    /// mark rather than one metered against a window nothing here reports.
    private func runtimeItem(for kind: AgentKind) -> ThemedMenuItem {
        ThemedMenuItem(
            title: kind.displayName,
            image: AccountMarkImage.make(for: kind),
            representedValue: ComposerIdentity(agent: kind, account: nil),
            isSelected: kind == selectedAgent
        )
    }

    /// Every project, then the two ways to bring a new one in. The composer can swap projects
    /// because the alternative was leaving it for the sidebar — one more place to look for a
    /// decision this screen exists to gather.
    private func projectItems() -> [ThemedMenuEntry] {
        var items: [ThemedMenuEntry] = ProjectStore.shared.projects.map { project in
            .item(
                ThemedMenuItem(
                    title: project.name,
                    subtitle: abbreviatedPath(project.folderPath),
                    representedValue: project.id,
                    isSelected: project.id == projectID
                )
            )
        }
        if !items.isEmpty {
            items.append(.separator)
        }
        items.append(
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.addExistingFolderTitle,
                    representedValue: ProjectAction.addExisting
                )
            )
        )
        items.append(
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.createNewFolderTitle,
                    representedValue: ProjectAction.createNew
                )
            )
        )
        return items
    }

    /// One runtime's logins, each carrying its mark and what is left of it. See
    /// `identityItems()` for why they are not filed under a heading.
    private func accountItems(for kind: AgentKind, accounts: [AgentAccount]) -> [ThemedMenuEntry] {
        accounts.map { account in
            let name = AccountName.display(for: account)
            var item = ThemedMenuItem(
                // The emoji when the account has one: it is how the same login is identified in
                // the sidebar, and a menu that names it differently makes the user learn it
                // twice.
                title: account.emoji.map { "\($0)  \(name)" } ?? name,
                representedValue: ComposerIdentity(agent: kind, account: account.handle),
                isSelected: kind == selectedAgent && account.handle == selectedAccountHandle
            )

            // Which login to start on is decided here, so this is where what is left of each
            // one belongs — not only in the toolbar, which speaks after the choice is made.
            // Read against the model this session will run, since the account's own windows are
            // not the whole story when the plan meters that model separately.
            AccountUsageMenu.decorate(
                &item,
                for: account,
                metering: modelToLaunch(on: account, for: kind),
                markedAs: kind
            )
            return .item(item)
        }
    }

    /// The model a session started now would run on `account`: an explicit choice, else what
    /// that account is configured to use. Resolved per account, because the configured default
    /// is the account's own setting rather than a global one.
    ///
    /// `kind` is the account's runtime rather than the selected one, because the identity menu
    /// meters logins the composer is *not* currently on. A model pinned here belongs to the
    /// selected runtime alone — reading another runtime's login against it would charge that
    /// login's window for a model it could not run.
    private func modelToLaunch(on account: AgentAccount, for kind: AgentKind) -> String? {
        let pinned = kind == selectedAgent ? selectedModel : nil
        return pinned ?? AgentModels.defaultModel(for: kind, account: account)
    }

    /// The model whose catalog governs controls that are set before a session exists.
    func modelIdentifierToLaunch(on account: AgentAccount?) -> String? {
        selectedModel ?? resolvedDefaultModel(for: account).identifier
    }

    /// A model change is also a schema change. Never carry a value into a model that did not
    /// publish it, even briefly while the footer is redrawn.
    private func discardUnsupportedEffort(account: AgentAccount? = nil) {
        guard let selectedReasoningEffort else { return }
        let resolvedAccount = account
            ?? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
        let option = ReasoningEffortPresentation.option(
            kind: selectedAgent,
            model: modelIdentifierToLaunch(on: resolvedAccount),
            account: resolvedAccount
        )
        if option?.supports(reasoningEffort: selectedReasoningEffort) != true {
            self.selectedReasoningEffort = nil
        }
    }

    /// Do not leave a hidden Fast choice waiting to return after the model changes back. An
    /// explicit Standard is retained so it can still override an account configured for Fast.
    private func discardUnsupportedFastMode(account: AgentAccount? = nil) {
        guard selectedFastMode == true else { return }
        let resolvedAccount = account
            ?? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
        if !AgentModels.supportsFastMode(
            kind: selectedAgent,
            model: modelIdentifierToLaunch(on: resolvedAccount),
            account: resolvedAccount
        ) {
            selectedFastMode = false
        }
    }

    /// What the chip says: the chosen model, else the one the account is configured to use,
    /// else "Default".
    ///
    /// Naming the resolved model is the point. "Default model" answers a question nobody asked
    /// — the user knows they have not chosen one — while the thing they actually want to know
    /// is what this session will run on, which the account's own settings already state.
    private func modelChipTitle(for account: AgentAccount?) -> String {
        if let selectedModel { return ModelName.display(for: selectedModel) }

        guard let resolved = resolvedDefaultModel(for: account).identifier else {
            return ComposerDefaults.defaultModelTitle
        }
        return ModelName.display(for: resolved)
    }

    /// Nothing is running here, so the runtime cannot report — but this login may have run
    /// before, and what it resolved to then is the only local answer for an account that
    /// configures no model. That is precisely the case the composer used to call "Default".
    private func resolvedDefaultModel(for account: AgentAccount?) -> ResolvedDefaultModel {
        AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: AgentModels.defaultModel(for: selectedAgent, account: account),
            rememberedModel: account.flatMap {
                AccountPreferencesStore.shared.lastReportedModel(for: $0.id)
                    ?? ClaudeAccountLastRunModel.lastRunModel(account: $0)
            }
        )
    }

    private func modelItems() -> [ThemedMenuEntry] {
        let account = AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
        let resolved = resolvedDefaultModel(for: account)
        let models = AgentModels.available(for: selectedAgent, account: account)

        // "Leave it to the CLI" is marked on the model it would pick rather than named again
        // above the list. It used to lead with a row of its own, which put the same model on
        // screen twice — and the two rows were not the same choice, since one followed the
        // account's setting and the other pinned today's value of it. Marked in place, the row
        // that says which model this starts on *is* the row that leaves the choice alone.
        let markedInList = resolved.identifier.map(models.contains) ?? false

        // A model named as the one this session starts on unless something else is chosen, with
        // where that came from — a setting on the account, or what it last ran.
        func markedTitle(_ model: String) -> String {
            "\(ModelName.display(for: model))\(ComposerDefaults.suffix(for: resolved.source))"
        }

        var items: [ThemedMenuEntry] = []

        // The account's own windows, once. They are identical under every model by
        // construction, so the rows carry only the windows scoped to them — and the header is
        // what lets a row with no line of its own read as "nothing beyond this" rather than as
        // a failed lookup.
        if let account, let header = AccountUsageMenu.modelMenuHeader(for: account) {
            items.append(.item(header))
            items.append(.separator)
        }

        // Kept for the two cases the list cannot mark: an account that names no model at all,
        // and one whose model this catalog does not carry.
        if !markedInList {
            var defaultItem = ThemedMenuItem(
                title: resolved.identifier.map(markedTitle) ?? ComposerDefaults.defaultModelTitle,
                representedValue: nil,
                isSelected: selectedModel == nil
            )
            // On an account that names no default there is no model to meter by, and the
            // account's own windows are the answer.
            if let account {
                AccountUsageMenu.decorate(&defaultItem, forModel: resolved.meteredIdentifier, on: account)
            }
            items.append(.item(defaultItem))
        }

        // Where a scoped limit is finally actionable: a spent Fable window is escaped by
        // picking another model, and this is the menu that does it. Each row states only the
        // windows scoped to it — the shared ones live in the header — and the marked row is a
        // row naming a model like any other and is metered as one.
        items += models.map { model in
            let isDefault = markedInList && model == resolved.identifier
            var item = ThemedMenuItem(
                title: isDefault ? markedTitle(model) : ModelName.display(for: model),
                representedValue: isDefault ? nil : model,
                isSelected: isDefault
                    ? (selectedModel == nil || selectedModel == model)
                    : model == selectedModel
            )
            if let account {
                AccountUsageMenu.decorate(&item, forModel: model, on: account)
            }
            return .item(item)
        }
        return items
    }

    private func effortItems() -> [ThemedMenuEntry] {
        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil
        return ReasoningEffortPresentation.rows(
            selected: selectedReasoningEffort,
            kind: selectedAgent,
            model: modelIdentifierToLaunch(on: account),
            account: account
        )
    }

    private func speedItems() -> [ThemedMenuEntry] {
        ConversationSpeedPresentation.rows(
            selected: selectedFastMode,
            kind: selectedAgent,
            timing: .whenTheSessionStarts
        )
    }

    // MARK: - Actions

    private func start(with prompt: String) {
        guard let projectID else { return }

        // Read before the start, because starting is what empties the strip. The paths are
        // already inside `prompt` — a CLI is handed a path, never pixels — but a path in a
        // sentence is not a handoff anything downstream can recognise, so the images the user
        // attached have to cross this boundary as themselves or they are filed nowhere.
        let attachmentPaths = promptView.attachmentPaths
        let started = delegate?.sessionComposer(
            self,
            startSessionIn: projectID,
            kind: selectedAgent,
            accountHandle: selectedAccountHandle,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode,
            branch: selectedBranch,
            usesNativeUI: usesNativeUI,
            permissionMode: selectedAgent.supportsPermissionModes ? selectedPermissionMode : nil,
            managedWorkspacePlan: selectedManagedWorkspacePlan,
            prompt: prompt,
            attachmentPaths: attachmentPaths
        ) ?? false

        // The composer is not rebuilt for the project it already holds, so what has just been
        // sent has to be taken out of it here — otherwise coming back to the project shows the
        // opening prompt, and the images sent with it, as though they were still waiting.
        // Only once a session actually exists: a start that failed leaves the words where the
        // user can still use them, which is also why `DraftStore` is cleared on the same answer.
        guard started else { return }
        promptView.clear()
    }

    /// How much the session may do before it has to ask.
    ///
    /// Inheriting is not a row of its own: the mode this session would inherit is marked where
    /// it already stands in the list, qualified by where that answer was read from — Settings,
    /// the agent's own configuration, or the run this login last made. Each mode carries what it
    /// means, and where the chosen agent expresses it imperfectly it says so: Codex has no plan
    /// mode, and a menu that offered "Plan" without that sentence would be promising something
    /// it cannot deliver.
    private func permissionModeItems() -> [ThemedMenuEntry] {
        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil
        return PermissionModePresentation.rows(
            for: selectedAgent,
            selected: selectedPermissionMode,
            inherited: inheritedPermissionMode(
                account: account,
                project: projectID.flatMap { ProjectStore.shared.project(withID: $0) }
            ),
            timing: .whenTheSessionStarts
        )
    }

    /// The choice of surface: the agent's own terminal, or Threading's conversation view.
    private func surfaceItems() -> [ThemedMenuEntry] {
        [false, true].map { isNative in
            .item(
                ThemedMenuItem(
                    title: isNative ? ComposerDefaults.nativeTitle : selectedAgent.originalUITitle,
                    representedValue: isNative,
                    isSelected: isNative == usesNativeUI
                )
            )
        }
    }

    /// Offers the conversations found on disk, adopting whichever are chosen.
    private func presentImportPicker() {
        guard let projectID, !importable.isEmpty else { return }

        let picker = SessionImportViewController(sessions: importable)
        picker.onPick = { [weak self, weak picker] chosen in
            guard let self, let picker else { return }
            self.dismiss(picker)

            guard !chosen.isEmpty else { return }

            // Dropped from the list as well as adopted: the project now tracks them, and
            // offering them again would only be refused as duplicates.
            let adopted = Set(chosen.map(\.id))
            self.importable.removeAll { adopted.contains($0.id) }
            self.refreshImportOffer()

            self.delegate?.sessionComposer(self, importSessions: chosen, into: projectID)
        }

        presentAsSheet(picker)
    }

    @objc private func importTapped() {
        presentImportPicker()
    }

    /// Sent through the box rather than read off it, so the button, ⌘Return and the box's own
    /// rules stay one path: the attachments go with the words, and a submission the box has
    /// disabled stays disabled however it was asked.
    @objc func startTapped() {
        promptView.submit()
    }

    private func createWorktree() {
        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            return
        }

        guard let branch = promptForBranchName() else { return }
        guard let destination = GitWorktree.suggestedLocation(forBranch: branch, in: project) else {
            present(error: GitWorktree.Failure.notARepository)
            return
        }

        do {
            let created = try GitWorktree.create(branch: branch, at: destination, from: project)
            delegate?.sessionComposer(self, didCreateWorktreeAt: created, branch: branch)
        } catch {
            present(error: error)
        }
    }

    // MARK: - Private Methods

    private func promptForBranchName() -> String? {
        let request = TextPromptRequest(
            title: L10n.string("New Worktree"),
            message: L10n.string(
                "A worktree lets a session run on its own branch without disturbing this checkout."
            ),
            confirmTitle: L10n.string("Create"),
            placeholder: L10n.string("branch name"),
            fieldSize: NSSize(
                width: ComposerDefaults.branchFieldWidth,
                height: ComposerDefaults.branchFieldHeight
            )
        )

        guard case .text(let branch)? = TextPromptAlert.ask(request) else { return nil }
        return branch
    }

    private func present(error: Error) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Could not create worktree")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }
}

// MARK: - SessionComposerViewControllerDelegate

@MainActor
protocol SessionComposerViewControllerDelegate: AnyObject {
    /// Answers whether a session was actually started. The composer empties itself on `true`
    /// and keeps everything it holds on `false`, so a start that could not be recorded does not
    /// take the prompt with it.
    ///
    /// `attachmentPaths` are the images the opening prompt carries. They travel beside the text
    /// rather than being read back out of it: the session they belong to does not exist yet, so
    /// filing them is the receiver's job, and a path parsed back out of a sentence is a guess
    /// where this is a fact.
    @discardableResult
    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        managedWorkspacePlan: ManagedWorkspacePlan?,
        prompt: String,
        attachmentPaths: [String]
    ) -> Bool

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    )

    /// Conversations the import sheet chose, newest first. Plural because the sheet is: a
    /// project rebuilding its history adopts a search's worth at a time, and one round trip
    /// each would be the whole cost of it.
    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSessions sessions: [ImportableSession],
        into projectID: ProjectID
    )

    /// The location chip chose an existing project. Routed through the delegate so selection,
    /// the header tab, and the sidebar all move on the one existing path.
    func sessionComposer(
        _ composer: SessionComposerViewController,
        didSelectProject projectID: ProjectID
    )

    /// The location chip asked for a folder that is not a project yet.
    func sessionComposerDidRequestAddFolder(_ composer: SessionComposerViewController)
    func sessionComposerDidRequestNewFolder(_ composer: SessionComposerViewController)
}

// MARK: - Project Actions

/// What the project list offers besides the projects themselves.
private enum ProjectAction {
    case addExisting
    case createNew
}

// MARK: - Composer Identity

/// Who a session runs as, as one value: the runtime and the login inside it.
///
/// One value rather than two menu cases, because the identity menu now offers every runtime's
/// logins in one flat list and a row there answers *both* halves at once. Carrying only the
/// handle would leave a Codex login setting a Claude session's account, which is how the
/// two-section menu could not go wrong and this one could.
///
/// `account` is nil for a runtime that offered no login to choose — the row is the runtime.
private struct ComposerIdentity: Equatable {
    let agent: AgentKind
    let account: AccountHandle?
}

// MARK: - Checkout Selection

/// What the location menu's first section offers: a place to run, or the action that makes one.
///
/// The worktree action lived in a chip of its own, which read as a *state* — one of the
/// choices in the row, seemingly selected — when it is a thing that happens. Folded in here,
/// one section answers one question: which checkout does this session run in. Kept apart from
/// the project rows in the same menu because choosing one of these routes the session while
/// leaving the composer alone, where choosing a project navigates away from it.
private enum CheckoutSelection {
    case thisCheckout
    case checkout(String)
    case newWorktree
}

// MARK: - Composer Defaults

/// Only what is specific to this screen. Everything visual comes from `Design`.
enum ComposerDefaults {
    static let managedWorkspaceSymbol = "arrow.triangle.branch"
    static let managedWorkspacePublicationSymbol = "arrow.up.right.square"

    static func managedWorkspaceDeliveryTitle(_ delivery: ManagedWorkspaceDelivery) -> String {
        switch delivery {
        case .mergeAndCleanUp: return L10n.string("Finish: Merge and clean up")
        case .keepForReview: return L10n.string("Finish: Keep workspace for review")
        }
    }

    static func managedWorkspacePublicationTitle(
        _ publication: ManagedWorkspacePublication,
        provider: SourceControlProvider = .github
    ) -> String {
        switch publication {
        case .draft:
            return L10n.format("Review: Draft %@", provider.changeRequestName)
        case .ready:
            return L10n.format("Review: Ready %@", provider.changeRequestName)
        }
    }

    /// The mark on the chip that starts this session later. A clock rather than a calendar: the
    /// offers behind it are times of day and window resets, not dates.
    static let scheduleSymbol = "clock"

    /// The hero's mark: larger than the sidebar's 24 because it stands alone over a greeting,
    /// smaller than an app icon because it is a flourish, not the content.
    static let heroMarkSide: CGFloat = 40

    /// The least air the hero needs beyond its own height before it is worth showing at all.
    static let heroMinimumClearance: CGFloat = 48

    /// The widest the location chip may grow before its title truncates.
    ///
    /// Sixty points above the 260 the project name alone had, because the chip now answers with
    /// a repository *and* a checkout and a branch name is not free. Still under half the
    /// column's `contentWidth`, which is the actual constraint: past that a long name starts
    /// eating the identity beside it, and a row where only one chip is readable is worse than a
    /// truncated breadcrumb with the whole answer on its tooltip.
    static let locationChipMaxWidth: CGFloat = 320

    /// Wider than `readableWidth`, which paces prose. This column holds a row of controls
    /// and a prompt box with a control row of its own, and squeezing those to a reading measure
    /// is what shrank the chips to unlabelled icons.
    static let contentWidth: CGFloat = 720

    /// How hard the column insists on filling the pane. Below every split item's holding
    /// priority, and that is the whole point: paired with the required `contentWidth` cap, an
    /// equality at `.defaultHigh` states "the *pane* is no wider than 784" as surely as it states
    /// how wide the column is, and Auto Layout is happy to satisfy it by refusing to widen the
    /// pane. In a 1200pt window that pinned the terminal at 784 and left the sidebar unable to be
    /// dragged narrower than 415 — the divider stopped dead well short of its floor, and carrying
    /// on shut the column instead. Under the split view's own priorities the same measurement can
    /// only ever answer "as wide as there is room for".
    static let columnMeasurePriority = NSLayoutConstraint.Priority(240)

    /// Below `columnMeasurePriority`, so the column goes on filling the pane rather than hugging
    /// its widest row — which is what a stack does the moment its own hugging outranks the
    /// measurement, and is the narrowing that measurement exists to prevent.
    static let columnHuggingPriority = NSLayoutConstraint.Priority(1)

    /// Below `columnMeasurePriority`: a narrow pane shortens the location breadcrumb before it
    /// abandons the column measurement or breaks the pane insets. The identity chip remains the
    /// non-compressible answer at the trailing edge.
    static let locationChipCompressionPriority = NSLayoutConstraint.Priority(239)

    /// Gives the footer's longest choice the same narrow-pane contract as the location
    /// breadcrumb: truncate its visible title before the prompt can acquire a minimum width.
    static let modelChipCompressionPriority = NSLayoutConstraint.Priority(239)

    /// The posture chips' last-resort ladder: above the usage reading's `defaultLow`, below
    /// required.
    ///
    /// Required was wrong in one direction and the model chip's priority in the other. A
    /// required chip is a hidden minimum width on the whole column, and with a fourth posture
    /// on the row that floor measured 569 points — so a 560pt pane produced a column wider than
    /// the pane it hangs in, and Auto Layout broke a required inset to draw it. Dropping these
    /// below the usage label instead made them the *first* thing to give, and a 720pt pane,
    /// which has room to spare the moment the reading shortens, began truncating "Agent's
    /// Setting" under its own arrow well.
    ///
    /// So a posture yields only after the model name and the usage reading have, and among
    /// themselves in a stated order: the surface first, the permission mode last, because it is
    /// the one posture that changes what a turn may do without asking.
    static let surfaceChipCompressionPriority = NSLayoutConstraint.Priority(260)
    static let speedChipCompressionPriority = NSLayoutConstraint.Priority(261)
    static let effortChipCompressionPriority = NSLayoutConstraint.Priority(262)
    static let modeChipCompressionPriority = NSLayoutConstraint.Priority(263)

    /// Below every control's own hugging, so a spacer is what stretches when a row has width to
    /// spare. Any real priority would leave the chips competing for the slack with it.
    static let spacerPriority = NSLayoutConstraint.Priority(1)

    /// The prompt opens several lines tall. The composer owns the whole pane and is replaced
    /// by the conversation the moment it is used, so there is nothing to be compact for — and
    /// the size of the box is what says how much of a description is wanted.
    static let promptHeight: CGFloat = 116

    static let branchFieldWidth: CGFloat = 260
    static let branchFieldHeight: CGFloat = 24

    /// Reached only by a login that has never run this agent anywhere — no configuration, no
    /// organisation default, and no transcript to read a previous run out of. Everything else
    /// names a model. See `ConversationControlDefaults.defaultModel` for why these words and not
    /// "Default model".
    static var defaultModelTitle: String { L10n.string("Agent's choice") }

    /// Marks the CLI's own choice in the model menu, so picking it explicitly and leaving it
    /// alone are visibly the same thing.
    static var accountDefaultSuffix: String { L10n.string("  (account default)") }

    /// A model nothing configured, named because this login ran on it before. Qualified apart
    /// from a configured one: it is where the account landed last time, not a setting to change.
    static var lastUsedSuffix: String { L10n.string("  (last used)") }

    /// Nothing runs while the composer is open, so a runtime report is impossible here and the
    /// two reachable sources are the account's configuration and what it last ran.
    static func suffix(for source: ResolvedDefaultModel.Source) -> String {
        switch source {
        case .accountConfiguration, .reportedByRuntime: return accountDefaultSuffix
        case .rememberedFromEarlierRun: return lastUsedSuffix
        }
    }
    static var newWorktreeTitle: String { L10n.string("New Worktree…") }

    /// Marks the project's own folder in the checkout section, so the default reads as a place
    /// rather than as one branch name among several. Parenthesised in the shape the model
    /// menu's "(account default)" already uses: it was joined with an em dash, which is not
    /// a mark this app's copy uses anywhere.
    static var thisCheckoutSuffix: String { L10n.string("  (this checkout)") }

    /// Opens the projects, one layer in. Titled as the act rather than as the thing, because
    /// the rows above it are places too and only the verb tells them apart.
    static var switchProjectTitle: String { L10n.string("Switch Project") }

    /// A session is the durable object; these names describe only the UI rendering it.
    static var nativeTitle: String { L10n.string("Native (Experimental)") }
    static let surfaceSymbol = "bubble.left.and.text.bubble.right"

    /// The permission-mode symbol, wording and rows live in `PermissionModePresentation`, which
    /// three surfaces share.
    static var promptPlaceholder: String {
        L10n.string("Describe a task or ask a question")
    }

    static let importSymbol = "tray.and.arrow.down"

    /// What the start button answers to and what it draws on its face — one value, so it cannot
    /// name a chord it does not answer. `PromptView` handles the same chord in `keyDown`, which
    /// is what makes it work in a box that has no button beside it at all.
    static let startShortcut = KeyboardShortcut(key: "\r", modifiers: .command)

    /// Why the send will not fire, on the start button's tooltip and on the box's. A short
    /// sentence rather than a dimmed control with nothing to say — the chip above is already the
    /// ask, and this is what connects the two. Both are told, because ⌘Return reaches the box
    /// without going near the button.
    static var chooseProjectFirstReason: String { L10n.string("Choose a project first") }

    /// How old the usage reading is, on the label's tooltip. The panel this replaced said it
    /// the same way, in words the usage surfaces already share.
    static func updatedTitle(_ age: String) -> String {
        L10n.format("Updated %@", age)
    }

    /// Counted, because the number is what tells the user whether it is worth opening.
    static func importTitle(count: Int) -> String {
        count == 1
            ? L10n.string("Import 1 conversation")
            : L10n.format("Import %lld conversations", Int64(count))
    }

    static let modelSymbol = "cpu"

    /// The folder the session runs in, which is what the location chip is *about* — a branch
    /// glyph would name the finer half of the answer.
    static let locationSymbol = "folder"

    /// A step *into* something: the same mark the app's copy uses for a path through menus
    /// ("Settings ▸ Themes"). A checkout is inside a project and reads that way.
    static let breadcrumbSeparator = "▸"

    /// Joins peers rather than nesting them, which is what an agent and its login are — and
    /// what "Opus · 1M" on the row below already looks like.
    static let identitySeparator = "·"

    /// `AnotherTerminal ▸ master`; the project alone outside a repository; the ask when there is
    /// no project yet, since that is the one question this chip has to make somebody answer.
    static func locationTitle(project: String?, branch: String?) -> String {
        guard let project else { return chooseProjectTitle }
        guard let branch, !branch.isEmpty else { return project }
        return "\(project) \(breadcrumbSeparator) \(branch)"
    }

    /// `Claude Code · work`, or the agent alone where there is only one login to run as.
    static func identityTitle(agent: String, account: String?) -> String {
        guard let account, !account.isEmpty else { return agent }
        return "\(agent) \(identitySeparator) \(account)"
    }

    /// The chip's ask when the composer has nowhere to start yet.
    static var chooseProjectTitle: String { L10n.string("Choose a project…") }
    static var addExistingFolderTitle: String { L10n.string("Add Existing Folder…") }
    static var createNewFolderTitle: String { L10n.string("Create New Folder…") }
}
