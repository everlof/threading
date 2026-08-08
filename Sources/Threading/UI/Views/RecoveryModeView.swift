import AppKit

// MARK: - Recovery Mode Action

/// One way out of recovery: a title, an optional line saying what it costs, and what it does.
struct RecoveryModeAction {

    let identifier: String
    let title: String
    /// Shown beneath the title in the troubleshooting group. Absent for the two leading
    /// buttons, whose titles are the whole sentence.
    let detail: String?
    let emphasis: ThemedButton.Emphasis
    let handler: () -> Void

    init(
        identifier: String,
        title: String,
        detail: String? = nil,
        emphasis: ThemedButton.Emphasis = .secondary,
        handler: @escaping () -> Void
    ) {
        self.identifier = identifier
        self.title = title
        self.detail = detail
        self.emphasis = emphasis
        self.handler = handler
    }
}

// MARK: - Recovery Mode Actions

/// The primitives the surface presses, injected so the screen can be exercised without
/// relaunching the app, resetting anybody's data or writing a support report.
struct RecoveryModeActions {
    var tryNormalLaunchOnce: () -> Void
    var continueInRecoveryMode: () -> Void
    var toggleExtensionsForNextLaunch: () -> Void
    var resetWindowLayout: () -> Void
    var createSupportReport: () -> Void
    var moveAppDataAside: () -> Void
    var revealCrashReport: () -> Void
}

// MARK: - Recovery Mode Copy

/// Every sentence the surface says, apart from the layout that says it.
///
/// Split out so the wording is held by a test without a window, the way
/// `MainWindowController.uncleanExitMessage` already is.
enum RecoveryModeCopy {

    static func reason(_ reason: LaunchModeReason) -> String {
        switch reason {
        case .crashLoop:
            return L10n.string(
                "Threading has quit unexpectedly more than once, so it started in recovery mode."
            )
        case .recoveryLaunchFailed:
            return L10n.string(
                "The recovery launch did not come back either, so nothing automatic has been started."
            )
        case .optionKeyHeld:
            return L10n.string("You held Option at launch, so Threading started in recovery mode.")
        case .commandLineFlag:
            return L10n.string("Threading was started with the recovery flag.")
        case .normal, .forcedNormal:
            // Not reachable from a recovery launch, and a sentence rather than a crash: the
            // surface is also what a future entry point would land on, and a blank line is a
            // worse answer than the general one.
            return L10n.string("Threading started in recovery mode.")
        }
    }

    /// How far the launch that died got. The single most useful line on this screen.
    static func checkpoint(_ checkpoint: StartupCheckpoint?) -> String {
        guard let checkpoint else {
            return L10n.string("The last launch stopped before it recorded anything.")
        }
        return L10n.format("The last launch stopped after: %@", name(of: checkpoint))
    }

    /// A checkpoint in words. The raw case name is a fact about this code, not copy: a person
    /// reading this screen is being asked to act on it.
    static func name(of checkpoint: StartupCheckpoint) -> String {
        switch checkpoint {
        case .migrationDone: return L10n.string("Reading the old data folder")
        case .persistenceOpened: return L10n.string("Opening your projects")
        case .themeRestored: return L10n.string("Applying the theme")
        case .mainWindowConstructed: return L10n.string("Building the window")
        case .firstWindowVisible: return L10n.string("Showing the window")
        case .recoverySurfaceShown: return L10n.string("Showing recovery mode")
        case .extensionsStarted: return L10n.string("Starting extensions")
        case .mcpListenerStarted: return L10n.string("Starting the tool listener")
        case .selectedSessionRestored: return L10n.string("Restoring your session")
        case .stable: return L10n.string("Running normally")
        }
    }

    /// Armed reads as a state rather than as a command, so the flag can never be a thing the
    /// user set and cannot see. Pressing again disarms it.
    static func extensionsTitle(armed: Bool) -> String {
        armed
            ? L10n.string("Extensions Will Stay Off Next Launch")
            : L10n.string("Disable Extensions for Next Launch")
    }
}

// MARK: - Recovery Mode View

