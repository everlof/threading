import XCTest
@testable import Threading

// MARK: - Shim Directory

/// The per-user directory Threading republishes its tools into at every launch.
///
/// The interesting cases are all about *what it must not touch*: the bundle moves under it on
/// every autoinstall, so the refresh has to be free to rewrite its own entries, and it shares a
/// directory with nothing, so anything it did not write belongs to whoever did.
final class ThreadingCommandLineToolsTests: XCTestCase {

    private var root: URL!
    private let tool = PTYHostDefaults.helperName

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "ThreadingCommandLineToolsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Refresh

    func testRefreshLinksEveryPublicToolAtTheRunningBundle() throws {
        let bundle = try makeBundle(named: "First", shipping: [tool])

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: bundle,
            directory: shimDirectory
        )

        XCTAssertEqual(outcome.created, ThreadingCommandLineTools.publicTools)
        XCTAssertEqual(outcome.replaced, [])
        XCTAssertEqual(outcome.removed, [])
        XCTAssertTrue(outcome.changedAnything)
        XCTAssertEqual(
            destination(of: shimDirectory.appendingPathComponent(tool)),
            bundle.appendingPathComponent("Contents/Helpers/\(tool)").path
        )
    }

    /// The whole reason the shim exists: the bundle is replaced wholesale by the autoinstall
    /// hook, and a link written by yesterday's launch names a path that no longer holds a helper.
    func testRefreshRepointsALinkLeftByAnEarlierBundle() throws {
        let old = try makeBundle(named: "Old", shipping: [tool])
        ThreadingCommandLineTools.refresh(bundleURL: old, directory: shimDirectory)
        let new = try makeBundle(named: "New", shipping: [tool])

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: new,
            directory: shimDirectory
        )

        XCTAssertEqual(outcome.replaced, [tool])
        XCTAssertEqual(outcome.created, [])
        XCTAssertEqual(
            destination(of: shimDirectory.appendingPathComponent(tool)),
            new.appendingPathComponent("Contents/Helpers/\(tool)").path
        )
    }

    /// The ordinary launch. Nothing is written, which is what lets the journal line mean
    /// something when it does appear.
    func testRefreshChangesNothingWhenTheBundleHasNotMoved() throws {
        let bundle = try makeBundle(named: "Same", shipping: [tool])
        ThreadingCommandLineTools.refresh(bundleURL: bundle, directory: shimDirectory)

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: bundle,
            directory: shimDirectory
        )

        XCTAssertFalse(outcome.changedAnything)
        XCTAssertEqual(outcome, ThreadingCommandLineTools.RefreshOutcome())
    }

    /// A build that ships no helper gets no link. A dangling one would be worse than nothing:
    /// `command -v` still finds the name and the exec is what fails.
    func testRefreshRemovesTheLinkWhenTheBundleStopsShippingTheTool() throws {
        let shipping = try makeBundle(named: "Shipping", shipping: [tool])
        ThreadingCommandLineTools.refresh(bundleURL: shipping, directory: shimDirectory)
        let empty = try makeBundle(named: "Empty", shipping: [])

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: empty,
            directory: shimDirectory
        )

        XCTAssertEqual(outcome.removed, [tool])
        XCTAssertEqual(outcome.unavailable, [tool])
        XCTAssertEqual(
            ThreadingCommandLineTools.entry(at: shimDirectory.appendingPathComponent(tool)),
            .missing
        )
    }

    func testRefreshRemovesARetiredShimAndLeavesEverythingElseAlone() throws {
        let bundle = try makeBundle(named: "Current", shipping: [tool])
        ThreadingCommandLineTools.refresh(bundleURL: bundle, directory: shimDirectory)

        // One of ours from an older release, one of somebody else's, and a plain file.
        let retired = shimDirectory.appendingPathComponent("threading-retired")
        try FileManager.default.createSymbolicLink(
            atPath: retired.path,
            withDestinationPath: bundle.appendingPathComponent(
                "Contents/Helpers/threading-retired"
            ).path
        )
        let foreignLink = shimDirectory.appendingPathComponent("ls")
        try FileManager.default.createSymbolicLink(
            atPath: foreignLink.path,
            withDestinationPath: "/bin/ls"
        )
        let note = shimDirectory.appendingPathComponent("notes.txt")
        try "mine".write(to: note, atomically: true, encoding: .utf8)

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: bundle,
            directory: shimDirectory
        )

        XCTAssertEqual(outcome.removed, ["threading-retired"])
        XCTAssertEqual(ThreadingCommandLineTools.entry(at: retired), .missing)
        XCTAssertEqual(
            ThreadingCommandLineTools.entry(at: foreignLink),
            .symbolicLink(destination: "/bin/ls")
        )
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "mine")
    }

    /// A real file wearing a tool's name is a collision, not a stale link. Reported and left.
    func testRefreshWillNotWriteOverAFileHoldingAToolsName() throws {
        let bundle = try makeBundle(named: "Colliding", shipping: [tool])
        try FileManager.default.createDirectory(
            at: shimDirectory,
            withIntermediateDirectories: true
        )
        let occupied = shimDirectory.appendingPathComponent(tool)
        try "not ours".write(to: occupied, atomically: true, encoding: .utf8)

        let outcome = ThreadingCommandLineTools.refresh(
            bundleURL: bundle,
            directory: shimDirectory
        )

        XCTAssertEqual(outcome.foreign, [tool])
        XCTAssertFalse(outcome.changedAnything)
        XCTAssertEqual(ThreadingCommandLineTools.entry(at: occupied), .other)
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "not ours")
    }

    // MARK: - Hosted Test Redirect

    /// The bundle hosting this test *is* the shipping app, so an unredirected refresh would
    /// rewrite the developer's own shims to point at the test host.
    func testTheShimDirectoryRedirectsUnderAHostedTestBundle() {
        XCTAssertTrue(StateManager.isHostedTest)
        XCTAssertTrue(
            ThreadingCommandLineTools.directory.path
                .hasPrefix(StateManager.hostedTestDirectory().path)
        )
        XCTAssertNotEqual(
            ThreadingCommandLineTools.supportRoot,
            AppDataLocations.supportDirectory
        )
        XCTAssertEqual(
            ThreadingCommandLineTools.directory.lastPathComponent,
            ThreadingCommandLineToolDefaults.directoryName
        )
    }

    // MARK: - Fixtures

    private var shimDirectory: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    private func makeBundle(named name: String, shipping tools: [String]) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).app", isDirectory: true)
        let helpers = bundle.appendingPathComponent(
            ThreadingCommandLineToolDefaults.helpersDirectoryPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        for tool in tools {
            let executable = helpers.appendingPathComponent(tool)
            try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return bundle
    }

    private func destination(of url: URL) -> String? {
        guard case .symbolicLink(let destination) =
            ThreadingCommandLineTools.entry(at: url) else { return nil }
        return destination
    }
}

