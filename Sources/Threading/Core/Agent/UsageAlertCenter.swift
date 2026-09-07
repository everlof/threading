import Foundation
@preconcurrency import UserNotifications

// MARK: - Usage Alert Center

/// Posts a notification when one of the user's own limits crosses a line they asked to be told
/// about, and withdraws it when the window it described turns over.
///
/// **Deliberately not an `AttentionAlert`.** That family is session-scoped, and every case in it
/// is a change the user can act on *in that session* — answer this, read that — which is why a
/// provider limit stop posts nothing at all. A usage alert is account-scoped, explicitly
/// subscribed to by the rule that fires it, and actionable at the account level: slow down,
/// switch login, change model. It therefore has its own switch (`CustomLimitSettings.
/// alertsEnabled`) rather than a fourth case shoehorned into the session family, and the
/// session-attention master switch does not gate it — someone who silenced their sessions has not
/// thereby said they no longer want to hear about their quota.
///
/// **Two locks against acting under a test bundle**, the convention `UsageWindowPoker` set: the
/// stores redirect to a scratch suite, and this refuses to start. One guard for something that
/// posts to the user's real Notification Center is not enough.
///
/// Evaluation is edge-driven and never polled. A fixed cap moves only when the reading does, so
/// the events below are the complete set of moments the answer can change; the armed wakeup the
/// draft describes belongs to the pace-share metric, whose bound rises with the clock, and
/// arrives with it.
@MainActor
final class UsageAlertCenter {

    // MARK: - Singleton

    static let shared = UsageAlertCenter()

    // MARK: - Properties

    private let ledger: UsageAlertLedger
    private let observations = AppEventObservations()

    /// Set once `start()` runs. Everything reachable from elsewhere no-ops before it, which is
    /// what keeps `UNUserNotificationCenter` and its permission prompt out of the test host.
    ///
    /// Readable so the refusal is a *test* rather than the developer's luck: a lock nothing
    /// asserts on is a lock somebody removes while tidying.
    private(set) var isStarted = false

    // MARK: - Initialization

    init(ledger: UsageAlertLedger? = nil) {
        self.ledger = ledger ?? .shared
    }

    // MARK: - Public Methods

    /// Starts observing. Called once from the real app startup, never under tests.
    func start() {
        guard NSClassFromString("XCTestCase") == nil, !isStarted else { return }
        isStarted = true

        // A new reading is the one moment a fixed cap's answer can have moved.
        observations.observe(AccountUsageDidChange.self) { [weak self] event in
            Task { @MainActor in self?.evaluate(accountID: event.accountID) }
        }

        // A rule created now must be able to speak before the next reading arrives — someone who
        // has just asked to be told at 50% on an account already at 61% is watching the page to
        // see whether it did anything.
        observations.observe(CustomLimitsDidChange.self) { [weak self] _ in
            Task { @MainActor in self?.evaluateAll() }
        }

        // Limits live in the account-preferences blob, so an edit there arrives on this event as
        // well. Re-evaluating is idempotent and costs one pass over a user-fixed, small rule list,
        // which is cheaper than a second event that could be forgotten at one of the call sites.
        observations.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            Task { @MainActor in self?.evaluateAll() }
        }

