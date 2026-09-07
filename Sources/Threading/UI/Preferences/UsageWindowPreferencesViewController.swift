import AppKit

// MARK: - Usage Window Preferences

/// The Usage Windows page: when the day's window opens.
///
/// The page has an unusual burden for a settings screen. Every other one here configures
/// something the reader already understands — a font, a shortcut, which accounts exist. This one
/// configures a consequence of how a subscription meters time, which almost nobody has had
/// explained to them, and which sounds like a trick until it is drawn. So the explanation and the
/// picture come first and the controls come second, rather than the usual way round.
final class UsageWindowPreferencesViewController: NSViewController {

    typealias AccountsProvider = @MainActor () -> [AgentAccount]
    typealias DecisionProvider = @MainActor (AgentAccount) -> UsageWindowDecision

    private enum PresentationRow {
        case explanation
        case diagram
        case schedule
        case scheduledSend
        case limitRecovery
        case curfew
        case accountsCaption
        case noAccounts
        case account(Int)
        case ledgerCaption
        case ledger(Int)
        case footnote
    }

    // MARK: - Properties

    private let appEvents = AppEventObservations()

    /// Discovery can return any number of isolated provider logins. Keep only their cheap value
    /// records here; AppKit owns the much smaller set of controls intersecting the viewport.
    private let accountsProvider: AccountsProvider
    private let decisionProvider: DecisionProvider
    private var accounts: [AgentAccount] = []
    private var records: [UsageWindowPoker.Record] = []
    private var presentationRows: [PresentationRow] = []

    /// The wrap-up template, retained across row refreshes.
    ///
    /// Every other control on this page is rebuilt from the value it shows, which is correct for
    /// a switch and wrong for free text: a usage reading landing while somebody is halfway
    /// through a sentence would replace the field under them. Retained, the field keeps what is
    /// in it, and the two edges below — `currentEditor()` and `controlTextDidEndEditing` — decide
    /// when the stored message and the typed one meet.
    ///
    /// Built here rather than through `SettingsUI.textField`, because this one spans its row:
    /// that helper pins a fixed control width, which cannot be satisfied inside a `fullRow`
    /// whose content is pinned to both of the card's edges.
    private lazy var windDownField: ThemedTextField = {
        let field = ThemedTextField()
        field.applyFont(.body)
        field.delegate = self
        field.setAccessibilityIdentifier(CurfewSettingsDefaults.wrapUpFieldIdentifier)
        return field
    }()

    /// True only while the field's own commit is being written. See `commitWindDownText`.
    private var isCommittingWindDownText = false

    /// An external curfew edit can arrive while this field owns AppKit's field editor. The value
    /// rows may refresh immediately, but replacing that one row would tear the editor out from
    /// under a keystroke, so its refresh waits for editing to end.
    private var hasDeferredCurfewRefresh = false

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("UsageWindowSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = UsageWindowPreferencesDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    init(
        accountsProvider: @escaping AccountsProvider = { UsageWindowPoker.eligibleAccounts },
        decisionProvider: @escaping DecisionProvider = {
            UsageWindowPoker.shared.decide(account: $0)
        }
    ) {
        self.accountsProvider = accountsProvider
        self.decisionProvider = decisionProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        let page = SettingsUI.listPage(
            title: UsageWindowStrings.title,
            summary: UsageWindowStrings.summary,
            body: scrollView
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        reloadPresentationRows()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Each event names the state that moved. Refresh only the value rows derived from that
        // state; the page, its scroll position and every unrelated editor remain installed.
        appEvents.observe(UsageWindowPokeDidChange.self) { [weak self] event in
            self?.refreshAfterPoke(event)
        }
        appEvents.observe(UsageWindowScheduleDidChange.self) { [weak self] _ in
            self?.reloadRows { row in
                switch row {
                case .diagram, .schedule, .account: true
                default: false
                }
            }
        }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.refreshUsage(accountID: event.accountID)
        }
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            self?.reloadPresentationRows()
        }

