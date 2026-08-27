import AppKit
import XCTest
@testable import Threading

@MainActor
final class ProjectScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("ProjectScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ProjectScriptService.shared.activate(executionDirectory: nil)
        CommandRegistry.shared.replaceProjectScripts([])
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingConfigurationDiscoversNothing() {
        let catalog = ProjectScriptConfigurationLoader.load(repositoryRoot: root)

        XCTAssertFalse(catalog.configurationExists)
        XCTAssertTrue(catalog.scripts.isEmpty)
        XCTAssertTrue(catalog.diagnostics.isEmpty)
    }

    func testValidConfigurationReadsEveryPublishedField() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("web"),
            withIntermediateDirectories: true
        )
        try writeConfiguration([
            "version": 1,
            "$schema": "./docs/schemas/threading-project.schema.json",
            "scripts": [[
                "id": "web.dev",
                "name": "Web development",
                "command": "npm run dev",
                "icon": "play.fill",
                "workingDirectory": "web",
                "previewURL": "http://localhost:3000/path"
            ]]
        ])

        let catalog = ProjectScriptConfigurationLoader.load(repositoryRoot: root)
        let script = try XCTUnwrap(catalog.scripts.first)
        XCTAssertTrue(catalog.isValid)
        XCTAssertEqual(script.id, "web.dev")
        XCTAssertEqual(script.name, "Web development")
        XCTAssertEqual(script.command, "npm run dev")
        XCTAssertEqual(script.icon, "play.fill")
        XCTAssertEqual(script.workingDirectory, "web")
        XCTAssertEqual(script.previewURL?.absoluteString, "http://localhost:3000/path")

        let invocation = try XCTUnwrap(
            ProjectScriptConfigurationLoader.resolve(script, repositoryRoot: root).invocation
        )
        XCTAssertEqual(invocation.workingDirectory.path, root.appendingPathComponent("web").path)
    }

    func testDefaultsWorkingDirectoryToRepositoryRoot() throws {
        try writeConfiguration([
            "version": 1,
            "scripts": [["id": "check", "name": "Check", "command": "make check"]]
        ])

        let script = try XCTUnwrap(
            ProjectScriptConfigurationLoader.load(repositoryRoot: root).scripts.first
        )
        XCTAssertEqual(script.workingDirectory, ".")
        XCTAssertEqual(
            ProjectScriptConfigurationLoader.resolve(script, repositoryRoot: root)
                .invocation?.workingDirectory.path,
            root.path
        )
    }

    func testMalformedUnknownVersionAndHugeInputsAreRefused() throws {
        try Data("{".utf8).write(to: configurationURL)
        XCTAssertEqual(load().diagnostics.first?.code, .malformedJSON)

        try writeConfiguration(["version": 1, "scripts": [], "setup": "make install"])
        XCTAssertEqual(load().diagnostics.first?.code, .unknownField)

        try writeConfiguration(["version": 2, "scripts": []])
        XCTAssertEqual(load().diagnostics.first?.code, .unsupportedVersion)

        try writeConfiguration(["$schema": 1, "version": 1, "scripts": []])
        XCTAssertEqual(load().diagnostics.first?.code, .invalidSchema)

        let scripts = (0...ProjectScriptDefaults.maximumScripts).map { index in
            ["id": "script-\(index)", "name": "Script \(index)", "command": "true"]
        }
        try writeConfiguration(["version": 1, "scripts": scripts])
        XCTAssertEqual(load().diagnostics.first?.code, .tooManyScripts)
        XCTAssertTrue(load().scripts.isEmpty)

        try Data(repeating: 0x20, count: ProjectScriptDefaults.maximumConfigurationBytes + 1)
            .write(to: configurationURL)
        XCTAssertEqual(load().diagnostics.first?.code, .tooLarge)
    }

    func testInvalidEntriesAreBoundedAndValidNeighborsRemainAvailable() throws {
        var scripts: [[String: Any]] = (0..<ProjectScriptDefaults.maximumScripts).map { index in
            ["id": "BAD \(index)", "name": "Bad", "command": "true"]
        }
        scripts[5] = ["id": "good", "name": "Good", "command": "true"]
        try writeConfiguration(["version": 1, "scripts": scripts])

        let catalog = load()
        XCTAssertEqual(catalog.scripts.map(\.id), ["good"])
        XCTAssertEqual(catalog.diagnostics.count, ProjectScriptDefaults.maximumDiagnostics)
    }

    func testIDsCommandsPathsAndDuplicatesAreValidated() throws {
        try writeConfiguration([
            "version": 1,
            "scripts": [
                ["id": "ok", "name": "Okay", "command": "true"],
                ["id": "ok", "name": "Again", "command": "true"],
                ["id": "Upper", "name": "Upper", "command": "true"],
                ["id": "blank", "name": "   ", "command": "true"],
                ["id": "newline", "name": "Bad", "command": "echo a\necho b"],
                ["id": "escape", "name": "Escape", "command": "true", "workingDirectory": "../outside"],
                ["id": "absolute", "name": "Absolute", "command": "true", "workingDirectory": "/tmp"]
            ]
        ])

        let catalog = load()
        XCTAssertEqual(catalog.scripts.map(\.id), ["ok"])
        XCTAssertTrue(catalog.diagnostics.contains { $0.code == .duplicateID })
        XCTAssertEqual(catalog.diagnostics.count, 6)
    }

    func testPreviewURLAllowsHttpAndHTTPSOnlyWithoutCredentials() throws {
        for (value, accepted) in [
            ("https://example.com:8443/app", true),
            ("http://localhost:5173", true),
            ("file:///tmp/index.html", false),
            ("javascript:alert(1)", false),
            ("https://user:secret@example.com", false),
            ("/relative", false)
        ] {
            try writeConfiguration([
                "version": 1,
                "scripts": [[
                    "id": "preview", "name": "Preview", "command": "true",
                    "previewURL": value
                ]]
            ])
            XCTAssertEqual(!load().scripts.isEmpty, accepted, value)
        }
    }

    func testSymlinkedWorkingDirectoryCannotEscapeCheckout() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("ProjectScriptOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"),
            withDestinationURL: outside
        )
        try writeConfiguration([
            "version": 1,
            "scripts": [[
                "id": "escape", "name": "Escape", "command": "true",
                "workingDirectory": "outside"
            ]]
        ])

        let script = try XCTUnwrap(load().scripts.first)
        XCTAssertTrue(
            ProjectScriptConfigurationLoader.resolve(script, repositoryRoot: root)
                .reason?.contains("outside this checkout") == true
        )
    }

    func testConfigurationFileCannotBeASymbolicLink() throws {
        let target = root.appendingPathComponent("configuration-target.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "scripts": []])
            .write(to: target)
        try FileManager.default.createSymbolicLink(
            at: configurationURL,
            withDestinationURL: target
        )

        XCTAssertEqual(load().diagnostics.first?.code, .unreadable)
        XCTAssertTrue(load().scripts.isEmpty)
    }

    func testDiscoveryAndRefreshNeverExecuteRepositoryCommands() throws {
        let sentinel = root.appendingPathComponent("must-not-exist")
        try writeConfiguration([
            "version": 1,
            "scripts": [[
                "id": "danger", "name": "Danger",
                "command": "touch \(sentinel.path)"
            ]]
        ])
        let registry = CommandRegistry(builtInCommands: [])
        let service = ProjectScriptService(registry: registry)

        service.activate(executionDirectory: root)
        service.reload()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertNotNil(registry.command(id: CommandRegistry.projectScriptID("danger")))
    }

    func testReloadPredictablyReplacesRegistryCommands() throws {
        let registry = CommandRegistry(builtInCommands: [])
        let service = ProjectScriptService(registry: registry)
        try writeConfiguration([
            "version": 1,
            "scripts": [["id": "first", "name": "First", "command": "true"]]
        ])
        service.activate(executionDirectory: root)
        XCTAssertEqual(registry.projectScriptCommands.map(\.id), ["project.script.first"])

        try writeConfiguration([
            "version": 1,
            "scripts": [["id": "second", "name": "Second", "command": "false"]]
        ])
        service.reload()

        XCTAssertNil(registry.command(id: "project.script.first"))
        XCTAssertEqual(registry.projectScriptCommands.map(\.id), ["project.script.second"])
        XCTAssertEqual(registry.projectScriptCommands.first?.detail, "false")
        XCTAssertFalse(registry.projectScriptCommands.first?.isEditable ?? true)
    }

    func testManagedWorktreeUsesItsOwnConfigurationAndWorkingDirectory() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git is unavailable")
        }
        let main = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main"], in: main)
        try writeConfiguration(
            ["version": 1, "scripts": [["id": "main", "name": "Main", "command": "true"]]],
            root: main
        )
        try git(["add", "."], in: main)
        try git([
            "-c", "user.email=tests@example.com", "-c", "user.name=Threading Tests",
            "commit", "-q", "-m", "seed"
        ], in: main)

        let worktree = root.appendingPathComponent("managed")
        try git(["worktree", "add", "-q", "-b", "managed", worktree.path], in: main)
        let package = worktree.appendingPathComponent("packages/app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeConfiguration([
            "version": 1,
            "scripts": [[
                "id": "managed", "name": "Managed", "command": "pwd",
                "workingDirectory": "packages/app"
            ]]
        ], root: worktree)

        let registry = CommandRegistry(builtInCommands: [])
        let service = ProjectScriptService(registry: registry)
        service.activate(executionDirectory: package)

        XCTAssertEqual(service.activeCatalog?.repositoryRoot.path, worktree.path)
        XCTAssertEqual(registry.projectScriptCommands.map(\.id), ["project.script.managed"])
        XCTAssertEqual(
            service.availability(commandID: "project.script.managed")
                .invocation?.workingDirectory.path,
            package.path
        )
    }

    func testShellLineQuotesRepositoryCommandAndPrintsHonestReceipt() throws {
        let marker = root.appendingPathComponent("marker")
        let script = ProjectScript(
            id: "quote",
            name: "Quote ' safely",
            command: "printf '%s' 'ran; safely' > '\(marker.path)'",
            icon: nil,
            workingDirectory: ".",
            previewURL: URL(string: "http://localhost:3000")
        )
        let invocation = ProjectScriptInvocation(
            script: script,
            repositoryRoot: root,
            workingDirectory: root
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ProjectScriptShellCommand.source(for: invocation)]
        process.currentDirectoryURL = root
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ran; safely")
        XCTAssertTrue(text.contains("finished with exit code 0"))
        XCTAssertTrue(text.contains("Preview: http://localhost:3000"))

        let failed = ProjectScript(
            id: "failed",
            name: "Failed",
            command: "exit 23",
            icon: nil,
            workingDirectory: ".",
            previewURL: nil
        )
        let failedProcess = Process()
        let failedOutput = Pipe()
        failedProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        failedProcess.arguments = ["-c", ProjectScriptShellCommand.source(for: .init(
            script: failed,
            repositoryRoot: root,
            workingDirectory: root
        ))]
        failedProcess.standardOutput = failedOutput
        try failedProcess.run()
        failedProcess.waitUntilExit()
        XCTAssertTrue(
            String(
                decoding: failedOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).contains("finished with exit code 23")
        )
    }

    func testWatcherFilterWakesOnlyForConfigurationOrDroppedEvents() {
        let configuration = root.appendingPathComponent(".threading.json").path
        XCTAssertTrue(ProjectScriptConfigurationWatcher.isRelevant(
            path: configuration,
            flags: 0,
            configurationPath: configuration
        ))
        XCTAssertFalse(ProjectScriptConfigurationWatcher.isRelevant(
            path: root.appendingPathComponent("Sources/App.swift").path,
            flags: 0,
            configurationPath: configuration
        ))
        XCTAssertTrue(ProjectScriptConfigurationWatcher.isRelevant(
            path: root.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            configurationPath: configuration
        ))
    }

    func testProjectCommandsJoinRegistryAndPaletteFilter() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceProjectScripts([
            ProjectScript(
                id: "serve", name: "Serve web", command: "npm run dev",
                icon: "play.fill", workingDirectory: ".", previewURL: nil
            )
        ])
        let command = try XCTUnwrap(registry.projectScriptCommands.first)

        XCTAssertEqual(command.id, "project.script.serve")
        XCTAssertEqual(command.group, .projectScripts)
        XCTAssertEqual(command.origin.localCommandID, "serve")
        XCTAssertEqual(command.iconName, "play.fill")
        // A declared script reaches the palette as an ordinary host command: it is registered,
        // so it is searchable by its name, its command text and its group, and it is refused
        // the searches that name none of those.
        let descriptor = command.hostDescriptor(shortcut: nil, availability: .available)
        for query in ["serve", "npm", "project scripts"] {
            XCTAssertEqual(
                HostCommandSearch.results(in: [descriptor], matching: query).map(\.id),
                ["project.script.serve"],
                "a project script must be findable by \(query)"
            )
        }
        XCTAssertTrue(HostCommandSearch.results(in: [descriptor], matching: "unrelated").isEmpty)

        let palette = CommandPaletteViewController(
            catalog: { [descriptor] },
            invoke: { .invoked(commandID: $0) }
        )
        _ = palette.view
        let deadline = Date().addingTimeInterval(2)
        while palette.visibleCommandIDsForTesting.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(palette.visibleCommandIDsForTesting, ["project.script.serve"])
    }

    func testProjectScriptConfirmationAlwaysDefaultsToCancel() {
        let alert = ConfirmationAlert.makeAlert(ConfirmationRequest(
            prompt: .runProjectScript,
            title: "Run?",
            message: "Command",
            confirmTitle: "Run"
        ))

        XCTAssertTrue(ConfirmationPrompt.runProjectScript.defaultsToCancel)
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\r")
        XCTAssertFalse(alert.showsSuppressionButton)
    }

    /// Consent covers the command the terminal will execute, not a plausible prefix chosen by
    /// the repository. The old 600-character excerpt hid this suffix even though the loader
    /// deliberately accepts a bounded 4 KiB command.
    func testProjectScriptConfirmationShowsEveryByteOfTheMaximumCommand() throws {
        let dangerousSuffix = "\nprintf 'hidden suffix reached' >&2"
        let command = String(
            repeating: "#",
            count: ProjectScriptDefaults.maximumCommandBytes - dangerousSuffix.utf8.count
        ) + dangerousSuffix
        XCTAssertEqual(command.utf8.count, ProjectScriptDefaults.maximumCommandBytes)
        XCTAssertFalse(String(command.prefix(600)).contains(dangerousSuffix))

        let invocation = ProjectScriptInvocation(
            script: ProjectScript(
                id: "review",
                name: "Review command",
                command: command,
                icon: nil,
                workingDirectory: ".",
                previewURL: nil
            ),
            repositoryRoot: URL(fileURLWithPath: "/tmp/Project Script"),
            workingDirectory: URL(fileURLWithPath: "/tmp/Project Script")
        )
        let request = AppDelegate.projectScriptConfirmation(for: invocation)
        let accessory = try XCTUnwrap(request.accessory)
        let scroll = try XCTUnwrap(
            accessory.subviews.compactMap { $0 as? ThemedTextScrollView }.first
        )

        XCTAssertEqual(scroll.textView.string, command)
        XCTAssertTrue(scroll.textView.string.hasSuffix(dangerousSuffix))
        XCTAssertFalse(scroll.textView.isEditable)
        XCTAssertTrue(scroll.textView.isSelectable)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(
            request.message.contains(String(command.prefix(600))),
            "the explanatory copy must not reintroduce a truncated command"
        )
        XCTAssertTrue(request.message.contains(invocation.workingDirectory.path))
    }

    private var configurationURL: URL {
        root.appendingPathComponent(ProjectScriptDefaults.configurationFileName)
    }

    private func load() -> ProjectScriptCatalog {
        ProjectScriptConfigurationLoader.load(repositoryRoot: root)
    }

    private func writeConfiguration(_ object: [String: Any], root: URL? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(
            to: (root ?? self.root).appendingPathComponent(
                ProjectScriptDefaults.configurationFileName
            ),
            options: .atomic
        )
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
