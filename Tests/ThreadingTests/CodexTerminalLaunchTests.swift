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

    func testRemoteResumeReceivesTheExecutionDirectoryExplicitly() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ctl-\(UUID().uuidString)")
        let checkout = root.appendingPathComponent("a checkout's directory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
        let client = root.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3
        import json, os, signal, socket, sys
        if '--help' in sys.argv:
            print('unix://PATH --remote')
        elif sys.argv[1] == 'app-server':
            server = socket.socket(socket.AF_UNIX)
            server.bind(sys.argv[-1].removeprefix('unix://'))
            server.listen()
            signal.pause()
        else:
            if '--cd' not in sys.argv:
                sys.exit('tui.resume_cwd = "current" requires --cd when using a remote workspace')
            print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}))
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)

        let socket = root.appendingPathComponent("server.sock").path
        var server = ShellCommand(word: client.path)
        server.append(word: "app-server")
        server.append(flag: "--listen", value: "unix://\(socket)")
        var terminal = ShellCommand(word: client.path)
        terminal.append(words: ["resume", "saved-conversation"])
        let command = CodexTerminalLaunch.wrap(terminal, server: server, socketPath: socket, store: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.source]
        process.currentDirectoryURL = checkout
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let ended = expectation(description: "terminal supervisor exits")
        process.terminationHandler = { _ in ended.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        wait(for: [ended], timeout: 15)
        guard !process.isRunning else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard process.terminationStatus == 0 else { return }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cwd = try XCTUnwrap(result["cwd"] as? String)
        XCTAssertEqual(result["args"] as? [String], [
            "--remote", "unix://\(socket)", "--cd", cwd, "resume", "saved-conversation"
        ])
        XCTAssertEqual(cwd, checkout.path)
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
