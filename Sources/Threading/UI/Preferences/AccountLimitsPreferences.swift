import AppKit

// MARK: - Account Limits Section

/// The "Your Own Limits" half of the Accounts page: the switch that lets a limit speak, and one
/// fold per login holding the lines drawn on it.
///
/// Kept as its own renderer rather than folded into `AccountsPreferencesViewController` because
/// it owns state the rest of that page does not — which folds are open, and a menu hanging off one
/// of its buttons. It publishes cheap row identities; the Accounts table owns their views.
///
/// **Quiet until relevant.** The shipped default is no rules at all, so an untouched install sees
/// one switch and a list of logins reading "No limits" — not a form. Everything else appears
/// because somebody drew a line.
@MainActor
final class AccountLimitsSectionController {

    enum PresentationRow {
        case alertsSection
        case scopeHeader(Int)
        case rule(scopeIndex: Int, ruleIndex: Int)
        case empty(Int)
        case add(Int)
        case note
    }

    // MARK: - Properties

    /// Called after any edit, so the page that owns this can refresh anything of its own that
    /// reads the same accounts.
    var onChange: (() -> Void)?

    /// Called whenever expansion or an edit changes the cheap row model.
    var onPresentationChange: (() -> Void)?

    private var accounts: [AgentAccount] = []

    /// Which logins are unfolded. Held across rebuilds — see the type's note.
    private var expanded: Set<String> = []

    /// The open templates menu, retained for as long as it is on screen.
    private var menuSession: AnyObject?

    /// The two stores this section edits.
    ///
    /// Injectable so a test can drive the page over its own suite. The app passes neither and
    /// gets the shared ones; a test that used those would be writing rules into whatever the
    /// next test in the process reads, which is the contamination `PreferenceStore` exists to
    /// make hard rather than one to reintroduce a page at a time.
    private let settings: CustomLimitSettings
    private let accountStore: AccountPreferencesStore

    // MARK: - Initialization

    init(
        settings: CustomLimitSettings? = nil,
        accountStore: AccountPreferencesStore? = nil
    ) {
        self.settings = settings ?? .shared
        self.accountStore = accountStore ?? .shared
    }

    // MARK: - Public Methods

    /// Replaces the cheap account model. The page decides when to reload its visible cells.
    func reload(accounts: [AgentAccount]) {
        self.accounts = accounts
        let liveKeys = Set([AccountLimitsLayout.allAccountsKey] + accounts.map(\.id.rawValue))
        expanded.formIntersection(liveKeys)
    }

    /// Opens every fold, so a render can review the rows that only exist when one is open.
    ///
    /// The folds are what keep this page quiet on an untouched install, which also means the rule
    /// rows — the part with the most to get wrong — are the part a closed-by-default render never
    /// draws.
    func expandEverythingForTesting() {
        expanded = Set([AccountLimitsLayout.allAccountsKey] + accounts.map(\.id.rawValue))
        onPresentationChange?()
    }

