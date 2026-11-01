import XCTest
@testable import Threading

final class CodexTerminalLaunchTests: XCTestCase {
    func testSupervisorKeepsCredentialPrefixOutsideItsLongLivedScript() {
        var terminal = ShellCommand(word: "env")
        terminal.append(word: "CODEX_HOME=/account's home")
        terminal.append(word: "THREADING_SESSION_TOKEN=PRIVATE_TOKEN")
        terminal.append(word: "/selected/codex")
        terminal.append(flag: "-m", value: "chosen-model")
        terminal.append(operand: "- prompt with $(touch /unexpected) and 'quotes'")
        var server = ShellCommand(word: "/selected/codex")
        server.append(word: "app-server")
        server.append(flag: "--listen", value: "unix:///private/socket")
        let script = CodexTerminalLaunch.script(server: server, socketPath: "/private/socket")
        XCTAssertFalse(script.contains("PRIVATE_TOKEN"))
        XCTAssertFalse(script.contains("prompt with"))
        let wrapped = CodexTerminalLaunch.wrap(terminal, server: server, socketPath: "/private/socket", store: nil)
        XCTAssertEqual(wrapped.executableWord, "/bin/sh")
        XCTAssertTrue(wrapped.source.hasPrefix("'env' 'CODEX_HOME="))
        XCTAssertTrue(wrapped.source.hasSuffix("-- '- prompt with $(touch /unexpected) and '\\''quotes'\\'''"))
    }

    func testPrivateSocketIsStableShortAndSessionScoped() {
        let id = SessionID()
        let path = CodexTerminalLaunch.socketPath(for: id)
        XCTAssertEqual(path, CodexTerminalLaunch.socketPath(for: id))
        XCTAssertNotEqual(path, CodexTerminalLaunch.socketPath(for: SessionID()))
        XCTAssertLessThan(path.utf8.count, 104)
    }

    func testTerminalServerInheritsPermissionsWhenNoOverrideWasChosen() {
        let server = CodexLaunchCommand.appServer(model: nil, permissionMode: nil,
            listen: "unix:///private/socket", suppliesDefaultSandbox: false)
        XCTAssertFalse(server.source.contains("--sandbox"))
        XCTAssertTrue(server.source.contains("unix:///private/socket"))
        let native = CodexLaunchCommand.appServer(model: nil, permissionMode: nil)
        XCTAssertTrue(native.source.contains("workspace-write"))
        XCTAssertTrue(native.source.contains("stdio://"))
    }
}
