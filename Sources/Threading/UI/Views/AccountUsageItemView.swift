import AppKit
import ThreadingExtensionKit

/// Toolbar pill showing how much of the current account's rate limit is spent.
///
/// Sits at the window's trailing edge and follows the selected session's account. A small
/// ring gauges whichever window is closest to its limit; beside it every window is named
/// with its value — `5h 43% · 7d 73%` — because the two limits answer different questions
/// (can I keep going now, and will the week hold). Monochrome while usage is comfortable,
/// tinted only as a window approaches its limit — the toolbar is glanced at, not read, so
/// colour is reserved for the moment it means something. Hovering opens the detail popover;
/// clicking pins it, and Option-clicking opens the bounded all-account fleet.
///
/// Hidden outright for sessions with no metered account (shells, nothing selected): a pill
/// with nothing to say is noise in the one corner that is always visible.
final class AccountUsageItemView: BackdropThemedControl {

    // MARK: - Properties

    typealias UsagePopoverContentProvider = @MainActor (AgentAccount) -> NSViewController?

    private let ringView = UsageRingView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let appEvents = AppEventObservations()

    private var isPressed = false { didSet { updateBackground() } }
    private var pressModifiers: NSEvent.ModifierFlags = []

    private(set) var account: AgentAccount?

    /// The model the shown session runs, which decides whether a model-scoped window is one of
    /// *this* session's limits or another model's business.
    private(set) var model: String?

    /// Other logins to which the shown conversation can safely resume. Kept separate from the
    /// fleet's readings because migration eligibility belongs to the current session, not to an
    /// account's capacity.
    private(set) var handoffAccountIDs: Set<AccountID> = []

    var onHandoff: ((AgentAccount) -> Void)?

    /// Re-asks the service on a short cadence; the service's own spacing decides whether a
    /// tick actually fetches, so the timer stays cheap.
    private let refreshTimer = MainRunLoopTimer()

    private var popover: ThemedPopover?
    private var isPopoverPinned = false

