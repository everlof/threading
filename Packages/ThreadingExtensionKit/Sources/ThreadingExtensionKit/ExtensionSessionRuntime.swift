import Foundation

public enum ExtensionSessionRuntimeLimits {
    public static let maximumProcesses = 256
    public static let maximumPorts = 128
    public static let maximumCommandLength = 128
    public static let maximumAddressLength = 64
}

/// The part of a session process tree that produced a runtime row.
///
/// This stays extensible on the wire so a future host can add another bounded origin without
/// making an older extension unable to decode the snapshot.
public struct ExtensionSessionRuntimeOrigin: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let agent: Self = "agent"
    public static let shell: Self = "shell"
}

/// One sanitized process inside the selected session's agent or shell process group.
///
/// This is a broker result, not process-table authority. An extension can inspect only rows the
/// host has already attributed to the requested Threading session.
public struct ExtensionSessionRuntimeProcess: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let command: String
    public let memoryBytes: UInt64
    public let cpuPercent: Double?

    public init(
        processIdentifier: Int32,
        command: String,
        memoryBytes: UInt64,
        cpuPercent: Double? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.command = command
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }
}

public struct ExtensionSessionRuntimeProcessGroup: Codable, Equatable, Sendable {
    public let origin: ExtensionSessionRuntimeOrigin
    public let processes: [ExtensionSessionRuntimeProcess]

    public init(
        origin: ExtensionSessionRuntimeOrigin,
        processes: [ExtensionSessionRuntimeProcess]
    ) {
        self.origin = origin
        self.processes = processes
    }
}

/// Semantic exposure of a listening socket's bind address.
public struct ExtensionSessionRuntimePortInterface: RawRepresentable, Codable, Hashable,
    Sendable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let allInterfaces: Self = "all-interfaces"
    public static let localhost: Self = "localhost"
    public static let specificAddress: Self = "specific-address"
}

public struct ExtensionSessionRuntimePort: Codable, Equatable, Sendable {
    public let port: UInt16
    public let processIdentifier: Int32
    public let command: String
    public let address: String
    public let isIPv6: Bool
    public let interface: ExtensionSessionRuntimePortInterface
    public let isReachableViaLocalhost: Bool

    public init(
        port: UInt16,
        processIdentifier: Int32,
        command: String,
        address: String,
        isIPv6: Bool,
        interface: ExtensionSessionRuntimePortInterface,
        isReachableViaLocalhost: Bool
    ) {
        self.port = port
        self.processIdentifier = processIdentifier
        self.command = command
        self.address = address
        self.isIPv6 = isIPv6
        self.interface = interface
        self.isReachableViaLocalhost = isReachableViaLocalhost
    }
}

public struct ExtensionSessionRuntimePortGroup: Codable, Equatable, Sendable {
    public let origin: ExtensionSessionRuntimeOrigin
    public let ports: [ExtensionSessionRuntimePort]

    public init(
        origin: ExtensionSessionRuntimeOrigin,
        ports: [ExtensionSessionRuntimePort]
    ) {
        self.origin = origin
        self.ports = ports
    }
}

/// One bounded host reading of the processes and listening ports attributed to a session.
///
/// No parent relationships, arguments, environment, open files, filesystem paths, sockets, or
/// processes outside the session's two host-known roots cross this boundary.
public struct ExtensionSessionRuntimeSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: String
    public let processGroups: [ExtensionSessionRuntimeProcessGroup]
    public let portGroups: [ExtensionSessionRuntimePortGroup]

    public init(
        version: Int = Self.currentVersion,
        sessionID: String,
        processGroups: [ExtensionSessionRuntimeProcessGroup],
        portGroups: [ExtensionSessionRuntimePortGroup]
    ) {
        self.version = version
        self.sessionID = sessionID
        self.processGroups = processGroups
        self.portGroups = portGroups
    }
}