        // The curfew defaults and the standing quiet hours are edited on this page and read by
        // the menu, the strip and the engine, so the page follows the store rather than its own
        // last write — a curfew lifted from a chat, or a window edited in another window, has to
        // reach the "Tonight" line here too.
        appEvents.observe(CurfewSettingsDidChange.self) { [weak self] _ in
            guard let self, !self.isCommittingWindDownText else { return }
            self.refreshCurfewRows()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadPresentationRows()

        // The page's whole subject is the state of a window, so it asks for a fresh reading on
        // the way in rather than drawing whatever was last cached.
        for account in accounts {
            AccountUsageService.shared.refresh(account)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    // MARK: - Build

    /// Rebuilds the cheap row identity model only when account or ledger membership can change.
    /// Fixed sections stay one identity each, and a long account list remains values rather than
    /// an equally long retained control tree.
    private func reloadPresentationRows() {
        accounts = accountsProvider()
        records = Array(UsageWindowPoker.shared.records.suffix(
            UsageWindowPreferencesDefaults.shownRecords
        ).reversed())

        var rows: [PresentationRow] = [
            .explanation,
            .diagram,
            .schedule,
            .scheduledSend,
            .limitRecovery,
            .curfew,
            .accountsCaption
        ]
        if accounts.isEmpty {
            rows.append(.noAccounts)
        } else {
            rows.append(contentsOf: accounts.indices.map(PresentationRow.account))
        }
        if !records.isEmpty {
            rows.append(.ledgerCaption)
            rows.append(contentsOf: records.indices.map(PresentationRow.ledger))
        }
        rows.append(.footnote)
        presentationRows = rows
        updateCardDecorations()
        tableView.reloadData()
    }

    private func refreshAfterPoke(_ event: UsageWindowPokeDidChange) {
        syncLedgerRows()
        reloadRows { row in
            switch row {
            case .account(let index):
                return accounts.indices.contains(index)
                    && event.accountIDs.contains(accounts[index].id)
            case .ledger:
                return true
            default:
                return false
            }
        }
    }

    /// The ledger is the only structural part a poke can change. Insert or remove precisely that
    /// bounded run so a first record does not make NSTableView discard unrelated visible rows.
    private func syncLedgerRows() {
        let newRecords = Array(UsageWindowPoker.shared.records.suffix(
            UsageWindowPreferencesDefaults.shownRecords
        ).reversed())
        let oldLedgerRows = presentationRows.indices.filter {
            switch presentationRows[$0] {
            case .ledgerCaption, .ledger: true
            default: false
            }
        }
        let newRowCount = newRecords.isEmpty ? 0 : newRecords.count + 1
        records = newRecords

        guard oldLedgerRows.count != newRowCount else { return }
        tableView.beginUpdates()
        if let first = oldLedgerRows.first, let last = oldLedgerRows.last {
            let range = first ... last
            presentationRows.removeSubrange(range)
            tableView.removeRows(
                at: IndexSet(integersIn: first ..< last + 1),
                withAnimation: []
            )
        }
        if !records.isEmpty,
           let insertion = presentationRows.firstIndex(where: {
               if case .footnote = $0 { true } else { false }
           }) {
            let rows: [PresentationRow] = [.ledgerCaption]
                + records.indices.map(PresentationRow.ledger)
            presentationRows.insert(contentsOf: rows, at: insertion)
            tableView.insertRows(
                at: IndexSet(integersIn: insertion ..< insertion + rows.count),
                withAnimation: []
            )
        }
        tableView.endUpdates()
        updateCardDecorations()
    }

    private func refreshUsage(accountID: AccountID) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let subjectChanged = subjectAccount?.id == accountID
        reloadRows { row in
            switch row {
            case .account(let index): index == accountIndex
            case .diagram, .schedule: subjectChanged
            default: false
            }
        }
    }

    private func refreshCurfewRows() {
        let editing = windDownField.currentEditor() != nil
        if editing { hasDeferredCurfewRefresh = true }
        reloadRows { row in
            switch row {
            case .curfew: !editing
            case .account: true
            default: false
            }
        }
    }

    private func reloadRows(where shouldReload: (PresentationRow) -> Bool) {
        let rows = IndexSet(presentationRows.indices.filter {
            shouldReload(presentationRows[$0])
        })
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Scheduled Sends

    /// What a message aimed at a window's reset should do if the window has not turned over.
    ///
    /// On this page rather than a page of its own, because the question is entirely about these
    /// windows: `resetsAt` is a reading refreshed on an interval and sometimes served from a
    /// local cache, so a send aimed at one can arrive to find it still spent. See
    /// `docs/architecture/scheduled-messages.md`.
    private func scheduledSendSection() -> NSView {
        let popUp = SettingsUI.popUp(target: self, action: #selector(resetPolicyChanged))
        for policy in ScheduledResetPolicy.allCases {
            popUp.addItem(ThemedMenuItem(title: policy.title, representedValue: policy.rawValue))
        }
        popUp.selectItem(
            at: ScheduledResetPolicy.allCases.firstIndex(of: ScheduledResetPolicy.current) ?? 0
        )

        return SettingsUI.section(
            UsageWindowStrings.scheduledSendCaption,
            SettingsCard(rows: [
                SettingsUI.row(title: UsageWindowStrings.scheduledSendTitle, control: popUp),
                SettingsUI.detailRow(
                    symbol: "clock.badge.questionmark",
                    title: UsageWindowStrings.scheduledSendTitle,
                    detail: ScheduledResetPolicy.current.explanation,
                    localizes: false
                )
            ])
        )
    }

    @objc private func resetPolicyChanged(_ sender: ThemedPopUp) {
        guard let raw = sender.selectedItem?.representedValue as? String,
              let policy = ScheduledResetPolicy(rawValue: raw) else { return }
        ScheduledResetSettings.policy = policy
        reloadRows { if case .scheduledSend = $0 { true } else { false } }
    }

    // MARK: - Limit Recovery

    /// What happens when a running session is refused over its account's usage limit.
    ///
    /// On this page for the scheduled-send rule's reason: the whole question is about these
    /// windows — the recovery schedules its continuation against one — and the default does
    /// nothing but mark the session, so the automatic half is chosen here or not at all. See
    /// `docs/architecture/limit-recovery.md`.
    private func limitRecoverySection() -> NSView {
        // The runtime-neutral answers only. Settings speaks for every chat in the app and a login
        // belongs to exactly one runtime, so "continue as Nova Hartley" is a sentence only a chat
        // can say — it is offered in the chat's own menu. See `LimitRecoveryPolicy.resumeVia`.
        let choices = LimitRecoveryPolicy.runtimeNeutralChoices
        let popUp = SettingsUI.popUp(target: self, action: #selector(limitRecoveryChanged))
        for policy in choices {
            popUp.addItem(ThemedMenuItem(title: policy.title, representedValue: policy.rawValue))
        }
        popUp.selectItem(at: choices.firstIndex(of: LimitRecoveryPolicy.current) ?? 0)

        return SettingsUI.section(
            UsageWindowStrings.limitRecoveryCaption,
            SettingsCard(rows: [
                SettingsUI.row(title: UsageWindowStrings.limitRecoveryTitle, control: popUp),
                SettingsUI.detailRow(
                    symbol: "clock.badge.exclamationmark",
                    title: UsageWindowStrings.limitRecoveryTitle,
                    detail: LimitRecoveryPolicy.current.explanation,
                    localizes: false
                )
            ])
        )
    }

    @objc private func limitRecoveryChanged(_ sender: ThemedPopUp) {
        guard let raw = sender.selectedItem?.representedValue as? String,
              let policy = LimitRecoveryPolicy(rawValue: raw) else { return }
        LimitRecoverySettings.policy = policy
        reloadRows { if case .limitRecovery = $0 { true } else { false } }
    }

    // MARK: - Curfew

    /// When a session stops being spent, and the standing window that ends all of them.
    ///
    /// On this page for the reason the two sections above it are: a curfew is chosen against a
    /// window's boundaries — the case the whole feature was written for is a window that resets
    /// at 04:00 while its owner is asleep — and the standing half of it is set here or nowhere.
    /// The per-session half lives in the composer and in each session's own menu, which is what
    /// the explanation says first, because a page of margins for a thing the reader has never
    /// seen chosen explains nothing.
    ///
    /// Every writer here is a read-modify-write on `CurfewSettings.shared.preferences`: the
    /// record carries five fields edited by four controls, and a whole-record write from a stale
    /// copy is how one popup erases another. See `docs/feature-drafts/curfew.md`.
    private func curfewSection() -> NSView {
        let preferences = CurfewSettings.shared.preferences
        let quietHours = preferences.quietHours

        // Not while it is being typed into — see `windDownField`.
        if windDownField.currentEditor() == nil {
            windDownField.stringValue = preferences.windDownText
        }

        let rows: [NSView] = [
            SettingsUI.fullRow(SettingsUI.note(CurfewSettingsStrings.explanation)),
            SettingsUI.row(
                title: CurfewSettingsStrings.windDownTitle,
                control: choicePopUp(
                    titles: CurfewDefaults.windDownMarginChoices
                        .map(CurfewSettingsStrings.windDownChoice),
                    selecting: CurfewDefaults.windDownMarginChoices
                        .firstIndex(of: preferences.windDownMargin),
                    action: #selector(windDownMarginChanged)
                )
            ),
            SettingsUI.row(
                title: CurfewSettingsStrings.graceTitle,
                control: choicePopUp(
                    titles: CurfewDefaults.graceChoices.map(CurfewSettingsStrings.graceChoice),
                    selecting: CurfewDefaults.graceChoices.firstIndex(of: preferences.grace),
                    action: #selector(graceChanged)
                )
            ),
            SettingsUI.row(title: CurfewSettingsStrings.wrapUpTitle),
            windDownEditor(),
            SettingsUI.row(
                title: CurfewSettingsStrings.giveUpTitle,
                subtitle: CurfewSettingsStrings.giveUpSubtitle,
                control: choicePopUp(
                    titles: CurfewSettingsStrings.giveUpChoices,
                    selecting: preferences.stopsAgentOnGiveUp
                        ? CurfewSettingsDefaults.stopsAgentIndex
                        : CurfewSettingsDefaults.notifyIndex,
                    action: #selector(giveUpPolicyChanged)
                )
            ),
            SettingsUI.row(
                title: CurfewSettingsStrings.quietHoursTitle,
                subtitle: CurfewSettingsStrings.quietHoursSubtitle,
                control: SettingsUI.toggle(
                    isOn: quietHours.isEnabled,
                    target: self,
                    action: #selector(quietHoursEnabledChanged)
                )
            ),
            // The two times stay on the page while the window is off rather than disappearing
            // with it: a switch whose consequences vanish gives the reader nothing to decide
            // with, and these are the rows that say what switching it on would do.
            SettingsUI.row(
                title: CurfewSettingsStrings.fromTitle,
                control: quietHoursTimePopUp(
                    selecting: quietHours.startMinute,
                    isEnabled: quietHours.isEnabled,
                    action: #selector(quietHoursStartChanged)
                )
            ),
            SettingsUI.row(
                title: CurfewSettingsStrings.toTitle,
                control: quietHoursTimePopUp(
                    selecting: quietHours.endMinute,
                    isEnabled: quietHours.isEnabled,
                    action: #selector(quietHoursEndChanged)
                )
            ),
            // What the four controls above actually amount to tonight, in times rather than in
            // margins — the row that turns a form into a plan the reader can check.
            SettingsUI.detailRow(
                symbol: CurfewDefaults.symbol,
                title: CurfewSettingsStrings.tonightTitle,
                detail: CurfewSettingsSentence.tonight(preferences: preferences),
                localizes: false
            )
        ]

        return SettingsUI.section(CurfewSettingsStrings.caption, SettingsCard(rows: rows))
    }

    /// The wrap-up template across the card, with the one thing its author has to know under it.
    private func windDownEditor() -> NSView {
        let note = SettingsUI.note(CurfewSettingsStrings.placeholderNote)
        let stack = NSStackView(views: [windDownField, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small

        // A `.leading` stack gives each arranged view its fitting width, and neither a field nor
        // a wrapping label has one worth having: both are pinned to the column instead.
        for child in [windDownField, note] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }

        return SettingsUI.fullRow(stack)
    }

    /// A pop-up over an ordered list of choices, carrying its **index**.
    ///
    /// Two of the three curfew choices have `nil` as a legitimate answer — no wrap-up at all,
    /// never interrupt — and `nil` cannot ride in a `representedValue` and be told apart from a
    /// row that carries nothing. The index can, and it is the same list on the way back out.
    private func choicePopUp(
        titles: [String],
        selecting index: Int?,
        action: Selector,
        isEnabled: Bool = true
    ) -> ThemedPopUp {
        let popUp = SettingsUI.popUp(target: self, action: action)
        for (offset, title) in titles.enumerated() {
            popUp.addItem(ThemedMenuItem(title: title, representedValue: offset))
        }
        popUp.selectItem(at: index ?? 0)
        popUp.isEnabled = isEnabled
        return popUp
    }

    /// A time of day over the whole day, in half hours: a nightly window is as legitimately
    /// 23:30 to 07:00 as 04:00 to 08:00, so neither end is bounded the way a working day's is.
    private func quietHoursTimePopUp(
        selecting minute: Int,
        isEnabled: Bool,
        action: Selector
    ) -> ThemedPopUp {
        let popUp = timePopUp(
            selecting: minute,
            range: CurfewSettingsDefaults.quietHoursRange,
            action: action
        )
        popUp.isEnabled = isEnabled
        return popUp
    }

    // MARK: - Curfew Actions

    @objc private func windDownMarginChanged(_ sender: ThemedPopUp) {
        guard let choice = choice(CurfewDefaults.windDownMarginChoices, from: sender) else {
            return
        }
        var preferences = CurfewSettings.shared.preferences
        preferences.windDownMargin = choice
        CurfewSettings.shared.preferences = preferences
    }

    @objc private func graceChanged(_ sender: ThemedPopUp) {
        guard let choice = choice(CurfewDefaults.graceChoices, from: sender) else { return }
        var preferences = CurfewSettings.shared.preferences
        preferences.grace = choice
        CurfewSettings.shared.preferences = preferences
    }

    @objc private func giveUpPolicyChanged(_ sender: ThemedPopUp) {
        guard let index = sender.selectedItem?.representedValue as? Int else { return }
        var preferences = CurfewSettings.shared.preferences
        preferences.stopsAgentOnGiveUp = index == CurfewSettingsDefaults.stopsAgentIndex
        CurfewSettings.shared.preferences = preferences
    }

    @objc private func quietHoursEnabledChanged(_ sender: ThemedToggle) {
        var preferences = CurfewSettings.shared.preferences
        preferences.quietHours.isEnabled = sender.state == .on
        CurfewSettings.shared.preferences = preferences
    }

    @objc private func quietHoursStartChanged(_ sender: ThemedPopUp) {
        guard let minute = sender.selectedItem?.representedValue as? Int else { return }
        var preferences = CurfewSettings.shared.preferences
        // No clamping against the end, unlike the working day above: `end <= start` is how a
        // window says it crosses midnight, which is the ordinary case here.
        preferences.quietHours.startMinute = minute
        CurfewSettings.shared.preferences = preferences
    }

    @objc private func quietHoursEndChanged(_ sender: ThemedPopUp) {
        guard let minute = sender.selectedItem?.representedValue as? Int else { return }
        var preferences = CurfewSettings.shared.preferences
        preferences.quietHours.endMinute = minute
        CurfewSettings.shared.preferences = preferences
    }

    /// The choice a pop-up built by `choicePopUp` is standing on, back out of its index.
    private func choice(
        _ choices: [TimeInterval?],
        from popUp: ThemedPopUp
    ) -> TimeInterval?? {
        guard let index = popUp.selectedItem?.representedValue as? Int,
              choices.indices.contains(index) else { return nil }
        return choices[index]
    }

    /// The typed message becomes the stored one when the field is left, never per keystroke: a
    /// half-typed template is a message that would be sent, and the store refuses an empty one.
    ///
    /// The write is flagged, because the page rebuilds on `CurfewSettingsDidChange` and this
    /// notification arrives while AppKit is still delivering the field's own end of editing —
    /// rebuilding there would pull the field out of the view tree mid-notification, for a change
    /// that alters nothing else the page draws.
    fileprivate func commitWindDownText() {
        var preferences = CurfewSettings.shared.preferences
        guard windDownField.stringValue != preferences.windDownText else { return }
        preferences.windDownText = windDownField.stringValue

        isCommittingWindDownText = true
        CurfewSettings.shared.preferences = preferences
        isCommittingWindDownText = false

        // A refused message — empty, or longer than the store accepts — leaves the stored one
        // exactly as it was, so the field goes back to saying what is actually stored rather
        // than showing text nothing will ever send.
        windDownField.stringValue = CurfewSettings.shared.preferences.windDownText
    }

    // MARK: - Diagram

    /// The picture, and one line saying where its burn figure came from.
    private func diagramSection() -> NSView {
        let grid = UsageWindowGridView()
        grid.show(
            workday: illustrativeWorkday(),
            burn: burn ?? assumedBurn,
            windowLength: windowLength
        )

        let caption = NSTextField(wrappingLabelWithString: burnCaption())
        caption.applyFont(.subheading)
        caption.textColor = Design.Text.secondary

        return SettingsUI.section(
            nil,
            SettingsCard(rows: [
                SettingsUI.fullRow(grid),
                SettingsUI.fullRow(caption)
            ])
        )
    }

    /// The working day the diagram illustrates: the configured hours, placed on today so the
    /// times on it are the reader's own.
    private func illustrativeWorkday() -> DateInterval {
        let schedule = UsageWindowSettings.shared.schedule
        let midnight = Calendar.current.startOfDay(for: Date())
        let start = midnight.addingTimeInterval(TimeInterval(schedule.startMinute) * 60)
        let end = midnight.addingTimeInterval(TimeInterval(max(
            schedule.endMinute,
            schedule.startMinute + UsageWindowPreferencesDefaults.minimumWorkdayMinutes
        )) * 60)
        return DateInterval(start: start, end: end)
    }

    private func burnCaption() -> String {
        let lead = UsageWindowPlan.lead(burn: burn, windowLength: windowLength)

        guard let estimate = burnEstimate else {
            return UsageWindowStrings.burnAssumed(
                UsageFormat.duration(assumedBurn),
                UsageFormat.duration(lead)
            )
        }

        return UsageWindowStrings.burnMeasured(
            UsageFormat.duration(estimate.burn),
            UsageFormat.duration(lead)
        )
    }

    // MARK: - Schedule

    private func scheduleSection() -> NSView {
        let schedule = UsageWindowSettings.shared.schedule

        var rows: [NSView] = [
            SettingsUI.row(
                title: UsageWindowStrings.enabledTitle,
                subtitle: UsageWindowStrings.enabledSubtitle,
                control: SettingsUI.toggle(
                    isOn: schedule.isEnabled,
                    target: self,
                    action: #selector(enabledChanged)
                )
            ),
            SettingsUI.row(
                title: UsageWindowStrings.startTitle,
                control: timePopUp(
                    selecting: schedule.startMinute,
                    range: UsageWindowPreferencesDefaults.startRange,
                    action: #selector(startChanged)
                )
            ),
            SettingsUI.row(
                title: UsageWindowStrings.endTitle,
                control: timePopUp(
                    selecting: schedule.endMinute,
                    range: UsageWindowPreferencesDefaults.endRange,
                    action: #selector(endChanged)
                )
            ),
            SettingsUI.row(
                title: UsageWindowStrings.daysTitle,
                control: daysPopUp(schedule)
            )
        ]

        rows.append(SettingsUI.detailRow(
            symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            title: UsageWindowStrings.planTitle,
            detail: planDetail(),
            localizes: false
        ))

        return SettingsUI.section(UsageWindowStrings.scheduleCaption, SettingsCard(rows: rows))
    }

    /// The plan in plain times: when the poke fires and where the day's boundaries land. This is
    /// the row that makes the lead something the reader can check rather than trust.
    private func planDetail() -> String {
        let workday = illustrativeWorkday()
        let lead = UsageWindowPlan.lead(burn: burn, windowLength: windowLength)
        let anchor = workday.start.addingTimeInterval(-lead)

        var boundaries: [String] = []
        var moment = anchor
        while moment < workday.end, boundaries.count < UsageWindowDefaults.maximumOutlookWindows {
            boundaries.append(Self.time.string(from: moment))
            moment = moment.addingTimeInterval(windowLength)
        }

        return UsageWindowStrings.plan(
            Self.time.string(from: anchor),
            boundaries.joined(separator: UsageWindowPreferencesDefaults.boundarySeparator)
        )
    }

    private func timePopUp(selecting minute: Int, range: StrideThrough<Int>, action: Selector) -> ThemedPopUp {
        let popUp = SettingsUI.popUp(target: self, action: action)
        var selected = 0

        for (index, value) in range.enumerated() {
            popUp.addItem(ThemedMenuItem(
                title: Self.time.string(from: date(atMinute: value)),
                representedValue: value
            ))
            if value <= minute { selected = index }
        }

        popUp.selectItem(at: selected)
        return popUp
    }

    private func daysPopUp(_ schedule: UsageWindowSchedule) -> ThemedPopUp {
        let popUp = SettingsUI.popUp(target: self, action: #selector(daysChanged))
        popUp.addItem(ThemedMenuItem(
            title: UsageWindowStrings.weekdays,
            representedValue: UsageWindowDefaults.defaultWeekdays
        ))
        popUp.addItem(ThemedMenuItem(
            title: UsageWindowStrings.everyDay,
            representedValue: UsageWindowPreferencesDefaults.everyDay
        ))
        popUp.selectItem(at: schedule.weekdays == UsageWindowPreferencesDefaults.everyDay ? 1 : 0)
        return popUp
    }

    // MARK: - Accounts

    private func accountRow(for account: AgentAccount) -> NSView {
        let decision = decisionProvider(account)
        return SettingsUI.row(
            title: account.presentation(in: .usage).visibleName,
            subtitle: state(of: decision),
            control: accountControls(for: account, decision: decision),
            localizes: false
        )
    }

    /// Try-it-now beside the switch. A feature whose whole promise lands at 07:00 tomorrow is one
    /// nobody can tell is working, so the button spends one message to prove it.
    private func accountControls(
        for account: AgentAccount,
        decision: UsageWindowDecision
    ) -> NSView {
        let poke = SettingsUI.button(
            UsageWindowStrings.pokeNow,
            target: self,
            action: #selector(pokeNowClicked)
        )
        poke.identifier = NSUserInterfaceItemIdentifier(account.id.rawValue)
        poke.isEnabled = canPokeNow(decision)

        let toggle = SettingsUI.toggle(
            isOn: UsageWindowSettings.shared.isEnabled(account.id),
            target: self,
            action: #selector(accountChanged)
        )
        toggle.identifier = NSUserInterfaceItemIdentifier(account.id.rawValue)

        let stack = NSStackView(views: [poke, toggle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        return stack
    }

    /// What this account is doing about its window right now, in one line.
    private func state(of decision: UsageWindowDecision) -> String {
        switch decision {
        case .poke:
            return UsageWindowStrings.readyToPoke
        case .hold(let reason):
            return holdText(reason)
        }
    }

    private func holdText(_ hold: UsageWindowHold) -> String {
        switch hold {
        case .disabled:
            return UsageWindowStrings.holdDisabled
        case .notScheduledToday:
            return UsageWindowStrings.holdNotToday
        case .dailyLimitReached(let count):
            return UsageWindowStrings.holdDailyLimit(count)
        case .usageUnknown:
            return UsageWindowStrings.holdUsageUnknown
        case .windowOpen(let resetsAt):
            return UsageWindowStrings.holdWindowOpen(
                Self.time.string(from: resetsAt),
                UsageFormat.remaining(until: resetsAt)
            )
        case .settling:
            return UsageWindowStrings.holdSettling
        case .working:
            return UsageWindowStrings.holdWorking
        case .neverExhausts:
            return UsageWindowStrings.holdNeverExhausts
        case .beforePokeTime(let date):
            return UsageWindowStrings.holdBeforePokeTime(Self.time.string(from: date))
        case .tailTooShort:
            return UsageWindowStrings.holdTailTooShort
        case .weeklyAheadOfPace(let fraction):
            return UsageWindowStrings.holdWeeklyAheadOfPace(Int((fraction * 100).rounded()))
        case .customLimitReached(let reason):
            // The rule's own sentence, not a paraphrase: the page that explains why nothing
            // happened this morning should say it in the same words as everywhere else.
            return reason
        case .quietHours(let until):
            return UsageWindowStrings.holdQuietHours(Self.time.string(from: until))
        }
    }

    private func canPokeNow(_ decision: UsageWindowDecision) -> Bool {
        switch decision {
        case .poke:
            return true
        case .hold(let reason):
            // The button overrides the planning rules but not the two facts: a window that is
            // already open cannot be opened again, and the daily limit is a limit.
            switch reason {
            case .windowOpen, .settling, .dailyLimitReached, .usageUnknown:
                return false
            default:
                return true
            }
        }
    }

    // MARK: - Ledger

    private func ledgerRow(for record: UsageWindowPoker.Record) -> NSView {
        SettingsUI.row(
            title: recordTitle(record),
            subtitle: record.detail,
            localizes: false
        )
    }

    private func recordTitle(_ record: UsageWindowPoker.Record) -> String {
        let name = AccountID(rawValue: record.accountID)
            .flatMap { id in
                accounts.first { $0.id == id }
            }
            .map { $0.presentation(in: .usage).visibleName } ?? record.accountID

        let when = UsageFormat.absolute(record.at)

        return record.outcome == .opened
            ? UsageWindowStrings.recordOpened(when, name)
            : UsageWindowStrings.recordFailed(when, name)
    }

    // MARK: - Derived Values

    /// The account the diagram is drawn for: the first enabled one, else the first there is.
    private var subjectAccount: AgentAccount? {
        return accounts.first { UsageWindowSettings.shared.isEnabled($0.id) } ?? accounts.first
    }

    private var burnEstimate: UsageWindowBurn.Estimate? {
        subjectAccount.flatMap { UsageWindowPoker.shared.burn(for: $0) }
    }

    private var burn: TimeInterval? { burnEstimate?.burn }

    /// The stand-in used until a window has been watched being spent, chosen so the assumed lead
    /// is exactly `UsageWindowDefaults.assumedLead`.
    private var assumedBurn: TimeInterval {
        max(windowLength - UsageWindowDefaults.assumedLead, 0)
    }

    private var windowLength: TimeInterval {
        subjectAccount
            .flatMap { AccountUsageService.shared.usage(for: $0)?.anchoredWindow?.windowDuration }
            ?? UsageDefaults.fiveHourSeconds
    }

    private func date(atMinute minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute) * 60)
    }

    // MARK: - Actions

    @objc private func enabledChanged(_ sender: ThemedToggle) {
        var schedule = UsageWindowSettings.shared.schedule
        schedule.isEnabled = sender.state == .on
        UsageWindowSettings.shared.schedule = schedule
    }

    @objc private func startChanged(_ sender: ThemedPopUp) {
        guard let minute = sender.selectedItem?.representedValue as? Int else { return }
        var schedule = UsageWindowSettings.shared.schedule
        schedule.startMinute = minute
        // A start pushed past the end leaves a schedule that describes no day at all, so the end
        // moves with it rather than the page silently doing nothing all week.
        schedule.endMinute = max(
            schedule.endMinute,
            minute + UsageWindowPreferencesDefaults.minimumWorkdayMinutes
        )
        UsageWindowSettings.shared.schedule = schedule
    }

    @objc private func endChanged(_ sender: ThemedPopUp) {
        guard let minute = sender.selectedItem?.representedValue as? Int else { return }
        var schedule = UsageWindowSettings.shared.schedule
        schedule.endMinute = minute
        schedule.startMinute = min(
            schedule.startMinute,
            minute - UsageWindowPreferencesDefaults.minimumWorkdayMinutes
        )
        UsageWindowSettings.shared.schedule = schedule
    }

    @objc private func daysChanged(_ sender: ThemedPopUp) {
        guard let days = sender.selectedItem?.representedValue as? Set<Int> else { return }
        var schedule = UsageWindowSettings.shared.schedule
        schedule.weekdays = days
        UsageWindowSettings.shared.schedule = schedule
    }

    @objc private func accountChanged(_ sender: ThemedToggle) {
        guard let raw = sender.identifier?.rawValue,
              let id = AccountID(rawValue: raw) else { return }
        UsageWindowSettings.shared.setEnabled(sender.state == .on, for: id)
    }

    @objc private func pokeNowClicked(_ sender: ThemedButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = AccountID(rawValue: raw),
              let account = accounts.first(where: { $0.id == id })
        else { return }

        UsageWindowPoker.shared.pokeNow(account: account)
        refreshAfterPoke(UsageWindowPokeDidChange(accountIDs: [id]))
    }

    // MARK: - Scaling Evidence

    /// Stress-fixture observability: cheap row identities versus live AppKit cells.
    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    func scrollAccountToVisibleForTesting(_ accountID: AccountID) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }),
              let row = presentationRows.firstIndex(where: {
                  if case .account(let index) = $0 { index == accountIndex } else { false }
              }) else { return }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
    }
}

// MARK: - Virtualized Page

extension UsageWindowPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("UsageWindowSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(forRowAt: tableRow),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .explanation:
            return SettingsUI.note(UsageWindowStrings.explanation)
        case .diagram:
            return diagramSection()
        case .schedule:
            return scheduleSection()
        case .scheduledSend:
            return scheduledSendSection()
        case .limitRecovery:
            return limitRecoverySection()
        case .curfew:
            return curfewSection()
        case .accountsCaption:
            return SettingsUI.caption(UsageWindowStrings.accountsCaption)
        case .noAccounts:
            return SettingsUI.fullRow(SettingsUI.note(UsageWindowStrings.noAccounts))
        case .account(let index):
            guard accounts.indices.contains(index) else { return NSView() }
            return accountRow(for: accounts[index])
        case .ledgerCaption:
            return SettingsUI.caption(UsageWindowStrings.ledgerCaption)
        case .ledger(let index):
            guard records.indices.contains(index) else { return NSView() }
            return ledgerRow(for: records[index])
        case .footnote:
            return SettingsUI.note(UsageWindowStrings.footnote)
        }
    }

    private func updateCardDecorations() {
        var accountBounds: (first: Int, last: Int)?
        var ledgerBounds: (first: Int, last: Int)?
        for (index, row) in presentationRows.enumerated() {
            switch row {
            case .noAccounts, .account:
                if var bounds = accountBounds {
                    bounds.last = index
                    accountBounds = bounds
                } else {
                    accountBounds = (index, index)
                }
            case .ledger:
                if var bounds = ledgerBounds {
                    bounds.last = index
                    ledgerBounds = bounds
                } else {
                    ledgerBounds = (index, index)
                }
            default:
                break
            }
        }

        tableView.cardDecorations = [accountBounds, ledgerBounds].compactMap { bounds in
            bounds.map { ThemedTableCardDecoration(rows: $0.first ... $0.last) }
        }
    }

    private func topInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .noAccounts, .account, .ledger:
            return 0
        default:
            return Design.Spacing.large
        }
    }

    private func bottomInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .accountsCaption, .ledgerCaption:
            return Design.Spacing.small
        case .footnote:
            return Design.Spacing.large
        default:
            return 0
        }
    }
}

