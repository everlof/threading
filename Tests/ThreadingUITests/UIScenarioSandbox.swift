import Foundation
import XCTest

/// One disposable Cocoa home per application-level scenario.
///
/// `CFFIXED_USER_HOME` is the isolation boundary Foundation uses for Application Support and
/// preferences; `HOME` gives child-process discovery the same answer. A UI test must never launch
/// the production app against the developer's real stores, even when the test fails halfway.
struct UIScenarioSandbox {
    private enum Defaults {
        static let markerName = ".threading-ui-scenario-home"
        static let markerContents = "Threading UI scenario home\n"
        static let onboardingCompletedVersion = "onboardingCompletedVersion"
    }

    let root: URL

    private var evidenceDirectory: URL {
        root.appendingPathComponent("evidence", isDirectory: true)
    }

    private var evidenceToken: String {
        root.lastPathComponent
    }

    struct CodexScenarioFixture {
        let project: URL
        let freshTape: URL
        let resumeTape: URL
        let title: String

        @MainActor
        func configure(_ application: XCUIApplication, scenarioRoot: URL) {
            application.launchEnvironment["CODEX_HOME"] = scenarioRoot
                .appendingPathComponent(".codex", isDirectory: true).path
            application.launchEnvironment["THREADING_UI_SCENARIO_PROJECT"] = project.path
            application.launchEnvironment["THREADING_UI_SCENARIO_FRESH_TAPE"] = freshTape.path
            application.launchEnvironment["THREADING_UI_SCENARIO_RESUME_TAPE"] = resumeTape.path
            application.launchEnvironment["THREADING_UI_SCENARIO_TITLE"] = title
        }
    }

    static func make(fileManager: FileManager = .default) throws -> UIScenarioSandbox {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ThreadingUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: root.appendingPathComponent("evidence", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(Defaults.markerContents.utf8).write(
            to: root.appendingPathComponent(Defaults.markerName),
            options: .atomic
        )
        return UIScenarioSandbox(root: root)
    }

    @MainActor
    @discardableResult
    func configure(_ application: XCUIApplication) -> CGSize {
        application.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        application.launchEnvironment["HOME"] = root.path
        application.launchEnvironment["THREADING_UI_SCENARIO_HOME"] = root.path
        application.launchEnvironment["THREADING_UI_SCENARIO_EVIDENCE_DIR"] = evidenceDirectory.path
        application.launchEnvironment["THREADING_UI_SCENARIO_EVIDENCE_TOKEN"] = evidenceToken
        application.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-\(Defaults.onboardingCompletedVersion)", "1",
        ]
        return UIWindowContract.configure(application)
    }

