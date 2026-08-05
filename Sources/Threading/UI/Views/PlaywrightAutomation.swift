import Foundation

struct PlaywrightAutomationOutput: Sendable {
    let text: String
    let screenshotPNG: Data?
    let succeeded: Bool
}

/// Runs one Playwright scenario in a short-lived helper process.
///
/// Playwright and its browser binaries are intentionally not downloaded by Threading. The backend
/// uses a local installation when present and otherwise returns one actionable installation
/// command. This keeps the signed-in WKWebView surface independent from a large test runtime.
///
/// Two scenarios, two argument types, and two entry points, because their guarantees differ:
/// an isolated run imports nothing, while an attached run drives a Chrome profile the user has
/// signed into and is therefore fenced by an origin allowlist granted before it launches.
final class PlaywrightAutomationRunner: Sendable {
    static let maximumRequestBytes = 256 * 1_024
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumScreenshotBytes = 24 * 1_024 * 1_024
    static let processTimeout: TimeInterval = 75
    /// An attached run is allowed to wait for a person: the whole point of driving real Chrome
    /// is that the sign-in is one Touch ID *the user performs*, and a 75-second ceiling would
    /// end the run while they were still reaching for the sensor.
    static let attachProcessTimeout: TimeInterval = 300

    struct Runtime {
        let python: URL
        let script: URL
    }

    /// The profile facts an attached run needs, decided by the app rather than by the agent.
    ///
    /// The origins are the canonical `BrowserOrigin.key` strings the user actually granted, not
    /// the strings the tool call asked for — the bridge compares against exactly these.
    struct AttachProfile: Sendable {
        let userDataDirectory: URL
        let channel: String
        let allowedOrigins: [String]
    }

    private let pythonOverride: URL?
    private let scriptOverride: URL?

    init(python: URL? = nil, script: URL? = nil) {
        pythonOverride = python
        scriptOverride = script
    }

    func availability() -> Bool {
        (try? resolveRuntime()) != nil
    }

