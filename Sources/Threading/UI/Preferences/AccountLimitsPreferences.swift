import AppKit

// MARK: - Account Limits Section

/// The "Your Own Limits" half of the Accounts page: the switch that lets a limit speak, and one
/// fold per login holding the lines drawn on it.
///
/// Kept as its own controller rather than as more rows in `AccountsPreferencesViewController`
/// because it has state the rest of that page does not — which folds are open, and a menu hanging
/// off one of its buttons — and because the page rebuilds itself wholesale on every edit. A fold
/// that closed every time a rule was added would be the page arguing with the person using it.
///
/// **Quiet until relevant.** The shipped default is no rules at all, so an untouched install sees
/// one switch and a list of logins reading "No limits" — not a form. Everything else appears
/// because somebody drew a line.
@MainActor
final class AccountLimitsSectionController {

    // MARK: - Properties

    /// The section's root. Handed to the page once and repopulated in place, so the page's own
    /// rebuild does not have to know this exists.
    let view = NSView()

    /// Called after any edit, so the page that owns this can refresh anything of its own that
    /// reads the same accounts.
    var onChange: (() -> Void)?

    private var accounts: [AgentAccount] = []

    /// Which logins are unfolded. Held across rebuilds — see the type's note.
    private var expanded: Set<String> = []

    /// The open templates menu, retained for as long as it is on screen.
    private var menuSession: AnyObject?

    /// Row index → the scope its Add button edits, for the controls that carry a tag rather than
    /// a value.
    private var rowScopes: [Int: Scope] = [:]

    /// Button tag → the rule it removes and the scope it removes it from, for the same reason.
    private var rowRules: [Int: (scope: Scope, ruleID: UUID)] = [:]

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

    /// Rebuilds the section for the given logins.
    func reload(accounts: [AgentAccount]) {
        self.accounts = accounts
        rebuild()
    }

    /// Opens every fold, so a render can review the rows that only exist when one is open.
    ///
    /// The folds are what keep this page quiet on an untouched install, which also means the rule
    /// rows — the part with the most to get wrong — are the part a closed-by-default render never
    /// draws.
    func expandEverythingForTesting() {
        expanded = Set([AccountLimitsLayout.allAccountsKey] + accounts.map(\.id.rawValue))
        rebuild()
    }

    // MARK: - Building

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        rowScopes.removeAll()
        rowRules.removeAll()

        let built = sections()
        let content = NSStackView(views: built)
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = Design.Spacing.large
        content.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Every fold fills the column, the rule `SettingsUI.page` states for its own sections and
        // for the same failure. A vertical stack aligned `.leading` pins leading edges and lets
        // each arranged view take its *fitting* width, so without this the cards sat at about a
        // third of the pane with the rest of the column empty — and each card's label column, cut
        // to that width, wrapped a one-line caption into five lines and truncated `Claude Code` to
        // `Clau`. Nothing asserted on the section could see it; the render could.
        for section in built {
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func sections() -> [NSView] {
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

        var views: [NSView] = [
            SettingsUI.section(AccountLimitsStrings.sectionTitle, switchCard)
        ]

        // The app-wide fold comes first, because it is the one that explains the others: a login
        // reading "from All Accounts" under its rules is only legible beside the place those were
        // set.
        views.append(fold(for: .allAccounts, row: 0))
        for (index, account) in accounts.enumerated() {
            views.append(fold(for: .account(account), row: index + 1))
        }

        views.append(SettingsUI.note(AccountLimitsStrings.explanation))
        return views
    }

    /// One scope's fold: the count when closed, its rules and an Add control when open.
    private func fold(for scope: Scope, row index: Int) -> NSView {
        rowScopes[index] = scope

        let rules = self.rules(in: scope)
        let isInherited = isInheriting(scope)
        let isExpanded = expanded.contains(scope.key)

        var detail: [NSView] = rules.enumerated().map { ruleIndex, rule in
            row(
                for: rule,
                scope: scope,
                isInherited: isInherited,
                tag: index * AccountLimitsLayout.tagStride + ruleIndex
            )
        }
        if rules.isEmpty {
            detail.append(SettingsUI.row(
                title: AccountLimitsStrings.noRulesTitle,
                subtitle: emptySubtitle(for: scope, isInherited: isInherited)
            ))
        }

        let add = SettingsUI.button(
            AccountLimitsStrings.addButton,
            target: self,
            action: #selector(addClicked(_:))
        )
        add.tag = index
        add.isEnabled = rules.count < CustomLimitDefaults.maximumRulesPerAccount
        detail.append(SettingsUI.row(
            title: scope.account == nil
                ? AccountLimitsStrings.addRowTitleForAll
                : AccountLimitsStrings.addRowTitle,
            subtitle: AccountLimitsStrings.addRowSubtitle,
            control: add,
            localizes: false
        ))

        return SettingsUI.disclosureCard(
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
                self.rebuild()
            },
            detailRows: detail
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

        rowRules[tag] = (scope, rule.id)

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
            entries.append(.separator)
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
        rebuild()
    }

    @objc private func addClicked(_ sender: ThemedButton) {
        guard let scope = rowScopes[sender.tag] else { return }

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
        guard let entry = rowRules[sender.tag] else { return }

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
        guard let entry = rowRules[sender.tag] else { return }

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
        rebuild()
        onChange?()
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

    /// What a closed fold says about a login.
    static func summary(count: Int) -> String {
        switch count {
        case 0: return L10n.string("No limits")
        case 1: return L10n.string("1 limit")
        default: return L10n.format("%lld limits", count)
        }
    }
}