    /// The semantic menu tree without presenting it, so a behavior test can hold the custom
    /// routes to the same window-scoped list the Add button ships.
    func templateEntriesForTesting(account: AgentAccount?) -> [ThemedMenuEntry] {
        templates(for: account.map(Scope.account) ?? .allAccounts)
    }

#if DEBUG
    /// A finite retained fixture for direct component tests. The shipping Accounts page never
    /// calls this; it consumes `presentationRows` through its single virtual table.
    func materializedSectionForTesting() -> NSView {
        let rows = presentationRows
        var sections: [NSView] = []
        if let alerts = rows.first {
            sections.append(content(for: alerts))
        }
        for scopeIndex in 0..<scopeCount {
            let cardRows = rows.filter { cardScopeIndex(for: $0) == scopeIndex }
            sections.append(SettingsCard(rows: cardRows.map { content(for: $0) }))
        }
        if let note = rows.last {
            sections.append(content(for: note))
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = Design.Spacing.large
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
#endif

    // MARK: - Virtual Row Model

    /// Closed scopes contribute only their header. Expanded scopes contribute value identities
    /// for their bounded rule list and Add row; no hidden AppKit subtree is constructed.
    var presentationRows: [PresentationRow] {
        var result: [PresentationRow] = [.alertsSection]
        for scopeIndex in 0..<scopeCount {
            result.append(.scopeHeader(scopeIndex))
            guard let scope = scope(at: scopeIndex), expanded.contains(scope.key) else { continue }
            let rules = self.rules(in: scope)
            if rules.isEmpty {
                result.append(.empty(scopeIndex))
            } else {
                result.append(contentsOf: rules.indices.map {
                    .rule(scopeIndex: scopeIndex, ruleIndex: $0)
                })
            }
            result.append(.add(scopeIndex))
        }
        result.append(.note)
        return result
    }

    /// Identifies the rows whose shared card surface is painted by the owning virtual table.
    func cardScopeIndex(for row: PresentationRow) -> Int? {
        switch row {
        case .scopeHeader(let index), .empty(let index), .add(let index):
            return index
        case .rule(let index, _):
            return index
        case .alertsSection, .note:
            return nil
        }
    }

    func content(for row: PresentationRow) -> NSView {
        switch row {
        case .alertsSection:
            return alertsSection()
        case .scopeHeader(let scopeIndex):
            return scopeHeader(at: scopeIndex)
        case .rule(let scopeIndex, let ruleIndex):
            guard let scope = scope(at: scopeIndex),
                  rules(in: scope).indices.contains(ruleIndex) else { return NSView() }
            return self.row(
                for: rules(in: scope)[ruleIndex],
                scope: scope,
                isInherited: isInheriting(scope),
                tag: scopeIndex * AccountLimitsLayout.tagStride + ruleIndex
            )
        case .empty(let scopeIndex):
            guard let scope = scope(at: scopeIndex) else { return NSView() }
            return SettingsUI.row(
                title: AccountLimitsStrings.noRulesTitle,
                subtitle: emptySubtitle(for: scope, isInherited: isInheriting(scope))
            )
        case .add(let scopeIndex):
            guard let scope = scope(at: scopeIndex) else { return NSView() }
            let add = SettingsUI.button(
                AccountLimitsStrings.addButton,
                target: self,
                action: #selector(addClicked(_:))
            )
            add.tag = scopeIndex
            add.isEnabled = rules(in: scope).count < CustomLimitDefaults.maximumRulesPerAccount
            return SettingsUI.row(
                title: scope.account == nil
                    ? AccountLimitsStrings.addRowTitleForAll
                    : AccountLimitsStrings.addRowTitle,
                subtitle: AccountLimitsStrings.addRowSubtitle,
                control: add,
                localizes: false
            )
        case .note:
            return SettingsUI.note(AccountLimitsStrings.explanation)
        }
    }

    private var scopeCount: Int { accounts.count + 1 }

    private func alertsSection() -> NSView {
        let alerts = SettingsUI.toggle(
            isOn: settings.alertsEnabled,
            target: self,
            action: #selector(alertsChanged(_:))
        )
        alerts.setAccessibilityLabel(AccountLimitsStrings.alertsToggleLabel)

        let switchCard = SettingsCard(rows: [
            SettingsUI.row(
                title: AccountLimitsStrings.alertsTitle,
                subtitle: AccountLimitsStrings.alertsSubtitle,
                control: alerts
            )
        ])

        return SettingsUI.section(AccountLimitsStrings.sectionTitle, switchCard)
    }

    /// One scope's cheap header. Detail rows enter `presentationRows` only while it is open.
    private func scopeHeader(at index: Int) -> NSView {
        guard let scope = scope(at: index) else { return NSView() }
        let rules = self.rules(in: scope)
        let isExpanded = expanded.contains(scope.key)
        return SettingsUI.disclosureHeader(
            title: scope.title,
            subtitle: scope.subtitle,
            summary: AccountLimitsStrings.summary(count: rules.count),
            control: nil,
            isExpanded: isExpanded,
            localizes: false,
            onToggle: { [weak self] open in
                guard let self else { return }
                if open {
                    self.expanded.insert(scope.key)
                } else {
                    self.expanded.remove(scope.key)
                }
                self.onPresentationChange?()
            }
        )
    }

    /// One rule: what it is called, where it stands, and the button that removes it.
    ///
    /// An **inherited** rule is drawn exactly like an owned one, with a working Remove — removing
    /// it materializes the inherited list onto the account minus that rule. A row that looked
    /// operable and was not would be the quietest kind of broken.
    private func row(
        for rule: CustomLimit,
        scope: Scope,
        isInherited: Bool,
        tag: Int
    ) -> NSView {
        let usage = scope.account.flatMap { AccountUsageService.shared.usage(for: $0) }
        let window = usage?.allWindows.first { $0.id == rule.windowID }
        let windowName = window?.label ?? UsageDefaults.label(forWindowID: rule.windowID)

        let evaluation = CustomLimitEvaluator.evaluate(CustomLimitEvaluator.Input(
            rules: [rule],
            usage: usage,
            fired: [:]
        )).first

        let remove = SettingsUI.button(
            AccountLimitsStrings.removeButton,
            target: self,
            action: #selector(removeClicked(_:))
        )
        remove.tag = tag

        // The pill is the one surface that cannot be dismissed, so a rule reaches it only by
        // asking. Off by default, which is why the switch sits beside the rule rather than in the
        // section's own header: it is a property of this line, not a mode of the page.
        let pill = SettingsUI.toggle(
            isOn: rule.showsInToolbar,
            target: self,
            action: #selector(toolbarChanged(_:))
        )
        pill.tag = tag
        pill.toolTip = AccountLimitsStrings.toolbarTooltip
        pill.setAccessibilityLabel(AccountLimitsStrings.toolbarLabel)

        var subtitle = evaluation.map {
            CustomLimitReceipt.status(for: $0, windowName: windowName)
        }
        if isInherited {
            subtitle = [subtitle, AccountLimitsStrings.inheritedMarker]
                .compactMap { $0 }
                .joined(separator: UsageDefaults.segmentSeparator)
        }

        return SettingsUI.row(
            title: CustomLimitReceipt.name(for: rule, windowName: windowName),
            subtitle: subtitle,
            // The switch is named on its face, not only in its tooltip. An unlabelled toggle
            // beside a Remove button is a guess, and the guess a reader makes about a control
            // next to Remove is not a good one.
            control: SettingsUI.controlGroup(
                [SettingsUI.caption(AccountLimitsStrings.toolbarCaption), pill, remove],
                spacing: Design.Spacing.small
            ),
            localizes: false
        )
    }

    // MARK: - Scope

    /// Which of the two scopes a fold edits. A limit is an account fact, so there is no third.
    private enum Scope {
        case allAccounts
        case account(AgentAccount)

        var account: AgentAccount? {
            if case .account(let account) = self { return account }
            return nil
        }

        /// Stable across rebuilds, so a fold left open stays open.
        var key: String { account?.id.rawValue ?? AccountLimitsLayout.allAccountsKey }

        var title: String { account?.displayName ?? AccountLimitsStrings.allAccountsTitle }

        var subtitle: String? {
            account?.provider.displayName ?? AccountLimitsStrings.allAccountsSubtitle
        }
    }

    /// Scope zero is app-wide; the remaining stable indexes map directly to discovered accounts.
    private func scope(at index: Int) -> Scope? {
        guard index >= 0 else { return nil }
        if index == 0 { return .allAccounts }
        guard accounts.indices.contains(index - 1) else { return nil }
        return .account(accounts[index - 1])
    }

    private func ruleEntry(for tag: Int) -> (scope: Scope, ruleID: UUID)? {
        let scopeIndex = tag / AccountLimitsLayout.tagStride
        let ruleIndex = tag % AccountLimitsLayout.tagStride
        guard let scope = scope(at: scopeIndex) else { return nil }
        let rules = rules(in: scope)
        guard rules.indices.contains(ruleIndex) else { return nil }
        return (scope, rules[ruleIndex].id)
    }

    private func rules(in scope: Scope) -> [CustomLimit] {
        guard let account = scope.account else { return settings.defaultLimits }
        return settings.rules(for: account.id, store: accountStore)
    }

    private func isInheriting(_ scope: Scope) -> Bool {
        guard let account = scope.account else { return false }
        return settings.inheritsDefaults(for: account.id, store: accountStore)
    }

    private func emptySubtitle(for scope: Scope, isInherited: Bool) -> String {
        guard scope.account != nil else { return AccountLimitsStrings.noDefaultsSubtitle }
        return isInherited
            ? AccountLimitsStrings.inheritedSubtitle
            : AccountLimitsStrings.clearedSubtitle
    }

    // MARK: - Templates

    /// The lines a person actually asks for, in their own words, one window at a time.
    ///
    /// Windows come from what the account's reading *reports*, so the menu never offers a limit on
    /// a window this login does not have. With no reading yet — and for the app-wide fold, which
    /// belongs to no one login — the two window lengths both providers normalize to are offered,
    /// and the rule that results says "No Weekly reading yet" until a reading arrives, which is
    /// the honest state and visibly so.
    private func templates(for scope: Scope) -> [ThemedMenuEntry] {
        windows(for: scope).map { window in
            var entries: [ThemedMenuEntry] = CustomLimitDefaults.offeredAlertFractions.map {
                fraction in
                .item(ThemedMenuItem(
                    title: AccountLimitsStrings.atPercent(CustomLimitReceipt.percent(fraction)),
                    onChoose: { [weak self] in
                        self?.add(.alert(windowID: window.id, at: fraction), to: scope)
                    }
                ))
            }
            entries.append(.item(ThemedMenuItem(
                title: AccountLimitsStrings.everyStep(
                    CustomLimitReceipt.percent(CustomLimitDefaults.tenPercentStep)
                ),
                onChoose: { [weak self] in
                    self?.add(
                        .everyStep(
                            windowID: window.id,
                            step: CustomLimitDefaults.tenPercentStep
                        ),
                        to: scope
                    )
                }
            )))
            entries.append(customValuesEntry(window: window, scope: scope))

            // The two templates that *act*, kept under their own headers so the list never reads
            // as one ladder of percentages with different consequences hidden in it.
            entries.append(.header(AccountLimitsStrings.holdHeader))
            entries += CustomLimitDefaults.offeredCapFractions.map { fraction in
                .item(ThemedMenuItem(
                    title: AccountLimitsStrings.keepUnder(CustomLimitReceipt.percent(fraction)),
                    onChoose: { [weak self] in
                        self?.add(.cap(windowID: window.id, at: fraction), to: scope)
                    }
                ))
            }
            entries.append(.header(AccountLimitsStrings.recreateHeader))
            entries += CustomLimitDefaults.offeredSyntheticWindows.map { offer in
                .item(ThemedMenuItem(
                    title: AccountLimitsStrings.recreateWindow(
                        span: UsageFormat.duration(offer.span),
                        budget: CustomLimitReceipt.percent(offer.budget)
                    ),
                    onChoose: { [weak self] in
                        self?.add(
                            .syntheticWindow(
                                windowID: window.id,
                                budget: offer.budget,
                                span: offer.span
                            ),
                            to: scope
                        )
                    }
                ))
            }
            entries.append(.header(AccountLimitsStrings.shareHeader))
            entries += CustomLimitDefaults.offeredPaceShares.map { share in
                .item(ThemedMenuItem(
                    title: AccountLimitsStrings.reserveShare(CustomLimitReceipt.percent(1 - share)),
                    onChoose: { [weak self] in
                        self?.add(.paceShare(windowID: window.id, share: share), to: scope)
                    }
                ))
            }

            return .item(ThemedMenuItem(title: window.name, submenu: entries))
        }
    }

    private func customValuesEntry(
        window: (id: String, name: String),
        scope: Scope
    ) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: AccountLimitsStrings.customValuesMenu,
            help: AccountLimitsStrings.customValuesHelp,
            submenu: AccountLimitCustomTemplate.allCases.map {
                customEntry($0, window: window, scope: scope)
            }
        ))
    }

    private func customEntry(
        _ template: AccountLimitCustomTemplate,
        window: (id: String, name: String),
        scope: Scope
    ) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: template.menuTitle,
            help: template.menuHelp,
            onChoose: { [weak self] in
                self?.addCustom(template, window: window, to: scope)
            }
        ))
    }

    private func addCustom(
        _ template: AccountLimitCustomTemplate,
        window: (id: String, name: String),
        to scope: Scope
    ) {
        guard let values = IntegerPromptAlert.ask(template.prompt(windowName: window.name)),
              let rule = template.rule(windowID: window.id, values: values) else { return }
        add(rule, to: scope)
    }

    /// The windows a scope can draw a line on, deduplicated by identifier and in reading order.
    private func windows(for scope: Scope) -> [(id: String, name: String)] {
        let readings: [AccountUsage]
        if let account = scope.account {
            readings = [AccountUsageService.shared.usage(for: account)].compactMap { $0 }
        } else {
            // The app-wide fold belongs to no one login, so it offers what any of them reports.
            readings = accounts.compactMap { AccountUsageService.shared.usage(for: $0) }
        }

        var seen: Set<String> = []
        var result: [(id: String, name: String)] = []
        for window in readings.flatMap(\.allWindows) where seen.insert(window.id).inserted {
            result.append((window.id, window.label))
        }

        guard result.isEmpty else { return result }
        return [
            (UsageDefaults.fiveHourWindowID, UsageDefaults.fiveHourLabel),
            (UsageDefaults.weeklyWindowID, UsageDefaults.weeklyLabel)
        ]
    }

    private func add(_ rule: CustomLimit, to scope: Scope) {
        if let account = scope.account {
            settings.add(rule, for: account.id, store: accountStore)
        } else {
            settings.addDefault(rule)
        }
        edited()
    }

    // MARK: - Actions

    @objc private func alertsChanged(_ sender: ThemedToggle) {
        settings.alertsEnabled = sender.state == .on
    }

    @objc private func addClicked(_ sender: ThemedButton) {
        guard let scope = scope(at: sender.tag) else { return }

        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [.header(AccountLimitsStrings.menuHeader)] + templates(for: scope),
                minimumWidth: AccountLimitsLayout.menuWidth
            ),
            from: sender,
            anchor: .control,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    @objc private func toolbarChanged(_ sender: ThemedToggle) {
        guard let entry = ruleEntry(for: sender.tag) else { return }

        if let account = entry.scope.account {
            settings.setShowsInToolbar(
                sender.state == .on,
                ruleID: entry.ruleID,
                for: account.id,
                store: accountStore
            )
        } else {
            settings.setDefaultShowsInToolbar(sender.state == .on, ruleID: entry.ruleID)
        }
        edited()
    }

    @objc private func removeClicked(_ sender: ThemedButton) {
        guard let entry = ruleEntry(for: sender.tag) else { return }

        if let account = entry.scope.account {
            settings.remove(ruleID: entry.ruleID, for: account.id, store: accountStore)
        } else {
            settings.removeDefault(ruleID: entry.ruleID)
        }
        edited()
    }

    /// What every edit does afterwards. One place, because the event is what wakes the alert
    /// centre and a rule created now has to be able to speak before the next reading arrives.
    private func edited() {
        NotificationCenter.default.post(CustomLimitsDidChange())
        onPresentationChange?()
        onChange?()
    }
}

