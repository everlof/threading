import Foundation

// MARK: - Catalog

/// How a provider publishes the current version of its command-line agent.
///
/// Four runtimes publish an official npm package. Cursor's native installer is itself the
/// installer manifest: it pins the build directory and download URL that a fresh install receives.
/// Both are small, public, credential-free reads.
enum AgentCLIReleaseSource: Equatable, Sendable {
    case npm(packageName: String)
    case cursorInstaller

    var url: URL {
        let string: String
        switch self {
        case .npm(let packageName):
            string = "https://registry.npmjs.org/\(packageName)/latest"
        case .cursorInstaller:
            string = "https://cursor.com/install"
        }
        guard let url = URL(string: string) else {
            preconditionFailure("Authored agent release URL is invalid: \(string)")
        }
        return url
    }

    func latestVersion(in data: Data) throws -> String {
        switch self {
        case .npm:
            let response: NPMLatestPackageResponse
            do {
                response = try JSONDecoder().decode(NPMLatestPackageResponse.self, from: data)
            } catch {
                throw AgentCLIUpdateFailure.Reason.invalidSourceResponse
            }
            guard response.version.utf8.count <= AgentCLIUpdateDefaults.maximumVersionBytes,
                  AgentCLIVersion(response.version) != nil else {
                throw AgentCLIUpdateFailure.Reason.invalidSourceResponse
            }
            return response.version

        case .cursorInstaller:
            guard let script = String(data: data, encoding: .utf8),
                  let finalDirectoryLine = script.split(separator: "\n").first(where: {
                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("FINAL_DIR=")
                  }),
                  let version = AgentCLIVersion(String(finalDirectoryLine)),
                  version.numericComponents.count == AgentCLIUpdateDefaults.cursorVersionParts
            else {
                throw AgentCLIUpdateFailure.Reason.invalidSourceResponse
            }
            return version.display
        }
    }
}

enum AgentCLIVersionComparison: Equatable, Sendable {
    /// SemVer ordering, including prerelease identifiers.
    case semantic
    /// Cursor's date parts are ordered; its trailing commit hash is identity, not precedence.
    case datedBuild
}

struct AgentCLIUpdateDefinition: Equatable, Sendable {
    let id: String
    let displayName: String
    let executable: String
    let versionArguments: [String]
    let source: AgentCLIReleaseSource
    let comparison: AgentCLIVersionComparison
    let updateCommand: String
}

extension AgentKind {
    /// Release metadata for every runtime in the authoritative `AgentKind` inventory.
    ///
    /// The switch is exhaustive on purpose: adding a runtime cannot silently make discovery and
    /// launching support it while leaving update health unaware of it.
    var cliUpdateDefinition: AgentCLIUpdateDefinition {
        switch self {
        case .claude:
            return AgentCLIUpdateDefinition(
                id: rawValue,
                displayName: displayName,
                executable: executableName,
                versionArguments: ["--version"],
                source: .npm(packageName: "@anthropic-ai/claude-code"),
                comparison: .semantic,
                updateCommand: "claude update"
            )
        case .codex:
            return AgentCLIUpdateDefinition(
                id: rawValue,
                displayName: displayName,
                executable: executableName,
                versionArguments: ["--version"],
                source: .npm(packageName: "@openai/codex"),
                comparison: .semantic,
                updateCommand: "codex update"
            )
        case .grok:
            return AgentCLIUpdateDefinition(
                id: rawValue,
                displayName: displayName,
                executable: executableName,
                versionArguments: ["version"],
                source: .npm(packageName: "@xai-official/grok"),
                comparison: .semantic,
                updateCommand: "grok update"
            )
        case .openCode:
            return AgentCLIUpdateDefinition(
                id: rawValue,
                displayName: displayName,
                executable: executableName,
                versionArguments: ["--version"],
                source: .npm(packageName: "opencode-ai"),
                comparison: .semantic,
                updateCommand: "opencode upgrade"
            )
        case .cursor:
            return AgentCLIUpdateDefinition(
                id: rawValue,
                displayName: displayName,
                executable: executableName,
                versionArguments: ["--version"],
                source: .cursorInstaller,
                comparison: .datedBuild,
                updateCommand: "cursor-agent update"
            )
        }
    }
}

enum AgentCLIUpdateCatalog {
    static let all = AgentKind.allCases.map(\.cliUpdateDefinition)
}

// MARK: - Values

struct AgentCLIInstalledTool: Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
}

struct AgentCLIUpdate: Equatable, Sendable {
    let id: String
    let displayName: String
    let installedVersion: String
    let latestVersion: String
    let updateCommand: String
}

