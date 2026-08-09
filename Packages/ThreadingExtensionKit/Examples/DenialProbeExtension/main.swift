import Darwin
import Foundation
import LocalAuthentication
import Security
import ThreadingExtensionKit

/// Measures what the containment actually denies, from inside it.
///
/// Every other sandbox test in this project reads a generated profile or an entitlements file,
/// which proves what was *written* rather than what the kernel *enforced*. This runs as a real
/// extension and reports what it managed to do.
///
/// It reports on **stderr** and emits an ordinary registration on stdout, so it is a valid
/// extension the launcher will start rather than a special mode the launcher would have to
/// allow. That matters: `--threading-register` and `--threading-serve` are the only entry modes the
/// helper accepts, and widening that list to accommodate a test would weaken the thing the test
/// exists to check.
///
/// `Security` is imported here and nowhere else in the SDK. A real extension has no business
/// touching the Keychain directly — secrets are brokered — which is exactly why a probe must
/// try.
enum DenialProbe {
    static let secretService =
        "codes.threading.extension-secrets.v1.codes.threading.tests.probe"
    static let secretAccount = "containment-probe"
    static let adversarialKeychainEnvironment =
        "THREADING_EXTENSION_ADVERSARIAL_KEYCHAIN_PROBE"

    struct Finding {
        let name: String
        let allowed: Bool
    }

    static func run() -> [Finding] {
        let home = realHomeDirectory()
        let packagePath = CommandLine.arguments[0]
        let adversarialKeychainProbe =
            ProcessInfo.processInfo.environment[adversarialKeychainEnvironment] == "1"

        // This must happen before *any* Keychain query. Even a broad attributes-only query can
        // reach a legacy login-Keychain ACL and ask the user whether this executable should be
        // trusted. The explicit adversarial mode is the sole exception: it proves the runner
        // denies the request even when extension code actively permits UI.
        guard adversarialKeychainProbe
                || SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            FileHandle.standardError.write(Data(
                "keychainProbe=could-not-disable-interaction\n".utf8
            ))
            exit(70)
        }

        return [
            // The positive control. A probe that quietly does nothing reports total denial,
            // which looks identical to perfect containment.
            Finding(name: "readsOwnPackage", allowed: canRead(packagePath)),

            Finding(name: "readsHomeDirectory", allowed: canRead(home + "/.bashrc")),
            Finding(
                name: "readsProjectDatabase",
                allowed: canRead(
                    home + "/Library/Application Support/Threading/threading.db"
                )
            ),
            // The *parent* of the granted directory. The entitlement names
            // `Extensions/Packages/`, so listing `Extensions/` — where every other extension's
            // private storage lives — must be refused. Chosen over `Extensions/Data` because
            // that directory may not exist yet, and "absent" would read as "denied".
            Finding(
                name: "readsExtensionsRoot",
                allowed: canReadDirectory(
                    home + "/Library/Application Support/Threading/Extensions"
                )
            ),
            Finding(name: "writesOwnPackage", allowed: canWrite(packagePath + ".written")),
            Finding(name: "writesTemporaryDirectory", allowed: canWrite("/tmp/threading-probe")),
            // Not "can it call the Keychain API" — a sandboxed process can, scoped to its own
            // access group, and finding nothing there proves nothing. The property that matters
            // is whether it can *read items that are not its own*, so this counts what comes
            // back.
            Finding(
                name: "readsAnyKeychainItem",
                allowed: adversarialKeychainProbe
                    ? false
                    : keychainItemCount(service: nil) > 0
            ),
            Finding(
                name: "readsExtensionSecrets",
                allowed: canReadKeychainData(
                    service: secretService,
                    account: secretAccount,
                    permitsInteraction: adversarialKeychainProbe
                )
            ),
            Finding(name: "listensOnATCPPort", allowed: canListen()),
            Finding(name: "spawnsAnotherProgram", allowed: canSpawn()),
            // Spawning is permitted under App Sandbox where the Seatbelt profile denied it, so
            // what matters is that the child is contained too. A child that escaped would make
            // the whole boundary a formality.
            Finding(
                name: "spawnedChildEscapes",
                allowed: spawnedChildCanRead(home + "/.bashrc")
            )
        ]
    }

    // MARK: - Probes

    private static func canRead(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private static func canReadDirectory(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return false }
        closedir(directory)
        return true
    }

    private static func canWrite(_ path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        unlink(path)
        return true
    }

    /// How many Keychain items the probe can actually see.
    ///
    /// A sandboxed process may call the Keychain API — it is scoped to the access group its own
    /// signature grants — so a permitted query is not an escape. Only items coming *back* are.
    private static func keychainItemCount(service: String?) -> Int {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return 0
        }
        return (result as? [Any])?.count ?? 0
    }

    /// Requests the bytes, not merely metadata, from the exact service/account the host seeds
    /// before launching this probe. A query for a made-up namespace would make "not found"
    /// indistinguishable from isolation, and attributes alone would not prove the secret stayed
    /// secret.
    private static func canReadKeychainData(
        service: String,
        account: String,
        permitsInteraction: Bool
    ) -> Bool {
        // The host store uses the legacy login Keychain on macOS, so the process-wide switch in
        // `run` is the actual guard. Set both modern controls too: they cover Data Protection
        // items and make the query's no-UI contract explicit to Security.framework.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !permitsInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return false
        }
        return (result as? Data)?.isEmpty == false
    }

    /// Runs a child and reports whether *it* could read the path — the containment has to be
    /// inherited, or spawning is a way around it.
    private static func spawnedChildCanRead(_ path: String) -> Bool {
        var pid: pid_t = 0
        let script = "read -r _ < \(path)"
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/bash"), strdup("--norc"), strdup("-c"), strdup(script), nil
        ]
        defer { arguments.forEach { pointer in pointer.map { free($0) } } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        guard posix_spawn(&pid, "/bin/bash", nil, nil, &arguments, &environment) == 0 else {
            return false
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status == 0
    }

    private static func canListen() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0 && listen(descriptor, 1) == 0
    }

    private static func canSpawn() -> Bool {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/echo"), nil]
        defer { arguments.forEach { pointer in pointer.map { free($0) } } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let result = posix_spawn(&pid, "/bin/echo", nil, nil, &arguments, &environment)
        guard result == 0 else { return false }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return true
    }

    /// `getpwuid`, not `NSHomeDirectory()`: under App Sandbox the latter is the container, so a
    /// probe using it would test paths that do not exist and call the absence containment.
    private static func realHomeDirectory() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: directory)
    }
}

let findings = DenialProbe.run()
FileHandle.standardError.write(Data(
    findings
        .map { "\($0.name)=\($0.allowed ? "allowed" : "denied")\n" }
        .joined()
        .utf8
))

switch CommandLine.arguments.dropFirst().first {
case "--threading-register", "--threading-serve", nil:
    let registration = ExtensionRegistration(
        panels: [
            .init(
                id: "denial-probe",
                title: "Denial Probe",
                root: .status(
                    findings.contains { $0.allowed && $0.name != "readsOwnPackage" }
                        ? "Containment is incomplete"
                        : "Contained",
                    role: findings.contains { $0.allowed && $0.name != "readsOwnPackage" }
                        ? .negative
                        : .positive
                )
            )
        ]
    )
    let data = try JSONEncoder().encode(registration)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
default:
    exit(64)
}