// MARK: - Installer

/// The user-facing half: one symlink in `~/.local/bin`, and the question of whether the shell
/// that would run it can see that directory at all.
final class CommandLineToolInstallerTests: XCTestCase {

    private var root: URL!
    private let tool = PTYHostDefaults.helperName

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "CommandLineToolInstallerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Install and remove

    func testInstallAndRemoveRoundTripInAScratchHome() throws {
        XCTAssertEqual(status().placement, .absent)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: CommandLineToolInstaller.binaryDirectory(home: home).path
            ),
            "the fixture home must start without the directory, or creating it is untested"
        )

        try CommandLineToolInstaller.install(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )

        let installed = status()
        XCTAssertEqual(installed.placement, .installed)
        XCTAssertTrue(installed.isInstalled)
        XCTAssertEqual(
            installed.linkURL.path,
            home.appendingPathComponent(".local/bin/\(tool)").path
        )
        XCTAssertEqual(
            ThreadingCommandLineTools.entry(at: installed.linkURL),
            .symbolicLink(destination: shimDirectory.appendingPathComponent(tool).path)
        )

        try CommandLineToolInstaller.remove(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        XCTAssertEqual(status().placement, .absent)
    }

    func testInstallingTwiceIsTheSameAsInstallingOnce() throws {
        try CommandLineToolInstaller.install(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        try CommandLineToolInstaller.install(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        XCTAssertEqual(status().placement, .installed)
    }

    /// A user's own binary of the same name is a collision to report, not a file to overwrite.
    func testInstallRefusesAFileSomebodyElsePutThere() throws {
        try makeBinaryDirectory()
        let link = CommandLineToolInstaller.linkURL(for: tool, home: home)
        try "theirs".write(to: link, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CommandLineToolInstaller.install(
                tool: tool,
                home: home,
                shimDirectory: shimDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? CommandLineToolInstallError,
                .pathOccupied(path: link.path)
            )
        }
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "theirs")
        XCTAssertEqual(status().placement, .occupied)
    }

    func testRemoveRefusesALinkThreadingDidNotWrite() throws {
        try makeBinaryDirectory()
        let link = CommandLineToolInstaller.linkURL(for: tool, home: home)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/bin/ls"
        )

        XCTAssertThrowsError(
            try CommandLineToolInstaller.remove(
                tool: tool,
                home: home,
                shimDirectory: shimDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? CommandLineToolInstallError,
                .pathNotOurs(path: link.path, destination: "/bin/ls")
            )
        }
        XCTAssertEqual(
            ThreadingCommandLineTools.entry(at: link),
            .symbolicLink(destination: "/bin/ls")
        )
        XCTAssertEqual(status().placement, .foreignLink(destination: "/bin/ls"))
    }

    /// A link written before the support directory moved is still ours, and is repointed rather
    /// than refused.
    func testInstallRepointsALinkIntoAnOlderShimDirectory() throws {
        try makeBinaryDirectory()
        let link = CommandLineToolInstaller.linkURL(for: tool, home: home)
        let older = root.appendingPathComponent("older/bin/\(tool)")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: older.path
        )

        try CommandLineToolInstaller.install(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )

        XCTAssertEqual(status().placement, .installed)
    }

    func testRemovingSomethingThatIsNotThereIsNotAnError() throws {
        try CommandLineToolInstaller.remove(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        XCTAssertEqual(status().placement, .absent)
    }

    // MARK: - PATH

    func testTheBinaryDirectoryIsRecognisedHoweverThePATHEntryIsSpelled() {
        let directory = "/Users/someone/.local/bin"
        XCTAssertTrue(
            CommandLineToolInstaller.directory(directory, isOn: "/usr/bin:\(directory):/bin")
        )
        XCTAssertTrue(
            CommandLineToolInstaller.directory(directory, isOn: "\(directory)/:/usr/bin")
        )
        XCTAssertTrue(CommandLineToolInstaller.directory(directory, isOn: directory))
        XCTAssertFalse(CommandLineToolInstaller.directory(directory, isOn: "/usr/bin:/bin"))
        // A `PATH` ending in a colon carries an empty entry, which means the working directory
        // and must never be mistaken for a match.
        XCTAssertFalse(CommandLineToolInstaller.directory(directory, isOn: "/usr/bin:"))
        XCTAssertFalse(CommandLineToolInstaller.directory(directory, isOn: ""))
        // A near miss is a miss: `/Users/someone/.local/bin2` is a different directory.
        XCTAssertFalse(CommandLineToolInstaller.directory(directory, isOn: "\(directory)2"))
    }

    func testATildeEntryAndAnExpandedOneAreTheSameDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(
            CommandLineToolInstaller.directory("\(home)/.local/bin", isOn: "~/.local/bin:/usr/bin")
        )
    }

    func testThePATHIsReadOutOfAnEnvironmentDump() {
        let output = """
        SHELL=/bin/zsh
        PATH=/opt/homebrew/bin:/usr/bin:/bin
        LANG=en_US.UTF-8
        """
        XCTAssertEqual(
            CommandLineToolInstaller.path(fromEnvironmentOutput: output),
            "/opt/homebrew/bin:/usr/bin:/bin"
        )
        XCTAssertNil(CommandLineToolInstaller.path(fromEnvironmentOutput: "SHELL=/bin/zsh"))
        XCTAssertNil(CommandLineToolInstaller.path(fromEnvironmentOutput: ""))
    }

    func testTheProfileLineNamesTheDirectoryAndKeepsWhatIsAlreadyThere() {
        XCTAssertEqual(
            CommandLineToolInstaller.profileLine,
            "export PATH=\"$HOME/.local/bin:$PATH\""
        )
    }

    // MARK: - Fixtures

    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var shimDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }

    private func status() -> CommandLineToolStatus {
        CommandLineToolInstaller.status(
            for: tool,
            home: home,
            shimDirectory: shimDirectory
        )
    }

    private func makeBinaryDirectory() throws {
        try FileManager.default.createDirectory(
            at: CommandLineToolInstaller.binaryDirectory(home: home),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Environment

/// What the opt-in does to the environment of everything Threading launches.
final class CommandLineToolsEnvironmentTests: XCTestCase {

    private let shim = "/Users/someone/Library/Application Support/Threading/bin"

    func testTheShimDirectoryGoesInFrontAndNothingElseMoves() {
        let environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "HOME": "/Users/someone",
            "TERM": "xterm-256color",
        ]

        let applied = AgentEnvironment.applyingCommandLineTools(
            to: environment,
            directory: shim,
            isEnabled: true
        )

        XCTAssertEqual(applied["PATH"], "\(shim):/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(applied["HOME"], environment["HOME"])
        XCTAssertEqual(applied["TERM"], environment["TERM"])
        XCTAssertEqual(applied.count, environment.count)
        // Prepended, never substituted: every entry the user had is still behind it, in order.
        XCTAssertEqual(
            applied["PATH"]?.split(separator: ":").dropFirst().joined(separator: ":"),
            environment["PATH"]
        )
    }

    func testTheEnvironmentIsUntouchedWhileTheSettingIsOff() {
        let environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"]

        XCTAssertEqual(
            AgentEnvironment.applyingCommandLineTools(
                to: environment,
                directory: shim,
                isEnabled: false
            ),
            environment
        )
    }

    func testASecondPassDoesNotGrowThePATH() {
        let once = AgentEnvironment.applyingCommandLineTools(
            to: ["PATH": "/usr/bin:/bin"],
            directory: shim,
            isEnabled: true
        )

        XCTAssertEqual(
            AgentEnvironment.applyingCommandLineTools(
                to: once,
                directory: shim,
                isEnabled: true
            ),
            once
        )
    }

    /// A child that inherits no `PATH` gets `execvp`'s own default. Replacing that with a
    /// directory holding two symlinks would break every command in the session.
    func testAnAbsentOrEmptyPATHIsNotInvented() {
        XCTAssertEqual(
            AgentEnvironment.applyingCommandLineTools(
                to: ["HOME": "/Users/someone"],
                directory: shim,
                isEnabled: true
            ),
            ["HOME": "/Users/someone"]
        )
        XCTAssertEqual(
            AgentEnvironment.applyingCommandLineTools(
                to: ["PATH": ""],
                directory: shim,
                isEnabled: true
            ),
            ["PATH": ""]
        )
    }

    /// Absence is off, and the person's first write is still distinguishable from a default.
    func testTheSettingIsAbsentAndOffUntilThePersonOptsIn() throws {
        let suiteName = "CommandLineToolsEnvironmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "prependsCommandLineToolsToPATH"))
        XCTAssertEqual(
            AppSettingDefinitions.prependsCommandLineToolsToPATH.read(from: defaults),
            false
        )

        XCTAssertTrue(
            AppSettingDefinitions.prependsCommandLineToolsToPATH.write(true, to: defaults)
        )
        XCTAssertEqual(
            AppSettingDefinitions.prependsCommandLineToolsToPATH.read(from: defaults),
            true
        )
    }
}
