import CryptoKit
import Foundation
import XCTest
@testable import Threading

final class ManagedAgentRuntimeTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var suite: String!
    private var store: ManagedAgentRuntimeStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tools-\(UUID())")
        suite = "ManagedAgentTests.\(UUID())"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = ManagedAgentRuntimeStore(root: root, preferences: preferences)
        root = store.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        preferences.removePersistentDomain(forName: suite)
    }

    func testEveryClientResolvesOnlyItsSelectedExecutableAndPreservesArguments() throws {
        for kind in AgentKind.allCases {
            let missing = store.selection(for: kind)
            XCTAssertTrue(missing.managed)
            XCTAssertTrue(missing.executable.hasPrefix(root.path + "/"))
            XCTAssertTrue(missing.executable.contains("not-installed"))
            let path = root.appendingPathComponent("external 'client;$(touch nope)").path
            store.selectExternal(path, for: kind)
            var command = ShellCommand(word: "env")
            command.append(word: "-u")
            command.append(word: "CLAUDECODE")
            command.append(word: "ACCOUNT_HOME=/a path/claude")
            command.append(word: kind.executableName)
            command.append(word: "a prompt mentioning claude; $(touch nope)")
            let plan = store.plan(command: command, in: root.path, resumeState: .unavailable)
            XCTAssertEqual(plan.executable, "/bin/sh")
            XCTAssertEqual(plan.arguments.first, "-c")
            XCTAssertTrue(plan.arguments.last?.contains(ShellCommand(word: path).source) == true)
            XCTAssertTrue(plan.arguments.last?.contains("'a prompt mentioning claude; $(touch nope)'") == true)
            XCTAssertNil(plan.environmentOverrides["DISABLE_AUTOUPDATER"])
        }
        var unrelated = ShellCommand(word: "printf")
        unrelated.append(word: "claude")
        XCTAssertEqual(store.resolve(unrelated).command.source, unrelated.source)
    }

    func testRealLaunchUsesExactQuotedPathWithoutUserShellOrNode() throws {
        let client = root.appendingPathComponent("client ' with spaces")
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' \"$1\" \"$DISABLE_AUTOUPDATER\"\n", to: client)
        store.selectExternal(client.path, for: .claude)
        var command = ShellCommand(word: "claude")
        command.append(word: "$(echo not executed); literal")
        let plan = store.plan(command: command, in: root.path, resumeState: .unavailable)
        let result = try BoundedChildProcess.run(executable: plan.executable, arguments: plan.arguments,
                                                environment: plan.environmentOverrides, timeout: 3,
                                                maximumOutputBytes: 4096)
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "$(echo not executed); literal\n\n")
    }

    func testProjectPATHSurvivesRestartAndABrokenLoginShell() throws {
        let shell = root.appendingPathComponent("fixture-shell")
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' '\(AgentCLIProbe.environmentMarker)' 'PATH=/fixture/bin:/usr/bin:/bin'\n",
                            to: shell)
        store.refresh(shell: shell.path)
        let reopened = ManagedAgentRuntimeStore(root: root, preferences: preferences)
        XCTAssertEqual(reopened.effectivePATH, "/fixture/bin:/usr/bin:/bin")
        reopened.refresh(shell: "/nonexistent/login-shell")
        XCTAssertEqual(reopened.effectivePATH, "/fixture/bin:/usr/bin:/bin")
        XCTAssertTrue(reopened.selection(for: .claude).executable.hasPrefix(root.path))
    }

    func testManagedCursorFlagsPrecedeItsSubcommandAndCodexKeepsPackagedHelpers() throws {
        var cursor = ShellCommand(word: "cursor-agent")
        cursor.append(word: "acp")
        let resolved = store.resolve(cursor)
        XCTAssertTrue(resolved.command.source.hasSuffix("'--disable-auto-update' 'acp'"))
        let codex = store.resolve(ShellCommand(word: "codex"))
        XCTAssertTrue(codex.environment["PATH"]?.contains("/codex-path:") == true)
        XCTAssertEqual(store.resolve(ShellCommand(word: "grok")).environment["GROK_DISABLE_AUTOUPDATER"], "1")
    }

    @MainActor
    func testUnconfiguredRestoresHaveAnInstallationRemedyBeforeSpawning() throws {
        let previous = AgentLocalLaunch.store
        AgentLocalLaunch.configure(store)
        defer { AgentLocalLaunch.configure(previous) }
        let project = Project(name: "Recovery", folderURL: root)
        for kind in AgentKind.allCases {
            let session = AgentSession(kind: kind, title: "Restored chat")
            XCTAssertThrowsError(try AgentLauncher.plan(for: session, in: project)) { error in
                let refusal = error as? AgentClientUnavailable
                XCTAssertEqual(refusal?.failure.origin, .preflight)
                XCTAssertEqual(refusal?.failure.knownCause, SessionLaunchDiagnosis.Cause.executableMissing)
                XCTAssertTrue(refusal?.failure.report.contains(store.selection(for: kind).executable) == true)
            }
            XCTAssertThrowsError(try AgentLauncher.streamPlan(for: session, in: project)) { error in
                XCTAssertTrue(error is AgentClientUnavailable)
            }
            store.selectExternal("/explicit/\(kind.executableName)", for: kind)
            XCTAssertNoThrow(try AgentLocalLaunch.requireConfigured(kind))
        }
    }

    func testActivationRollbackAndReloadKeepExactGenerations() throws {
        let first = try installation(version: "1.0.0")
        try store.activate(first, for: .claude)
        let firstPath = store.selection(for: .claude).executable
        let second = try installation(version: "2.0.0")
        try store.activate(second, for: .claude)
        XCTAssertEqual(store.receipt(for: .claude)?.previous, first)
        let secondPath = store.selection(for: .claude).executable
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: firstPath))
        try store.rollback(.claude)
        XCTAssertEqual(store.selection(for: .claude).executable, firstPath)
        store.loadReceipts()
        XCTAssertEqual(store.selection(for: .claude).version, "1.0.0")
        XCTAssertEqual(store.receipt(for: .claude)?.previous, second)
    }

    func testInvalidReceiptCannotEscapeAndVerifiedReinstallRepairsIt() throws {
        let provider = store.providerRoot(.claude)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let invalid = ManagedAgentInstallation(version: "1.0.0", directory: "../outside",
                                                executable: "claude", archiveIntegrity: "no")
        try JSONEncoder().encode(ManagedAgentReceipt(active: invalid)).write(
            to: provider.appendingPathComponent("active.json"))
        store.loadReceipts()
        XCTAssertNil(store.receipt(for: .claude))
        XCTAssertNotNil(store.failure(for: .claude))
        XCTAssertTrue(store.selection(for: .claude).executable.contains("not-installed"))
        try store.activate(installation(version: "2.0.0"), for: .claude)
        XCTAssertEqual(store.selection(for: .claude).version, "2.0.0")
        XCTAssertNil(store.failure(for: .claude))
    }

    func testArchiveRejectsTraversalLinksSpecialFilesAndOversizedPayloadBeforeExtraction() throws {
        for names in ["/absolute/cli", "package/../cli", "package/cli\nother/file", "package/a\\b"] {
            XCTAssertThrowsError(try ManagedAgentInstaller.validateArchiveListing(names))
        }
        for type in ["l", "h", "b", "c", "p"] {
            XCTAssertThrowsError(try ManagedAgentInstaller.validateArchiveMetadata(
                "\(type)rwxr-xr-x 0 0 0 12 Oct 20 2026 package/cli"))
        }
        XCTAssertThrowsError(try ManagedAgentInstaller.validateArchiveMetadata(
            "-rwxr-xr-x 0 0 0 9999999999 Oct 20 2026 package/cli"))
        XCTAssertNoThrow(try ManagedAgentInstaller.validateArchiveMetadata(
            "-rwxr-xr-x 0 0 0 12 Oct 20 2026 package/cli"))
    }

    func testFailedDownloadChecksumAndVerificationPreserveActiveSelection() async throws {
        let original = try installation(version: "1.0.0")
        try store.activate(original, for: .claude)
        let fixture = try archive(version: "2.0.0")
        let failDownload = ManagedAgentInstaller(store: store, download: { _, _ in
            throw ManagedAgentError.downloadFailed(503)
        })
        do { try await failDownload.install(fixture.release); XCTFail("download failure accepted") }
        catch { XCTAssertEqual(error as? ManagedAgentError, .downloadFailed(503)) }
        XCTAssertEqual(store.receipt(for: .claude)?.active, original)

        let installer = ManagedAgentInstaller(store: store, download: { _, destination in
            try FileManager.default.copyItem(at: fixture.url, to: destination)
        })
        let corrupt = ManagedAgentRelease(kind: .claude, version: "2.0.0", executable: "cli",
                                           archiveURL: fixture.release.archiveURL, integrity: "sha256-wrong")
        do { try await installer.install(corrupt); XCTFail("checksum failure accepted") }
        catch { XCTAssertEqual(error as? ManagedAgentError, .checksumMismatch) }
        let wrongVersion = ManagedAgentRelease(kind: .claude, version: "3.0.0", executable: "cli",
                                                archiveURL: fixture.release.archiveURL,
                                                integrity: fixture.release.integrity)
        do { try await installer.install(wrongVersion); XCTFail("wrong version accepted") }
        catch { XCTAssertTrue(error is ManagedAgentError) }
        XCTAssertEqual(store.receipt(for: .claude)?.active, original)
        try await installer.install(fixture.release)
        XCTAssertEqual(store.receipt(for: .claude)?.previous, original)
        XCTAssertEqual(store.selection(for: .claude).version, "2.0.0")
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.providerRoot(.claude).path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    func testCancelledInstallDoesNotActivateOrLeaveStaging() async throws {
        let original = try installation(version: "1.0.0")
        try store.activate(original, for: .claude)
        let started = expectation(description: "downloading")
        let installer = ManagedAgentInstaller(store: store, download: { _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        })
        let install = Task { try await installer.install(.claude) }
        await fulfillment(of: [started], timeout: 3)
        install.cancel()
        do { try await install.value; XCTFail("cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.receipt(for: .claude)?.active, original)
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.providerRoot(.claude).path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    func testAllPinnedPublisherArtifactsInstallAndLaunchWithoutGlobalRuntime() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_MANAGED_AGENT_LIVE_TESTS"] == "1",
                          "Opt in to downloading and launching the five pinned publisher clients")
        let installer = ManagedAgentInstaller(store: store)
        for kind in AgentKind.allCases {
            try await installer.install(kind)
            let selection = store.selection(for: kind)
            XCTAssertEqual(selection.version, ManagedAgentCatalog.release(for: kind).version)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: selection.executable))
            XCTAssertNotNil(try store.readReceipt(for: kind))
        }
    }

    private func installation(version: String) throws -> ManagedAgentInstallation {
        let installation = ManagedAgentInstallation(version: version, directory: UUID().uuidString,
                                                      executable: "cli", archiveIntegrity: "fixture")
        let executable = store.executableURL(installation, kind: .claude)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\necho '\(version)'\n", to: executable)
        return installation
    }

    private func archive(version: String) throws -> (url: URL, release: ManagedAgentRelease) {
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\necho '\(version)'\n", to: package.appendingPathComponent("cli"))
        let archive = root.appendingPathComponent("fixture.tgz")
        let result = try BoundedChildProcess.run(executable: "/usr/bin/tar",
                                                arguments: ["-czf", archive.path, "-C", root.path, "package"],
                                                timeout: 3, maximumOutputBytes: 4096)
        XCTAssertEqual(result.termination, .exited(0))
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        return (archive, ManagedAgentRelease(kind: .claude, version: version, executable: "cli",
                                             archiveURL: URL(string: "https://example.invalid/client.tgz")!,
                                             integrity: "sha256-" + digest))
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