// MARK: - Custom Templates

/// The five places a preset percentage can be replaced by the person's own whole number.
///
/// This stays a semantic value rather than five modal closures in the menu builder: the prompt,
/// its validation range, and the exact stored rule are one decision that behavior tests can read
/// without running a modal.
enum AccountLimitCustomTemplate: CaseIterable {
    case alert
    case repeatingAlert
    case cap
    case syntheticWindow
    case reserveShare

    private static let percentageRange = 1...99

    var menuTitle: String {
        switch self {
        case .alert: return AccountLimitsStrings.customAlertMenu
        case .repeatingAlert: return AccountLimitsStrings.customRepeatingAlertMenu
        case .cap: return AccountLimitsStrings.customCapMenu
        case .syntheticWindow: return AccountLimitsStrings.customSyntheticWindowMenu
        case .reserveShare: return AccountLimitsStrings.customReserveShareMenu
        }
    }

    var menuHelp: String? {
        switch self {
        case .reserveShare: return AccountLimitsStrings.customReserveShareHelp
        default: return nil
        }
    }

    func prompt(windowName: String) -> IntegerPromptRequest {
        switch self {
        case .alert:
            return IntegerPromptRequest(
                title: AccountLimitsStrings.customAlertTitle,
                message: AccountLimitsStrings.customAlertMessage(windowName),
                confirmTitle: AccountLimitsStrings.addAlert,
                fields: [percentageField(
                    title: AccountLimitsStrings.notifyAt,
                    accessibilityLabel: AccountLimitsStrings.notifyAtAccessibility,
                    current: 50
                )],
                helperText: AccountLimitsStrings.percentageHelper
            )

        case .repeatingAlert:
            return IntegerPromptRequest(
                title: AccountLimitsStrings.customRepeatingAlertTitle,
                message: AccountLimitsStrings.customRepeatingAlertMessage(windowName),
                confirmTitle: AccountLimitsStrings.addAlert,
                fields: [percentageField(
                    title: AccountLimitsStrings.every,
                    accessibilityLabel: AccountLimitsStrings.everyAccessibility,
                    current: 10
                )],
                helperText: AccountLimitsStrings.percentageHelper
            )

        case .cap:
            return IntegerPromptRequest(
                title: AccountLimitsStrings.customCapTitle,
                message: AccountLimitsStrings.customCapMessage(windowName),
                confirmTitle: AccountLimitsStrings.addLimit,
                fields: [percentageField(
                    title: AccountLimitsStrings.keepUnderLabel,
                    accessibilityLabel: AccountLimitsStrings.keepUnderAccessibility,
                    current: 80
                )],
                helperText: AccountLimitsStrings.percentageHelper
            )

        case .syntheticWindow:
            return IntegerPromptRequest(
                title: AccountLimitsStrings.customSyntheticWindowTitle,
                message: AccountLimitsStrings.customSyntheticWindowMessage(windowName),
                confirmTitle: AccountLimitsStrings.addWindow,
                fields: [
                    percentageField(
                        title: AccountLimitsStrings.budget,
                        accessibilityLabel: AccountLimitsStrings.budgetAccessibility,
                        current: 15
                    ),
                    IntegerPromptFieldRequest(
                        title: AccountLimitsStrings.window,
                        accessibilityLabel: AccountLimitsStrings.windowHoursAccessibility,
                        suffix: AccountLimitsStrings.hours,
                        current: 5,
                        range: CustomLimitDefaults.syntheticWindowHourRange
                    )
                ],
                helperText: AccountLimitsStrings.syntheticWindowHelper
            )

        case .reserveShare:
            return IntegerPromptRequest(
                title: AccountLimitsStrings.customReserveShareTitle,
                message: AccountLimitsStrings.customReserveShareMessage(windowName),
                confirmTitle: AccountLimitsStrings.addReserve,
                fields: [percentageField(
                    title: AccountLimitsStrings.alwaysLeave,
                    accessibilityLabel: AccountLimitsStrings.alwaysLeaveAccessibility,
                    current: 50
                )],
                helperText: AccountLimitsStrings.percentageHelper
            )
        }
    }

