import Foundation
import ControllerRuntime
import ThreadingController

/// `agent`, `agent-mcp` and `agent-notice` when the launch gave a broker socket: every tool call
/// is one request to the resident supervisor, and this process never opens the owner store.
/// The caller identity comes only from the launch environment, exactly as on the legacy path.
struct ControllerAgentClient {
    let socket: String
    let environment: [String: String]

    private enum Key {
        static let execution = "THREADING_EXECUTION_ID"
        static let executionCredential = "THREADING_EXECUTION_CREDENTIAL"
        static let mailbox = "THREADING_MAILBOX_ADDRESS"
        static let mailboxCredential = "THREADING_MAILBOX_CREDENTIAL"
    }

    /// An execution when its identity is present; otherwise a session mailbox (`agent-mcp` and
    /// `agent-notice` only, as before).
    func caller(allowMailbox: Bool) throws -> ControllerMCPServer.Caller {
        if let execution = environment[Key.execution] {
            guard let credential = environment[Key.executionCredential] else { throw ControllerError.forbidden }
            return .execution(try ExecutionID(execution), credential: credential)
        }
        if allowMailbox, let address = environment[Key.mailbox], let credential = environment[Key.mailboxCredential] {
            return .mailbox(try MailAddress(address), credential: credential)
        }
        throw ControllerError.forbidden
    }

    func perform(_ caller: ControllerMCPServer.Caller, _ request: ControllerAgentRequest? = nil,
                 transcript: ProviderTranscript? = nil) throws -> ControllerAgentResponse {
        let envelope: ControllerBrokerRequest
        switch caller {
        case .execution(let id, let credential):
            envelope = ControllerBrokerRequest(execution: id.description, credential: credential, request: request, transcript: transcript)
        case .mailbox(let address, let credential):
            envelope = ControllerBrokerRequest(mailbox: address.description, credential: credential, request: request)
        }
        return try ControllerAgentBrokerClient.perform(socket: socket, envelope)
    }

    func run(_ command: String, _ arguments: [String]) async throws {
        if command == "agent-mcp" {
            let caller = try caller(allowMailbox: true)
            try await ControllerMCPServer.run(caller: caller) { try perform(caller, $0) }
        } else {
            let caller = try caller(allowMailbox: false)
            let request = try JSONDecoder().decode(ControllerAgentRequest.self, from: Data(ControllerMain.file(arguments[0]).utf8))
            try ControllerMain.output(try perform(caller, request))
        }
    }

    /// The hook path: bind the provider transcript (best effort), then ask for the notice.
    func notice(event: MailNoticeEvent, hookInput: Data?) -> String? {
        guard let caller = try? caller(allowMailbox: true) else { return nil }
        if case .execution = caller, let transcript = ControllerAgentNotice.transcript(from: hookInput) {
            _ = try? perform(caller, transcript: transcript)
        }
        return (try? perform(caller, .mailNotice(event: event)))?.notice
    }
}