// MARK: - Text Editing

extension UsageWindowPreferencesViewController: NSTextFieldDelegate {

    /// A field that is left settles the message; so does leaving the page, since ending editing
    /// is what removing the field produces. Between them, no path out of this row can lose what
    /// was typed into it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === windDownField else { return }
        commitWindDownText()
        guard hasDeferredCurfewRefresh else { return }
        hasDeferredCurfewRefresh = false
        reloadRows { if case .curfew = $0 { true } else { false } }
    }
}

// MARK: - Usage Window Preferences Defaults

enum UsageWindowPreferencesDefaults {
    /// The times offered for the start and the end of a working day, in half hours.
    static let startRange = stride(from: 4 * 60, through: 13 * 60, by: 30)
    static let endRange = stride(from: 12 * 60, through: 23 * 60 + 30, by: 30)

    /// The shortest day the schedule will describe. Below this the arithmetic still works and the
    /// picture stops meaning anything.
    static let minimumWorkdayMinutes = 120

    static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    static let shownRecords = 8

    static let estimatedRowHeight: CGFloat = 72

    static let boundarySeparator = ", "
}

// MARK: - Usage Window Strings

private enum UsageWindowStrings {
    static var scheduledSendCaption: String { L10n.string("Scheduled sends") }
    static var scheduledSendTitle: String {
        L10n.string("If the window has not reset")
    }

