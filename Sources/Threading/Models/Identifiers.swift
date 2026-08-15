import Foundation
import ThreadingDomain

// Stable Foundation-only identities live in ThreadingDomain. These aliases keep the migration
// source-compatible while the remaining application layers become explicit modules one boundary
// at a time.
typealias StoredPathComponent = ThreadingDomain.StoredPathComponent
typealias ProjectID = ThreadingDomain.ProjectID
typealias SessionID = ThreadingDomain.SessionID
typealias TerminalID = ThreadingDomain.TerminalID
typealias TerminalInstanceIdentity = ThreadingDomain.TerminalInstanceIdentity
typealias TranscriptID = ThreadingDomain.TranscriptID
typealias AccountHandle = ThreadingDomain.AccountHandle

/// A provider-qualified account identity.
struct AccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    let provider: AgentKind
    let handle: AccountHandle

    init(provider: AgentKind, handle: AccountHandle) {
        self.provider = provider
        self.handle = handle
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = AgentKind(rawValue: String(parts[0])) else {
            return nil
        }
        self.provider = provider
        self.handle = AccountHandle(storedName: String(parts[1]))
    }

    var rawValue: String { "\(provider.rawValue):\(handle.name)" }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = AccountID(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid account id")
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