    func run(
        _ arguments: BrowserIsolatedRunArguments,
        completion: @escaping @MainActor @Sendable (PlaywrightAutomationOutput) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let output = runSynchronously(arguments)
            Task { @MainActor in
                completion(output)
            }
        }
    }

    func run(
        _ arguments: BrowserAttachRunArguments,
        profile: AttachProfile,
        completion: @escaping @MainActor @Sendable (PlaywrightAutomationOutput) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let output = runSynchronously(arguments, profile: profile)
            Task { @MainActor in
                completion(output)
            }
        }
    }

    private func runSynchronously(
        _ arguments: BrowserIsolatedRunArguments
    ) -> PlaywrightAutomationOutput {
        let steps = arguments.steps ?? []
        guard (1...50).contains(steps.count) else {
            return failure("steps must contain between 1 and 50 entries.")
        }
        if arguments.fullPage == true && arguments.screenshot != true {
            return failure("full_page requires screenshot=true.")
        }
        if arguments.includeImage == true && arguments.screenshot != true {
            return failure("include_image requires screenshot=true.")
        }

        return execute(
            arguments,
            capturesScreenshot: arguments.screenshot == true,
            timeout: Self.processTimeout,
            failureIntro: "Isolated Playwright scenario failed",
            failureHint: """
                If the browser binary is missing, run: python3 -m playwright install \
                \(arguments.engine ?? "chromium")
                """
        ) { _ in [:] }
    }

    private func runSynchronously(
        _ arguments: BrowserAttachRunArguments,
        profile: AttachProfile
    ) -> PlaywrightAutomationOutput {
        let steps = arguments.steps ?? []
        guard (1...50).contains(steps.count) else {
            return failure("steps must contain between 1 and 50 entries.")
        }
        if arguments.fullPage == true && arguments.screenshot != true {
            return failure("full_page requires screenshot=true.")
        }
        if arguments.includeImage == true && arguments.screenshot != true {
            return failure("include_image requires screenshot=true.")
        }
        guard !profile.allowedOrigins.isEmpty else {
            return failure("An attached run needs at least one authorized origin.")
        }

        return execute(
            arguments,
            capturesScreenshot: arguments.screenshot == true,
            timeout: Self.attachProcessTimeout,
            failureIntro: "Attached Chrome scenario failed",
            failureHint: """
                If Chrome refused the profile, close any window already using it and try again; \
                one profile directory can only be open in one Chrome at a time.
                """
        ) { _ in
            // The app decides the mode, the profile, and the granted origins. Whatever the tool
            // call said about them was already normalized and authorized before this point.
            [
                "mode": "attach",
                "user_data_dir": profile.userDataDirectory.path,
                "channel": profile.channel,
                "allowed_origins": profile.allowedOrigins
            ]
        }
    }

    /// Encodes one request, runs the bridge, and reads its bounded reply.
    ///
    /// `overrides` is where an app-owned fact wins over an agent-supplied one, so a mode or an
    /// origin list cannot be talked into something else by the arguments it travels beside.
    private func execute<Arguments: Encodable>(
        _ arguments: Arguments,
        capturesScreenshot: Bool,
        timeout: TimeInterval,
        failureIntro: String,
        failureHint: String,
        overrides: (Arguments) -> [String: Any]
    ) -> PlaywrightAutomationOutput {
        let runtime: Runtime
        do {
            runtime = try resolveRuntime()
        } catch {
            return failure(error.localizedDescription)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-playwright-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporary,
                withIntermediateDirectories: true
            )
        } catch {
            return failure("Could not prepare browser automation files: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let requestURL = temporary.appendingPathComponent("request.json")
        let responseURL = temporary.appendingPathComponent("response.json")
        let errorURL = temporary.appendingPathComponent("stderr.txt")
        let screenshotURL = temporary.appendingPathComponent("screenshot.png")

        do {
            let encoded = try JSONEncoder().encode(arguments)
            guard encoded.count <= Self.maximumRequestBytes,
                  var object = try JSONSerialization.jsonObject(with: encoded)
                    as? [String: Any] else {
                return failure(
                    "The browser automation request exceeds \(Self.maximumRequestBytes) bytes."
                )
            }
            for (key, value) in overrides(arguments) {
                object[key] = value
            }
            if capturesScreenshot {
                object["_screenshot_path"] = screenshotURL.path
            }
            let request = try JSONSerialization.data(withJSONObject: object)
            try request.write(to: requestURL, options: .atomic)
            FileManager.default.createFile(atPath: responseURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        } catch {
            return failure("Could not encode isolated browser request: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = runtime.python
        process.arguments = [runtime.script.path]
        process.currentDirectoryURL = temporary

        do {
            let input = try FileHandle(forReadingFrom: requestURL)
            let output = try FileHandle(forWritingTo: responseURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer {
                try? input.close()
                try? output.close()
                try? error.close()
            }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            let timeoutLock = NSLock()
            var timedOut = false
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                timeoutLock.lock()
                timedOut = true
                timeoutLock.unlock()
                process.terminate()
            }
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: watchdog
            )
            process.waitUntilExit()
            watchdog.cancel()
            timeoutLock.lock()
            let didTimeOut = timedOut
            timeoutLock.unlock()
            if didTimeOut {
                return failure(
                    "The browser automation run exceeded \(Int(timeout)) seconds and was stopped."
                )
            }
        } catch {
            return failure("Could not launch Playwright: \(error.localizedDescription)")
        }

        let stderr = boundedText(at: errorURL, maximumBytes: 4_096)
        guard process.terminationStatus == 0 else {
            let detail = stderr.isEmpty ? "" : " \(stderr)"
            return failure("The Playwright helper exited unexpectedly.\(detail)")
        }
        guard let responseData = try? Data(contentsOf: responseURL),
              !responseData.isEmpty,
              responseData.count <= Self.maximumResponseBytes,
              let response = try? JSONSerialization.jsonObject(with: responseData)
                as? [String: Any],
              let succeeded = response["ok"] as? Bool else {
            return failure("The Playwright helper returned an invalid or oversized response.")
        }

        if !succeeded {
            let detail = (response["error"] as? String).map {
                String($0.prefix(1_000))
            } ?? "The scenario failed."
            return failure(
                """
                \(failureIntro): \(detail)
                \(failureHint)
                """
            )
        }

        var screenshot: Data?
        if capturesScreenshot,
           let data = try? Data(contentsOf: screenshotURL),
           data.count <= Self.maximumScreenshotBytes {
            screenshot = data
        }
        guard let formatted = prettyJSON(response) else {
            return failure("The Playwright helper result could not be encoded.")
        }
        return PlaywrightAutomationOutput(
            text: formatted,
            screenshotPNG: screenshot,
            succeeded: true
        )
    }

    private func resolveRuntime() throws -> Runtime {
        let fileManager = FileManager.default
        guard let script = scriptOverride ?? Self.defaultScriptURL(),
              fileManager.fileExists(atPath: script.path) else {
            throw NSError(
                domain: "PlaywrightAutomation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Threading's bundled Playwright bridge is unavailable."]
            )
        }
        let candidates = [pythonOverride].compactMap { $0 }
            + Self.pythonCandidates()
        guard let python = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw NSError(
                domain: "PlaywrightAutomation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    """
                    Playwright is not installed. Install Python Playwright and its browser binaries \
                    (`python3 -m pip install playwright` then \
                    `python3 -m playwright install chromium`), or set \
                    THREADING_PLAYWRIGHT_PYTHON to that Python executable.
                    """]
            )
        }
        return Runtime(python: python, script: script)
    }

    private static func defaultScriptURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "playwright_bridge",
            withExtension: "py",
            subdirectory: "BrowserAutomation"
        ) {
            return bundled
        }
        // Keeps the Xcode test host and an unbundled development launch useful.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BrowserAutomation/playwright_bridge.py")
    }

    private static func pythonCandidates() -> [URL] {
        var paths: [String] = []
        if let configured = ProcessInfo.processInfo.environment["THREADING_PLAYWRIGHT_PYTHON"],
           configured.hasPrefix("/") {
            paths.append(configured)
        }
        var playwrightCommands = [
            "/opt/homebrew/bin/playwright",
            "/usr/local/bin/playwright"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            playwrightCommands += path.split(separator: ":").map {
                String($0) + "/playwright"
            }
        }
        for command in playwrightCommands {
            if let interpreter = shebangInterpreter(at: URL(fileURLWithPath: command)) {
                paths.append(interpreter)
            }
        }
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static func shebangInterpreter(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512),
              let firstLine = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first,
              firstLine.hasPrefix("#!/") else {
            return nil
        }
        return String(firstLine.dropFirst(2)).split(separator: " ").first.map(String.init)
    }

    private func boundedText(at url: URL, maximumBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes) else { return "" }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prettyJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func failure(_ message: String) -> PlaywrightAutomationOutput {
        PlaywrightAutomationOutput(
            text: message,
            screenshotPNG: nil,
            succeeded: false
        )
    }
}