    static var limitRecoveryCaption: String { L10n.string("Limit recovery") }
    static var limitRecoveryTitle: String {
        L10n.string("When a session hits its usage limit")
    }

    static var title: String { L10n.string("Usage Windows") }

    static var summary: String {
        L10n.string("Open the day's window when your day starts, not when you get to it.")
    }

    static var explanation: String {
        L10n.string("""
            A usage window opens with the first message you send and resets a fixed time later, \
            so where its boundaries fall is decided by when you happened to start. Threading can \
            send one very small message earlier, on the days you choose, to put those boundaries \
            where your working day can use them.
            """)
    }

    static var footnote: String {
        L10n.string("""
            This raises no limit. The same window still holds the same allowance, and the weekly \
            cap above it does not move at all: an extra window pulled into the day is a week \
            spent faster, which is why the poke stands down when the weekly limit is running \
            ahead of the clock. It never fires while a window is already open, while a session \
            is busy, or more than three times a day. Offered for Claude only, because Claude is \
            the runtime whose short window has been measured to open on the first message rather \
            than slide continuously, and there is nothing to move on a window that slides.
            """)
    }

    static var scheduleCaption: String { L10n.string("Schedule") }
    static var accountsCaption: String { L10n.string("Accounts") }
    static var ledgerCaption: String { L10n.string("Recent pokes") }