    func rule(windowID: String, values: [Int]) -> CustomLimit? {
        guard let percentage = values.first,
              Self.percentageRange.contains(percentage) else { return nil }
        let fraction = Double(percentage) / 100

        switch self {
        case .alert:
            return .alert(windowID: windowID, at: fraction)
        case .repeatingAlert:
            return .everyStep(windowID: windowID, step: fraction)
        case .cap:
            return .cap(windowID: windowID, at: fraction)
        case .syntheticWindow:
            guard values.indices.contains(1),
                  CustomLimitDefaults.syntheticWindowHourRange.contains(values[1]) else {
                return nil
            }
            return .syntheticWindow(
                windowID: windowID,
                budget: fraction,
                span: TimeInterval(values[1] * 3_600)
            )
        case .reserveShare:
            return .paceShare(windowID: windowID, share: 1 - fraction)
        }
    }

    private func percentageField(
        title: String,
        accessibilityLabel: String,
        current: Int
    ) -> IntegerPromptFieldRequest {
        IntegerPromptFieldRequest(
            title: title,
            accessibilityLabel: accessibilityLabel,
            suffix: AccountLimitsStrings.percentSuffix,
            current: current,
            range: Self.percentageRange
        )
    }
}

// MARK: - Account Limits Layout

enum AccountLimitsLayout {
    /// How many rule tags one fold's rows may occupy before the next fold's begin.
    /// `maximumRulesPerAccount` with room to spare, so a tag can be decoded back to its row.
    static let tagStride = 100

