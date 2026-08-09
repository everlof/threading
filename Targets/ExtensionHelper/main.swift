import Darwin
import Foundation

/// The contained launcher an extension is executed out of.
///
/// It is App Sandboxed by its own entitlements, which the kernel applies before this code runs,
/// and it `execve`s the extension **in place** — so the pid Threading spawned is the pid the
/// extension runs as, with the descriptors it was spawned with, still sandboxed. Measured: an
/// App Sandbox survives `execve` into a binary carrying no entitlements of its own, and the
/// home-relative read-only exception is what permits the exec at all.
///
/// Nothing here is trusted from the caller except *which* package to run, and that claim is
/// re-checked from scratch before it is acted on. See `docs/extensions/SANDBOX_RUNNER.md`.
enum ThreadingExtensionHelper {
    /// Exit codes distinct from anything an extension can return, so a failure to launch is
    /// never mistaken for the extension's own answer.
    enum ExitCode {
        static let refused: Int32 = 78      // EX_CONFIG: the request did not validate.
        static let unresolvable: Int32 = 71 // EX_OSERR: no install root, so no boundary.
        static let execFailed: Int32 = 126  // The shell's "found but not executable".
    }

    static func main() -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            fail(
                "usage: \(arguments.first ?? "helper") <package> <executable> <entry-mode>",
                code: ExitCode.refused
            )
        }

        guard let installRoot = ExtensionRunnerValidator.installRootPath() else {
            fail(
                "the helper could not resolve the extension install root",
                code: ExitCode.unresolvable
            )
        }

        // The environment the helper was given *is* the environment the extension will run
        // with, since `execve` carries it across. Validating it here is therefore validating
        // the extension's own environment, not a copy of it.
        let environment = ProcessInfo.processInfo.environment
        let request = ExtensionRunnerRequest(
            packagePath: arguments[1],
            executablePath: arguments[2],
            arguments: [arguments[3]],
            environment: environment
        )
        do {
            try ExtensionRunnerValidator.validate(request, installRootPath: installRoot)
        } catch {
            fail(
                (error as? LocalizedError)?.errorDescription ?? "\(error)",
                code: ExitCode.refused
            )
        }

        // App Sandbox contains subprocesses but does not tie their lifetime to this pid. Until
        // Threading has an explicit process-spawning capability with its own descendant broker,
        // an extension must therefore be unable to create one. Lowering both the soft and hard
        // per-user process limit to one is inherited across exec and cannot be raised again by
        // the extension; because the logged-in user already has more than one process, fork and
        // posix_spawn fail with EAGAIN while threads remain unaffected.
        var processLimit = rlimit(rlim_cur: 1, rlim_max: 1)
        guard setrlimit(RLIMIT_NPROC, &processLimit) == 0 else {
            fail(
                "could not disable extension subprocesses: \(String(cString: strerror(errno)))",
                code: ExitCode.refused
            )
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(request.executablePath),
            strdup(request.arguments[0]),
            nil
        ]
        var envp: [UnsafeMutablePointer<CChar>?] = environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]

        execve(request.executablePath, &argv, &envp)

        // Only reachable if the exec failed. There is nothing to clean up: the descriptors this
        // process holds are the ones Threading gave it, and closing them is what tells Threading.
        fail(
            "execve failed: \(String(cString: strerror(errno)))",
            code: ExitCode.execFailed
        )
    }

    /// Diagnostics go to stderr, which Threading is already draining into the launch failure it
    /// shows the user. A helper that failed silently would be indistinguishable from an
    /// extension that exited on its own.
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("threading-extension-helper: \(message)\n".utf8))
        exit(code)
    }
}

ThreadingExtensionHelper.main()
