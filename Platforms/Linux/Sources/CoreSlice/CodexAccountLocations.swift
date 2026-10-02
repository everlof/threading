import Foundation

/// A routing address, not a credential. Registered locations have already passed the CLI's
/// own login-status check; legacy homes must prove themselves with Codex's auth marker.
struct CodexAccountLocation: Equatable, Sendable {
    let handle: AccountHandle
    let configPath: String
}

/// Resolves the same durable account handle for the Mac host and the Linux experiment.
/// The standard handle always means HOME/.codex: launch routing clears inherited CODEX_HOME.
/// Filesystem inspection belongs on a worker, never in a row or input callback.
enum CodexAccountLocations {
    static func discover(home: URL, candidates: [URL], verified: [CodexAccountLocation])
        -> [CodexAccountLocation] {
        var locations: [CodexAccountLocation] = []
        var pathHandles: [String: AccountHandle] = [:]
        var ambiguousPaths = Set<String>()

        func append(_ handle: AccountHandle, _ directory: URL, requiresMarker: Bool) {
            let path = directory.standardizedFileURL.path
            guard isDirectory(path),
                  (!requiresMarker || isFile(directory.appendingPathComponent(
                    AgentAccountDefaults.codexAuthMarker).path)) else { return }
            if let previous = pathHandles[path] {
                if previous != handle { ambiguousPaths.insert(path) }
                return
            }
            pathHandles[path] = handle
            locations.append(CodexAccountLocation(handle: handle, configPath: path))
        }

        append(.standard, home.appendingPathComponent(AgentAccountDefaults.codexDefaultDirectory),
               requiresMarker: true)
        for directory in candidates where directory.lastPathComponent.hasPrefix(
            AgentAccountDefaults.codexDirectoryPrefix) {
            let name = String(directory.lastPathComponent.dropFirst())
            guard validLegacyName(name) else { continue }
            append(.named(name), directory, requiresMarker: true)
        }
        for record in verified {
            guard record.configPath.hasPrefix("/"), record.configPath.utf8.count <= 4_096,
                  record.handle.name.utf8.count <= 128 else { continue }
            let directory = URL(fileURLWithPath: record.configPath, isDirectory: true)
            // A standard login may use the OS keyring and have no auth.json. Its registry
            // proof is usable only at the same HOME/.codex that the launcher selects.
            if record.handle.isStandard && directory.standardizedFileURL.path != home
                .appendingPathComponent(AgentAccountDefaults.codexDefaultDirectory,
                                        isDirectory: true).standardizedFileURL.path { continue }
            append(record.handle, directory,
                   requiresMarker: false)
        }

        // A handle is an identity. Two distinct homes using it cannot both be presented as
        // routable; choosing either by list order would resume a conversation as someone else.
        var counts: [AccountHandle: Int] = [:]
        for location in locations { counts[location.handle, default: 0] += 1 }
        return locations.filter {
            counts[$0.handle] == 1 && !ambiguousPaths.contains($0.configPath)
        }
    }

    /// Exact lookup for a stored session or an explicit new-session choice. This reads one
    /// legacy directory at most; it does not enumerate every home on a launch path.
    static func resolve(_ handle: AccountHandle, home: URL,
                        verified: [CodexAccountLocation] = []) -> CodexAccountLocation? {
        let standard = home.appendingPathComponent(AgentAccountDefaults.codexDefaultDirectory,
                                                   isDirectory: true).standardizedFileURL.path
        if handle.isStandard { return CodexAccountLocation(handle: .standard, configPath: standard) }
        let legacy: URL?
        if validLegacyName(handle.name) {
            legacy = home.appendingPathComponent(".\(handle.name)", isDirectory: true)
        } else {
            legacy = nil
        }
        let found = discover(home: home, candidates: legacy.map { [$0] } ?? [], verified: verified)
        return found.first { $0.handle == handle }
    }

    private static func validLegacyName(_ name: String) -> Bool {
        name.hasPrefix(String(AgentAccountDefaults.codexDirectoryPrefix.dropFirst()))
            && name.count > AgentAccountDefaults.codexDirectoryPrefix.count - 1
            && !name.contains("/") && !name.contains("\\") && name.utf8.count <= 128
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
