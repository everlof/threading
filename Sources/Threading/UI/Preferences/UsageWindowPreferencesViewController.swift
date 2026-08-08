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

    // MARK: - Properties

    private let appEvents = AppEventObservations()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Three sources move this page: the poke itself, the schedule behind it, and the usage
        // reading every hold reason is computed from.
        appEvents.observe(UsageWindowPokeDidChange.self) { [weak self] _ in self?.rebuild() }
        appEvents.observe(UsageWindowScheduleDidChange.self) { [weak self] _ in self?.rebuild() }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in self?.rebuild() }

        // Built on load rather than only on appearance, so the page has its content the moment
        // it has a view. The observers above keep it current from there.
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()

        // The page's whole subject is the state of a window, so it asks for a fresh reading on
        // the way in rather than drawing whatever was last cached.
        for account in UsageWindowPoker.eligibleAccounts {
            AccountUsageService.shared.refresh(account)
        }
    }

    // MARK: - Build

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        var sections: [NSView] = [
            SettingsUI.note(UsageWindowStrings.explanation),
            diagramSection(),
            scheduleSection()
        ]

        sections.append(scheduledSendSection())
        sections.append(limitRecoverySection())
        sections.append(accountsSection())
        if let ledger = ledgerSection() { sections.append(ledger) }
        sections.append(SettingsUI.note(UsageWindowStrings.footnote))

        let page = SettingsUI.page(
            title: UsageWindowStrings.title,
            summary: UsageWindowStrings.summary,
            sections: sections
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
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
        rebuild()
    }

    // MARK: - Limit Recovery

    /// What happens when a running session is refused over its account's usage limit.
    ///
    /// On this page for the scheduled-send rule's reason: the whole question is about these
    /// windows — the recovery schedules its continuation against one — and the default does
    /// nothing but mark the session, so the automatic half is chosen here or not at all. See
    /// `docs/architecture/limit-recovery.md`.
    private func limitRecoverySection() -> NSView {
        let popUp = SettingsUI.popUp(target: self, action: #selector(limitRecoveryChanged))
        for policy in LimitRecoveryPolicy.allCases {
            popUp.addItem(ThemedMenuItem(title: policy.title, representedValue: policy.rawValue))
        }
        popUp.selectItem(
            at: LimitRecoveryPolicy.allCases.firstIndex(of: LimitRecoveryPolicy.current) ?? 0
        )

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
        rebuild()
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

    private func accountsSection() -> NSView {
        let accounts = UsageWindowPoker.eligibleAccounts

        guard !accounts.isEmpty else {
            return SettingsUI.section(
                UsageWindowStrings.accountsCaption,
                SettingsCard(rows: [
                    SettingsUI.fullRow(SettingsUI.note(UsageWindowStrings.noAccounts))
                ])
            )
        }

        let rows = accounts.map { account in
            SettingsUI.row(
                title: AccountName.display(for: account),
                subtitle: state(of: account),
                control: accountControls(for: account),
                localizes: false
            )
        }

        return SettingsUI.section(UsageWindowStrings.accountsCaption, SettingsCard(rows: rows))
    }

    /// Try-it-now beside the switch. A feature whose whole promise lands at 07:00 tomorrow is one
    /// nobody can tell is working, so the button spends one message to prove it.
    private func accountControls(for account: AgentAccount) -> NSView {
        let poke = SettingsUI.button(
            UsageWindowStrings.pokeNow,
            target: self,
            action: #selector(pokeNowClicked)
        )
        poke.identifier = NSUserInterfaceItemIdentifier(account.id.rawValue)
        poke.isEnabled = canPokeNow(account)

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
    private func state(of account: AgentAccount) -> String {
        switch UsageWindowPoker.shared.decide(account: account) {
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
        }
    }

    private func canPokeNow(_ account: AgentAccount) -> Bool {
        switch UsageWindowPoker.shared.decide(account: account) {
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

    /// What the poke has actually done, most recent first. Absent until it has done something,
    /// because an empty card claiming to be a history is noise.
    private func ledgerSection() -> NSView? {
        let records = UsageWindowPoker.shared.records.suffix(
            UsageWindowPreferencesDefaults.shownRecords
        ).reversed()
        guard !records.isEmpty else { return nil }

        let rows = records.map { record in
            SettingsUI.row(
                title: recordTitle(record),
                subtitle: record.detail,
                localizes: false
            )
        }

        return SettingsUI.section(UsageWindowStrings.ledgerCaption, SettingsCard(rows: rows))
    }

    private func recordTitle(_ record: UsageWindowPoker.Record) -> String {
        let name = AccountID(rawValue: record.accountID)
            .flatMap { id in
                UsageWindowPoker.eligibleAccounts.first { $0.id == id }
            }
            .map { AccountName.display(for: $0) } ?? record.accountID

        let when = UsageFormat.absolute(record.at)

        return record.outcome == .opened
            ? UsageWindowStrings.recordOpened(when, name)
            : UsageWindowStrings.recordFailed(when, name)
    }

    // MARK: - Derived Values

    /// The account the diagram is drawn for: the first enabled one, else the first there is.
    private var subjectAccount: AgentAccount? {
        let accounts = UsageWindowPoker.eligibleAccounts
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
              let account = UsageWindowPoker.eligibleAccounts.first(where: { $0.id == id })
        else { return }

        UsageWindowPoker.shared.pokeNow(account: account)
        rebuild()
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
