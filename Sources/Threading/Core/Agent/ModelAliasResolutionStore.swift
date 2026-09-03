import Foundation
import os

// MARK: - Model Alias Resolution Store

/// What each login's runtime was watched resolving an alias to.
///
/// The Claude catalogue is four aliases — `fable`, `opus`, `sonnet`, `haiku` — and an alias
/// names a family, not a version: `opus` is whatever Opus is newest when the session launches,
/// which is the point of launching by alias and also why a picker row reading "Opus" cannot say
/// *which* Opus. The version is not written down anywhere on disk this app may read (the alias
/// table lives inside the CLI binary), but the runtime announces the id it resolved to when a
/// session starts, and a transcript records it on every answer. This remembers that per login:
/// `opus` → `claude-opus-5`, `fable[1m]` → `claude-fable-5-1[1m]`. The alias row then reads
/// "Opus 5" while still launching `opus`, so it keeps following the CLI's latest, and the label
/// is at most one run stale — the next start on that login overwrites it.
///
/// **A record of its own rather than a field on `AccountPreference`**, though it is the same
/// kind of per-login fact as `lastReportedModel`. The catalogue is built off the main actor —
/// the phone's create request names its models from a server handler — and
/// `AccountPreferencesStore` is main-actor state. This is a lock, not an actor, for the same
/// reason `ClaudeAccountFactMemo` is: the catalogue asks from wherever it is.
///
/// Observed, never inferred: an alias no session has launched on a login has no entry, and its
/// row reads the bare family until one does. Nothing here guesses a version.
final class ModelAliasResolutionStore: @unchecked Sendable {

    // MARK: - Types

    /// Per login, the id each launched identifier was seen to resolve to.
    private typealias Resolutions = [String: [String: String]]

    private struct State {
        var resolutions: Resolutions
        /// Touched only under the lock, which is what makes the class `@unchecked Sendable`
        /// rather than a data race: the persistence store keeps a `writesAllowed` flag of its
        /// own and is not `Sendable` itself.
        let persistence: RecoverableDefaultsStore<Resolutions>
    }

    // MARK: - Properties

    static let shared = ModelAliasResolutionStore(defaults: PreferenceStore.shared)

    private let state: OSAllocatedUnfairLock<State>

    // MARK: - Initialization

    /// Not private so a test can stand one up over its own suite; the app uses `shared`.
    ///
    /// `PreferenceStore.shared` for the same reason `AccountPreferencesStore` uses it: the tests
    /// are hosted in the app, and a suite that watches a fixture session start must not teach
    /// the developer's own login that `opus` is a model invented for the test.
    init(defaults: UserDefaults) {
        let persistence = RecoverableDefaultsStore<Resolutions>(
            defaults: defaults,
            key: Keys.modelAliasResolutions,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        state = OSAllocatedUnfairLock(initialState: State(
            resolutions: persistence.load(defaultValue: [:]).value,
            persistence: persistence
        ))
    }

    // MARK: - Public Methods

    /// The id this login's runtime last resolved `launched` to, or nil when it has never been
    /// watched launching it.
    func resolvedModel(forLaunched launched: String, in accountID: AccountID) -> String? {
        guard let key = normalized(launched) else { return nil }
        return state.withLock { $0.resolutions[accountID.rawValue]?[key] }
    }

    /// Records that a session on this login launched as `launched` and announced `reported`.
    ///
    /// Only an alias has anything to learn: a launch naming its own version
    /// (`claude-fable-5-1[1m]`) is skipped, as is one the runtime echoed back unchanged. Writes
    /// only on a change, since this is called at every session start and each write persists.
    /// Bounded per login so a malformed launch cannot grow a compact preference without limit.
    func record(_ reported: String, forLaunched launched: String, in accountID: AccountID) {
        guard accountID.provider.supports(.modelAliasResolution),
              let key = normalized(launched),
              let value = normalized(reported),
              key != value,
              !ModelName.isVersioned(key)
        else { return }

        state.withLock { state in
            var forAccount = state.resolutions[accountID.rawValue] ?? [:]
            guard forAccount[key] != value else { return }
            guard forAccount[key] != nil || forAccount.count < Limits.maximumEntriesPerAccount
            else { return }
            forAccount[key] = value

            var candidate = state.resolutions
            candidate[accountID.rawValue] = forAccount
            if state.persistence.save(candidate) {
                state.resolutions = candidate
            }
        }
    }

    /// Drops everything remembered, so a test can start from nothing.
    func forgetAll() {
        state.withLock { state in
            guard !state.resolutions.isEmpty else { return }
            if state.persistence.save([:]) {
                state.resolutions = [:]
            }
        }
    }

    // MARK: - Private Methods

    /// Trims whitespace and refuses an empty or oversized identifier.
    private func normalized(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Limits.maximumIdentifierBytes else {
            return nil
        }
        return trimmed
    }

    // MARK: - Keys

    private enum Keys {
        static let modelAliasResolutions = "modelAliasResolutions"
    }

    private enum Limits {
        static let maximumEntriesPerAccount = 32
        static let maximumIdentifierBytes = 512
    }
}