/// What the pane shows when the app came up in recovery: why it did, how far the launch that
/// died got, and the ordered set of things to try.
///
/// **Pane content, never a window.** `applicationShouldTerminateAfterLastWindowClosed` answers
/// true, so a screen of its own would recreate the trap onboarding's completion order exists to
/// avoid — and the main window is always built here, only its `showWindow` is gated. Living
/// inside it also means the sidebar stays beside this, which is the point: the first thing
/// somebody in a crash loop wants is evidence that their projects are still there.
///
/// **Composed from `UI/Design`, not added to it.** A component under `UI/Design` owes an
/// interactive Component Gallery story (`ThemedControlTests` scans that directory for class
/// declarations), and rightly: that directory is the vocabulary a second pane repeats. This is
/// one screen, in one place, under one condition — `SessionPlaceholderView`'s position exactly.
///
/// It draws no ground of its own: the pane behind it is filled with chrome by
/// `applyPaneBackground(.chrome)` before this is shown, so a fill here would be a second opinion
/// about the same surface.
final class RecoveryModeView: NSView {

    // MARK: - Properties

    private let glyph = GlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let reasonLabel: NSTextField
    private let checkpointLabel: NSTextField
    private let groupCaption = NSTextField(labelWithString: "")
    private let separator = SeparatorView()
    private let appEvents = AppEventObservations()

    /// Kept beside the buttons rather than captured in them: a `ThemedButton` is an `NSControl`,
    /// so its press arrives as target/action and the sender's tag names which answer was pressed.
    private var handlers: [() -> Void] = []
    private var buttons: [ThemedButton] = []
    private var detailLabels: [NSTextField] = []

    /// Whether the surface has already told VoiceOver it arrived.
    private var hasAnnounced = false

    // MARK: - Initialization

