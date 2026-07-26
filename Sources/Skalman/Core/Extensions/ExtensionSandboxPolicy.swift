import Foundation
import SkalmanExtensionKit

enum ExtensionSandboxError: LocalizedError {
    case unavailable
    case invalidPath(String)
    case invalidHostURL
    case unsupportedInterpreter(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The macOS extension sandbox is unavailable."
        case .invalidPath(let path):
            return "The extension sandbox cannot represent the path \(path)."
        case .invalidHostURL:
            return "The extension host URL is not a valid loopback endpoint."
        case .unsupportedInterpreter(let path):
            return "The extension uses the unsupported script interpreter \(path)."
        }
    }
}

struct ExtensionProcessLaunch: Equatable {
    let executableURL: URL
    let arguments: [String]
}

/// Turns a manifest's declared authorities into an OS-enforced process boundary.
///
/// `sandbox-exec` is deprecated but remains the only macOS mechanism which can apply a
/// generated Seatbelt profile to an arbitrary child of an otherwise unsandboxed app. Keeping
/// it behind this one launch-policy type is intentional: a future XPC runner can replace the
/// mechanism without changing the package, manifest, host service, or process protocol.
enum ExtensionSandboxPolicy {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    static func launch(
        bundle: SkalmanExtensionBundle,
        commandArguments: [String],
        environment: [String: String],
        sandboxExecutableURL: URL = executableURL,
        fileManager: FileManager = .default
    ) throws -> ExtensionProcessLaunch {
        guard fileManager.isExecutableFile(atPath: sandboxExecutableURL.path) else {
            throw ExtensionSandboxError.unavailable
        }
        let profile = try profile(
            bundle: bundle,
            environment: environment
        )
        let interpreter = try interpreters(for: bundle.executableURL).first
        let commandURL: URL
        let entryArguments: [String]
        if interpreter == "/bin/sh" {
            commandURL = URL(fileURLWithPath: "/bin/bash")
            entryArguments = ["--posix", bundle.executableURL.path]
        } else if let interpreter {
            commandURL = URL(fileURLWithPath: interpreter)
            entryArguments = [bundle.executableURL.path]
        } else {
            commandURL = bundle.executableURL
            entryArguments = []
        }
        return ExtensionProcessLaunch(
            executableURL: sandboxExecutableURL,
            arguments: [
                "-p",
                profile,
                commandURL.path
            ] + entryArguments + commandArguments
        )
    }