struct AgentCLIUpdateFailure: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case installedVersion
        case releaseSource
    }

    enum Reason: Error, Equatable, Sendable {
        case versionCommandTimedOut
        case versionCommandFailed(status: Int32?)
        case versionOutputTooLarge
        case unreadableVersionOutput
        case transport
        case httpStatus(Int)
        case responseTooLarge
        case invalidSourceResponse

        var logValue: String {
            switch self {
            case .versionCommandTimedOut: return "version-command-timeout"
            case .versionCommandFailed(let status):
                return "version-command-exit-\(status.map(String.init) ?? "spawn")"
            case .versionOutputTooLarge: return "version-output-too-large"
            case .unreadableVersionOutput: return "unreadable-version-output"
            case .transport: return "transport"
            case .httpStatus(let status): return "http-\(status)"
            case .responseTooLarge: return "response-too-large"
            case .invalidSourceResponse: return "invalid-source-response"
            }
        }
    }

    let toolID: String
    let stage: Stage
    let reason: Reason
}

struct AgentCLIUpdateReport: Equatable, Sendable {
    let installed: [AgentCLIInstalledTool]
    let updates: [AgentCLIUpdate]
    let failures: [AgentCLIUpdateFailure]
    let checkedSourceCount: Int
    let missingCount: Int
}

// MARK: - Version ordering

/// A bounded version token extracted from human-oriented CLI output.
///
/// The tools currently answer shapes such as `2.1.237 (Claude Code)`, `codex-cli 0.148.0`,
/// and `2026.08.11-e8db854`. Reading the first dotted numeric token keeps the parser independent
/// of provider prose while still refusing a bare build number or an arbitrary line.
struct AgentCLIVersion: Equatable, Comparable, Sendable {
    let display: String
    fileprivate let numericComponents: [Int]
    private let prerelease: [PrereleaseIdentifier]?

    private enum PrereleaseIdentifier: Equatable, Sendable {
        case number(Int)
        case text(String)
    }

    init?(_ output: String) {
        let bytes = Array(output.utf8.prefix(AgentCLIUpdateDefaults.maximumVersionInputBytes))
        var start = 0

        while start < bytes.count {
            guard Self.isDigit(bytes[start]) else {
                start += 1
                continue
            }

            var cursor = start
            var components: [Int] = []
            while cursor < bytes.count {
                let numberStart = cursor
                while cursor < bytes.count, Self.isDigit(bytes[cursor]) { cursor += 1 }
                guard numberStart < cursor,
                      let number = Int(String(decoding: bytes[numberStart..<cursor], as: UTF8.self))
                else { break }
                components.append(number)

                guard cursor < bytes.count, bytes[cursor] == Self.period,
                      cursor + 1 < bytes.count, Self.isDigit(bytes[cursor + 1]) else { break }
                cursor += 1
            }

            guard components.count >= AgentCLIUpdateDefaults.minimumVersionParts else {
                start = max(cursor, start + 1)
                continue
            }

            var end = cursor
            var parsedPrerelease: [PrereleaseIdentifier]?
            if end < bytes.count, bytes[end] == Self.hyphen {
                let suffixStart = end + 1
                var suffixEnd = suffixStart
                while suffixEnd < bytes.count, Self.isVersionSuffix(bytes[suffixEnd]) {
                    suffixEnd += 1
                }
                if suffixStart < suffixEnd {
                    let suffix = String(decoding: bytes[suffixStart..<suffixEnd], as: UTF8.self)
                    parsedPrerelease = suffix.split(separator: ".").map { part in
                        if let number = Int(part) { return .number(number) }
                        return .text(String(part))
                    }
                    end = suffixEnd
                }
            }

            display = String(decoding: bytes[start..<end], as: UTF8.self)
            numericComponents = components
            prerelease = parsedPrerelease
            return
        }
        return nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        compareNumeric(lhs.numericComponents, rhs.numericComponents) == .orderedSame
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch compareNumeric(lhs.numericComponents, rhs.numericComponents) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: break
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?): return false
        case (_?, nil): return true
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                guard left[index] != right[index] else { continue }
                switch (left[index], right[index]) {
                case (.number(let lhs), .number(let rhs)): return lhs < rhs
                case (.number, .text): return true
                case (.text, .number): return false
                case (.text(let lhs), .text(let rhs)): return lhs < rhs
                }
            }
            return left.count < right.count
        }
    }

    func isOlder(than latest: AgentCLIVersion, comparison: AgentCLIVersionComparison) -> Bool {
        switch comparison {
        case .semantic:
            return self < latest
        case .datedBuild:
            return Self.compareNumeric(numericComponents, latest.numericComponents)
                == .orderedAscending
        }
    }

    private static func compareNumeric(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= nine }
    private static func isVersionSuffix(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (byte >= uppercaseA && byte <= uppercaseZ)
            || (byte >= lowercaseA && byte <= lowercaseZ)
            || byte == period
            || byte == hyphen
    }

    private static let zero = Character("0").asciiValue!
    private static let nine = Character("9").asciiValue!
    private static let uppercaseA = Character("A").asciiValue!
    private static let uppercaseZ = Character("Z").asciiValue!
    private static let lowercaseA = Character("a").asciiValue!
    private static let lowercaseZ = Character("z").asciiValue!
    private static let period = Character(".").asciiValue!
    private static let hyphen = Character("-").asciiValue!
}

