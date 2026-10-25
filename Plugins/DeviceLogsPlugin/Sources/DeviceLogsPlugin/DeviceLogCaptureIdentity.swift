import Foundation

/// A discovered executable, rather than a display name inferred from the first log row.
/// PIDs describe the discovery instant; matching follows the executable across app restarts.
public struct DeviceLogProcessIdentity: Equatable, Sendable {
    public let name: String
    public let executablePath: String?
    public let pid: Int?
    public let bundleID: String?

    public init(name: String, executablePath: String? = nil, pid: Int? = nil, bundleID: String? = nil) {
        self.name = name
        self.executablePath = executablePath
        self.pid = pid
        self.bundleID = bundleID
    }

    func matches(_ row: DeviceLogRow) -> Bool {
        if let bundleID, let actual = row.bundleID { return bundleID == actual }
        if let executablePath, let actual = row.processPath {
            return Self.normalized(executablePath) == Self.normalized(actual)
        }
        // The legacy relay has no executable path. Keep its exact-name rows usable without
        // presenting that weaker association as a proven bundle ID on the row.
        return name == row.process
    }

    func provesBundleIdentity(of row: DeviceLogRow) -> Bool {
        guard let bundleID else { return false }
        if let actual = row.bundleID { return bundleID == actual }
        guard let executablePath, let actual = row.processPath else { return false }
        return Self.normalized(executablePath) == Self.normalized(actual)
    }

    static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}

public struct DeviceLogApplication: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let executableName: String
    public let executablePath: String?

    public init(bundleID: String, name: String, executableName: String, executablePath: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.executableName = executableName
        self.executablePath = executablePath
    }

    var processIdentity: DeviceLogProcessIdentity {
        DeviceLogProcessIdentity(name: executableName, executablePath: executablePath, bundleID: bundleID)
    }
}
