import Foundation

/// Capacity is independent of session and transcript catalogue revisions.
public struct RemoteUsageCapacityDTO: Codable, Equatable, Sendable {
    public let epoch: String
    public let revision: UInt64
    public let accounts: [RemoteUsageCapacityAccountDTO]
    public let omittedAccountCount: Int
    public let omittedWindowCount: Int

    public init(epoch: String, revision: UInt64, accounts: [RemoteUsageCapacityAccountDTO],
                omittedAccountCount: Int = 0, omittedWindowCount: Int = 0) {
        self.epoch = epoch
        self.revision = revision
        self.accounts = accounts
        self.omittedAccountCount = omittedAccountCount
        self.omittedWindowCount = omittedWindowCount
    }

    public func validate() throws {
        guard UUID(uuidString: epoch) != nil,
              accounts.count <= RemoteUsageCapacityLimits.accounts,
              accounts.reduce(0, { $0 + $1.windows.count }) <= RemoteUsageCapacityLimits.windows,
              Set(accounts.map(\.id)).count == accounts.count,
              omittedAccountCount >= 0, omittedWindowCount >= 0 else {
            throw RemoteUsageCapacityError.invalidSnapshot
        }
        for account in accounts { try account.validate() }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= RemoteUsageCapacityLimits.bytes else {
            throw RemoteUsageCapacityError.oversized
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

public enum RemoteUsageCapacityReadingState: String, Codable, Sendable {
    case current, stale, unavailable
}

public struct RemoteUsageCapacityAccountDTO: Codable, Equatable, Sendable, Identifiable {
    public let runtimeID: String
    public let runtimeName: String
    public let accountID: String
    public let accountName: String
    public let observedAt: Double?
    public let state: RemoteUsageCapacityReadingState
    public let windows: [RemoteAccountUsageWindowDTO]

    /// Length-prefix the provider so identical handles in two runtimes remain distinct.
    public var id: String { "\(runtimeID.utf8.count):\(runtimeID)\(accountID)" }

    public init(runtimeID: String, runtimeName: String, accountID: String, accountName: String,
                observedAt: Double?, state: RemoteUsageCapacityReadingState,
                windows: [RemoteAccountUsageWindowDTO]) {
        self.runtimeID = runtimeID
        self.runtimeName = runtimeName
        self.accountID = accountID
        self.accountName = accountName
        self.observedAt = observedAt
        self.state = state
        self.windows = windows
    }

    public func validate() throws {
        guard [runtimeID, accountID].allSatisfy(RemoteUsageCapacityLimits.validIdentity),
              [runtimeName, accountName].allSatisfy(RemoteUsageCapacityLimits.validLabel),
              observedAt.map({ $0.isFinite && $0 > 0 }) ?? true,
              state != .unavailable || windows.isEmpty,
              state == .unavailable || observedAt != nil,
              windows.count <= RemoteUsageCapacityLimits.windows,
              Set(windows.map(\.id)).count == windows.count else {
            throw RemoteUsageCapacityError.invalidSnapshot
        }
        for window in windows {
            guard RemoteUsageCapacityLimits.validIdentity(window.id),
                  RemoteUsageCapacityLimits.validLabel(window.name),
                  window.fraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  window.resetsAt.map({ $0.isFinite && $0 > 0 }) ?? true,
                  window.windowDuration.map({ $0.isFinite && $0 > 0 }) ?? true,
                  window.metersModelIDs == nil else {
                throw RemoteUsageCapacityError.invalidSnapshot
            }
        }
    }
}

/// The scope remains in the window's supplied name. Model catalogues never enter capacity data.
public enum RemoteUsageCapacityLimits {
    public static let accounts = 128
    public static let windows = 256
    public static let bytes = 128 * 1_024
    public static let identityBytes = 256
    public static let labelBytes = 120

    public static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= identityBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= labelBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func label(_ value: String) -> String {
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars.prefix(labelBytes) {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let width = String(scalar).utf8.count
            guard byteCount + width <= labelBytes else { break }
            result.unicodeScalars.append(scalar)
            byteCount += width
        }
        return result.isEmpty ? "?" : result
    }
}

public enum RemoteUsageCapacityError: Error {
    case invalidSnapshot, oversized
}

public struct RemoteUsageCapacityChangedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let epoch: String
    public let revision: UInt64

    public init(epoch: String, revision: UInt64) {
        type = "usageCapacityChanged"
        self.epoch = epoch
        self.revision = revision
    }
}
