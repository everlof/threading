import Foundation
import ThreadingExtensionKit

enum WorkspaceNavigatorOptionPersistenceOutcome: Equatable, Sendable {
    /// No backing file existed when this generation was hydrated.
    case missing
    /// A supported backing file was decoded without recovery.
    case loaded
    /// Corrupt bytes were moved aside before defaults were exposed.
    case quarantinedCorrupt(recoveryURL: URL?)
    /// Newer bytes stay untouched and writes remain disabled for this activation.
    case unsupportedNewer(found: Int)
    /// Generations without declared options do not pay for a filesystem read.
    case skippedNoDeclarations
}

struct WorkspaceNavigatorOptionSnapshot: Equatable, Sendable {
    let processGeneration: String
    let revision: UInt64
    let valuesByNavigatorID: [String: [String: ExtensionJSONValue]]
    let persistenceOutcome: WorkspaceNavigatorOptionPersistenceOutcome
}

enum WorkspaceNavigatorOptionValueStoreError: LocalizedError, Equatable {
    case invalidExtensionIdentifier(String)
    case inactiveGeneration
    case unknownNavigator(String)
    case unknownOption(String)
    case invalidValue(String)
    case unsupportedNewerFormat(Int)
    case couldNotBeSaved

    var errorDescription: String? {
        switch self {
        case .invalidExtensionIdentifier(let identifier):
            return L10n.format("Invalid extension identifier: %@.", identifier)
        case .inactiveGeneration:
            return ExtensionProcessError.notRunning.localizedDescription
        case .unknownNavigator(let identifier):
            return L10n.format("The value does not match extension setting “%@”.", identifier)
        case .unknownOption(let identifier):
            return L10n.format("The value does not match extension setting “%@”.", identifier)
        case .invalidValue(let identifier):
            return L10n.format("The value does not match extension setting “%@”.", identifier)
        case .unsupportedNewerFormat(let version):
            return L10n.format(
                "Extension settings use unsupported format version %lld.",
                Int64(version)
            )
        case .couldNotBeSaved:
            return L10n.string(
                "Extension settings could not be saved without risking their recovery copy."
            )
        }
    }
}

protocol WorkspaceNavigatorOptionValueStoring: Sendable {
    func activate(
        extensionIdentifier: String,
        processGeneration: String,
        navigators: [ExtensionWorkspaceNavigator]
    ) throws -> WorkspaceNavigatorOptionSnapshot

    func deactivate(extensionIdentifier: String, processGeneration: String)

    func set(
        _ value: ExtensionJSONValue,
        extensionIdentifier: String,
        processGeneration: String,
        navigatorID: String,
        optionID: String,
        completion: @escaping @Sendable (
            Result<WorkspaceNavigatorOptionSnapshot, Error>
        ) -> Void
    )
}

