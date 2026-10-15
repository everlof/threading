import AppKit
import XCTest
@testable import Threading

/// Opt-in shipping-controller journey, using the real SSH host, login and provider.
@MainActor
final class RemoteNativeConversationLiveTests: HostedStoreTestCase {
    func testNativeChatLaunchesReplaysAndResumesThroughTheApplication() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["THREADING_REMOTE_HOST_DESTINATION"],
              let configPath = environment["THREADING_REMOTE_NATIVE_ACCOUNT"],
              let binaryPath = environment["THREADING_REMOTE_HOST_BINARIES"]
        else { throw XCTSkip("set the remote native live-test variables to use a real account and host") }
        XCTAssertTrue(StateManager.isHostedTest)
        XCTAssertEqual(AppSettings.shared.developerRemoteHostBinaryDirectory?.path, binaryPath)
        let selectedAccount = try XCTUnwrap(AgentAccountDiscovery.account(for: .codex, handle: .standard))
        XCTAssertEqual(selectedAccount.configPath, configPath)
        XCTAssertEqual(selectedAccount.handle, .standard)
        let sockets = URL(fileURLWithPath: "/tmp/threading-ui-live-\(getpid())")
        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels(); try? FileManager.default.removeItem(at: sockets) }
        let host = RemoteHostRecord(label: "Native live test", destination: alias,
            sshConfigFile: environment["THREADING_REMOTE_HOST_SSH_CONFIG"],
            defaultDirectory: "/home/threading/projects/remote-chat-test", reusesLocalCredentials: true)
        XCTAssertEqual(RemoteHostStore.shared.add(host), .applied)
        defer { _ = RemoteHostStore.shared.remove(host.id) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-live-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let initialProject = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(.on(host, remoteDirectory: try XCTUnwrap(host.defaultDirectory)),
            forProjectID: initialProject.id), .applied)
        let project = try XCTUnwrap(ProjectStore.shared.project(withID: initialProject.id))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex,
            accountHandle: .standard, usesNativeUI: true, title: "Remote native login test"))
        await withCheckedContinuation { continuation in
            MCPServer.shared.start { continuation.resume() }
        }
        defer {
            AgentRuntime.shared.discard(sessionID: session.id)
            RemoteExecutionHosts.shared.closeAllTunnels()
            MCPServer.shared.stop()
        }
        XCTAssertNotNil(MCPServer.shared.socketPath)
        let marker = "UI-WSL-REUSED-LOGIN"
        for iteration in 0..<2 {
            let current = try XCTUnwrap(ProjectStore.shared.session(withID: session.id))
            let controller = try XCTUnwrap(ConversationViewController(agentSession: current, project: project,
                currentSessionProjection: .projectStore(.shared), remoteConversation: RemoteNativeConversation(hosts: hosts)))
            XCTAssertTrue(AgentRuntime.shared.registerConversationRuntimeSurface(controller, for: session.id))
            controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            controller.launch()
            try await waitForReady(controller)
            if iteration == 1 {
                XCTAssertTrue(lastAssistantText(controller).contains(marker), "the reopened UI did not replay the remote transcript")
            }
            let previousReplies = assistantTexts(controller).count
            XCTAssertTrue(controller.sendAppPrompt(iteration == 0
                ? "Reply exactly \(marker). Do not use tools."
                : "What exact word did I ask you to reply with in our previous turn? Reply only with that word. Do not use tools."))
            try await waitForReady(controller, minimumReplies: previousReplies + 1)
            XCTAssertTrue(lastAssistantText(controller).contains(marker))
            let stored = try XCTUnwrap(ProjectStore.shared.session(withID: session.id))
            XCTAssertNotNil(stored.resumeState.transcriptID)
            XCTAssertEqual(stored.remoteUsesCopiedAccount, true)
            AgentRuntime.shared.discard(sessionID: session.id)
        }
    }

    private func waitForReady(_ controller: ConversationViewController, minimumReplies: Int = 0) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            for row in controller.timeline.rows {
                if case .notice(let message, kind: .error) = row {
                    throw NSError(domain: "RemoteNativeLiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            if controller.remoteSnapshot.canSend, assistantTexts(controller).count >= minimumReplies { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "RemoteNativeLiveTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native chat readiness or reply timed out"])
    }

    private func lastAssistantText(_ controller: ConversationViewController) -> String {
        assistantTexts(controller).last ?? ""
    }

    private func assistantTexts(_ controller: ConversationViewController) -> [String] {
        controller.timeline.rows.compactMap { row in
            guard case .assistant(let text) = row else { return nil }
            return text
        }
    }
}
