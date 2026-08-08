import Foundation

// MARK: - Usage Window Poker

/// Opens an account's usage window at the moment the user's day is planned around, and keeps a
/// record of every time it did.
///
/// The rules are in `UsageWindowPlan`, which is pure. This is the part with a clock, a process and
/// the user's real limits attached to it, so it is deliberately thin: gather the inputs, ask,
/// obey, write down what happened.
///
/// **Why this exists in the app rather than as a cron line.** Claude Code ships schedulers of its
/// own, and a 07:00 job that sends "." is three minutes of work. What a cron line cannot do is
/// look first. It fires whether or not a window is already open, so on every day the user
/// happened to start early it spends a message to achieve nothing, and it can never notice that
/// the window it opened yesterday is still open today. Every rule worth having is a rule about
/// state that only the app holds: the reading, the burn history, whether a session is busy right
/// now. That is the justification for the feature, and also its whole design.
@MainActor
final class UsageWindowPoker {

    // MARK: - Record

    /// One poke that actually ran. Holds are not recorded — they happen every minute and would
    /// bury the handful of lines that matter; the standing reason is reported live instead.
    struct Record: Codable, Equatable {
        enum Outcome: String, Codable {
            case opened
            case failed
        }

        let at: Date
        let accountID: String
        let outcome: Outcome
        /// One line of context: what the run cost in wall time, or why it failed.
        let detail: String?
    }

    // MARK: - Singleton

    static let shared = UsageWindowPoker()

    // MARK: - Properties

    /// Past pokes, oldest first.
    private(set) var records: [Record] = []

    /// The standing reason each account is not being poked, from the last evaluation. Live only:
    /// it describes this minute, and this minute is not worth a file.
    private(set) var holds: [String: UsageWindowHold] = [:]

    private var lastPoke: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var timer: Timer?

    private let persistence: RecoverableFileStore<[Record]>
    private let observations = AppEventObservations()

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(UsageWindowPokeDefaults.ledgerFileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.records = persistence.load(defaultValue: []).value

        // A schedule edited in Settings should take effect without waiting out a tick: someone
        // who has just turned this on is watching the page to see whether it did anything.
        observations.observe(UsageWindowScheduleDidChange.self) { [weak self] _ in
            self?.evaluate()
        }
    }

    // MARK: - Public Methods

