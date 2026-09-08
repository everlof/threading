import Foundation
import os

struct AgentModelsDidChange: AppEvent {
    static let name = Notification.Name("agentModelsDidChange")
}

/// Keeps a direct CLI answer separate from the provider's shared, last-writer-wins file.
/// A newer file from the same/newer CLI still wins, so a manual refresh does not freeze the
/// catalog forever. An older bundled client cannot remove models the installed CLI reported.
final class CodexModelCatalogStore: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let catalog: CodexModelCatalogClient.Catalog
        let refreshedAt: Date
        let authentication: ProviderSettingsFileIdentity?

        func prefersDirectAnswer(cacheVersion: String?, cacheModified: Date?) -> Bool {
            guard let cacheVersion else { return true }
            let comparison = cacheVersion.compare(catalog.version, options: .numeric)
            if comparison == .orderedAscending { return true }
            guard let cacheModified else { return true }
            return cacheModified <= refreshedAt
        }
    }

    static let maximumAccounts = 32
    static let shared = CodexModelCatalogStore {
        let root = StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : AppDataLocations.supportDirectory
        return root.appendingPathComponent("codex-model-catalogs.json")
    }

    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private let queue = DispatchQueue(label: "codes.threading.model-catalog-store", qos: .utility)
    // Queue-confined. The lock above protects only the immutable projection read by pickers.
    private var persistence: RecoverableFileStore<[String: Entry]>?

    init(url: @escaping @Sendable () -> URL) {
        queue.async { [self] in
            let store = RecoverableFileStore<[String: Entry]>(
                url: url(), fileManager: .default,
                criticality: .rebuildableCache, sizePolicy: .derivedCache
            )
            persistence = store
            let loaded = store.load(defaultValue: [:], validate: Self.validate).value
            entries.withLock { $0 = loaded }
            if !loaded.isEmpty {
                Task { @MainActor in NotificationCenter.default.post(AgentModelsDidChange()) }
            }
        }
    }

    func entry(for account: AgentAccount) -> Entry? {
        entries.withLock { $0[account.configPath] }
    }

    /// Called on the refresh worker, after the CLI has finished any token renewal of its own.
    static func authenticationIdentity(for account: AgentAccount) -> ProviderSettingsFileIdentity? {
        ProviderSettingsFileIdentity(of: URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentAccountDefaults.codexAuthMarker))
    }

    func record(_ entry: Entry, for account: AgentAccount) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var candidate = entries.withLock { $0 }
                if candidate[account.configPath] == nil, candidate.count >= Self.maximumAccounts,
                   let oldest = candidate.min(by: { $0.value.refreshedAt < $1.value.refreshedAt })?.key {
                    candidate.removeValue(forKey: oldest)
                }
                candidate[account.configPath] = entry
                do {
                    try Self.validate(candidate)
                    guard persistence?.save(candidate) == true else {
                        continuation.resume(returning: false)
                        return
                    }
                    let committed = candidate
                    entries.withLock { $0 = committed }
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func finishLoading() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private static func validate(_ entries: [String: Entry]) throws {
        guard entries.count <= maximumAccounts,
              entries.allSatisfy({ path, entry in
                  path.hasPrefix("/") && path.utf8.count <= 4_096
                      && !entry.catalog.version.isEmpty && entry.catalog.version.utf8.count <= 128
                      && !entry.catalog.options.isEmpty
                      && entry.catalog.options.count <= CodexModelCatalogClient.maximumModels
              }) else { throw CodexModelRefreshError.tooLarge }
    }
}
