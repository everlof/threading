import Foundation

/// A string token sent by the host that an older client must be able to preserve even when a
/// newer host adds a case. Concrete enums keep decisions exhaustive for known values while the
/// shared codec keeps their wire representation as the original single JSON string.
public protocol RemoteLosslessStringToken:
    RawRepresentable, Codable, Equatable, Hashable, Sendable where RawValue == String {}

public extension RemoteLosslessStringToken {
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid remote token")
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RemoteThemeMode: RemoteLosslessStringToken {
    case light
    case dark
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "light": self = .light
        case "dark": self = .dark
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case .unknown(let value): return value
        }
    }
}

public enum RemoteThemeTypeface: RemoteLosslessStringToken {
    case `default`
    case serif
    case rounded
    case monospaced
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "serif": self = .serif
        case "rounded": self = .rounded
        case "monospaced": self = .monospaced
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .default: return "default"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        case .unknown(let value): return value
        }
    }
}

public enum RemoteManagedWorkspaceDelivery: RemoteLosslessStringToken {
    case mergeAndCleanUp
    case keepForReview
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "mergeAndCleanUp": self = .mergeAndCleanUp
        case "keepForReview": self = .keepForReview
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .mergeAndCleanUp: return "mergeAndCleanUp"
        case .keepForReview: return "keepForReview"
        case .unknown(let value): return value
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public enum RemoteManagedWorkspacePublication: RemoteLosslessStringToken {
    case draft
    case ready
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "draft": self = .draft
        case "ready": self = .ready
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .draft: return "draft"
        case .ready: return "ready"
        case .unknown(let value): return value
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public enum RemoteUsageLimitResetCause: RemoteLosslessStringToken {
    case scheduled
    case provider
    case bankedCredit
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "scheduled": self = .scheduled
        case "provider": self = .provider
        case "bankedCredit": self = .bankedCredit
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scheduled: return "scheduled"
        case .provider: return "provider"
        case .bankedCredit: return "bankedCredit"
        case .unknown(let value): return value
        }
    }
}

public enum RemoteShareScope: RemoteLosslessStringToken {
    case all
    case session
    case terminal
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "session": self = .session
        case "terminal": self = .terminal
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .all: return "all"
        case .session: return "session"
        case .terminal: return "terminal"
        case .unknown(let value): return value
        }
    }
}

/// Capability as advertised by a host. Client mutations use the closed `RemoteCapability`
/// instead, so an unknown request is rejected while a future host response remains decodable.
public enum RemoteAdvertisedCapability: RemoteLosslessStringToken {
    case view
    case interact
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "view": self = .view
        case "interact": self = .interact
        default: self = .unknown(rawValue)
        }
    }

    public init(_ capability: RemoteCapability) {
        switch capability {
        case .view: self = .view
        case .interact: self = .interact
        }
    }

    public var rawValue: String {
        switch self {
        case .view: return "view"
        case .interact: return "interact"
        case .unknown(let value): return value
        }
    }

    public var knownCapability: RemoteCapability? {
        switch self {
        case .view: return .view
        case .interact: return .interact
        case .unknown: return nil
        }
    }
}

public enum RemoteDeviceApprovalState: RemoteLosslessStringToken {
    case pendingApproval
    case denied
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pendingApproval": self = .pendingApproval
        case "denied": self = .denied
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pendingApproval: return "pendingApproval"
        case .denied: return "denied"
        case .unknown(let value): return value
        }
    }
}

public enum RemoteNotificationEnvironment: String, Codable, Equatable, Hashable, Sendable {
    case sandbox
    case production
}

public enum RemoteNotificationDelivery: RemoteLosslessStringToken {
    case push
    case live
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "push": self = .push
        case "live": self = .live
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .push: return "push"
        case .live: return "live"
        case .unknown(let value): return value
        }
    }
}
