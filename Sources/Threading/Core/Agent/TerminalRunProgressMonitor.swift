import Foundation

/// Serial, off-main reconciliation for a terminal session's hook and transcript feeds.
///
/// Hooks are the low-latency path. Transcript records pass through the same reducer and provider
/// call IDs, making them an idempotent catch-up path instead of a competing source of truth.
final class TerminalRunProgressMonitor: @unchecked Sendable {
    struct ScanResult: Sendable {
        let progress: RunProgress?
        let hasMore: Bool
    }

    private let queue = DispatchQueue(
        label: "codes.threading.run-progress",
        qos: .utility
    )
    private var reducer = RunProgressReducer()
    private var seen: Set<String> = []
    private var receivedHookThisTurn = false
    private var transcriptPath: String?
    private var transcriptOffset: UInt64 = 0

    func beginTurn(_ completion: @escaping @MainActor @Sendable (RunProgress?) -> Void) {
        queue.async { [self] in
            _ = reducer.reset()
            seen.removeAll(keepingCapacity: true)
            receivedHookThisTurn = false
            publish(reducer.snapshot, completion: completion)
        }
    }

    func clear(_ completion: @escaping @MainActor @Sendable (RunProgress?) -> Void) {
        queue.async { [self] in
            _ = reducer.reset()
            seen.removeAll(keepingCapacity: true)
            receivedHookThisTurn = false
            transcriptPath = nil
            transcriptOffset = 0
            publish(nil, completion: completion)
        }
    }

    /// Ends the visible plan for one turn without rewinding the durable transcript cursor.
    /// The next turn can therefore consume only newly appended JSONL rather than replaying a
    /// large conversation from byte zero every time the status strip clears.
    func endTurn(_ completion: @escaping @MainActor @Sendable (RunProgress?) -> Void) {
        queue.async { [self] in
            _ = reducer.reset()
            seen.removeAll(keepingCapacity: true)
            receivedHookThisTurn = false
            publish(nil, completion: completion)
        }
    }

    func apply(
        _ report: HookRunProgressReport,
        completion: @escaping @MainActor @Sendable (RunProgress?) -> Void
    ) {
        queue.async { [self] in
            switch report.mutation {
            case .toolUse(let id, let tool, let input):
                guard seen.insert("use:\(id)").inserted else { return }
                receivedHookThisTurn = true
                _ = reducer.apply(
                    toolUseID: id,
                    tool: tool,
                    input: input.mapValues(\.foundationValue)
                )
            case .result(let result):
                guard seen.insert("result:\(result.toolUseID)").inserted else { return }
                receivedHookThisTurn = true
                _ = reducer.apply(result: result)
            }
            publish(reducer.snapshot, completion: completion)
        }
    }

    func scan(
        at url: URL,
        kind: AgentKind,
        completion: @escaping @MainActor @Sendable (ScanResult) -> Void
    ) {
        queue.async { [self] in
            let size = Self.fileSize(url)
            if transcriptPath != url.path {
                transcriptPath = url.path
                if receivedHookThisTurn {
                    // The hook is newer than an undiscovered transcript path. Start at the
                    // current end so hydrating old turns cannot replace the live snapshot; all
                    // subsequent appends still flow through the ordinary resumable scan.
                    transcriptOffset = size
                } else {
                    transcriptOffset = 0
                    _ = reducer.reset()
                    seen.removeAll(keepingCapacity: true)
                }
            } else if size < transcriptOffset {
                transcriptOffset = 0
                _ = reducer.reset()
                seen.removeAll(keepingCapacity: true)
                receivedHookThisTurn = false
            }

            let scan = TranscriptReplay.runProgressEvents(
                at: url,
                kind: kind,
                from: transcriptOffset
            )
            transcriptOffset = scan.endOffset
            for event in scan.events {
                switch event {
                case .turnStarted:
                    // `beginTurn` already establishes the boundary. If a hook for this turn
                    // arrived before the transcript scan caught up, that hook is newer than
                    // the delayed user-message record and must not be erased by it.
                    guard !receivedHookThisTurn else { continue }
                    _ = reducer.reset()
                    seen.removeAll(keepingCapacity: true)
                case .toolUse(let id, let tool, let input):
                    guard seen.insert("use:\(id)").inserted else { continue }
                    _ = reducer.apply(
                        toolUseID: id,
                        tool: tool,
                        input: input.mapValues(\.foundationValue)
                    )
                case .result(let result):
                    guard seen.insert("result:\(result.toolUseID)").inserted else { continue }
                    _ = reducer.apply(result: result)
                }
            }
            let result = ScanResult(
                progress: reducer.snapshot,
                hasMore: transcriptOffset < Self.fileSize(url)
            )
            Task { @MainActor in completion(result) }
        }
    }

    private func publish(
        _ progress: RunProgress?,
        completion: @escaping @MainActor @Sendable (RunProgress?) -> Void
    ) {
        Task { @MainActor in completion(progress) }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
    }
}
