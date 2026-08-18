import Foundation

/// A config location whose login was completed through Threading.
///
/// Legacy accounts remain discoverable from provider-owned markers on disk. This registry is
/// the other half of discovery for credentials a CLI keeps in the system keychain: a successful
/// provider status check is the proof, and the app remembers only where to route that login.
struct AgentAccountLocationRecord: Codable, Equatable, Sendable {
    let provider: AgentKind
    let handleName: String
    let configPath: String

    var handle: AccountHandle { AccountHandle(storedName: handleName) }
    var id: AccountID { AccountID(provider: provider, handle: handle) }
}

/// Persists locations created and verified by the in-app account setup flow.
///
/// No credential material crosses this boundary. A record is provider, handle, and absolute
/// config path only. The bounded store prevents a corrupt preference from turning account
/// discovery into an unbounded retained surface.
@MainActor
final class AgentAccountLocationRegistry {

    static let shared = AgentAccountLocationRegistry()

    private enum Defaults {
        static let key = "agentAccountLocations.v1"
        static let maximumRecords = 64
        static let maximumPathBytes = 4 * 1_024
        static let maximumHandleBytes = 128
    }

    private enum ValidationError: Error {
        case invalidRecord
    }

    private let persistence: RecoverableDefaultsStore<[AgentAccountLocationRecord]>
    private var storedRecords: [AgentAccountLocationRecord]

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<[AgentAccountLocationRecord]>(
            defaults: defaults,
            key: Defaults.key,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.storedRecords = persistence.load(
            defaultValue: [],
            validate: Self.validate
        ).value
    }

    var records: [AgentAccountLocationRecord] { storedRecords }

    func records(for provider: AgentKind) -> [AgentAccountLocationRecord] {
        storedRecords.filter { $0.provider == provider }
    }

    func contains(provider: AgentKind, configPath: String) -> Bool {
        let path = URL(fileURLWithPath: configPath).standardizedFileURL.path
        return storedRecords.contains {
            $0.provider == provider
                && URL(fileURLWithPath: $0.configPath).standardizedFileURL.path == path
        }
    }

    /// Records a login only after the provider's own status command has confirmed it.
    @discardableResult
    func register(provider: AgentKind, handle: AccountHandle, configPath: String) -> Bool {
        let record = AgentAccountLocationRecord(
            provider: provider,
            handleName: handle.name,
            configPath: URL(fileURLWithPath: configPath).standardizedFileURL.path
        )
        var candidate = storedRecords.filter {
            $0.id != record.id
                && !(URL(fileURLWithPath: $0.configPath).standardizedFileURL.path
                    == record.configPath && $0.provider == provider)
        }
        candidate.append(record)
        candidate.sort {
            if $0.provider.rawValue == $1.provider.rawValue {
                return $0.handleName < $1.handleName
            }
            return $0.provider.rawValue < $1.provider.rawValue
        }

        do {
            try Self.validate(candidate)
        } catch {
            ThreadingLogger.agent.error("Refusing an invalid account-location record")
            return false
        }
        guard persistence.save(candidate) else { return false }
        storedRecords = candidate
        return true
    }

    private static func validate(_ records: [AgentAccountLocationRecord]) throws {
        var ids = Set<AccountID>()
        var paths = Set<String>()
        guard records.count <= Defaults.maximumRecords,
              records.allSatisfy({ record in
                  let path = URL(fileURLWithPath: record.configPath).standardizedFileURL.path
                  let pathKey = "\(record.provider.rawValue):\(path)"
                  return record.provider.supportsAccounts
                      && !record.handle.isStandard
                      && record.handleName.utf8.count <= Defaults.maximumHandleBytes
                      && path.hasPrefix("/")
                      && path.utf8.count <= Defaults.maximumPathBytes
                      && ids.insert(record.id).inserted
                      && paths.insert(pathKey).inserted
              }) else {
            throw ValidationError.invalidRecord
        }
    }
}
