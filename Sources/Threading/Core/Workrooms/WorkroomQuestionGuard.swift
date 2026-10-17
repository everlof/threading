import Foundation
import ThreadingController

// MARK: - Workroom Question Guard

/// Keeps a chat that works in a Linked Workroom from stopping on a question in its terminal.
///
/// A session is **tied** while it created, or asked in, a workroom that is not closed
/// (`ControllerStore.workroomTies`). For a tied session two answering hooks speak:
///
/// - **`PreToolUse` on `AskUserQuestion`** (Claude) is denied, with a reason the model reads: ask
///   through `workroom_ask` instead and keep working. This is enforcement — the tool does not run.
/// - **`Stop`** (Claude and Codex) is blocked **once per turn** when the turn's last message ends
///   on a question: route it through the workroom, then continue or end with a status. A turn that
///   ends on a question again is let through, so a question only the person at the terminal can
///   answer still reaches them, and nothing can loop.
///
/// Every other session gets an empty answer and behaves exactly as before. The hooks are written
/// for every session with lifecycle hooks and decide at request time, because a chat becomes tied
/// in the middle of its life. A failure of any kind answers empty: a missed nudge costs a wait,
/// a wrong block costs a turn.
@MainActor
enum WorkroomQuestionGuard {

    enum Event: String, CaseIterable, Sendable {
        case preToolUse = "pre-tool-use"
        case stop

        var hookName: String { self == .preToolUse ? "PreToolUse" : "Stop" }
    }

    nonisolated static let askToolName = "AskUserQuestion"

    /// The last turn this guard blocked, per session, so it blocks a turn at most once.
    private static var lastBlocked: [SessionID: String] = [:]

    // MARK: - Hook commands

    static func endpoint(token: String, event: Event) -> String {
        "\(MCPDefaults.questionGuardPathPrefix)\(token)?\(MCPDefaults.questionGuardEventParameter)=\(event.rawValue)"
    }

    /// Claude's entry: the token is baked into the per-session `--settings` file. Its stdout is the
    /// answer; stderr and failure are swallowed, so an absent app prints nothing and exits 0.
    nonisolated static func claudeCommand(token: String, event: Event) -> String {
        let payload = "threading_hook_payload"
        return "\(payload)=$(cat); " + MCPDefaults.hookPostCommand(
            payloadVariable: payload,
            endpointSuffix: "\(MCPDefaults.questionGuardPathPrefix)\(token)?\(MCPDefaults.questionGuardEventParameter)=\(event.rawValue)",
            timeout: MCPDefaults.questionGuardTimeout
        ) + " 2>/dev/null || true"
    }

    /// Codex's entry in the account-shared `hooks.json`: token-guarded and stdin-draining like the
    /// mail entries, so a Codex run that is not Threading's says nothing.
    nonisolated static func codexCommand(event: Event, marker: String) -> String {
        let payload = "threading_hook_payload"
        let endpoint = "\(MCPDefaults.questionGuardPathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.questionGuardEventParameter)=\(event.rawValue)"
        return "\(payload)=$(cat);"
            + " [ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ] &&"
            + " " + MCPDefaults.hookPostCommand(payloadVariable: payload, endpointSuffix: endpoint,
                                                 timeout: MCPDefaults.questionGuardTimeout)
            + " 2>/dev/null; true \(marker)"
    }

    // MARK: - Deciding

    /// The hook's reply for this session and event, or nil for silence.
    static func decide(_ sessionID: SessionID, event: Event, payload: [String: Any]) async -> [String: Any]? {
        guard AppSettings.shared.workroomsEnabled, !ProjectStore.shared.sessionRunsOnRemoteHost(sessionID) else { return nil }
        switch event {
        case .preToolUse:
            guard payload["tool_name"] as? String == askToolName,
                  let reason = await tiedReason(sessionID, event: event) else { return nil }
            return ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason
            ]]
        case .stop:
            guard payload["stop_hook_active"] as? Bool != true,
                  let message = payload["last_assistant_message"] as? String,
                  endsOnQuestion(message) else { return nil }
            let turn = (payload["turn_id"] as? String) ?? String(message.suffix(200).hashValue)
            guard lastBlocked[sessionID] != turn, let reason = await tiedReason(sessionID, event: event) else { return nil }
            lastBlocked[sessionID] = turn
            return ["decision": "block", "reason": reason]
        }
    }

    /// The words for a tied session, or nil when it is not tied.
    private static func tiedReason(_ sessionID: SessionID, event: Event) async -> String? {
        do {
            let store = try await MacMailbox.shared.controllerStore()
            let address = try await MacMailbox.shared.address(for: sessionID)
            let rooms = try await store.workroomTies(address)
            guard !rooms.isEmpty else { return nil }
            var owner: WorkroomPerson?
            if let handle = AppSettings.shared.workroomOwnerHandle { owner = try await store.workroomPerson(handle: handle) }
            return reason(rooms: rooms.map(\.title), owner: owner.map { ($0.name, $0.handle) }, event: event)
        } catch {
            return nil
        }
    }

    /// What the model is told. Pure, so its wording is tested.
    nonisolated static func reason(rooms: [String], owner: (name: String, handle: String)?, event: Event) -> String {
        let room = rooms.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let forUser = owner.map { "a question only the user can answer goes to \($0.name) (person \"\($0.handle)\")" }
            ?? "for a question only the user can answer, state the assumption you will work under"
        let opening = event == .preToolUse
            ? "Threading: this chat works in the Linked Workroom \(room), so it does not wait for answers in its terminal."
            : "Threading: this chat works in the Linked Workroom \(room), and this turn ended on a question."
        return """
            \(opening) Ask it with workroom_ask instead — a domain question goes to the room's people, \(forUser) — \
            then keep working on whatever it does not block, or end the turn with a short status of what is waiting. \
            The answer arrives as mail.
            """
    }

    /// Whether a turn's last message ends on a question: its closing paragraph outside a code block
    /// ends with "?", or is short and has a sentence ending in "?" ("Ska jag fortsätta? Säg till.").
    /// A "?" inside a URL does not count. The Stop block fires once per turn, so a miss costs one
    /// wait and a false hit costs one extra turn.
    nonisolated static func endsOnQuestion(_ message: String) -> Bool {
        var inCode = false
        var lines: [Substring] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if !inCode { lines.append(line) }
        }
        let paragraphs = lines.split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = paragraphs.last else { return false }
        let text = last.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_)]\"'”’ "))
        if text.hasSuffix("?") { return true }
        guard text.utf8.count <= WorkroomQuestionGuardDefaults.closingParagraphBytes else { return false }
        let characters = Array(text)
        for (index, character) in characters.enumerated() where character == "?" {
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if next.isWhitespace || "\"”’)*_".contains(next) { return true }
        }
        return false
    }
}

enum WorkroomQuestionGuardDefaults {
    /// A closing paragraph this short that contains a question is taken to be asking it.
    static let closingParagraphBytes = 600
}
