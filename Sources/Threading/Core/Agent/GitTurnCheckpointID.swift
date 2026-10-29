import Foundation

/// Threading's stable identity for one admitted provider turn.
///
/// This is deliberately independent of transcript row numbers. Native transports may also
/// carry a client-minted message id and terminal hooks may carry a provider turn id, but neither
/// exists on every surface. The checkpoint id is the common identity that survives relaunches.
struct GitTurnCheckpointID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