    static var enabledTitle: String { L10n.string("Open a window before I start") }
    static var enabledSubtitle: String {
        L10n.string("Runs on the days below, for the accounts you allow.")
    }

    static var startTitle: String { L10n.string("I start at") }
    static var endTitle: String { L10n.string("I stop at") }
    static var daysTitle: String { L10n.string("Days") }
    static var weekdays: String { L10n.string("Weekdays") }
    static var everyDay: String { L10n.string("Every day") }

    static var planTitle: String { L10n.string("Today's plan") }

    static func plan(_ pokeTime: String, _ boundaries: String) -> String {
        L10n.format("Opens at %@. Windows then start at %@.", pokeTime, boundaries)
    }

    static func burnMeasured(_ burn: String, _ lead: String) -> String {
        L10n.format(
            "Measured from this account: about %@ of work spends a window, so the window opens %@ before you start.",
            burn,
            lead
        )
    }

    static func burnAssumed(_ burn: String, _ lead: String) -> String {
        L10n.format(
            "No window has been watched being spent on this account yet, so this assumes %@ of work per window and opens %@ early. The lead is re-derived once there is a measurement.",
            burn,
            lead
        )
    }

    static var noAccounts: String {
        L10n.string("No login was found on a runtime whose window can be opened this way.")
    }

