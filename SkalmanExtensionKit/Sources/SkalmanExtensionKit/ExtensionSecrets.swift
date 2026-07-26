import Foundation

/// Validation limits for secrets brokered through Skalman.
///
/// Secret values never enter extension storage or the process environment. The extension sends
/// them only over its generation-bound loopback connection and Skalman persists them in Keychain.
public enum ExtensionSecretConstraints {
    public static let maximumKeys = 256
    public static let maximumKeyBytes = 512
    public static let maximumValueBytes = 64 * 1024

    public static func validate(key: String) throws {
        let byteCount = key.lengthOfBytes(using: .utf8)
        guard byteCount > 0,
              byteCount <= maximumKeyBytes,
              key.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ExtensionSecretError.invalidKey
        }
    }

    public static func validate(value: Data) throws {
        guard value.count <= maximumValueBytes else {
            throw ExtensionSecretError.valueTooLarge(
                maximumBytes: maximumValueBytes
            )
        }
    }
}

public enum ExtensionSecretError: Error, Equatable, LocalizedError {
    case invalidKey
    case valueTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Secret keys must contain 1–512 UTF-8 bytes and no control characters."
        case .valueTooLarge(let maximumBytes):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(maximumBytes),
                countStyle: .file
            )
            return "A secret value may not exceed \(size)."
        }
    }
}

/// PUT body for one opaque Keychain value. `Data` uses Codable's base64 JSON representation.
public struct ExtensionSecretWrite: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let value: Data

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        value: Data
    ) {
        self.protocolVersion = protocolVersion
        self.value = value
    }

    public func validate() throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ExtensionValidationError(issues: [
                .init(
                    path: "protocolVersion",
                    message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
                )
            ])
        }
        try ExtensionSecretConstraints.validate(value: value)
    }
}

/// GET result. A missing key is represented by `nil`, not by a distinguishable HTTP error.
public struct ExtensionSecretResult: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let value: Data?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        value: Data?
    ) {
        self.protocolVersion = protocolVersion
        self.value = value
    }
}

/// The names owned by one extension. Values are never returned by the list operation.
public struct ExtensionSecretKeyList: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let keys: [String]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        keys: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.keys = keys
    }
}