    /// The app-wide fold's key in the set of open folds. Not an account identifier, and it does
    /// not have to avoid colliding with one — an `AccountID` is always `provider:handle`.
    static let allAccountsKey = "all-accounts"

    static let menuWidth: CGFloat = 200
}

// MARK: - Account Limits Strings

enum AccountLimitsStrings {

    static var sectionTitle: String { L10n.string("Your Own Limits") }

    static var alertsTitle: String { L10n.string("Tell me when I reach my own limits") }

    static var alertsSubtitle: String {
        L10n.string("""
            A notification when one of your accounts reaches a line you drew. Separate from \
            session notifications, and switched on or off on its own.
            """)
    }

    static var alertsToggleLabel: String { L10n.string("Notify me about my own usage limits") }

    static var addButton: String { L10n.string("Add Limit…") }
    static var addRowTitle: String { L10n.string("Draw a line on this account") }
    static var addRowTitleForAll: String { L10n.string("Draw a line on every account") }
    static var addRowSubtitle: String {
        L10n.string("Pick a window, then what should happen when it gets there.")
    }

    static var removeButton: String { L10n.string("Remove") }

    static var toolbarCaption: String { L10n.string("Toolbar") }

    static var toolbarTooltip: String {
        L10n.string("Let this limit colour the usage pill in the toolbar")
    }
    static var toolbarLabel: String { L10n.string("Show this limit on the toolbar pill") }
    static var menuHeader: String { L10n.string("Tell me when…") }