    func captureScenarioEvidence(named name: String) throws -> Data {
        let imageURL = evidenceDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        let errorURL = evidenceDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("error.txt")
        let request = EvidenceCaptureRequest(
            id: UUID(),
            token: evidenceToken,
            name: name
        )
        try JSONEncoder().encode(request).write(
            to: evidenceDirectory.appendingPathComponent("capture-request.json"),
            options: .atomic
        )

        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: imageURL.path)
                    || FileManager.default.fileExists(atPath: errorURL.path)
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [completed], timeout: 5) == .completed else {
            throw UIScenarioSandboxError.evidenceTimedOut(name)
        }
        if let message = try? String(contentsOf: errorURL, encoding: .utf8) {
            throw UIScenarioSandboxError.evidenceCaptureFailed(
                name: name,
                detail: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try Data(contentsOf: imageURL)
    }

    private struct EvidenceCaptureRequest: Encodable {
        let id: UUID
        let token: String
        let name: String
    }

    /// Builds the smallest real checkout and copies every mutable fixture below the isolated
    /// home. The signed replay executable is embedded in the tested app: macOS deliberately
    /// refuses to execute code copied into an XCUITest runner's temporary container.
    func prepareCodexFileChangeFixture(
        fileManager: FileManager = .default
    ) throws -> CodexScenarioFixture {
        try prepareCodexFixture(
            title: "Update status fixture",
            freshTapeName: "codex-update-status-fresh.json",
            resumeTapeName: "codex-update-status-resume.json",
            fileManager: fileManager
        )
    }

    func prepareCodexStopTurnFixture(
        fileManager: FileManager = .default
    ) throws -> CodexScenarioFixture {
        try prepareCodexFixture(
            title: "Stop turn fixture",
            freshTapeName: "codex-stop-turn-fresh.json",
            resumeTapeName: "codex-stop-turn-resume.json",
            fileManager: fileManager
        )
    }

    private func prepareCodexFixture(
        title: String,
        freshTapeName: String,
        resumeTapeName: String,
        fileManager: FileManager
    ) throws -> CodexScenarioFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureDirectory = root.appendingPathComponent("fixture", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let codexSessions = root
            .appendingPathComponent(".codex/sessions/2026/08/11", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(
            to: root.appendingPathComponent(".codex/auth.json"),
            options: .atomic
        )
        try Data("Synthetic UI scenario repository.\n".utf8).write(
            to: project.appendingPathComponent("README.md"),
            options: .atomic
        )
        try Data("before\n".utf8).write(
            to: project.appendingPathComponent("status.txt"),
            options: .atomic
        )

        try runGit(["init", "--quiet"], in: project)
        try runGit(["add", "README.md", "status.txt"], in: project)
        try runGit([
            "-c", "user.name=Threading UI Fixture",
            "-c", "user.email=fixture@invalid.example",
            "commit", "--quiet", "-m", "Initial synthetic state",
        ], in: project)

        let sourceScenarios = repository
            .appendingPathComponent("Fixtures/AgentScenarios", isDirectory: true)
        let freshTape = fixtureDirectory.appendingPathComponent(freshTapeName)
        let resumeTape = fixtureDirectory.appendingPathComponent(resumeTapeName)
        try fileManager.copyItem(
            at: sourceScenarios.appendingPathComponent(freshTape.lastPathComponent),
            to: freshTape
        )
        try fileManager.copyItem(
            at: sourceScenarios.appendingPathComponent(resumeTape.lastPathComponent),
            to: resumeTape
        )
        return CodexScenarioFixture(
            project: project,
            freshTape: freshTape,
            resumeTape: resumeTape,
            title: title
        )
    }

    func remove(fileManager: FileManager = .default) throws {
        let marker = root.appendingPathComponent(Defaults.markerName)
        guard UUID(uuidString: root.lastPathComponent) != nil,
              root.deletingLastPathComponent().lastPathComponent == "ThreadingUITests",
              fileManager.fileExists(atPath: marker.path)
        else {
            throw UIScenarioSandboxError.refusedUnsafeRemoval(root)
        }
        try fileManager.removeItem(at: root)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        // `/usr/bin/git` delegates through xcrun on a developer machine, and xcrun refuses to
        // run inside the UI runner's App Sandbox. Prefer the real command-line-tools binary;
        // retain the system path for hosts where it is a standalone Git executable.
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/usr/bin/git",
        ]
        guard let git = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw UIScenarioSandboxError.gitUnavailable
        }
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw UIScenarioSandboxError.gitFailed(arguments: arguments, detail: detail)
        }
    }
}

enum UIScenarioSandboxError: LocalizedError {
    case refusedUnsafeRemoval(URL)
    case gitUnavailable
    case gitFailed(arguments: [String], detail: String)
    case evidenceTimedOut(String)
    case evidenceCaptureFailed(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .refusedUnsafeRemoval(let url):
            return "refused to remove unverified UI scenario directory at \(url.path)"
        case .gitUnavailable:
            return "the UI scenario host has no executable Git binary"
        case .gitFailed(let arguments, let detail):
            return "git \(arguments.joined(separator: " ")) failed: \(detail)"
        case .evidenceTimedOut(let name):
            return "Threading did not produce UI evidence for \(name)"
        case .evidenceCaptureFailed(let name, let detail):
            return "Threading could not capture UI evidence for \(name): \(detail)"
        }
    }
}
