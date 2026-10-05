import Foundation

// MARK: - Event

/// A Claude login's keychain item answered differently from the last read — newly refusing,
/// newly granted, or gone. Posted only on a change, from whichever thread did the read.
struct ClaudeKeychainAccessDidChange: AppEvent {
    static let name = Notification.Name("ThreadingClaudeKeychainAccessDidChange")
    let configPath: String
}

// MARK: - Claude Keychain Access

/// The one host operation that asks macOS for Threading's standing access to Claude logins'
/// keychain items, and the one answer to "should this surface offer to ask".
///
/// It exists because the grant used to have exactly one door: flipping the Privacy page's
/// live-usage switch on, which prompted for every login that existed *at that moment*. A login
/// added afterwards — through Add Login or a terminal — was never offered the prompt, its silent
/// reads failed closed as designed, and its usage froze on the snapshot the CLI keeps in
/// `.claude.json` while every surface drew it as an ordinary reading. The remedy the page
/// offered was "toggle off and on". Now every place that shows the symptom offers the cure:
/// the usage popover, the fleet, the Privacy row, the command palette, and the end of Add Login.
///
/// **The no-surprise-prompt rule is unchanged.** Background reads still never prompt
/// (`ClaudeKeychainCredentials.token`). Every call into `requestAccess` here is the direct
/// consequence of a click on a control that said it would ask, or of the user finishing a
/// sign-in they started, with the opt-in already on.
@MainActor
final class ClaudeKeychainAccess {

    /// How one request went, per login.
    struct Outcome: Equatable {
        /// Logins this request's prompt opened to Threading. A login that already admitted it
        /// is not listed: nothing changed for it, and its reading needs no early re-read.
        var granted: [AgentAccount] = []
        /// Logins that still refuse — the prompt was declined or could not be shown.
        var stillWaiting: [AgentAccount] = []
    }

    typealias Probe = @Sendable (String) -> ClaudeKeychainCredentials.Availability
    typealias Grant = @Sendable (String) -> Bool

    // MARK: - Properties

    static let shared = ClaudeKeychainAccess()

    private let settings: AppSettings
    private let observedAvailability: (String) -> ClaudeKeychainCredentials.Availability?
    private let probe: Probe
    private let grant: Grant
    private let claudeAccounts: () -> [AgentAccount]
    private let refreshUsage: (AgentAccount) -> Void

    /// Config paths with a request on its way. A second click while macOS is still showing the
    /// first prompt joins nothing and asks nothing.
    private var requesting: Set<String> = []

    // MARK: - Initialization

    init(
        settings: AppSettings = .shared,
        observedAvailability: @escaping (String) -> ClaudeKeychainCredentials.Availability? = {
            ClaudeKeychainCredentials.observedAvailability(forConfigPath: $0)
        },
        probe: @escaping Probe = { ClaudeKeychainCredentials.availability(forConfigPath: $0) },
        grant: @escaping Grant = { ClaudeKeychainCredentials.requestAccess(forConfigPath: $0) },
        claudeAccounts: @escaping () -> [AgentAccount] = {
            AgentAccountDiscovery.accounts(for: .claude)
        },
        refreshUsage: @escaping (AgentAccount) -> Void = {
            AccountUsageService.shared.refreshAfterCredentialChange($0)
        }
    ) {
        self.settings = settings
        self.observedAvailability = observedAvailability
        self.probe = probe
        self.grant = grant
        self.claudeAccounts = claudeAccounts
        self.refreshUsage = refreshUsage
    }

    // MARK: - Public Methods

    /// Whether a surface drawing this login's usage should offer **Allow…**: the user asked for
    /// live usage, and the last read of this login's item was refused. Only the Claude usage
    /// fetcher reads these items, so no other runtime's login can ever answer yes — the rule
    /// needs no provider check of its own.
    func offersGrant(for account: AgentAccount) -> Bool {
        settings.readsClaudeLoginFromKeychain
            && observedAvailability(account.configPath) == .needsGrant
            && !requesting.contains(account.configPath)
    }

    /// Whether the palette command has anything it could do right now.
    var isEnabled: Bool { settings.readsClaudeLoginFromKeychain }

    /// Asks macOS for each listed login whose item does not yet admit Threading — one prompt
    /// per login, in order, while the user is looking at the control that said so. A login
    /// already granted, or with no item at all, is probed silently and never prompted.
    ///
    /// Granted logins are re-read at once rather than at the next refresh tick: the reading on
    /// screen is the stale one the user just acted on.
    func requestAccess(
        for accounts: [AgentAccount],
        completion: (@MainActor (Outcome) -> Void)? = nil
    ) {
        let pending = accounts.filter { !requesting.contains($0.configPath) }
        guard !pending.isEmpty else {
            completion?(Outcome())
            return
        }
        pending.forEach { requesting.insert($0.configPath) }
        pending.forEach(announce)

        let probe = self.probe
        let grant = self.grant
        let paths = pending.map(\.configPath)
        Task { [weak self] in
            // Off the main actor: an interactive read blocks for as long as the prompt is up.
            let answered = await Task.detached(priority: .userInitiated) {
                var granted: Set<String> = []
                var waiting: Set<String> = []
                for path in paths {
                    switch probe(path) {
                    case .granted, .missing: break
                    case .needsGrant:
                        if grant(path) { granted.insert(path) } else { waiting.insert(path) }
                    }
                }
                return (granted: granted, waiting: waiting)
            }.value
            self?.finish(pending, answered: answered, completion: completion)
        }
    }

    /// Every discovered Claude login — the palette command's and the Privacy page's scope.
    func requestAccessForAllLogins(completion: (@MainActor (Outcome) -> Void)? = nil) {
        requestAccess(for: claudeAccounts(), completion: completion)
    }

    /// The end of a verified Add Login: the one moment a keychain prompt is expected without a
    /// button, because the user has just finished signing in and the CLI has just written the
    /// item. Skipped entirely when the user has not opted in to keychain reads.
    func requestAccessAfterSignIn(_ account: AgentAccount) {
        guard settings.readsClaudeLoginFromKeychain else { return }
        requestAccess(for: [account])
    }

    // MARK: - Private Methods

    private func finish(
        _ accounts: [AgentAccount],
        answered: (granted: Set<String>, waiting: Set<String>),
        completion: (@MainActor (Outcome) -> Void)?
    ) {
        var outcome = Outcome()
        for account in accounts {
            requesting.remove(account.configPath)
            if answered.granted.contains(account.configPath) {
                outcome.granted.append(account)
                refreshUsage(account)
            } else if answered.waiting.contains(account.configPath) {
                outcome.stillWaiting.append(account)
            }
            announce(account)
        }
        completion?(outcome)
    }

    /// The in-flight set is part of what `offersGrant` answers, so entering and leaving it is a
    /// change every surface showing the button has to hear about.
    private func announce(_ account: AgentAccount) {
        NotificationCenter.default.post(
            ClaudeKeychainAccessDidChange(configPath: account.configPath)
        )
    }
}
