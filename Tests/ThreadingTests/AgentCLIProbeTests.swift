import Foundation
import XCTest
@testable import Threading

/// Exercise the shared CLI lookup through isolated login shells and its pure PATH parser.
final class AgentCLIProbeTests: XCTestCase {

    func testLoginLookupPreservesTheInstalledSymlinkPath() throws {
        try withLoginShell(profile: "") { shell, executable in
            XCTAssertEqual(AgentCLIProbe.locate("claude", shell: shell), executable)
        }
    }

    func testLoginLookupIgnoresProfileBannersAndMatchesSharedAvailability() throws {
        try withLoginShell(profile: "printf '/usr/bin/true\\nPATH=/wrong/banner\\nWelcome back\\n'") {
            shell, executable in
            XCTAssertEqual(AgentCLIProbe.locate("claude", shell: shell), executable)
            XCTAssertEqual(
                AgentCLIAvailability.loginShellProbe(shell: shell)?.paths[.claude],
                executable
            )
        }
    }

    func testLoginLookupFindsTheExecutableBehindAShellAlias() throws {
        try withLoginShell(profile: "alias claude='claude --verbose'") { shell, executable in
            XCTAssertEqual(AgentCLIProbe.locate("claude", shell: shell), executable)
        }
    }

    func testLoginLookupDoesNotMistakeAnAliasOrBannerForAnInstalledCLI() throws {
        try withLoginShell(profile: "printf '/usr/bin/true\\n'\nalias missing='true'") { shell, _ in
            XCTAssertNil(AgentCLIProbe.locate("missing", shell: shell))
        }
    }

    func testPATHLookupRequiresAnAbsoluteExecutableAndPreservesSearchOrder() {
        var checked: [String] = []
        XCTAssertEqual(
            AgentCLIProbe.locate("claude", on: ":relative:/first/bin:/second/bin") { path in
                checked.append(path)
                return path == "/second/bin/claude"
            },
            "/second/bin/claude"
        )
        XCTAssertEqual(checked, ["/first/bin/claude", "/second/bin/claude"])
        XCTAssertNil(AgentCLIProbe.locate("claude", on: "/first/bin", isExecutable: { _ in false }))
        XCTAssertNil(AgentCLIProbe.locate("claude", on: "", isExecutable: { _ in true }))
        XCTAssertNil(AgentCLIProbe.locate("", on: "/first/bin", isExecutable: { _ in true }))
        XCTAssertNil(AgentCLIProbe.locate("../claude", on: "/first/bin", isExecutable: { _ in true }))
    }

    func testLoginPATHIgnoresProfileOutputBeforeItsMarker() {
        let output = """
        PATH=/wrong/profile/banner
        welcome back
        \(AgentCLIProbe.environmentMarker)
        USER=fixture
        PATH=/fixture/bin:/usr/bin:/bin

        """

        XCTAssertEqual(
            AgentCLIProbe.path(fromLoginEnvironmentOutput: output),
            "/fixture/bin:/usr/bin:/bin"
        )
    }

    func testLoginPATHRequiresThePostProfileMarkerAndANonemptyValue() {
        XCTAssertNil(AgentCLIProbe.path(fromLoginEnvironmentOutput: "PATH=/unframed/bin\n"))
        XCTAssertNil(AgentCLIProbe.path(
            fromLoginEnvironmentOutput: "\(AgentCLIProbe.environmentMarker)\nPATH=\n"
        ))
    }

    /// Run the production login-shell probe with real zsh startup files, without sourcing the
    /// developer's profile or depending on which CLIs happen to be installed on this Mac.
    private func withLoginShell(
        profile: String,
        check: (_ shell: String, _ executable: String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIProbe-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = bin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: executable,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let fixturePATH = "\(bin.path):/usr/bin:/bin"
        let startup = "export PATH=\(ShellCommand(word: fixturePATH).source)\n\(profile)\n"
        try Data(startup.utf8).write(to: root.appendingPathComponent(".zprofile"))

        var command = ShellCommand(word: "/usr/bin/env")
        command.append(words: [
            "-i", "HOME=\(root.path)", "ZDOTDIR=\(root.path)", "PATH=/usr/bin:/bin", "/bin/zsh"
        ])
        let shell = root.appendingPathComponent("login-shell")
        try Data("#!/bin/sh\nexec \(command.source) \"$@\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        try check(shell.path, executable.path)
    }
}