    init(
        reason: String,
        checkpoint: String,
        leading: [RecoveryModeAction],
        troubleshooting: [RecoveryModeAction]
    ) {
        reasonLabel = NSTextField(wrappingLabelWithString: reason)
        checkpointLabel = NSTextField(wrappingLabelWithString: checkpoint)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setupViews(leading: leading, troubleshooting: troubleshooting)
        applyInk()

        // The ink is set on labels here rather than read at draw, so a live theme switch has to
        // reach it — `PaneNoticeView`'s rule, and this surface outlives a switch just as it does.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyInk() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyInk()
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(RecoveryModeDefaults.accessibilityLabel)
        setAccessibilityIdentifier(RecoveryModeDefaults.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Every button, leading to trailing then top to bottom. Readable so a test presses the
    /// control the user would press rather than the closure behind it.
    var actionControls: [ThemedButton] { buttons }

    func control(identifier: String) -> ThemedButton? {
        buttons.first { $0.identifier?.rawValue == identifier }
    }

    /// What the surface currently says, for a test and for the announcement it makes on arrival.
    var spokenSummary: String {
        [titleLabel.stringValue, reasonLabel.stringValue, checkpointLabel.stringValue]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        announce()
    }

    // MARK: - Private Methods

    private func setupViews(
        leading: [RecoveryModeAction],
        troubleshooting: [RecoveryModeAction]
    ) {
        // Configured at the slot's own size rather than through `pointSize(forSlot:)`, which
        // answers with the toolbar's 13 for anything at or above the tab slot: right for a glyph
        // beside a label, and a 13pt mark inside a 44pt box everywhere else.
        glyph.image = Design.Symbol.image(
            RecoveryModeDefaults.symbol,
            slot: RecoveryModeDefaults.glyphSlot,
            pointSize: RecoveryModeDefaults.glyphSlot
        )
        glyph.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = L10n.string("Recovery Mode")
        titleLabel.applyFont(.heading)
        reasonLabel.applyFont(.body)
        checkpointLabel.applyFont(.subheading)
        groupCaption.stringValue = L10n.string("If it keeps happening").localizedUppercase
        groupCaption.applyFont(.caption)

        for label in [titleLabel, reasonLabel, checkpointLabel, groupCaption] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // A pane's content may not decide how tall the window is, so a wrapping label yields
            // below the 500 at which AppKit reads a constraint as the window's minimum size.
            // See `window-chrome.md`, "a pane cannot be taller than its window".
            label.setContentCompressionResistancePriority(
                RecoveryModeDefaults.labelHeightPriority,
                for: .vertical
            )
        }

        let heading = NSStackView(views: [titleLabel, reasonLabel, checkpointLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.small
        heading.setCustomSpacing(Design.Spacing.tight, after: reasonLabel)

        let leadingRow = NSStackView(views: leading.map(button))
        leadingRow.orientation = .horizontal
        leadingRow.alignment = .centerY
        leadingRow.spacing = Design.Spacing.small

        var column: [NSView] = [heading, leadingRow, separator, groupCaption]
        column.append(contentsOf: troubleshooting.map(troubleshootingRow))

        let stack = NSStackView(views: column)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: heading)
        stack.setCustomSpacing(Design.Spacing.large, after: leadingRow)
        stack.setCustomSpacing(Design.Spacing.medium, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(stack)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            glyph.bottomAnchor.constraint(
                equalTo: stack.topAnchor,
                constant: -Design.Spacing.medium
            ),
            glyph.widthAnchor.constraint(equalToConstant: RecoveryModeDefaults.glyphSlot),
            glyph.heightAnchor.constraint(equalToConstant: RecoveryModeDefaults.glyphSlot),
            glyph.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.large
            ),

            // A readable measure, centred, rather than a column as wide as the pane: this is
            // prose with controls under it, and the settings pages already state what that
            // measure is.
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(
                lessThanOrEqualToConstant: RecoveryModeDefaults.columnWidth
            ),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.large
            ),

            separator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        // The column takes the readable measure when the pane can give it, and gives way when
        // it cannot. Below the 500 for the same reason the labels are.
        let preferredWidth = stack.widthAnchor.constraint(
            equalToConstant: RecoveryModeDefaults.columnWidth
        )
        preferredWidth.priority = RecoveryModeDefaults.labelHeightPriority
        preferredWidth.isActive = true
    }

    private func button(_ action: RecoveryModeAction) -> ThemedButton {
        let button = ThemedButton(
            title: action.title,
            target: self,
            action: #selector(actionPressed)
        )
        button.emphasis = action.emphasis
        button.tag = handlers.count
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(action.identifier)
        button.setAccessibilityIdentifier(action.identifier)
        handlers.append(action.handler)
        buttons.append(button)
        return button
    }

    /// A title and a line saying what it costs, with the control that does it on the trailing
    /// edge — the settings pages' row, stated here because this screen is not one of them and
    /// must not reach into `UI/Preferences` for a layout.
    private func troubleshootingRow(_ action: RecoveryModeAction) -> NSView {
        let detail = NSTextField(wrappingLabelWithString: action.detail ?? "")
        detail.applyFont(.subheading)
        detail.setContentCompressionResistancePriority(
            RecoveryModeDefaults.labelHeightPriority,
            for: .vertical
        )
        detail.isHidden = action.detail == nil
        detailLabels.append(detail)

        // The sentence yields and the control does not: a row too narrow for both wraps the
        // explanation rather than squeezing the button it explains.
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let control = button(action)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [detail, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func actionPressed(_ sender: NSControl) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }

    private func applyInk() {
        glyph.tint = Design.Status.warning
        titleLabel.textColor = Design.Text.label
        reasonLabel.textColor = Design.Text.label
        checkpointLabel.textColor = Design.Text.secondary
        groupCaption.textColor = Design.Text.tertiary
        for label in detailLabels { label.textColor = Design.Text.secondary }
        needsDisplay = true
    }

    /// The surface arrives without being asked for and takes no focus, so without this it is
    /// invisible to the part of the audience that cannot glance at it — `PaneNoticeView`'s reason.
    private func announce() {
        guard !hasAnnounced, let window else { return }
        hasAnnounced = true
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: spokenSummary,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

// MARK: - Recovery Mode Defaults

enum RecoveryModeDefaults {

    /// The same mark the unclean-exit band carries, for the same reason: this screen and that
    /// band are the two faces of one fact.
    static let symbol = DesignSymbols.reportRefused

    /// The pane placeholder's mark, at the pane placeholder's size: this surface stands where
    /// `SessionPlaceholderView` otherwise would, and a second answer to "how big is the mark on
    /// an empty pane" would read as a different kind of screen.
    static let glyphSlot: CGFloat = PlaceholderDefaults.iconSize

    /// The settings pages' readable measure. Prose with controls under it wants the same column
    /// they do, and restating the number here would be a second opinion about one decision.
    static var columnWidth: CGFloat { Design.Size.readableWidth }

    /// Below the 500 at which AppKit reads a constraint as the window's minimum content size —
    /// the rule `window-chrome.md` records after a preview grew the window off the screen.
    static let labelHeightPriority = NSLayoutConstraint.Priority(499)

    static let identifier = "recovery.surface"
    static let accessibilityLabel = "Recovery Mode"

    static let tryNormalAction = "recovery.action.try-normal"
    static let continueAction = "recovery.action.continue"
    static let extensionsAction = "recovery.action.extensions"
    static let windowLayoutAction = "recovery.action.window-layout"
    static let supportReportAction = "recovery.action.support-report"
    static let moveDataAsideAction = "recovery.action.move-data-aside"
    static let crashReportAction = "recovery.action.crash-report"

    /// The band that stays across the pane while recovery is on, so the surface can always be
    /// got back to. `PaneNoticeView` with no dismissal: this is a standing condition, and the
    /// only thing that ends it is a relaunch.
    static var bandMessage: String { L10n.string("Threading is in recovery mode.") }
    static var bandAction: String { L10n.string("Show Options") }
}

// MARK: - Recovery Mode Surface

/// Builds the surface's two action groups from the primitives that perform them.
///
/// A function rather than construction inside the view, so a test asserts that each offer
/// presses exactly the thing it names without a window, a store or a relaunch.
enum RecoveryModeSurface {

    static func make(
        reason: LaunchModeReason,
        checkpoint: StartupCheckpoint?,
        hasCrashReport: Bool,
        extensionsDisabledNextLaunch: Bool,
        actions: RecoveryModeActions
    ) -> RecoveryModeView {
        var leading: [RecoveryModeAction] = [
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.tryNormalAction,
                title: L10n.string("Try Normal Launch Once"),
                // Demoted when the recovery launch is itself what failed: pressing it again is
                // the least likely of the offers to help, and the group below is where the
                // answer now is.
                emphasis: reason == .recoveryLaunchFailed ? .secondary : .primary,
                handler: actions.tryNormalLaunchOnce
            ),
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.continueAction,
                title: L10n.string("Continue in Recovery Mode"),
                handler: actions.continueInRecoveryMode
            )
        ]
        if hasCrashReport {
            leading.append(RecoveryModeAction(
                identifier: RecoveryModeDefaults.crashReportAction,
                title: L10n.string("Reveal Crash Report"),
                emphasis: .tertiary,
                handler: actions.revealCrashReport
            ))
        }

        let troubleshooting = [
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.extensionsAction,
                title: RecoveryModeCopy.extensionsTitle(armed: extensionsDisabledNextLaunch),
                detail: L10n.string(
                    "Extensions and their companions stay off for the next launch only."
                ),
                handler: actions.toggleExtensionsForNextLaunch
            ),
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.windowLayoutAction,
                title: L10n.string("Reset Window Layout"),
                detail: L10n.string(
                    "Forgets the window size, the sidebar width and the panel widths."
                ),
                handler: actions.resetWindowLayout
            ),
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.supportReportAction,
                title: L10n.string("Create Support Report…"),
                detail: L10n.string("Writes a share-safe diagnostics file and reveals it."),
                handler: actions.createSupportReport
            ),
            RecoveryModeAction(
                identifier: RecoveryModeDefaults.moveDataAsideAction,
                title: L10n.string("Move App Data Aside…"),
                detail: L10n.string(
                    "Moves your projects, sessions and settings into a dated folder you can put back."
                ),
                handler: actions.moveAppDataAside
            )
        ]

        return RecoveryModeView(
            reason: RecoveryModeCopy.reason(reason),
            checkpoint: RecoveryModeCopy.checkpoint(checkpoint),
            leading: leading,
            troubleshooting: troubleshooting
        )
    }
}
