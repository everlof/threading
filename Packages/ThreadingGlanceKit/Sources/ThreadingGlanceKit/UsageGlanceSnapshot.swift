import Foundation
import ThreadingRemoteKit

/// Presentation data only. Pairing credentials, addresses, transcripts and images never enter
/// the App Group. The pairing identity keeps two Macs with the same name distinct.
public struct UsageGlanceSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let pairingID: String
    public let hostName: String
    public let capacity: RemoteUsageCapacityDTO
    public let receivedAt: Date

    public init(pairingID: String, hostName: String, capacity: RemoteUsageCapacityDTO, receivedAt: Date) {
        version = 1
        self.pairingID = pairingID
        self.hostName = RemoteUsageCapacityLimits.label(hostName)
        self.capacity = capacity
        self.receivedAt = receivedAt
    }

    public func validate() throws {
        guard version == 1 else { throw UsageGlanceStoreError.unsupportedVersion }
        guard !pairingID.isEmpty, pairingID.utf8.count <= 256,
              !pairingID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              hostName == RemoteUsageCapacityLimits.label(hostName),
              receivedAt.timeIntervalSince1970.isFinite, receivedAt.timeIntervalSince1970 > 0
        else { throw RemoteUsageCapacityError.invalidSnapshot }
        try capacity.validate()
    }

    /// A configured identity that disappears stays missing. It must not silently change login.
    public func account(id: String?) -> RemoteUsageCapacityAccountDTO? {
        guard let id else { return capacity.accounts.first }
        return capacity.accounts.first { $0.id == id }
    }

    public func selectionID(for account: RemoteUsageCapacityAccountDTO) -> String {
        "\(pairingID.utf8.count):\(pairingID)\(account.id)"
    }
}

public enum UsageGlanceFreshness: Equatable, Sendable {
    case recent, dated, cached, expired, unavailable

    public static func resolve(account: RemoteUsageCapacityAccountDTO,
                               window: RemoteAccountUsageWindowDTO, now: Date) -> Self {
        guard account.state != .unavailable, window.fraction != nil,
              let observed = account.observedAt else { return .unavailable }
        let age = now.timeIntervalSince1970 - observed
        guard age >= -60, age < 24 * 3600 else { return .expired }
        if let reset = window.resetsAt, reset <= now.timeIntervalSince1970 { return .expired }
        if account.state == .stale || age >= 6 * 3600 { return .cached }
        return age < 15 * 60 ? .recent : .dated
    }

    public var showsCapacity: Bool { self == .recent || self == .dated || self == .cached }

    /// Four visible windows produce at most 17 entries, including the initial entry. Reset
    /// countdowns are system date text; no minute-by-minute app refresh is necessary.
    public static func transitions(account: RemoteUsageCapacityAccountDTO?, now: Date) -> [Date] {
        guard let account else { return [now] }
        var dates = Set<Date>([now])
        if let stamp = account.observedAt {
            for offset: Double in [15 * 60, 6 * 3600, 24 * 3600] {
                let date = Date(timeIntervalSince1970: stamp + offset)
                if date > now { dates.insert(date) }
            }
        }
        for window in account.windows.prefix(4) {
            if let stamp = window.resetsAt {
                let date = Date(timeIntervalSince1970: stamp)
                if date > now { dates.insert(date) }
            }
        }
        return dates.sorted()
    }
}

public struct UsageGlanceRoute: Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let pairingID: String
    public let accountID: String?

    public init(pairingID: String, accountID: String?) {
        self.pairingID = pairingID
        self.accountID = accountID
    }

    public init?(url: URL) {
        guard url.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "threading", parts.host == "usage",
              parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard items.count <= 2, Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["host", "account"].contains($0.name) }),
              let host = items.first(where: { $0.name == "host" })?.value,
              !host.isEmpty, host.utf8.count <= 256 else { return nil }
        pairingID = host
        accountID = items.first(where: { $0.name == "account" })?.value
        guard accountID.map({ !$0.isEmpty && $0.utf8.count <= 520 }) ?? true else { return nil }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "threading"
        parts.host = "usage"
        parts.queryItems = [.init(name: "host", value: pairingID)]
        if let accountID { parts.queryItems?.append(.init(name: "account", value: accountID)) }
        return parts.url!
    }
}
