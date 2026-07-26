import Foundation

/// Host-authenticated storage schema transition for the current process generation.
///
/// Skalman commits `targetVersion` only after the extension has registered successfully. An
/// interrupted launch therefore sees the same transition again. Migration code must be
/// idempotent and should use `ExtensionKeyValueStore.mutate` for each atomic state change.
public struct ExtensionDataMigrationContext: Equatable, Sendable {
    public let previousVersion: Int
    public let targetVersion: Int

    public var isRequired: Bool {
        previousVersion < targetVersion
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        previousVersion = Int(
            environment[ExtensionDataMigrationEnvironment.previousVersion] ?? ""
        ) ?? 0
        targetVersion = Int(
            environment[ExtensionDataMigrationEnvironment.targetVersion] ?? ""
        ) ?? previousVersion
    }
}

public enum ExtensionDataMigrationEnvironment {
    public static let previousVersion = "SKALMAN_EXTENSION_DATA_VERSION_FROM"
    public static let targetVersion = "SKALMAN_EXTENSION_DATA_VERSION_TO"
}
