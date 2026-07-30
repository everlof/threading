import Foundation
import XCTest
@testable import Threading

/// Opt-in tests that cross process and network boundaries.
///
/// This file belongs only to the `ThreadingNotificationE2E` scheme. The ordinary `Threading`
/// scheme does not build this target, so a normal test run can never spend agent usage or send
/// a push notification.
@MainActor
final class NotificationDeliveryE2ETests: XCTestCase {

    func testAPNsAcceptsPermissionNotification() async throws {
        let configuration = try NotificationE2EConfiguration.load()
        let nonce = NotificationE2EConfiguration.nonce()
        let result = await configuration.sender.send(
            .init(
                kind: .permissionRequest,
                hostID: "notification-e2e",
                sessionID: UUID().uuidString.lowercased(),
                title: "Threading permission E2E \(nonce)",
                body: "Open this test chat to review the simulated request."
            ),
            deviceToken: configuration.deviceToken,
            environment: configuration.environment
        )

        XCTAssertTrue(
            result.accepted,
            "Apple did not accept the permission notification: \(result.diagnosticDescription)"
        )
        XCTAssertNotNil(result.apnsID, "An accepted APNs response should carry an apns-id receipt.")
    }

    func testClaudeNotifyUserToolReachesAPNs() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_E2E_RUN_CLAUDE"] == "1" else {
            throw XCTSkip(
                "Claude usage is a second explicit opt-in. Run the E2E script with --claude."
            )
        }
        guard MCPToolCatalog.enabledToolNames.contains(MCPTools.notifyUser) else {
            throw XCTSkip(
                "The Notifications tool group is disabled. Enable it in Threading’s Tools settings."
            )
        }

        let configuration = try NotificationE2EConfiguration.load()
        let nonce = NotificationE2EConfiguration.nonce()
        let expectedTitle = "Threading Claude E2E \(nonce)"
        let expectedMessage = "Claude completed notification E2E \(nonce)."
        let server = MCPServer.shared
        let previousHandler = server.handler
        let ready = expectation(description: "MCP server is listening")
        server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        guard server.port != nil else {
            XCTFail("The real MCP server could not bind its loopback listener.")
            return
        }

        let delivery = expectation(description: "notify_user reaches APNs")
        let turn = expectation(description: "Claude receives the tool result and finishes")
        let handler = NotificationE2EHandler(
            sender: configuration.sender,
            deviceToken: configuration.deviceToken,
            environment: configuration.environment
        )
        var didObserveDelivery = false
        var didFinishTurn = false
        var turnWasError = false
        var earlyExitCode: Int32?

        handler.onObservation = {
            guard !didObserveDelivery else { return }
            didObserveDelivery = true
            delivery.fulfill()
        }
        server.handler = handler

        var session = AgentSession(
            kind: .claude,
            title: "Notification E2E",
            model: ProcessInfo.processInfo.environment["THREADING_E2E_CLAUDE_MODEL"],
            usesNativeUI: true
        )
        // A unique, explicitly resumable id keeps this run isolated from every existing chat.
        session.resumeState = .resumable(TranscriptID(session.id.uuidString.lowercased()))
        let project = Project(
            name: "Notification E2E",
            folderURL: FileManager.default.temporaryDirectory
        )
        let stream = ClaudeStreamSession(sessionID: session.id) {
            AgentLauncher.streamPlan(for: session, in: project)
        }
        stream.onEvent = { event in
            guard case .turnFinished(_, let isError, _) = event, !didFinishTurn else { return }
            didFinishTurn = true
            turnWasError = isError
            turn.fulfill()
        }
        stream.onExit = { code in
            earlyExitCode = code
            if !didObserveDelivery {
                didObserveDelivery = true
                delivery.fulfill()
            }
            if !didFinishTurn {
                didFinishTurn = true
                turnWasError = true
                turn.fulfill()
            }
        }

        defer {
            stream.terminate()
            server.handler = previousHandler
            server.stop()
        }

        stream.start()
        guard stream.send(
            """
            This is an automated end-to-end test and I explicitly request one notification. \
            Call mcp__threading__notify_user exactly once with title "\(expectedTitle)", \
            message "\(expectedMessage)", and recipient "owner". Do not call another tool. \
            After the tool succeeds, answer only DONE.
            """
        ) else {
            XCTFail("Claude did not start. Confirm that the claude CLI is installed and authenticated.")
            return
        }

        await fulfillment(of: [delivery, turn], timeout: 90)

        XCTAssertNil(
            earlyExitCode,
            "Claude exited before the persistent stream was stopped (status \(earlyExitCode ?? -1))."
        )
        XCTAssertFalse(turnWasError, "Claude reported an error while completing the E2E turn.")
        XCTAssertEqual(handler.observations.count, 1, "Claude must call exactly one MCP tool.")
        guard let observation = handler.observations.first else { return }
        XCTAssertEqual(observation.sessionID, session.id, "MCP session routing changed the chat.")
        XCTAssertEqual(observation.title, expectedTitle)
        XCTAssertEqual(observation.message, expectedMessage)
        XCTAssertEqual(observation.recipient?.lowercased(), "owner")
        guard let result = observation.delivery else {
            XCTFail(observation.failure ?? "Claude did not call notify_user.")
            return
        }
        XCTAssertTrue(
            result.accepted,
            "Apple did not accept Claude’s notification: \(result.diagnosticDescription)"
        )
        XCTAssertNotNil(result.apnsID, "An accepted APNs response should carry an apns-id receipt.")
    }
}