    static var noRulesTitle: String { L10n.string("No limits") }

    static var allAccountsTitle: String { L10n.string("All Accounts") }
    static var allAccountsSubtitle: String {
        L10n.string("Applies to every login that has no limits of its own")
    }
    static var noDefaultsSubtitle: String {
        L10n.string("Set one here and every login without its own limits takes it.")
    }

    /// Appended to an inherited rule's line, so a row that can be removed from this account still
    /// says where it came from.
    static var inheritedMarker: String { L10n.string("from All Accounts") }

    static var inheritedSubtitle: String {
        L10n.string("This account runs on the provider's own limits.")
    }
    static var clearedSubtitle: String {
        L10n.string("You cleared this account's limits.")
    }

    static var explanation: String {
        L10n.string("""
            A limit here is yours, ahead of the provider's. Depending on the one you pick it \
            tells you, holds back what Threading would send on its own, or parks sessions on \
            that account at their next turn. It never stops the keyboard: a turn you type and \
            send goes, whatever your limits say. The percentage you are told about is always \
            the one the window itself reads.
            """)
    }

    static func atPercent(_ percent: String) -> String {
        L10n.format("It reaches %@", percent)
    }

    static func everyStep(_ percent: String) -> String {
        L10n.format("Every %@", percent)
    }

