import AppKit
import XCTest
@testable import Threading

/// Drives the shipping terminal controller against the real host and Claude CLI. The credential
/// is deliberately a fixture: this checks transfer/routing/onboarding without spending a turn.
@MainActor
final class RemoteTerminalLoginLiveTests: HostedStoreTestCase {
    func testFreshClaudeTerminalCopiesItsSelectedAccountBeforeStarting() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["THREADING_REMOTE_HOST_DESTINATION"],
              environment["THREADING_REMOTE_TERMINAL_LOGIN_TEST"] == "1"
        else { throw XCTSkip("opt in to the remote terminal login journey") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-login-\(UUID().uuidString)")
        let login = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: login, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = Data(#"{"claudeAiOauth":{"accessToken":"fixture-not-a-real-token","refreshToken":"fixture","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}}"#.utf8)
        try credential.write(to: login.appendingPathComponent(".credentials.json"))
        let handle = AccountHandle.named("remote-terminal-fixture")
        XCTAssertTrue(AgentAccountLocationRegistry.shared.register(provider: .claude, handle: handle, configPath: login.path))
        AgentAccountDiscovery.invalidate()
        let host = RemoteHostRecord(label: "Terminal login fixture", destination: alias,
            sshConfigFile: environment["THREADING_REMOTE_HOST_SSH_CONFIG"],
            defaultDirectory: "/home/threading/projects/remote-chat-test", reusesLocalCredentials: true)
        XCTAssertEqual(RemoteHostStore.shared.add(host), .applied)
        defer { _ = RemoteHostStore.shared.remove(host.id) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(.on(host, remoteDirectory: try XCTUnwrap(host.defaultDirectory)),
            forProjectID: project.id), .applied)
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude,
            accountHandle: handle, usesNativeUI: false, title: "Remote terminal login fixture"))
        let sockets = URL(fileURLWithPath: "/tmp/threading-terminal-\(getpid())")
        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        await withCheckedContinuation { continuation in MCPServer.shared.start { continuation.resume() } }
        let controller = AgentSessionViewController(agentSession: session, remoteHosts: hosts)
        defer {
            controller.terminate()
            if case .ready(let context) = hosts.phase(for: .init(alias: alias, configFile: host.sshConfigFile)),
               let copied = try? RemoteConversationAccount.make(
                account: AgentAccount(provider: .claude, handle: handle, configPath: login.path),
                home: context.facts.home, reuse: true) {
                // This directory belongs only to the unique fixture home above.
                _ = try? SystemSSHCommandRunner().run(on: context.destination,
                    command: "sleep 1; rm -rf -- \(ShellCommand(word: copied.directory).source)",
                    input: .none, extraOptions: [], timeout: 15)
            }
            hosts.closeAllTunnels()
            MCPServer.shared.stop()
            try? FileManager.default.removeItem(at: sockets)
        }
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.view.layoutSubtreeIfNeeded()
        controller.launch()
        let deadline = Date().addingTimeInterval(120)
        var reachedWorkspace = false
        while Date() < deadline {
            if let refusal = controller.launchRefusal { XCTFail(refusal.detail.joined(separator: "\n")); return }
            let screen = controller.session.terminalView.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
            XCTAssertFalse(screen.contains("Select login method"), "Copied login was sent back through first-run sign-in")
            if screen.contains("trust this folder") || screen.contains("Quick safety check") {
                reachedWorkspace = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(reachedWorkspace, "Claude never reached the workspace trust prompt")
        XCTAssertEqual(ProjectStore.shared.session(withID: session.id)?.remoteUsesCopiedAccount, true)
    }
}
