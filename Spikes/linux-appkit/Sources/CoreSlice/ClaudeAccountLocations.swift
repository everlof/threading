import Foundation

/// A routing address, not a credential. Registered locations have already passed Claude's
/// login-status check; legacy named homes must contain a Claude config marker.
struct ClaudeAccountLocation: Equatable, Sendable {
    let handle: AccountHandle
    let configPath: String
}

/// Shared Mac/Linux account admission. Filesystem work belongs on a worker, never a UI callback.
enum ClaudeAccountLocations {
    static func discover(home: URL, candidates: [URL], verified: [ClaudeAccountLocation])
        -> [ClaudeAccountLocation] {
        var locations: [ClaudeAccountLocation] = []
        var pathHandles: [String: AccountHandle] = [:]
        var filesystemPaths = Set<String>()
        var ambiguousPaths = Set<String>()

        func append(_ handle: AccountHandle, _ directory: URL,
                    requiresMarker: Bool, isVerified: Bool = false) {
            let path = directory.standardizedFileURL.path
            guard isDirectory(path), !isScienceDataDirectory(directory),
                  (!requiresMarker || AgentAccountDefaults.claudeConfigMarkers.contains(where: {
                      isFile(directory.appendingPathComponent($0).path)
                  })) else { return }
            if let previous = pathHandles[path] {
                if previous != handle {
                    // The Mac registry may rename a handle without moving its legacy home.
                    // Keep the marker-backed identity already used by saved sessions, as
                    // discovery did before the portable resolver was introduced.
                    if !(isVerified && filesystemPaths.contains(path)) {
                        ambiguousPaths.insert(path)
                    }
                }
                return
            }
            pathHandles[path] = handle
            if !isVerified { filesystemPaths.insert(path) }
            locations.append(ClaudeAccountLocation(handle: handle, configPath: path))
        }

        // The standard directory can exist before login or use a provider-owned keychain.
        append(.standard, home.appendingPathComponent(AgentAccountDefaults.claudeDefaultDirectory),
               requiresMarker: false)
        for directory in candidates where directory.lastPathComponent.hasPrefix(
            AgentAccountDefaults.claudeDirectoryPrefix) {
            let name = String(directory.lastPathComponent.dropFirst())
            guard validLegacyName(name) else { continue }
            append(.named(name), directory, requiresMarker: true)
        }
        for record in verified {
            guard record.configPath.hasPrefix("/"), record.configPath.utf8.count <= 4_096,
                  record.handle.name.utf8.count <= 128 else { continue }
            let directory = URL(fileURLWithPath: record.configPath, isDirectory: true)
            // Standard launch clears inherited CLAUDE_CONFIG_DIR, so it cannot route elsewhere.
            if record.handle.isStandard && directory.standardizedFileURL.path != home
                .appendingPathComponent(AgentAccountDefaults.claudeDefaultDirectory,
                                        isDirectory: true).standardizedFileURL.path { continue }
            append(record.handle, directory, requiresMarker: false, isVerified: true)
        }

        var counts: [AccountHandle: Int] = [:]
        for location in locations { counts[location.handle, default: 0] += 1 }
        // A handle claimed by different homes, or two verified aliases for one home, is not a
        // routable identity. Never choose between those by discovery order.
        return locations.filter {
            counts[$0.handle] == 1 && !ambiguousPaths.contains($0.configPath)
        }
    }

    /// Exact lookup for a stored session or a new choice; reads at most one legacy home.
    static func resolve(_ handle: AccountHandle, home: URL,
                        verified: [ClaudeAccountLocation] = []) -> ClaudeAccountLocation? {
        let standard = home.appendingPathComponent(AgentAccountDefaults.claudeDefaultDirectory,
                                                   isDirectory: true).standardizedFileURL.path
        if handle.isStandard { return ClaudeAccountLocation(handle: .standard, configPath: standard) }
        let legacy: URL? = validLegacyName(handle.name)
            ? home.appendingPathComponent(".\(handle.name)", isDirectory: true) : nil
        return discover(home: home, candidates: legacy.map { [$0] } ?? [], verified: verified)
            .first { $0.handle == handle }
    }

    /// Claude Science is a data root even if it also contains Claude-shaped settings.
    static func isScienceDataDirectory(_ directory: URL) -> Bool {
        guard isDirectory(directory.path) else { return false }
        if directory.lastPathComponent == AgentAccountDefaults.claudeScienceDirectory { return true }
        return isFile(directory.appendingPathComponent(
            AgentAccountDefaults.claudeScienceFileMarker).path)
            && AgentAccountDefaults.claudeScienceDirectoryMarkers.allSatisfy {
                isDirectory(directory.appendingPathComponent($0).path)
            }
    }

    private static func validLegacyName(_ name: String) -> Bool {
        name.hasPrefix(String(AgentAccountDefaults.claudeDirectoryPrefix.dropFirst()))
            && name.count > AgentAccountDefaults.claudeDirectoryPrefix.count - 1
            && !name.contains("/") && !name.contains("\\") && name.utf8.count <= 128
            && name != String(AgentAccountDefaults.claudeScienceDirectory.dropFirst())
    }
    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
    }
    private static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue
    }
}