    static var holdHeader: String { L10n.string("…and stop spending it for me") }
    static var shareHeader: String { L10n.string("…and leave a share for its owner") }
    static var recreateHeader: String { L10n.string("…and give it a shorter window back") }

    static func recreateWindow(span: String, budget: String) -> String {
        L10n.format("No more than %1$@ in any %2$@", budget, span)
    }

    static func keepUnder(_ percent: String) -> String {
        L10n.format("Keep it under %@", percent)
    }

    static func reserveShare(_ percent: String) -> String {
        L10n.format("Always leave them %@", percent)
    }

    static var customAlertMenu: String { L10n.string("Custom alert…") }
    static var customValuesMenu: String { L10n.string("Custom values…") }
    static var customValuesHelp: String {
        L10n.string("Enter exact percentages for alerts, spending limits, rolling windows, or reserved usage.")
    }
    static var customRepeatingAlertMenu: String { L10n.string("Custom repeating alert…") }
    static var customCapMenu: String { L10n.string("Custom spending limit…") }
    static var customSyntheticWindowMenu: String { L10n.string("Custom shorter window…") }
    static var customReserveShareMenu: String { L10n.string("Custom reserved share…") }
    static var customReserveShareHelp: String {
        L10n.string("Leaves this share of what the clock has released unused; Threading may use the rest.")
    }