/// Host-owned, generation-fenced persistence for navigator option values.
///
/// A lane is serialized per extension, rather than globally, so one slow disk cannot hold every
/// installed extension. Raw values retain unknown navigator and option IDs; each generation sees
/// only values accepted by its immutable declarations. The UI receives a main-actor memory
/// snapshot from `ExtensionManager` and never reads this file while opening a menu.
final class WorkspaceNavigatorOptionValueStore:
    WorkspaceNavigatorOptionValueStoring,
    @unchecked Sendable
{
    typealias SaveHook = @Sendable () -> Void

    private struct State: Codable {
        static let currentFormatVersion = 1

        var formatVersion = currentFormatVersion
        var values: [String: [String: ExtensionJSONValue]] = [:]
    }

    private struct StateVersionProbe: Decodable {
        let formatVersion: Int
    }

    /// Probes both supported wire shapes without asking `RecoverableFileStore` to quarantine a
    /// future format. A top-level `value` means the outer recoverable envelope is present;
    /// otherwise the document is the legacy bare state.
    private struct VersionProbe: Decodable {
        let formatVersion: Int
        let containsValue: Bool
        let stateVersion: Int?

        private enum CodingKeys: String, CodingKey {
            case formatVersion
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
            containsValue = container.contains(.value)
            if containsValue,
               formatVersion <= WorkspaceNavigatorOptionValueStore
                   .recoverableEnvelopeFormatVersion {
                stateVersion = try container.decodeIfPresent(
                    StateVersionProbe.self,
                    forKey: .value
                )?.formatVersion
            } else {
                // A newer envelope owns the shape of `value`; inspecting it as today's state
                // could turn a supported preservation case into a destructive quarantine.
                stateVersion = nil
            }
        }
    }

    private struct ActiveGeneration {
        let processGeneration: String
        var revision: UInt64
        var rawState: State
        let declarations: [String: [String: ExtensionWorkspaceNavigatorOption]]
        let persistenceOutcome: WorkspaceNavigatorOptionPersistenceOutcome
        let writesAllowed: Bool
    }

    private final class Lane: @unchecked Sendable {
        let queue: DispatchQueue
        var active: ActiveGeneration?
        var persistence: RecoverableFileStore<State>?

        init(extensionIdentifier: String) {
            queue = DispatchQueue(
                label: "codes.threading.navigator-options.\(extensionIdentifier)",
                qos: .userInitiated
            )
        }
    }

    private static let recoverableEnvelopeFormatVersion = 1

    private let rootURL: URL
    private let fileManager: FileManager
    private let saveHook: SaveHook?
    private let lanesLock = NSLock()
    private var lanes: [String: Lane] = [:]

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        saveHook: SaveHook? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.saveHook = saveHook
    }

    /// Hydrates a generation synchronously on the caller's background launch path. The serial lane
    /// drains option changes accepted before this activation before installing its new generation.
    func activate(
        extensionIdentifier: String,
        processGeneration: String,
        navigators: [ExtensionWorkspaceNavigator]
    ) throws -> WorkspaceNavigatorOptionSnapshot {
        guard ExtensionIdentifierRules.isReverseDNSIdentifier(extensionIdentifier) else {
            throw WorkspaceNavigatorOptionValueStoreError.invalidExtensionIdentifier(
                extensionIdentifier
            )
        }

        let lane = lane(for: extensionIdentifier)
        return lane.queue.sync {
            let declarations = Self.declarations(from: navigators)
            let loaded: (
                state: State,
                outcome: WorkspaceNavigatorOptionPersistenceOutcome,
                writesAllowed: Bool
            )
            if declarations.values.allSatisfy(\.isEmpty) {
                loaded = (State(), .skippedNoDeclarations, true)
            } else {
                loaded = load(extensionIdentifier: extensionIdentifier, lane: lane)
            }

            let active = ActiveGeneration(
                processGeneration: processGeneration,
                revision: 0,
                rawState: loaded.state,
                declarations: declarations,
                persistenceOutcome: loaded.outcome,
                writesAllowed: loaded.writesAllowed
            )
            lane.active = active
            return Self.snapshot(from: active)
        }
    }

    /// The fence is asynchronous so lifecycle work never waits on disk from the main actor. Writes
    /// accepted before it drain; later writes observe the cleared generation and fail closed.
    func deactivate(extensionIdentifier: String, processGeneration: String) {
        guard let lane = existingLane(for: extensionIdentifier) else { return }
        lane.queue.async {
            if lane.active?.processGeneration == processGeneration {
                lane.active = nil
            }
        }
    }

    func set(
        _ value: ExtensionJSONValue,
        extensionIdentifier: String,
        processGeneration: String,
        navigatorID: String,
        optionID: String,
        completion: @escaping @Sendable (
            Result<WorkspaceNavigatorOptionSnapshot, Error>
        ) -> Void
    ) {
        guard ExtensionIdentifierRules.isReverseDNSIdentifier(extensionIdentifier) else {
            completion(.failure(
                WorkspaceNavigatorOptionValueStoreError.invalidExtensionIdentifier(
                    extensionIdentifier
                )
            ))
            return
        }

        let lane = lane(for: extensionIdentifier)
        lane.queue.async { [self] in
            guard let active = lane.active,
                  active.processGeneration == processGeneration else {
                completion(.failure(WorkspaceNavigatorOptionValueStoreError.inactiveGeneration))
                return
            }
            guard let navigator = active.declarations[navigatorID] else {
                completion(.failure(
                    WorkspaceNavigatorOptionValueStoreError.unknownNavigator(navigatorID)
                ))
                return
            }
            guard let option = navigator[optionID] else {
                completion(.failure(
                    WorkspaceNavigatorOptionValueStoreError.unknownOption(optionID)
                ))
                return
            }
            guard option.control.accepts(value) else {
                completion(.failure(
                    WorkspaceNavigatorOptionValueStoreError.invalidValue(optionID)
                ))
                return
            }
            guard active.writesAllowed else {
                if case .unsupportedNewer(let found) = active.persistenceOutcome {
                    completion(.failure(
                        WorkspaceNavigatorOptionValueStoreError.unsupportedNewerFormat(found)
                    ))
                } else {
                    completion(.failure(
                        WorkspaceNavigatorOptionValueStoreError.couldNotBeSaved
                    ))
                }
                return
            }

            var candidate = active.rawState
            var navigatorValues = candidate.values[navigatorID] ?? [:]
            if value == option.control.defaultValue {
                navigatorValues.removeValue(forKey: optionID)
            } else {
                navigatorValues[optionID] = value
            }
            if navigatorValues.isEmpty {
                candidate.values.removeValue(forKey: navigatorID)
            } else {
                candidate.values[navigatorID] = navigatorValues
            }

            if candidate.values == active.rawState.values {
                completion(.success(Self.snapshot(from: active)))
                return
            }

            saveHook?()
            guard let current = lane.active,
                  current.processGeneration == processGeneration else {
                completion(.failure(
                    WorkspaceNavigatorOptionValueStoreError.inactiveGeneration
                ))
                return
            }
            guard Self.save(
                candidate,
                extensionIdentifier: extensionIdentifier,
                rootURL: rootURL,
                fileManager: fileManager,
                persistence: lane.persistence
            ) else {
                completion(.failure(
                    WorkspaceNavigatorOptionValueStoreError.couldNotBeSaved
                ))
                return
            }

            var updated = current
            updated.rawState = candidate
            updated.revision &+= 1
            lane.active = updated
            completion(.success(Self.snapshot(from: updated)))
        }
    }

    private func load(
        extensionIdentifier: String,
        lane: Lane
    ) -> (
        state: State,
        outcome: WorkspaceNavigatorOptionPersistenceOutcome,
        writesAllowed: Bool
    ) {
        let url = stateURL(extensionIdentifier: extensionIdentifier)
        if let found = unsupportedNewerVersion(at: url) {
            return (State(), .unsupportedNewer(found: found), false)
        }

        let persistence: RecoverableFileStore<State>
        if let existing = lane.persistence {
            persistence = existing
        } else {
            persistence = RecoverableFileStore<State>(
                url: url,
                fileManager: fileManager,
                criticality: .userAuthored,
                sizePolicy: .compactMetadata
            )
            lane.persistence = persistence
        }
        let outcome = persistence.load(defaultValue: State()) { state in
            guard state.formatVersion == State.currentFormatVersion else {
                throw WorkspaceNavigatorOptionValueStoreError.unsupportedNewerFormat(
                    state.formatVersion
                )
            }
        }
        switch outcome {
        case .missing(let state):
            return (state, .missing, persistence.writesAllowed)
        case .loaded(let state):
            return (state, .loaded, persistence.writesAllowed)
        case .unreadable(let state, let recovery):
            let recoveryURL: URL?
            if case .file(let url) = recovery {
                recoveryURL = url
            } else {
                recoveryURL = nil
            }
            return (
                state,
                .quarantinedCorrupt(recoveryURL: recoveryURL),
                persistence.writesAllowed
            )
        }
    }

    private func unsupportedNewerVersion(at url: URL) -> Int? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? BoundedFileReader.read(
                url,
                maximumBytes: RecoverableFileSizePolicy.compactMetadata.maximumBytes
              ),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return nil
        }
        if probe.containsValue {
            if probe.formatVersion > Self.recoverableEnvelopeFormatVersion {
                return probe.formatVersion
            }
            if let stateVersion = probe.stateVersion,
               stateVersion > State.currentFormatVersion {
                return stateVersion
            }
            return nil
        }
        return probe.formatVersion > State.currentFormatVersion
            ? probe.formatVersion
            : nil
    }

    private func lane(for extensionIdentifier: String) -> Lane {
        lanesLock.lock()
        defer { lanesLock.unlock() }
        if let lane = lanes[extensionIdentifier] { return lane }
        let lane = Lane(extensionIdentifier: extensionIdentifier)
        lanes[extensionIdentifier] = lane
        return lane
    }

    private func existingLane(for extensionIdentifier: String) -> Lane? {
        lanesLock.lock()
        defer { lanesLock.unlock() }
        return lanes[extensionIdentifier]
    }

    private func stateURL(extensionIdentifier: String) -> URL {
        rootURL
            .appendingPathComponent(extensionIdentifier, isDirectory: true)
            .appendingPathComponent("navigator-options.json", isDirectory: false)
    }

    private static func declarations(
        from navigators: [ExtensionWorkspaceNavigator]
    ) -> [String: [String: ExtensionWorkspaceNavigatorOption]] {
        var result: [String: [String: ExtensionWorkspaceNavigatorOption]] = [:]
        for navigator in navigators {
            result[navigator.id] = Dictionary(
                navigator.options.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return result
    }

    private static func snapshot(
        from active: ActiveGeneration
    ) -> WorkspaceNavigatorOptionSnapshot {
        var effective: [String: [String: ExtensionJSONValue]] = [:]
        for (navigatorID, options) in active.declarations {
            var values: [String: ExtensionJSONValue] = [:]
            for (optionID, option) in options {
                let persisted = active.rawState.values[navigatorID]?[optionID]
                values[optionID] = persisted.flatMap { value in
                    option.control.accepts(value) ? value : nil
                } ?? option.control.defaultValue
            }
            effective[navigatorID] = values
        }
        return WorkspaceNavigatorOptionSnapshot(
            processGeneration: active.processGeneration,
            revision: active.revision,
            valuesByNavigatorID: effective,
            persistenceOutcome: active.persistenceOutcome
        )
    }

    private static func save(
        _ state: State,
        extensionIdentifier: String,
        rootURL: URL,
        fileManager: FileManager,
        persistence: RecoverableFileStore<State>?
    ) -> Bool {
        guard let persistence else { return false }
        let directory = rootURL.appendingPathComponent(
            extensionIdentifier,
            isDirectory: true
        )
        let url = directory.appendingPathComponent(
            "navigator-options.json",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard persistence.save(state) else { return false }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            ThreadingLogger.storage.error(
                "Could not secure navigator options for \(extensionIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }
}
