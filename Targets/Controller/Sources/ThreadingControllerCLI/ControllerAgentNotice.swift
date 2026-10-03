import Foundation
import ThreadingController

/// The hook entry point for mail notices. Prints one host-authored line as hook JSON, or nothing.
/// It never fails loudly: a hook error would surface inside the agent's turn, and a missed
/// notice only delays mail, which stays in the inbox until acknowledged.
enum ControllerAgentNotice {
    static func run(_ arguments: [String]) async {
        guard arguments.count == 2, let event = MailNoticeEvent(rawValue: arguments[1]) else { return }
        // Drain the hook's JSON payload so the writer never sees a broken pipe; its content is
        // not needed. Bounded, and stdin may already be closed.
        _ = try? FileHandle.standardInput.read(upToCount: 262_144)
        let environment = ProcessInfo.processInfo.environment
        guard let database = environment["THREADING_CONTROLLER_DATABASE"],
              let store = try? ControllerStore(path: database) else { return }
        let response: ControllerAgentResponse?
        if let execution = environment["THREADING_EXECUTION_ID"], let credential = environment["THREADING_EXECUTION_CREDENTIAL"],
           let executionID = try? ExecutionID(execution) {
            response = try? await store.agentRequest(executionID: executionID, credential: credential, request: .mailNotice(event: event))
        } else if let address = environment["THREADING_MAILBOX_ADDRESS"], let credential = environment["THREADING_MAILBOX_CREDENTIAL"],
                  let mailbox = try? MailAddress(address) {
            response = try? await store.mailboxRequest(address: mailbox, credential: credential, request: .mailNotice(event: event))
        } else { response = nil }
        guard let notice = response?.notice else { return }
        try? ControllerMain.output(hookOutput(event: event, notice: notice))
    }

    /// The shape both Claude Code and Codex accept: additional context after a tool call or at
    /// session start, and a one-time block with a reason at a stop.
    static func hookOutput(event: MailNoticeEvent, notice: String) -> MCPValue {
        switch event {
        case .stop:
            return .object(["decision": .string("block"), "reason": .string(notice)])
        case .postToolUse, .sessionStart:
            return .object(["hookSpecificOutput": .object([
                "hookEventName": .string(event == .stop ? "Stop" : event == .postToolUse ? "PostToolUse" : "SessionStart"),
                "additionalContext": .string(notice)
            ])])
        }
    }
}