    static var pokeNow: String { L10n.string("Poke now") }
    static var readyToPoke: String { L10n.string("Ready to open a window.") }

    static var holdDisabled: String { L10n.string("Not enabled for this account.") }
    static var holdNotToday: String { L10n.string("Not one of today's scheduled days.") }
    static var holdUsageUnknown: String {
        L10n.string("Waiting for a usage reading before deciding anything.")
    }
    static var holdSettling: String { L10n.string("A poke just ran; waiting for the reading.") }
    static var holdWorking: String {
        L10n.string("A session is busy, so its next message opens the window anyway.")
    }
    static var holdNeverExhausts: String {
        L10n.string("This account never reaches its short limit, so moving it would gain nothing.")
    }
    static var holdTailTooShort: String {
        L10n.string("Too little of the working day is left to spend a fresh window.")
    }

    static func holdDailyLimit(_ count: Int) -> String {
        L10n.format("Already opened %lld today.", Int64(count))
    }

    static func holdWindowOpen(_ time: String, _ remaining: String) -> String {
        L10n.format("A window is open until %@, %@ from now.", time, remaining)
    }

    static func holdBeforePokeTime(_ time: String) -> String {
        L10n.format("Waiting until %@.", time)
    }

    static func holdQuietHours(_ time: String) -> String {
        L10n.format("Standing down for quiet hours until %@.", time)
    }

