import Foundation
import Glibc
import ThreadingPTYClient
import ThreadingPTYHostKit
@testable import CoreSlice

@main
struct NativeConversationFixture {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-conversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("THREADING_LINUX_DATA_DIR", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let socket = CommandLine.arguments.dropFirst(2).first
        for mode in ["claude", "codex", "grok", "cursor"] {
            let plan = {
                AgentLaunchPlan(executable: "/usr/bin/python3", arguments: [script, mode], resumeState: .unavailable)
            }
            let id = SessionID()
            let hostPlan: () throws -> PTYHostChildPlan? = {
                guard let socket else { return nil }
                return PTYHostChildPlan(identity: .agentSession(id), factory: { events in
                    let client = PTYHostClient(socketPath: socket, build: "native-conversation-contract",
                        events: events, journal: { _, _ in })
                    try client.connect()
                    return client
                }, workingDirectory: "/tmp")
            }
            let session: any ConversationStreamSession
            switch mode {
            case "claude": session = ClaudeStreamSession(sessionID: id, hostPlan: hostPlan, plan: plan)
            case "codex": session = CodexStreamSession(sessionID: id, workingDirectory: "/tmp", hostPlan: hostPlan, plan: plan)
            default: session = ACPStreamSession(sessionID: id, workingDirectory: "/tmp", profile: mode == "grok" ? .grok : .cursor, hostPlan: hostPlan, plan: plan)
            }
            try await exercise(session, mode: mode, hostBacked: socket != nil)
        }
        print("PASS \(socket == nil ? "local" : "daemon-backed") production native sessions: Claude, Codex, Grok/ACP, Cursor/ACP; two turns, Unicode, persistent child, permission denial/approval and exactly one exit")
    }

    @MainActor
    private static func exercise(_ session: any ConversationStreamSession, mode: String, hostBacked: Bool) async throws {
        let text = "日本語 🧵 café"
        var finishes = 0
        var deltas = ""
        var exits: [Int32] = []
        var outcomes: [TurnOutcome] = []
        session.onEvent = { event in
            switch event {
            case .textDelta(let value): deltas += value
            case .turnFinished(_, let outcome, _): finishes += 1; outcomes.append(outcome)
            default: break
            }
        }
        session.onExit = { exits.append($0) }
        defer { session.terminate() }
        let defaultDecision = ConversationPermissionDecision.decide
        defer { ConversationPermissionDecision.decide = defaultDecision }
        session.start()
        try check(session.isHostBacked == hostBacked, "selected child ownership changed")
        let pid = try require(session.rootProcessIdentifier, "\(mode) started no child")
        try check(AgentChildLedger.shared.currentRecords.contains { $0.pid == pid }, "\(mode) child was not durably owned")
        for turn in 1...2 {
            if mode == "codex" && turn == 2 {
                ConversationPermissionDecision.decide = { _, completion in completion(.allow(reason: "Inspected contract command")) }
            }
            try check(session.send("prompt \(turn) \(text)"), "\(mode) refused turn \(turn)")
            try await eventually("\(mode) turn \(turn), exits=\(exits)") { finishes >= turn || !exits.isEmpty }
            try check(finishes == turn && outcomes.last == .completed, "\(mode) failed/doubled turn: \(outcomes), exits=\(exits)")
            try check(session.canSend && session.rootProcessIdentifier == pid, "\(mode) lost persistent session")
        }
        try check(deltas == text + text, "\(mode) lost/repeated Unicode delta: \(deltas)")
        session.finish()
        try await eventually("\(mode) EOF exit") { !exits.isEmpty }
        try await Task.sleep(for: .milliseconds(80))
        try check(!AgentChildLedger.shared.currentRecords.contains { $0.pid == pid }, "\(mode) retained an exited child ledger record")
        try check(exits == [0] && !session.isRunning && session.rootProcessIdentifier == nil, "\(mode) invalid exit lifecycle: \(exits)")
    }

    @MainActor
    private static func eventually(_ label: String, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            try check(Date() < deadline, "timeout: \(label)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "NativeConversationContract", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        try check(value != nil, message)
        return value!
    }
}
