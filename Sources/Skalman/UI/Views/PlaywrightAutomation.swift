import Foundation

struct PlaywrightAutomationOutput {
    let text: String
    let screenshotPNG: Data?
    let succeeded: Bool
}

/// Runs one isolated Playwright scenario in a short-lived helper process.
///
/// Playwright and its browser binaries are intentionally not downloaded by Skalman. The backend
/// uses a local installation when present and otherwise returns one actionable installation
/// command. This keeps the signed-in WKWebView surface independent from a large test runtime.
final class PlaywrightAutomationRunner {
    static let maximumRequestBytes = 256 * 1_024
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumScreenshotBytes = 24 * 1_024 * 1_024
    static let processTimeout: TimeInterval = 75

    struct Runtime {
        let python: URL
        let script: URL
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
        completion: @escaping (PlaywrightAutomationOutput) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let output = runSynchronously(arguments)
            DispatchQueue.main.async {
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

        let runtime: Runtime
        do {
            runtime = try resolveRuntime()
        } catch {
            return failure(error.localizedDescription)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-playwright-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporary,
                withIntermediateDirectories: true
            )
        } catch {
            return failure("Could not prepare isolated browser files: \(error.localizedDescription)")
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
                    "The isolated browser request exceeds \(Self.maximumRequestBytes) bytes."
                )
            }
            if arguments.screenshot == true {
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
            let timeout = DispatchWorkItem {
                guard process.isRunning else { return }
                timeoutLock.lock()
                timedOut = true
                timeoutLock.unlock()
                process.terminate()
            }
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.processTimeout,
                execute: timeout
            )
            process.waitUntilExit()
            timeout.cancel()
            timeoutLock.lock()
            let didTimeOut = timedOut
            timeoutLock.unlock()
            if didTimeOut {
                return failure(
                    "The isolated browser exceeded \(Int(Self.processTimeout)) seconds and was stopped."
                )
            }
        } catch {
            return failure("Could not launch isolated Playwright: \(error.localizedDescription)")
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
                Isolated Playwright scenario failed: \(detail)
                If the browser binary is missing, run: python3 -m playwright install \
                \(arguments.engine ?? "chromium")
                """
            )
        }

        var screenshot: Data?
        if arguments.screenshot == true,
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
                    "Skalman's bundled Playwright bridge is unavailable."]
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
                    SKALMAN_PLAYWRIGHT_PYTHON to that Python executable.
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
        if let configured = ProcessInfo.processInfo.environment["SKALMAN_PLAYWRIGHT_PYTHON"],
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