    static func holdWeeklyAheadOfPace(_ percent: Int) -> String {
        L10n.format("Standing down: the weekly limit is %lld%% spent, ahead of the clock.", Int64(percent))
    }

    static func recordOpened(_ when: String, _ account: String) -> String {
        L10n.format("Opened a window at %@ · %@", when, account)
    }

    static func recordFailed(_ when: String, _ account: String) -> String {
        L10n.format("Failed at %@ · %@", when, account)
    }
}

// MARK: - Curfew Settings Defaults

enum CurfewSettingsDefaults {

    /// The whole day in half hours. A nightly window is as legitimately 23:30 to 07:00 as it is
    /// 04:00 to 08:00, so neither end is bounded the way the working day's two are.
    static let quietHoursRange = stride(from: 0, through: 23 * 60 + 30, by: 30)

    /// Where the give-up choice's two rows sit, so the popup and the write agree on one order.
    static let notifyIndex = 0
    static let stopsAgentIndex = 1

    /// The margins are stored in seconds and offered in minutes.
    static let secondsPerMinute: TimeInterval = 60

    /// What ends the "Tonight" line, whose clauses are joined by
    /// `CurfewDefaults.receiptSeparator` — a ledger of clauses, closed as a sentence.
    static let sentenceTerminator = "."

    static let wrapUpFieldIdentifier = "settings.curfew.wrap-up-message"
}

// MARK: - Curfew Settings Strings

private enum CurfewSettingsStrings {

    static var caption: String { L10n.string("Quiet Hours & Curfews") }

    static var explanation: String {
        L10n.string("""
            A curfew ends a session's spending at a time you choose — from the composer when you \
            start a session, or from a session's menu. Before it, Threading asks the agent to \
            wrap up; at the time it stops sending on its own; after a grace it interrupts \
            whatever is still running. You keep the conversation and can continue it by hand. \
            Quiet hours are a curfew every session follows daily unless it is exempt.
            """)
    }

