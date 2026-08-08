import Darwin
import Foundation

enum ExtensionSpawnError: LocalizedError {
    case spawnFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            return "The extension could not be started: \(String(cString: strerror(code)))."
        }
    }
}

/// Spawns an extension child with an exact descriptor map, leading its own process group.
///
/// `Process` can do neither, which is why this exists: it exposes only the three standard
/// streams and spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a descriptor past 2 — the host
/// broker socket — cannot reach the child through it at all. That limitation is the reason
/// `SandboxExecLaunchPolicy` refuses a request carrying `extraDescriptors`, and this is what a
/// containment wrapper that can honour one is built on.
///
/// The spawn itself is `ChildProcessSpawn`, shared with the native-agent transports, which is
/// where the group ownership and the reap-once supervisor are documented. This layer adds only
/// the extension-facing error, whose message names the extension.
///
/// This type is a primitive, not a launch policy, and deliberately does not conform to
/// `ExtensionLaunchPolicy`. Anything reachable through that protocol contains the child;
/// spawning without containment is a step in building one, never a way to run an extension.
enum ExtensionChildSpawner {
    /// - Parameter descriptors: child descriptor number → the parent descriptor to install
    ///   there. The parent keeps its own copies; the caller closes them once the child holds
    ///   them, which for a socket pair is what lets the child's exit reach end-of-file.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        descriptors: [Int32: Int32]
    ) throws -> ExtensionChildProcess {
        do {
            return try ChildProcessSpawn.spawn(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                descriptors: descriptors
            )
        } catch ChildSpawnError.spawnFailed(let code) {
            throw ExtensionSpawnError.spawnFailed(code: code)
        }
    }
}

/// Declared here rather than beside the type: `ChildProcessSpawn` is a process primitive and
/// must not know what an extension is. The members it already has are the whole protocol.
extension SpawnedChildProcess: ExtensionChildProcess {}