    /// Decides when the popover opens and closes; what it shows stays the pill's business.
    /// The policy follows the content — `readingPopoverPolicy` while the popover is the
    /// native reading, `actionablePopoverPolicy` once an extension composes content in —
    /// and `makeAccountUsagePopover` is where that decision is made.
    private lazy var popoverScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(
            policy: AccountUsageItemDefaults.readingPopoverPolicy
        )
        scheduler.onPresent = { [weak self] in self?.showPopover() }
        scheduler.onDismiss = { [weak self] in
            guard self?.isPopoverPinned == false else { return }
            self?.closePopover()
        }
        return scheduler
    }()

    /// The policy currently applied to the hover popover — read by tests asserting that it
    /// follows the content.
    var popoverPolicyForTesting: HoverPopoverScheduler.Policy { popoverScheduler.policy }
    private let customizationLookup: ComponentCustomizationHost.Lookup
    private let usagePopoverContentProvider: UsagePopoverContentProvider

    /// Invoked for semantic actions inside extension-rendered popover content.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    // MARK: - Initialization

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        customizationLookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
        usagePopoverContentProvider = Self.nativeUsagePopoverContent(for:)
        super.init(frame: frameRect)
        setupViews()
        startObserving()
    }

    /// Injection point for focused presentation-shell tests.
    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup,
        usagePopoverContentProvider: @escaping UsagePopoverContentProvider =
            AccountUsageItemView.nativeUsagePopoverContent(for:)
    ) {
        self.customizationLookup = customizationLookup
        self.usagePopoverContentProvider = usagePopoverContentProvider
        super.init(frame: .zero)
        setupViews()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// The pill's surface as well as its text: `Design.Surface.controlResting` is the *chrome's*
    /// label colour at 8%, which over a backdrop of the opposite tone is invisible — which is
    /// exactly how this pill disappeared under a light theme on a dark terminal.
    override func applyInk(_ ink: Design.Ink) {
        updateBackground()
        ringView.trackColor = ink.quaternary
        // The summary is an attributed string built per window, so it carries its colours with
        // it — rebuilding is the only way to re-ink it.
        render()
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // The toolbar's silhouette, shared with the page tab and the action buttons beside it.
        // A pill here left one rounded rect, one pill and three circles in a single strip.
        layer?.cornerRadius = Design.Radius.control
        updateBackground()

        onHoverChange = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                popoverScheduler.pointerEntered()
            } else {
                popoverScheduler.pointerExited()
            }
        }
        toolTip = L10n.string("Hover for this account · Option-click for all accounts")
        setAccessibilityLabel(L10n.string("Account usage"))

        ringView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ringView, summaryLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AccountUsageItemDefaults.horizontalPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AccountUsageItemDefaults.horizontalPadding
            ),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: AccountUsageItemDefaults.height),
            ringView.widthAnchor.constraint(equalToConstant: AccountUsageItemDefaults.ringSize),
            ringView.heightAnchor.constraint(equalToConstant: AccountUsageItemDefaults.ringSize)
        ])
    }

    private func startObserving() {
        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.usageDidChange(event)
        }

        let timer = Timer.scheduledTimer(
            withTimeInterval: UsageDefaults.refreshTimerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let account = self.account, self.window != nil else { return }
                AccountUsageService.shared.refresh(account)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer.install(timer)
    }

    // MARK: - Public Methods

    /// Points the pill at an account and the model the session runs on it, or hides it when the
    /// current session has no metered account.
    ///
    /// The model is part of the configuration rather than looked up here: the pill follows a
    /// session, and which limit binds that session depends on what it runs, not only on who
    /// pays for it.
    func configure(
        account: AgentAccount?,
        model: String? = nil,
        handoffAccountIDs: Set<AccountID> = []
    ) {
        if self.account?.id != account?.id || self.handoffAccountIDs != handoffAccountIDs {
            popoverScheduler.cancelPendingWork()
            closePopover()
        }
        self.account = account
        self.model = model
        self.handoffAccountIDs = handoffAccountIDs

        if let account {
            AccountUsageService.shared.refresh(account)
        }

        render()
    }

    // MARK: - Private Methods

    private func usageDidChange(_ event: AccountUsageDidChange) {
        guard let account, event.accountID == account.id else { return }
        render()
    }

    private func render() {
        guard let account else {
            isHidden = true
            return
        }

        let reading = AccountUsageService.shared.reading(for: account)
        let usage = reading.usage

        // Nothing yet, and no failure to explain: stay hidden until the first result.
        guard reading.hasResult else {
            isHidden = true
            return
        }

        isHidden = false

        // The ring is the glance: one gauge, driven by whichever of *this session's* windows is
        // closest to its limit — including the one metering the model it runs, which is
        // routinely the binding limit and was the one number the pill used to leave out. The
        // text beside it names every window, which is where the insight lives: a spent 5-hour
        // window, a spent week and a spent model mean three different things.
        //
        // A user-authored limit joins that comparison, but only from a rule that asked to be
        // here: this is the surface that cannot be dismissed, and it must not acquire a new red
        // state because somebody made a rule to fire one quiet 50% alert.
        show(
            usage: usage,
            limits: CustomLimitBounds.toolbarRules(
                CustomLimitSettings.shared.rules(for: account.id)
            )
        )
    }

    /// The drawing half, over values a caller supplies.
    ///
    /// Split from `render` so a render fixture can put two pills side by side — one on a login
    /// with a rule that asked for the toolbar and one without — which is the only way to review
    /// the claim that the two print the same numbers and differ only in tint.
    func show(
        usage: AccountUsage?,
        limits rules: [CustomLimit],
        at now: Date = Date()
    ) {
        let metered = usage?.windows(metering: model) ?? []
        let binding = CustomLimitBounds.bindingWindow(among: metered, in: rules, at: now)
        let severity = CustomLimitBounds.severity(
            of: binding?.fraction,
            on: binding?.id ?? "",
            in: rules,
            window: binding,
            at: now
        )

        // The gauge still draws the provider's own figure. A ring filled to consumed-of-bound
        // would be reporting a level the account never reached, on the one control whose whole
        // job is to say how much is left; what the line moves is the colour.
        ringView.fraction = binding?.fraction
        ringView.tint = severity.glyphColor

        // `at: now` rather than the default: every other reading in this method is taken at the
        // moment the caller named, and a `readings` call that quietly used `Date()` instead
        // reported every window as expired whenever the two differed — which is always, in a
        // fixture.
        let readings = usage?.readings(at: now, metering: model) ?? []
        summaryLabel.attributedStringValue = Self.summary(
            readings: CustomLimitBounds.retinted(readings, of: metered, in: rules, at: now),
            ink: ink
        )
    }

    /// `5h 43% · 7d 73%`: each window as a quiet label and its value, the value tinted by
    /// that window's own severity. The vocabulary is Claude's own status line, so the short
    /// names read as familiar rather than cryptic.
    ///
    /// Composed by `UsageReadingLabel`, which is where the composer's line comes from too. The
    /// composer promises to show *the reading this pill will go on showing* once the session
    /// exists, and two implementations of one sentence is how a promise like that stops being
    /// true. What stays here is the empty case: a pill is a fixed slot in the chrome and says
    /// `—` when there is nothing to report, where a line on a control row leaves instead.
    private static func summary(readings: [AccountUsage.Reading], ink: Design.Ink) -> NSAttributedString {
        guard !readings.isEmpty else {
            return NSAttributedString(
                string: AccountUsageItemDefaults.unknownValue,
                attributes: [
                    .font: Design.Typography.control(),
                    .foregroundColor: ink.secondary
                ]
            )
        }
        return UsageReadingLabel.summary(readings: readings, ink: ink)
    }

    // MARK: - Interaction

    override func hoverDidChange() {
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, account != nil else { return }
        window?.makeFirstResponder(self)
        pressModifiers = event.modifierFlags
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fires = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        let modifiers = pressModifiers
        isPressed = false
        pressModifiers = []
        guard fires else { return }
        presentClick(modifiers: modifiers)
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, account != nil else { return false }
        presentClick(modifiers: [])
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard account != nil else { return nil }
        return [
            NSAccessibilityCustomAction(name: L10n.string("Show all account usage")) {
                [weak self] in
                self?.showFleetPopover()
                return self != nil
            }
        ]
    }

    enum ClickPresentation: Equatable {
        case currentAccount
        case allAccounts
    }

    static func clickPresentation(
        for modifiers: NSEvent.ModifierFlags
    ) -> ClickPresentation {
        modifiers.intersection(.deviceIndependentFlagsMask).contains(.option)
            ? .allAccounts
            : .currentAccount
    }

    private func presentClick(modifiers: NSEvent.ModifierFlags) {
        switch Self.clickPresentation(for: modifiers) {
        case .currentAccount:
            showCurrentPopover(pinned: true)
        case .allAccounts:
            showFleetPopover()
        }
    }

    /// Opens the detail popover on hover; `popoverScheduler` decides when this is called and
    /// when the popover closes again.
    private func showPopover() {
        showCurrentPopover(pinned: false)
    }

    private func showCurrentPopover(pinned: Bool) {
        guard let account else { return }
        if popover?.isShown == true {
            if pinned {
                isPopoverPinned = true
                popover?.behavior = .semitransient
                popoverScheduler.cancelPendingWork()
            }
            return
        }

        // Hovering is the moment the user cares; the service's floor keeps it polite.
        AccountUsageService.shared.refresh(account, force: true)

        guard let controller = makeAccountUsagePopover(for: account) else { return }

        let popover = HostPopoverFactory.make(.toolbarAccountUsage)
        popover.contentViewController = controller
        isPopoverPinned = pinned
        popover.behavior = pinned ? .semitransient : .transient
        popover.animates = false
        popover.onClose = { [weak self] in
            self?.isPopoverPinned = false
            self?.popover = nil
        }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }

    private func showFleetPopover() {
        guard let account else { return }
        popoverScheduler.cancelPendingWork()
        closePopover()

        let controller = AccountUsageFleetPopoverViewController(
            currentAccountID: account.id,
            handoffAccountIDs: handoffAccountIDs
        )
        controller.onHandoff = { [weak self] destination in
            self?.closePopover()
            self?.onHandoff?(destination)
        }

        let popover = HostPopoverFactory.make(.toolbarAllAccountUsage)
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.onClose = { [weak self] in
            self?.isPopoverPinned = false
            self?.popover = nil
        }
        isPopoverPinned = true
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }

    /// Builds the account presentation independently from the toolbar hover trigger. The outer
    /// tracking view remains host-owned, so replacing all visual content cannot take over the
    /// popover's own hover reporting — the policy decides whether that report holds it open.
    ///
    /// This is also where the policy is decided: the native reading closes with the pointer,
    /// but the moment an extension composes content in, the popover may carry actions the
    /// pointer must be able to reach, so it gains the grace and the hold. Re-decided on every
    /// build and on every live resolution change, so it always describes what is showing.
    func makeAccountUsagePopover(for account: AgentAccount) -> NSViewController? {
        let target = ExtensionComponentTarget.accountUsagePopover(
            accountID: account.id.rawValue
        )
        let native = usagePopoverContentProvider(account)
        let initialResolution = customizationLookup(target)
        guard native != nil || !initialResolution.isEmpty else { return nil }
        applyPopoverPolicy(for: initialResolution)

        let hoverContainer = HoverTrackingView()
        hoverContainer.onHoverChange = { [weak self] hovering in
            self?.popoverScheduler.popoverHoverChanged(hovering)
        }

        let hasNativeContent = native != nil
        let child = native ?? EmptyComponentContentViewController()
        let controller = ExtensionComponentHookViewController(
            target: target,
            child: child,
            contentInsets: NSEdgeInsets(
                top: Design.Spacing.inset,
                left: Design.Spacing.inset,
                bottom: Design.Spacing.inset,
                right: Design.Spacing.inset
            ),
            fixedWidth: UsagePopoverDefaults.width,
            containerView: hoverContainer,
            lookup: customizationLookup,
            onAction: { [weak self] action in
                guard let self else { return }
                if let onCustomizationAction {
                    onCustomizationAction(action)
                } else {
                    ComponentCustomizationProviderSlot.shared.perform(action)
                }
            },
            onResolution: { [weak self] resolution in
                guard let self else { return }
                applyPopoverPolicy(for: resolution)
                if !hasNativeContent, resolution.isEmpty {
                    popover?.close()
                    popover = nil
                }
            }
        )
        controller.view.setAccessibilityIdentifier("toolbar.account-usage-popover")
        return controller
    }

    private func applyPopoverPolicy(for resolution: ComponentCustomizationResolution) {
        popoverScheduler.policy = resolution.isEmpty
            ? AccountUsageItemDefaults.readingPopoverPolicy
            : AccountUsageItemDefaults.actionablePopoverPolicy
    }

    private static func nativeUsagePopoverContent(
        for account: AgentAccount
    ) -> NSViewController? {
        AccountUsagePopoverViewController(account: account, isEmbedded: true)
    }

    private func closePopover() {
        let open = popover
        popover = nil
        isPopoverPinned = false
        open?.close()
    }

    private func updateBackground() {
        layer?.cornerRadius = Design.Radius.control
        applyLayerBackground(isPressed || isHovered ? ink.surfaceHover : ink.surface)
    }
}