    static var windDownTitle: String { L10n.string("Send a wrap-up before the curfew") }
    static var graceTitle: String { L10n.string("Interrupt a turn still running") }
    static var wrapUpTitle: String { L10n.string("Wrap-up message") }

    static var placeholderNote: String {
        L10n.format("%@ is replaced by the curfew time.", CurfewDefaults.timePlaceholder)
    }

    static var giveUpTitle: String {
        L10n.format(
            "If it keeps working after %lld interrupts",
            Int64(CurfewDefaults.maximumInterrupts)
        )
    }

    static var giveUpSubtitle: String {
        L10n.string("Stopping keeps the conversation on screen; Resume Session brings it back.")
    }

    static var giveUpChoices: [String] {
        [L10n.string("Notify me"), L10n.string("Stop the agent")]
    }

    static var quietHoursTitle: String { L10n.string("Quiet hours") }
    static var quietHoursSubtitle: String {
        L10n.string("Every session is held between these times unless it is exempt.")
    }

    static var fromTitle: String { L10n.string("From") }
    static var toTitle: String { L10n.string("To") }

    static var tonightTitle: String { L10n.string("Tonight") }

    /// "Off" rather than "0 minutes before": no wrap-up at all is a different answer from one
    /// sent at the deadline, and the popup should not make them look like the same scale.
    static func windDownChoice(_ margin: TimeInterval?) -> String {
        guard let margin else { return L10n.string("Off") }
        return L10n.format(
            "%lld minutes before",
            Int64(margin / CurfewSettingsDefaults.secondsPerMinute)
        )
    }

    static func graceChoice(_ grace: TimeInterval?) -> String {
        guard let grace else { return L10n.string("Never") }
        guard grace > 0 else { return L10n.string("At the curfew") }
        return L10n.format(
            "%lld minutes after",
            Int64(grace / CurfewSettingsDefaults.secondsPerMinute)
        )
    }
}

// MARK: - Curfew Settings Sentence

/// What tonight's settings actually do, as one line of times.
///
/// Pure, and separate from the page for the reason `CurfewReceiptWords` is separate from the
/// engine: this is the only part of the section that can be *wrong* rather than merely ugly — it
/// states margins as clock times, across a midnight and across the two nights a year that are
/// not 24 hours long — and it is asserted here on its answer rather than through a laid-out view.
enum CurfewSettingsSentence {

    /// The line under "Tonight".
    ///
    /// With quiet hours on it is the standing window's own ladder, in the order it happens:
    /// *"Wrap-up at 03:50 · held from 04:00 · a turn still running at 04:05 is interrupted ·
    /// lifts 08:00."* With them off there is no nightly deadline to name, so it says what the
    /// same margins would do to a curfew set on one session — which is the half of the feature
    /// that is still switched on.
    static func tonight(
        preferences: CurfewPreferences,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        // The window being served tonight is the one in progress if there is one — asked at
        // 05:00 inside a 04:00–08:00 window, "Tonight" means the hold the reader is standing in,
        // not tomorrow's.
        guard let window = preferences.quietHours.window(containing: now, calendar: calendar)
                ?? preferences.quietHours.nextWindow(after: now, calendar: calendar) else {
            return withoutQuietHours(preferences, locale: locale)
        }

        let deadline = window.start
        var clauses: [String] = []

        if let margin = preferences.windDownMargin {
            clauses.append(L10n.format(
                "Wrap-up at %@",
                time(deadline.addingTimeInterval(-margin), locale),
                locale: locale
            ))
            clauses.append(L10n.format("held from %@", time(deadline, locale), locale: locale))
        } else {
            // The hold leads the sentence when nothing precedes it, which is a different string
            // rather than a capitalized one: where a language capitalizes is its own business.
            clauses.append(L10n.format("Held from %@", time(deadline, locale), locale: locale))
        }

        clauses.append(interruptClause(preferences, deadline: deadline, locale: locale))
        clauses.append(L10n.format("lifts %@", time(window.end, locale), locale: locale))

        return clauses.joined(separator: CurfewDefaults.receiptSeparator)
            + CurfewSettingsDefaults.sentenceTerminator
    }

    // MARK: - Private Methods

    /// What happens to a turn that is still running when the deadline arrives.
    private static func interruptClause(
        _ preferences: CurfewPreferences,
        deadline: Date,
        locale: Locale
    ) -> String {
        guard let grace = preferences.grace else {
            // The hold still applies; nothing is typed. Said outright, because a ladder that
            // stops one rung early is exactly the thing a reader would otherwise assume.
            return L10n.string("nothing is interrupted")
        }

        let clause = L10n.format(
            "a turn still running at %@ is interrupted",
            time(deadline.addingTimeInterval(grace), locale),
            locale: locale
        )
        guard preferences.stopsAgentOnGiveUp else { return clause }
        return L10n.format("%@, then the agent is stopped", clause, locale: locale)
    }

    /// The same margins with no standing window to hang them on.
    private static func withoutQuietHours(
        _ preferences: CurfewPreferences,
        locale: Locale
    ) -> String {
        let wrapUp: String
        if let margin = preferences.windDownMargin {
            wrapUp = L10n.format(
                "sends a wrap-up %lld minutes before",
                Int64(margin / CurfewSettingsDefaults.secondsPerMinute),
                locale: locale
            )
        } else {
            wrapUp = L10n.string("sends no wrap-up")
        }

        var interrupt: String
        if let grace = preferences.grace {
            interrupt = grace > 0
                ? L10n.format(
                    "interrupts a turn still running %lld minutes after",
                    Int64(grace / CurfewSettingsDefaults.secondsPerMinute),
                    locale: locale
                )
                : L10n.string("interrupts a turn still running at the curfew")
            if preferences.stopsAgentOnGiveUp {
                interrupt = L10n.format("%@, then stops the agent", interrupt, locale: locale)
            }
        } else {
            interrupt = L10n.string("never interrupts a turn still running")
        }

        return L10n.format(
            "Quiet hours are off. A curfew you set on a session %1$@ and %2$@.",
            wrapUp,
            interrupt,
            locale: locale
        )
    }

    /// One clock reading, in the same words every other curfew surface uses.
    private static func time(_ date: Date, _ locale: Locale) -> String {
        ScheduledTimePresets.time(date, locale: locale)
    }
}