private struct NotificationE2EConfiguration {
    let sender: RemoteAPNSPushSender
    let deviceToken: String
    let environment: RemoteAPNSPushSender.Environment

    static func load(
        environment variables: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> NotificationE2EConfiguration {
        guard let sender = RemoteAPNSPushSender.fromEnvironment(variables) else {
            throw XCTSkip(
                "Set THREADING_APNS_KEY_ID, THREADING_APNS_TEAM_ID and "
                    + "THREADING_APNS_PRIVATE_KEY_PATH to a valid APNs .p8 key."
            )
        }
        let token = variables["THREADING_E2E_APNS_DEVICE_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({
            (48...57).contains($0.value)
                || (65...70).contains($0.value)
                || (97...102).contains($0.value)
        }) else {
            throw XCTSkip(
                "Set THREADING_E2E_APNS_DEVICE_TOKEN to the hex token copied from the debug iOS app."
            )
        }
        let environmentName = variables["THREADING_E2E_APNS_ENVIRONMENT"] ?? "sandbox"
        guard let environment = RemoteAPNSPushSender.Environment(rawValue: environmentName) else {
            XCTFail("THREADING_E2E_APNS_ENVIRONMENT must be sandbox or production.")
            throw XCTSkip("The APNs environment is invalid.")
        }
        return NotificationE2EConfiguration(
            sender: sender,
            deviceToken: token.lowercased(),
            environment: environment
        )
    }

    static func nonce() -> String {
        String(UUID().uuidString.lowercased().prefix(8))
    }
}

@MainActor
private final class NotificationE2EHandler: MCPToolHandling {
    struct Observation {
        let sessionID: SessionID
        let title: String?
        let message: String?
        let recipient: String?
        let delivery: RemoteAPNSDeliveryResult?
        let failure: String?
    }

    private let sender: RemoteAPNSPushSender
    private let deviceToken: String
    private let environment: RemoteAPNSPushSender.Environment

    private(set) var observations: [Observation] = []
    var onObservation: (() -> Void)?

    init(
        sender: RemoteAPNSPushSender,
        deviceToken: String,
        environment: RemoteAPNSPushSender.Environment
    ) {
        self.sender = sender
        self.deviceToken = deviceToken
        self.environment = environment
    }

    func handle(_ call: MCPToolCall, for sessionID: SessionID) -> MCPToolResult {
        .failure("The notification E2E handler requires the asynchronous MCP route.")
    }

    func handle(
        _ call: MCPToolCall,
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard case .notifyUser(let arguments) = call,
              let title = arguments.title,
              let message = arguments.message else {
            observations.append(Observation(
                sessionID: sessionID,
                title: nil,
                message: nil,
                recipient: nil,
                delivery: nil,
                failure: "Claude called \(call.name), not notify_user with title and message."
            ))
            onObservation?()
            completion(.failure("This E2E turn accepts only notify_user with title and message."))
            return
        }

        Task {
            let result = await sender.send(
                .init(
                    kind: .agentMessage,
                    hostID: "notification-e2e",
                    sessionID: sessionID.uuidString.lowercased(),
                    title: title,
                    body: message
                ),
                deviceToken: deviceToken,
                environment: environment
            )
            observations.append(Observation(
                sessionID: sessionID,
                title: title,
                message: message,
                recipient: arguments.recipient,
                delivery: result,
                failure: nil
            ))
            onObservation?()
            completion(result.accepted
                ? .success("Notification accepted by APNs.")
                : .failure("APNs delivery failed: \(result.diagnosticDescription)"))
        }
    }
}