        evaluateAll()
    }

    /// Re-checks every account. Also what an alerts-off switch calls, so what it described stops
    /// standing on screen.
    func evaluateAll(now: Date = Date()) {
        guard isStarted else { return }

        // Switched off takes down what it said: an off switch that leaves its traces behind is
        // not off. The **ledger survives**, deliberately — clearing it would make switching back
        // on inside the same window announce every line already crossed, in one burst, which is
        // the alert fatigue this feature is supposed to be careful about. Re-arming is the
        // window's job, not the switch's.
        guard CustomLimitSettings.shared.alertsEnabled else {
            withdraw(keys: ledger.keys)
            return
        }

        for account in Self.alertableAccounts() {
            evaluate(accountID: account.id, now: now)
        }
    }

    /// One account's rules against its last reading.
    ///
    /// Internal rather than private so a test can drive one evaluation at a chosen moment against
    /// a fixture, instead of waiting for a reading to arrive.
    func evaluate(accountID: AccountID, now: Date = Date()) {
        guard isStarted, CustomLimitSettings.shared.alertsEnabled else { return }
        guard let account = AgentAccountDiscovery.account(
            for: accountID.provider,
            handle: accountID.handle
        ) else { return }

        let rules = CustomLimitSettings.shared.rules(for: accountID)
        let usage = AccountUsageService.shared.usage(for: account)

        // Pruning first is what makes a reset re-arm: the record saying "50% already announced"
        // belongs to the turn of the window that has just ended, and evaluating against it would
        // keep this instance silent for a line it has not crossed yet.
        withdraw(keys: ledger.prune(
            accountID: accountID,
            liveRuleIDs: Set(rules.map(\.id)),
            now: now
        ))

        let evaluations = CustomLimitEvaluator.evaluate(CustomLimitEvaluator.Input(
            rules: rules,
            usage: usage,
            fired: ledger.fired(for: accountID),
            history: Self.history(for: account, rules: rules),
            now: now
        ))

        for evaluation in evaluations where evaluation.wantsNotification {
            post(evaluation, account: account, usage: usage)
            ledger.record(evaluation, for: accountID)
            NotificationCenter.default.post(CustomLimitDidFire(accountID: accountID))
        }
    }

    /// Every account a rule could apply to: each provider's discovered logins, switched off or
    /// not. A login taken out of use still has a quota, and a limit the user drew on it is still
    /// theirs — what "disabled" changes is where an account is *offered*.
    static func alertableAccounts() -> [AgentAccount] {
        AgentKind.allCases
            .filter(\.supportsAccounts)
            .flatMap { AgentAccountDiscovery.allAccounts(for: $0) }
    }

    /// The sparse history the synthetic-window rules on this account need, and nothing else.
    ///
    /// Bounded by the rules' own windows rather than by everything the store holds: a rule names
    /// one window, and reading the rest would be work proportional to the account's whole history
    /// on a path that runs on every reading.
    static func history(
        for account: AgentAccount,
        rules: [CustomLimit]
    ) -> [String: [UsageSample]] {
        var result: [String: [UsageSample]] = [:]
        for windowID in Set(rules.filter { $0.metric == .syntheticWindow }.map(\.windowID)) {
            result[windowID] = UsageHistoryStore.shared.samples(
                for: account,
                windowID: windowID
            )
        }
        return result
    }

    // MARK: - Private Methods

    private func post(
        _ evaluation: CustomLimitEvaluation,
        account: AgentAccount,
        usage: AccountUsage?
    ) {
        let window = usage?.allWindows.first { $0.id == evaluation.rule.windowID }
        let windowName = window?.label
            ?? UsageDefaults.label(forWindowID: evaluation.rule.windowID)

        let content = UNMutableNotificationContent()
        content.title = account.presentation(in: .notifications).visibleName
        content.subtitle = account.provider.displayName
        content.body = CustomLimitReceipt.announcement(
            for: evaluation,
            windowName: windowName
        )
        content.sound = nil
        content.userInfo = [UsageAlertDefaults.accountKey: account.id.rawValue]
        content.threadIdentifier = UsageAlertDefaults.threadIdentifier

        // The identifier is the rule's turn of the window, so a later line on the same rule
        // *replaces* the earlier banner rather than stacking beneath it. "Every 10%" on a busy
        // account is the user's explicit choice; five banners saying the same thing about the
        // same window is not what they chose.
        let key = UsageAlertLedger.key(
            accountID: account.id.rawValue,
            ruleID: evaluation.rule.id,
            instance: evaluation.instance
        )
        let request = UNNotificationRequest(
            identifier: key,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Asked on the first line a rule crosses rather than when the rule is created, so
                // the permission dialog appears beside a notification with a reason to exist.
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            default:
                center.add(request)
            }
        }
    }

    /// Takes down the banners for a set of ledger keys.
    ///
    /// The ledger key **is** the notification's request identifier, which is what lets a relaunch
    /// withdraw what the run before it delivered: an in-memory set of delivered ids would have
    /// left last night's "weekly reached 50%" sitting in Notification Center over this morning's
    /// fresh window. Withdrawing an identifier that was never delivered is a no-op, so the
    /// bookkeeping does not have to be exact in the other direction either.
    private func withdraw(keys: [String]) {
        guard !keys.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: keys)
        center.removePendingNotificationRequests(withIdentifiers: keys)
    }
}

// MARK: - Usage Alert Defaults

enum UsageAlertDefaults {

    /// The `userInfo` key naming the account an alert is about.
    static let accountKey = "usageAlertAccountID"

    /// Groups every usage alert together in Notification Center, apart from the session banners.
    static let threadIdentifier = "codes.threading.usage-limits"
}
