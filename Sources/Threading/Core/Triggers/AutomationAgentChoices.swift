import Foundation

/// Catalog and sign-in work belongs off the editor's main actor. These two serial workers
/// bound file decoding and CLI children independently, so a slow login probe cannot hold up
/// a model choice. Opening an editor never refreshes a provider's catalog over the network.
struct AutomationAgentCatalog: Sendable {
    let models: [AgentModelOption]
    let defaultModel: String?
}

enum AgentAccountSignInStatus: Sendable, Equatable {
    case signedIn
    case signedOut
    case unavailable
}

struct AutomationAgentChoiceProvider {
    var accounts: @MainActor (AgentKind) async -> [AgentAccount]
    var catalog: @Sendable (AgentKind, AgentAccount?) async -> AutomationAgentCatalog
    var signInStatus: @Sendable (AgentAccount, String) async -> AgentAccountSignInStatus
    var authenticationRefused: @MainActor (AgentAccount) -> Bool

    /// Main-actor isolated: the editor that reads it is, and two of its closures are.
    @MainActor static let live = AutomationAgentChoiceProvider(
        accounts: { await AgentAccountDiscovery.allAccountsAfterDiscovery(for: $0) },
        catalog: { await AutomationCatalogWorker.shared.read(kind: $0, account: $1) },
        signInStatus: { await AutomationSignInWorker.shared.read(account: $0, shell: $1) },
        authenticationRefused: { account in
            authenticationWasRefused(AccountUsageService.shared.reading(for: account).error)
        })

    static func authenticationWasRefused(_ error: UsageFetchError?) -> Bool {
        // An unreadable usage source, a network failure or a 403 is not proof of logout.
        switch error {
        case .tokenExpired, .http(status: 401): return true
        default: return false
        }
    }
}

private actor AutomationCatalogWorker {
    static let shared = AutomationCatalogWorker()

    func read(kind: AgentKind, account: AgentAccount?) -> AutomationAgentCatalog {
        guard !Task.isCancelled else { return .init(models: [], defaultModel: nil) }
        let inherited = AgentModels.defaultModel(for: kind, account: account)
        return .init(models: Array(AgentModels.options(for: kind, account: account, including: inherited).prefix(512)),
                     defaultModel: inherited)
    }
}

private actor AutomationSignInWorker {
    static let shared = AutomationSignInWorker()
    private struct Entry {
        let checkedAt: Date
        let configPath: String
        let status: AgentAccountSignInStatus
    }
    private var cache: [AccountID: Entry] = [:]

    func read(account: AgentAccount, shell: String) -> AgentAccountSignInStatus {
        guard !Task.isCancelled,
              let provider = AgentAccountSetupProvider(kind: account.provider) else { return .unavailable }
        let now = Date()
        if let entry = cache[account.id], entry.configPath == account.configPath,
           now.timeIntervalSince(entry.checkedAt) < 60 { return entry.status }
        // Shared account routing preserves the selected home and its saved long-lived token.
        let route = AgentAccountRouting.route(for: account.provider, account: account)
        var command = route.command
        command.append(word: account.provider.executableName)
        for argument in provider.existingLoginStatusArguments { command.append(word: argument) }
        let result = try? BoundedChildProcess.run(
            executable: shell, arguments: ["-l", "-c", command.source],
            environment: route.credentials.applied(to: AgentEnvironment.launchEnvironment()),
            timeout: AgentAccountSetupDefaults.verificationTimeout,
            maximumOutputBytes: AgentAccountSetupDefaults.maximumStatusBytes)
        let status = result.map { provider.signInStatus($0) } ?? .unavailable
        if cache.count >= 160, let oldest = cache.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[account.id] = Entry(checkedAt: now, configPath: account.configPath, status: status)
        return status
    }
}
