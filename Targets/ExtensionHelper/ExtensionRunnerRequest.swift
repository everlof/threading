import Darwin
import Foundation

/// What crosses the XPC boundary to spawn one extension child.
///
/// It is deliberately made of strings and a descriptor map rather than of the app's own types:
/// the runner is a separate, signed process that must be able to check everything it is told
/// without trusting the sender's model. Descriptors travel beside it as `FileHandle`s, which
/// `NSXPCConnection` transfers natively.
struct ExtensionRunnerRequest: Equatable {
    /// The installed package's root directory.
    let packagePath: String
    /// The entry point to execute, already resolved by the caller and re-resolved by the runner.
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

enum ExtensionRunnerRefusal: Equatable, LocalizedError {
    case packageOutsideInstallRoot(String)
    case packageNotAPackage(String)
    case executableEscapesPackage(String)
    case executableNotRunnable(String)
    case unknownEntryMode([String])
    case forbiddenEnvironmentKey(String)

    var errorDescription: String? {
        switch self {
        case .packageOutsideInstallRoot(let path):
            return "The runner refuses to launch \(path): it is not an installed extension."
        case .packageNotAPackage(let path):
            return "The runner refuses to launch \(path): it is not an extension package."
        case .executableEscapesPackage(let path):
            return "The runner refuses to launch \(path): it resolves outside its package."
        case .executableNotRunnable(let path):
            return "The runner refuses to launch \(path): it is not a runnable file."
        case .unknownEntryMode(let arguments):
            return "The runner refuses the entry mode \(arguments.first ?? "<none>")."
        case .forbiddenEnvironmentKey(let key):
            return "The runner refuses to pass the environment variable \(key)."
        }
    }
}

/// The runner's own check on what it has been asked to run.
///
/// The app validates first — `ExtensionBundleInspector` already resolves the executable and
/// refuses one that escapes its package — and this repeats the work from scratch. That is the
/// point: a broker which trusts its caller's paths is not a boundary, it is a convenience. The
/// checks are pure so they can be tested without an XPC connection, a signed bundle, or a
/// signing identity.
enum ExtensionRunnerValidator {
    /// The only argument vectors the runner will start. Without this it is a general-purpose
    /// exec service that happens to be used for extensions.
    static let entryModes: Set<String> = ["--threading-register", "--threading-serve"]

    /// Spelled out rather than read from `ExtensionPackageStore`, because this file is compiled
    /// into the helper as well as into the app and the helper has none of the app's types.
    /// `ExtensionPackageStoreTests` pins the two to the same value.
    static let packageExtension = "threadingextension"

    /// Where installed packages live, resolved without trusting the caller *or* the
    /// environment.
    ///
    /// `NSHomeDirectory()` and `$HOME` are both the sandbox container inside the helper —
    /// measured — so neither can find the real path. `getpwuid` reads the passwd database and
    /// still answers correctly under App Sandbox, which is why it is the one used.
    static func installRootPath() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return nil
        }
        return String(cString: directory)
            + "/Library/Application Support/Threading/Extensions/Packages"
    }

    /// Environment names the runner will not forward, whatever the caller says.
    ///
    /// `DYLD_*` is the one that matters: an injected library runs inside the child with the
    /// child's authority, which would make the sandbox profile irrelevant to what actually
    /// executes. The rest are refused for the same reason in weaker forms.
    static let forbiddenEnvironmentPrefixes = [
        "DYLD_",
        "LD_",
        "MallocLog",
        "NSUnbufferedIO",
        "__XPC_"
    ]

    static func validate(
        _ request: ExtensionRunnerRequest,
        installRootPath: String,
        fileManager: FileManager = .default
    ) throws {
        guard let mode = request.arguments.first,
              entryModes.contains(mode),
              request.arguments.count == 1 else {
            throw ExtensionRunnerRefusal.unknownEntryMode(request.arguments)
        }

        for key in request.environment.keys {
            guard !forbiddenEnvironmentPrefixes.contains(where: key.hasPrefix) else {
                throw ExtensionRunnerRefusal.forbiddenEnvironmentKey(key)
            }
        }

        let installRoot = normalized(installRootPath)
        let package = normalized(request.packagePath)

        // Directly inside the install root, not merely underneath it: nesting a package inside
        // another package's directory would inherit that package's read grant.
        guard package.deletingLastPathComponent().path == installRoot.path else {
            throw ExtensionRunnerRefusal.packageOutsideInstallRoot(request.packagePath)
        }
        guard package.pathExtension == packageExtension else {
            throw ExtensionRunnerRefusal.packageNotAPackage(request.packagePath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExtensionRunnerRefusal.packageNotAPackage(request.packagePath)
        }

        let executable = normalized(request.executablePath)
        guard executable.path.hasPrefix(package.path + "/") else {
            throw ExtensionRunnerRefusal.executableEscapesPackage(request.executablePath)
        }
        var executableIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: executable.path,
            isDirectory: &executableIsDirectory
        ),
            !executableIsDirectory.boolValue,
            fileManager.isExecutableFile(atPath: executable.path) else {
            throw ExtensionRunnerRefusal.executableNotRunnable(request.executablePath)
        }
    }

    /// Standardized *and* symlink-resolved, in that order.
    ///
    /// Standardizing alone collapses `..` textually, which a symlink can then step around;
    /// resolving alone leaves a `..` that never existed on disk. Both paths in a comparison
    /// must go through the same treatment or the prefix check compares different vocabularies.
    private static func normalized(_ path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