    /// Starts the minute timer. Refuses under a hosted test bundle: `UsageWindowSettings` already
    /// writes to a scratch suite there, and this is the second lock on the same door — a
    /// background process that spends the developer's own weekly limit is not a failure anyone
    /// should be able to reach by running the suite.
    func start() {
        guard NSClassFromString("XCTestCase") == nil, timer == nil else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: UsageWindowDefaults.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // The decision is a clock reading, not a user interaction: it must keep arriving while a
        // menu is open or a sheet is up, which is exactly the case the default mode drops.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Every account the poke could apply to: a login on a runtime whose short window is
    /// anchored. The settings page lists these, enabled or not.
    static var eligibleAccounts: [AgentAccount] {
        AgentKind.allCases
            .filter { $0.supports(.anchoredUsageWindow) }
            .flatMap { AgentAccountDiscovery.accounts(for: $0) }
    }

    /// Why this account is not being poked right now, from the last evaluation.
    func hold(for accountID: AccountID) -> UsageWindowHold? {
        holds[accountID.rawValue]
    }

    /// The most recent poke on this account, whatever came of it.
    func lastRecord(for accountID: AccountID) -> Record? {
        records.last { $0.accountID == accountID.rawValue }
    }

    /// How long this account takes to spend one window, measured from its own history.
    func burn(for account: AgentAccount) -> UsageWindowBurn.Estimate? {
        guard let window = AccountUsageService.shared.usage(for: account)?.anchoredWindow,
              let length = window.windowDuration else { return nil }

        return UsageWindowBurn.estimate(
            from: UsageHistoryStore.shared.samples(for: account, windowID: window.id),
            windowLength: length
        )
    }

    /// Asks the planner about every eligible account and acts on the answer.
    ///
    /// Internal rather than private so a test can drive one tick at a chosen moment instead of
    /// waiting a minute for one.
    func evaluate(now: Date = Date()) {
        var changed = false

        for account in Self.eligibleAccounts {
            let key = account.id.rawValue
            let decision = decide(account: account, now: now)

            switch decision {
            case .poke:
                if holds.removeValue(forKey: key) != nil { changed = true }
                fire(account: account, now: now)
            case .hold(let reason):
                if holds[key] != reason {
                    holds[key] = reason
                    changed = true
                }
            }
        }

        if changed { NotificationCenter.default.post(UsageWindowPokeDidChange()) }
    }

    /// The decision for one account, exposed so the settings page can show today's plan without
    /// waiting for a tick to store one.
    func decide(account: AgentAccount, now: Date = Date()) -> UsageWindowDecision {
        let key = account.id.rawValue

        if inFlight.contains(key) { return .hold(.settling) }
        if let last = lastPoke[key],
           now.timeIntervalSince(last) < UsageWindowDefaults.settleInterval {
            return .hold(.settling)
        }

        let usage = AccountUsageService.shared.usage(for: account)

        return UsageWindowPlan.decide(UsageWindowPlan.Input(
            now: now,
            schedule: UsageWindowSettings.shared.schedule,
            accountID: key,
            burn: burn(for: account)?.burn,
            shortWindow: usage?.anchoredWindow,
            weeklyWindow: usage?.longestWindow,
            isWorking: Self.isWorking(account: account),
            pokesToday: pokes(on: now, accountID: key)
        ))
    }

    /// Fires a poke the rules did not ask for — the settings page's own button, so the feature
    /// can be tried at 3pm rather than trusted until tomorrow morning.
    ///
    /// The daily limit and single-flight still apply. Nothing else does: the point of the button
    /// is to do the thing on purpose.
    func pokeNow(account: AgentAccount) {
        let key = account.id.rawValue
        guard !inFlight.contains(key),
              pokes(on: Date(), accountID: key) < UsageWindowDefaults.dailyLimit else { return }

        fire(account: account, now: Date())
    }

    /// How many pokes this account has run on the calendar day containing `date`.
    func pokes(on date: Date, accountID: String, calendar: Calendar = .current) -> Int {
        records.filter {
            $0.accountID == accountID && calendar.isDate($0.at, inSameDayAs: date)
        }.count
    }

    // MARK: - Private Methods

    /// Whether a session on this account is busy. A busy account opens its own window with
    /// whatever it sends next, so poking it would pay for something that was about to be free.
    private static func isWorking(account: AgentAccount) -> Bool {
        AgentRuntime.shared.liveSessionIDs.contains { sessionID in
            guard let session = ProjectStore.shared.session(withID: sessionID),
                  session.kind == account.provider,
                  AgentAccountDiscovery.account(
                      for: session.kind,
                      handle: session.accountHandle
                  )?.id == account.id
            else { return false }

            return AgentRuntime.shared.activity(sessionID: sessionID) == .working
        }
    }

    private func fire(account: AgentAccount, now: Date) {
        let key = account.id.rawValue
        guard !inFlight.contains(key),
              let plan = AgentLauncher.usageWindowPokePlan(
                  kind: account.provider,
                  account: account
              )
        else { return }

        inFlight.insert(key)
        lastPoke[key] = now

        ThreadingLogger.agent.info(
            "Usage window poke starting for \(key, privacy: .public)"
        )

        Task.detached(priority: .utility) {
            let started = Date()
            let failure = Self.execute(plan)
            let elapsed = Date().timeIntervalSince(started)

            await MainActor.run {
                UsageWindowPoker.shared.finish(
                    accountID: key,
                    account: account,
                    failure: failure,
                    elapsed: elapsed
                )
            }
        }
    }

    private func finish(
        accountID: String,
        account: AgentAccount,
        failure: String?,
        elapsed: TimeInterval
    ) {
        inFlight.remove(accountID)

        append(Record(
            at: Date(),
            accountID: accountID,
            outcome: failure == nil ? .opened : .failed,
            detail: failure ?? UsageWindowPokeDefaults.durationDetail(elapsed)
        ))

        if let failure {
            ThreadingLogger.agent.error(
                "Usage window poke failed for \(accountID, privacy: .public): \(failure, privacy: .public)"
            )
        }

        // Read the window straight back, so the page can show what the poke bought and the next
        // tick decides against fact rather than against a stale reading.
        AccountUsageService.shared.refresh(account, force: true)
        NotificationCenter.default.post(UsageWindowPokeDidChange())
    }

    private func append(_ record: Record) {
        records.append(record)
        records = Array(records.suffix(UsageWindowDefaults.ledgerLimit))
        _ = persistence.save(records)
    }

    /// Runs the poke and returns nil, or one line saying what went wrong.
    ///
    /// `SettingsSearchResearch.execute`'s shape, minus the output: a poke's reply is discarded by
    /// design, so only the exit status is read.
    private nonisolated static func execute(_ plan: AgentLaunchPlan) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = AgentEnvironment.launchEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }

        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + UsageWindowDefaults.pokeTimeout,
            execute: timeout
        )

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        if process.terminationReason == .uncaughtSignal {
            return UsageWindowPokeDefaults.timedOutDetail
        }
        guard process.terminationStatus == 0 else {
            let output = String(data: data.suffix(UsageWindowPokeDefaults.failureExcerptBytes),
                                encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return UsageWindowPokeDefaults.exitDetail(process.terminationStatus, output: output)
        }

        return nil
    }
}

// MARK: - Usage Window Poke Defaults

enum UsageWindowPokeDefaults {
    static let ledgerFileName = "usage-window-pokes.json"

    /// How much of a failing run's output is worth keeping beside the status. A CLI's last line
    /// is usually the whole story; more than this is a stack trace in a settings row.
    static let failureExcerptBytes = 400

    static func durationDetail(_ elapsed: TimeInterval) -> String {
        L10n.format("took %@", UsageFormat.duration(elapsed))
    }

    static var timedOutDetail: String { L10n.string("The poke timed out.") }

    static func exitDetail(_ status: Int32, output: String?) -> String {
        guard let output, !output.isEmpty else {
            return L10n.format("Exited with status %lld.", Int64(status))
        }
        return L10n.format("Exited with status %lld: %@", Int64(status), output)
    }
}