// MARK: - Checker

struct AgentCLIUpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

struct AgentCLIUpdateChecker: Sendable {
    typealias LocalReader = @Sendable (
        AgentCLIUpdateDefinition
    ) -> Result<String?, AgentCLIUpdateFailure.Reason>
    typealias Transport = @Sendable (URLRequest) async throws -> AgentCLIUpdateHTTPResponse

    /// Constructs the live reader with the login shell already resolved on the main actor.
    /// Background probes must not reach back through `ProfileStorage` to ask for it later.
    static func live(shell: String) -> AgentCLIUpdateChecker {
        AgentCLIUpdateChecker(
            definitions: AgentCLIUpdateCatalog.all,
            localReader: { definition in liveLocalVersion(definition, shell: shell) },
            transport: { request in try await liveTransport(request) }
        )
    }

    private let definitions: [AgentCLIUpdateDefinition]
    private let localReader: LocalReader
    private let transport: Transport

    init(
        definitions: [AgentCLIUpdateDefinition],
        localReader: @escaping LocalReader,
        transport: @escaping Transport
    ) {
        self.definitions = Array(definitions.prefix(AgentCLIUpdateDefaults.maximumTools))
        self.localReader = localReader
        self.transport = transport
    }

    func check() async -> AgentCLIUpdateReport {
        await withTaskGroup(of: IndexedOutcome.self) { group in
            for (index, definition) in definitions.enumerated() {
                group.addTask {
                    let outcome = await check(definition)
                    return IndexedOutcome(index: index, outcome: outcome)
                }
            }

            var outcomes: [IndexedOutcome] = []
            outcomes.reserveCapacity(definitions.count)
            for await outcome in group { outcomes.append(outcome) }
            outcomes.sort { $0.index < $1.index }

            var installed: [AgentCLIInstalledTool] = []
            var updates: [AgentCLIUpdate] = []
            var failures: [AgentCLIUpdateFailure] = []
            var checkedSourceCount = 0
            var missingCount = 0

            for indexed in outcomes {
                switch indexed.outcome {
                case .missing:
                    missingCount += 1
                case .failed(let installedTool, let failure):
                    if let installedTool { installed.append(installedTool) }
                    failures.append(failure)
                case .checked(let installedTool, let update):
                    checkedSourceCount += 1
                    installed.append(installedTool)
                    if let update { updates.append(update) }
                }
            }

            return AgentCLIUpdateReport(
                installed: installed,
                updates: updates,
                failures: failures,
                checkedSourceCount: checkedSourceCount,
                missingCount: missingCount
            )
        }
    }

    private func check(_ definition: AgentCLIUpdateDefinition) async -> Outcome {
        let localResult = await readLocalVersion(definition)
        let installedVersionText: String
        switch localResult {
        case .success(nil):
            return .missing
        case .success(.some(let version)):
            installedVersionText = version
        case .failure(let reason):
            return .failed(
                installed: nil,
                failure: AgentCLIUpdateFailure(
                    toolID: definition.id,
                    stage: .installedVersion,
                    reason: reason
                )
            )
        }

        guard let installedVersion = AgentCLIVersion(installedVersionText) else {
            return .failed(
                installed: nil,
                failure: AgentCLIUpdateFailure(
                    toolID: definition.id,
                    stage: .installedVersion,
                    reason: .unreadableVersionOutput
                )
            )
        }
        let installed = AgentCLIInstalledTool(
            id: definition.id,
            displayName: definition.displayName,
            version: installedVersion.display
        )

        let latestVersionText: String
        do {
            var request = URLRequest(
                url: definition.source.url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: AgentCLIUpdateDefaults.requestTimeout
            )
            request.httpMethod = "GET"
            request.setValue(AgentCLIUpdateDefaults.userAgent, forHTTPHeaderField: "User-Agent")
            let response = try await transport(request)
            guard (200...299).contains(response.statusCode) else {
                throw AgentCLIUpdateFailure.Reason.httpStatus(response.statusCode)
            }
            guard response.data.count <= AgentCLIUpdateDefaults.maximumResponseBytes else {
                throw AgentCLIUpdateFailure.Reason.responseTooLarge
            }
            latestVersionText = try definition.source.latestVersion(in: response.data)
        } catch let reason as AgentCLIUpdateFailure.Reason {
            return .failed(
                installed: installed,
                failure: AgentCLIUpdateFailure(
                    toolID: definition.id,
                    stage: .releaseSource,
                    reason: reason
                )
            )
        } catch {
            ThreadingLogger.updates.error(
                "Agent CLI release-source transport failed tool=\(definition.id, privacy: .public) host=\(definition.source.url.host ?? "unknown", privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .failed(
                installed: installed,
                failure: AgentCLIUpdateFailure(
                    toolID: definition.id,
                    stage: .releaseSource,
                    reason: .transport
                )
            )
        }

        guard let latestVersion = AgentCLIVersion(latestVersionText) else {
            return .failed(
                installed: installed,
                failure: AgentCLIUpdateFailure(
                    toolID: definition.id,
                    stage: .releaseSource,
                    reason: .invalidSourceResponse
                )
            )
        }
        let update: AgentCLIUpdate? = installedVersion.isOlder(
            than: latestVersion,
            comparison: definition.comparison
        ) ? AgentCLIUpdate(
            id: definition.id,
            displayName: definition.displayName,
            installedVersion: installedVersion.display,
            latestVersion: latestVersion.display,
            updateCommand: definition.updateCommand
        ) : nil

        return .checked(installed: installed, update: update)
    }