    static var customAlertTitle: String { L10n.string("Custom usage alert") }
    static func customAlertMessage(_ window: String) -> String {
        L10n.format(
            "Choose the point in the %@ window when Threading should notify you.",
            window
        )
    }
    static var customRepeatingAlertTitle: String { L10n.string("Custom repeating alert") }
    static func customRepeatingAlertMessage(_ window: String) -> String {
        L10n.format("Choose how often the %@ window should notify you as it fills.", window)
    }
    static var customCapTitle: String { L10n.string("Custom spending limit") }
    static func customCapMessage(_ window: String) -> String {
        L10n.format(
            "Threading will hold back work it starts on its own after the %@ window reaches this line. Turns you send still go through.",
            window
        )
    }
    static var customSyntheticWindowTitle: String { L10n.string("Custom shorter window") }
    static func customSyntheticWindowMessage(_ window: String) -> String {
        L10n.format(
            "Choose how much of the %@ window Threading may spend inside one rolling window.",
            window
        )
    }
    static var customReserveShareTitle: String { L10n.string("Custom reserved share") }
    static func customReserveShareMessage(_ window: String) -> String {
        L10n.format(
            "Reserve this share of %@ usage for the owner; Threading may use the rest.",
            window
        )
    }

    static var addAlert: String { L10n.string("Add Alert") }
    static var addLimit: String { L10n.string("Add Limit") }
    static var addWindow: String { L10n.string("Add Window") }
    static var addReserve: String { L10n.string("Add Reserve") }
    static var notifyAt: String { L10n.string("Notify at") }
    static var notifyAtAccessibility: String { L10n.string("Notify at percentage") }
    static var every: String { L10n.string("Every") }
    static var everyAccessibility: String { L10n.string("Repeat every percentage") }
    static var keepUnderLabel: String { L10n.string("Keep under") }
    static var keepUnderAccessibility: String { L10n.string("Keep usage under percentage") }
    static var budget: String { L10n.string("Budget") }
    static var budgetAccessibility: String { L10n.string("Rolling-window budget percentage") }
    static var window: String { L10n.string("Window") }
    static var windowHoursAccessibility: String { L10n.string("Rolling-window length in hours") }
    static var alwaysLeave: String { L10n.string("Always leave") }
    static var alwaysLeaveAccessibility: String { L10n.string("Reserved percentage") }
    static var percentSuffix: String { L10n.string("%") }
    static var hours: String { L10n.string("hours") }
    static var percentageHelper: String {
        L10n.string("Enter a whole percentage from 1% to 99%.")
    }
    static var syntheticWindowHelper: String {
        L10n.format(
            "Whole numbers only: 1%%–99%% across a rolling window of %1$lld–%2$lld hours.",
            CustomLimitDefaults.minimumSyntheticWindowHours,
            CustomLimitDefaults.maximumSyntheticWindowHours
        )
    }

    /// What a closed fold says about a login.
    static func summary(count: Int) -> String {
        switch count {
        case 0: return L10n.string("No limits")
        case 1: return L10n.string("1 limit")
        default: return L10n.format("%lld limits", count)
        }
    }
}