    static func profile(
        bundle: SkalmanExtensionBundle,
        environment: [String: String]
    ) throws -> String {
        let packagePaths = try pathVariants(bundle.rootURL.path).map(quoted)
        let executablePaths = try pathVariants(bundle.executableURL.path).map(quoted)
        let interpreterPaths = try interpreters(for: bundle.executableURL)
        let interpreterFilters = try interpreterPaths
            .map { "\n    (literal \(try quoted($0)))" }
            .joined()
        let packageFilters = packagePaths
            .map { "(subpath \($0))" }
            .joined(separator: "\n    ")
        let packageAncestors = packagePaths
            .map { "(path-ancestors \($0))" }
            .joined(separator: "\n    ")
        let executableFilters = executablePaths
            .map { "(literal \($0))" }
            .joined(separator: "\n    ")
        var sections = [
            """
            (version 1)
            (deny default)
            (import "system.sb")
            """,
            """
            ; Secrets are brokered by Skalman. `system.sb` permits Security.framework's
            ; securityd connection, and the legacy login Keychain can otherwise ask the user
            ; to grant arbitrary extension code access. Deny the daemon boundary itself so an
            ; extension cannot turn an ACL prompt into a social-engineering surface.
            (deny mach-lookup
                (global-name "com.apple.securityd.xpc")
                (global-name "com.apple.securityd.general")
                (global-name "com.apple.security.XPCKeychainSandboxCheck"))
            """,
            """
            ; The installed package is immutable to the child.
            (allow file-read* file-test-existence file-map-executable
                \(packageFilters)\(interpreterFilters))
            (allow file-read-metadata file-test-existence
                \(packageAncestors))
            """,
            """
            ; The wrapper may exec only the inspected package entry point.
            (allow process-exec
                \(executableFilters)\(interpreterFilters))
            (allow signal (target self))
            """
        ]

        let writablePaths = try [
            bundle.manifest.capabilities.contains(.keyValueStorage)
                ? environment[ExtensionStorageEnvironment.keyValueDirectory]
                : nil,
            bundle.manifest.capabilities.contains(.cacheStorage)
                ? environment[ExtensionStorageEnvironment.cacheDirectory]
                : nil
        ].compactMap { $0 }
            .flatMap { try pathVariants($0) }
            .map { try quoted($0) }
        if !writablePaths.isEmpty {
            let filters = writablePaths.map { "(subpath \($0))" }.joined(separator: "\n    ")
            let ancestors = writablePaths
                .map { "(path-ancestors \($0))" }
                .joined(separator: "\n    ")
            sections.append(
                """
                ; Storage is private, host-owned, and granted per declared capability.
                (allow file-read* file-write* file-test-existence
                    \(filters))
                (allow file-read-metadata file-test-existence
                    \(ancestors))
                """
            )
        }

        let permitsInternet = bundle.manifest.capabilities.contains(.networkClient)
        if permitsInternet {
            sections.append(
                """
                ; Explicit outbound internet authority. Inbound listeners remain denied.
                (system-network)
                (allow network-outbound
                    (literal "/private/var/run/mDNSResponder")
                    (remote tcp)
                    (remote udp))
                """
            )
        } else if !bundle.manifest.capabilities.isDisjoint(with: hostCapabilities),
                  let rawHostURL = environment[ExtensionHostConnection.urlEnvironmentKey] {
            guard let url = URL(string: rawHostURL),
                  url.scheme == "http",
                  url.host == "127.0.0.1",
                  let port = url.port,
                  (1...65_535).contains(port) else {
                throw ExtensionSandboxError.invalidHostURL
            }
            sections.append(
                """
                ; The broker token is useful only on this generation's loopback port.
                (system-network)
                (allow network-outbound
                    (remote tcp "localhost:\(port)"))
                """
            )
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func pathVariants(_ rawPath: String) throws -> [String] {
        guard NSString(string: rawPath).isAbsolutePath else {
            throw ExtensionSandboxError.invalidPath(rawPath)
        }
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        var paths = [standardized, resolved]
        for path in [standardized, resolved] {
            if path == "/private/var" || path.hasPrefix("/private/var/") {
                paths.append(String(path.dropFirst("/private".count)))
            } else if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
                paths.append(String(path.dropFirst("/private".count)))
            } else if path == "/var" || path.hasPrefix("/var/") {
                paths.append("/private" + path)
            } else if path == "/tmp" || path.hasPrefix("/tmp/") {
                paths.append("/private" + path)
            }
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private static func quoted(_ value: String) throws -> String {
        guard value.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && $0.value != 0x7F
        }) else {
            throw ExtensionSandboxError.invalidPath(value)
        }
        return "\""
            + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func interpreters(for executableURL: URL) throws -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else {
            return []
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: 512) ?? Data()
        } catch {
            return []
        }
        guard data.starts(with: Data("#!".utf8)),
              let line = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .first else {
            return []
        }

        let declaration = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard let rawInterpreter = declaration.split(whereSeparator: \.isWhitespace).first,
              rawInterpreter.first == "/" else {
            return []
        }
        let interpreter = String(rawInterpreter)
        guard interpreter == "/bin/sh" || interpreter == "/bin/bash" else {
            throw ExtensionSandboxError.unsupportedInterpreter(interpreter)
        }
        var interpreters = [interpreter]

        // `/bin/sh` is a dispatch shim on current macOS and execs bash as its implementation.
        if rawInterpreter == "/bin/sh" {
            interpreters.append("/bin/bash")
        }
        return interpreters
    }

    private static let hostCapabilities: Set<ExtensionCapability> = [
        .componentCustomization,
        .hostProjectsRead,
        .hostSessionsRead,
        .hostSessionRuntimeRead,
        .hostRepositoriesRead,
        .hostProvidersRead,
        .hostAccountsPresentationRead,
        .hostEvents,
        .providerIconResolver,
        .accountIconResolver,
        .sessionIdentityRenderer,
        .servicesConsume,
        .secrets
    ]
}