    private func readLocalVersion(
        _ definition: AgentCLIUpdateDefinition
    ) async -> Result<String?, AgentCLIUpdateFailure.Reason> {
        let reader = localReader
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: reader(definition))
            }
        }
    }

    private static func liveLocalVersion(
        _ definition: AgentCLIUpdateDefinition,
        shell: String
    ) -> Result<String?, AgentCLIUpdateFailure.Reason> {
        guard let path = AgentCLIProbe.locate(
            definition.executable,
            shell: shell
        ) else { return .success(nil) }

        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: path,
                arguments: definition.versionArguments,
                environment: AgentEnvironment.launchEnvironment(),
                timeout: AgentCLIUpdateDefaults.versionCommandTimeout,
                maximumOutputBytes: AgentCLIUpdateDefaults.maximumVersionOutputBytes,
                output: .standardOutput
            )
        } catch {
            return .failure(.versionCommandFailed(status: nil))
        }

        switch result.termination {
        case .timedOut:
            return .failure(.versionCommandTimedOut)
        case .exited(let status) where status != 0:
            return .failure(.versionCommandFailed(status: status))
        case .exited:
            break
        }
        guard !result.outputWasTruncated else { return .failure(.versionOutputTooLarge) }

        let output = String(decoding: result.output, as: UTF8.self)
        guard let version = AgentCLIVersion(output) else {
            return .failure(.unreadableVersionOutput)
        }
        return .success(version.display)
    }

    private static func liveTransport(
        _ request: URLRequest
    ) async throws -> AgentCLIUpdateHTTPResponse {
        let (bytes, response) = try await AgentCLIUpdateHTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentCLIUpdateFailure.Reason.transport
        }

        // A status failure needs no body. Dropping the byte sequence cancels the transfer rather
        // than accepting an error page whose size and format are irrelevant to the result.
        guard (200...299).contains(http.statusCode) else {
            return AgentCLIUpdateHTTPResponse(data: Data(), statusCode: http.statusCode)
        }

        let expectedLength = http.expectedContentLength
        guard expectedLength == NSURLSessionTransferSizeUnknown
                || expectedLength <= Int64(AgentCLIUpdateDefaults.maximumResponseBytes) else {
            throw AgentCLIUpdateFailure.Reason.responseTooLarge
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            guard data.count < AgentCLIUpdateDefaults.maximumResponseBytes else {
                throw AgentCLIUpdateFailure.Reason.responseTooLarge
            }
            data.append(byte)
        }
        return AgentCLIUpdateHTTPResponse(data: data, statusCode: http.statusCode)
    }

    private struct IndexedOutcome: Sendable {
        let index: Int
        let outcome: Outcome
    }

    private enum Outcome: Sendable {
        case missing
        case failed(installed: AgentCLIInstalledTool?, failure: AgentCLIUpdateFailure)
        case checked(installed: AgentCLIInstalledTool, update: AgentCLIUpdate?)
    }
}

private struct NPMLatestPackageResponse: Decodable {
    let version: String
}

private enum AgentCLIUpdateHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = AgentCLIUpdateDefaults.requestTimeout
        configuration.timeoutIntervalForResource = AgentCLIUpdateDefaults.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

private enum AgentCLIUpdateDefaults {
    static let maximumTools = 5
    static let minimumVersionParts = 2
    static let cursorVersionParts = 3
    static let maximumVersionBytes = 128
    static let maximumVersionInputBytes = 16 * 1_024
    static let maximumVersionOutputBytes = 16 * 1_024
    static let maximumResponseBytes = 256 * 1_024
    static let versionCommandTimeout: TimeInterval = 5
    static let requestTimeout: TimeInterval = 10
    static let userAgent = "Threading-Agent-CLI-Update-Check"
}
