#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import CoreSlice

/// Holds MainActor in the same blocking SDL loop as the workspace while real session classes
/// exchange protocol messages. No Task.yield, main-queue polling or provider service is involved.
@MainActor
enum NativeConversationDeliveryContract {
    static func run(script: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-ui-conversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("THREADING_LINUX_DATA_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let window = tw_open("Threading conversation callback contract", 360, 180) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        let loop = NativeUIWorkLoop(window: window)
        defer { loop.close() }
        let path = URL(fileURLWithPath: script).standardizedFileURL.path
        for mode in ["claude", "codex", "grok", "cursor"] {
            let plan = { AgentLaunchPlan(executable: "/usr/bin/python3", arguments: [path, mode], resumeState: .unavailable) }
            let session: any ConversationStreamSession
            switch mode {
            case "claude": session = ClaudeStreamSession(sessionID: SessionID(), callbackDelivery: NativeConversationDelivery.callbacks, plan: plan)
            case "codex": session = CodexStreamSession(sessionID: SessionID(), callbackDelivery: NativeConversationDelivery.callbacks, workingDirectory: "/tmp", plan: plan)
            default: session = ACPStreamSession(sessionID: SessionID(), callbackDelivery: NativeConversationDelivery.callbacks, workingDirectory: "/tmp", profile: mode == "grok" ? .grok : .cursor, plan: plan)
            }
            try exercise(session, mode: mode, window: window, loop: loop)
        }
        try checkOutputBudget(window: window, loop: loop)
        try checkSilentHandshake(window: window, loop: loop)
        try checkPlanningFailure(window: window, loop: loop)
        print("PASS native conversation UI delivery: four profiles, two persistent turns, permission replies, EOF, silent handshake deadline and deferred planning failure while SDL occupies MainActor")
    }

    private static func exercise(_ session: any ConversationStreamSession, mode: String, window: OpaquePointer, loop: NativeUIWorkLoop) throws {
        let text = "日本語 🧵 café"
        var finishes = 0
        var deltas = ""
        var exits: [Int32] = []
        var failed = false
        session.onEvent = {
            switch $0 {
            case .textDelta(let value): deltas += value
            case .turnFinished(_, let outcome, _): finishes += 1; failed = failed || outcome != .completed
            default: break
            }
        }
        session.onExit = { exits.append($0) }
        defer { session.terminate() }
        let defaultDecision = ConversationPermissionDecision.decide
        defer { ConversationPermissionDecision.decide = defaultDecision }
        session.start()
        guard let pid = session.rootProcessIdentifier else { throw WindowFailure("\(mode) started no child") }
        for turn in 1...2 {
            if mode == "codex" && turn == 2 {
                ConversationPermissionDecision.decide = { _, completion in completion(.allow(reason: "Inspected fixture command")) }
            }
            guard session.send("prompt \(turn) \(text)") else { throw WindowFailure("\(mode) refused turn") }
            try pump(window: window, loop: loop) { finishes >= turn || !exits.isEmpty }
            guard finishes == turn, !failed, session.canSend, session.rootProcessIdentifier == pid else {
                throw WindowFailure("\(mode) UI lost persistent turn: finishes=\(finishes) failed=\(failed) exits=\(exits)")
            }
        }
        guard deltas == text + text else { throw WindowFailure("\(mode) lost Unicode callbacks") }
        session.finish()
        try pump(window: window, loop: loop) { !exits.isEmpty }
        guard exits == [0], !session.isRunning else { throw WindowFailure("\(mode) invalid EOF exit: \(exits)") }
    }

    @MainActor private final class ExitReceipt { var exited = false }

    private static func checkOutputBudget(window: OpaquePointer, loop: NativeUIWorkLoop) throws {
        let receipt = ExitReceipt()
        let delivery = NativeConversationDelivery.callbacks
        let child = try AgentChildProcess.launch(executable: "/usr/bin/python3", arguments: ["-c", """
        import os, time
        os.write(1, b'first\\n')
        time.sleep(.03)
        for _ in range(512): os.write(1, b'x' * 8192)
        """], environment: ProcessInfo.processInfo.environment, sessionID: SessionID()) { _ in
            delivery.enqueue { receipt.exited = true }
        }
        defer { child.terminate() }
        var failures: [AgentStreamTransportFailure] = []
        let transport = AgentStreamTransport<String>(label: "codes.threading.native-ui-budget",
            input: child.standardInput, output: child.standardOutput, error: child.standardError,
            callbackDelivery: delivery, maximumPendingReadBytes: 64 * 1_024, maximumErrorBytes: 1_024,
            parser: { String(decoding: $0, as: UTF8.self) }, onLine: { _ in },
            onMalformedLine: {}, onFailure: { failure in failures.append(failure); child.terminate() })
        defer { transport.detach() }
        transport.start()
        // Keep the UI occupied while the first parsed line waits for its receipt. The peer's
        // many later chunks must hit byte admission rather than accumulate behind that receipt.
        let occupiedUntil = Date().addingTimeInterval(0.25)
        while Date() < occupiedUntil {
            var event = TWEvent()
            _ = tw_next_timeout(window, &event, 50)
        }
        try pump(window: window, loop: loop) { !failures.isEmpty && receipt.exited }
        guard failures == [.outputBackpressure] else { throw WindowFailure("native output budget: \(failures)") }
    }

    private static func checkSilentHandshake(window: OpaquePointer, loop: NativeUIWorkLoop) throws {
        let session = ACPStreamSession(sessionID: SessionID(), callbackDelivery: NativeConversationDelivery.callbacks,
            workingDirectory: "/tmp", profile: .grok, handshakeTimeout: 0.1) {
            AgentLaunchPlan(executable: "/bin/sh", arguments: ["-c", "cat >/dev/null"], resumeState: .unavailable)
        }
        defer { session.terminate() }
        var failed = false
        var exited = false
        session.onEvent = { if case .turnFinished(_, .failed, _) = $0 { failed = true } }
        session.onExit = { _ in exited = true }
        session.start()
        _ = session.send("The silent peer must not hold this conversation indefinitely.")
        try pump(window: window, loop: loop) { exited }
        guard failed else { throw WindowFailure("silent ACP peer did not report its handshake deadline") }
    }

    private static func checkPlanningFailure(window: OpaquePointer, loop: NativeUIWorkLoop) throws {
        let session = ClaudeStreamSession(sessionID: SessionID(), callbackDelivery: NativeConversationDelivery.callbacks) {
            throw WindowFailure("intentional launch refusal")
        }
        var exits: [Int32] = []
        session.onExit = { exits.append($0) }
        session.start()
        guard exits.isEmpty else { throw WindowFailure("planning failure was reentrant") }
        try pump(window: window, loop: loop) { !exits.isEmpty }
        guard exits == [-1] else { throw WindowFailure("planning failure delivered more than once") }
    }

    private static func pump(window: OpaquePointer, loop: NativeUIWorkLoop, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw WindowFailure("native conversation callback timed out in SDL") }
            var event = TWEvent()
            guard tw_next_timeout(window, &event, 1_000) >= 0 else { throw WindowFailure(String(cString: tw_error())) }
            loop.drain()
        }
    }
}
#endif
