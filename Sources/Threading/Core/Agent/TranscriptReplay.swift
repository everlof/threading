import Foundation

/// The measured local conversation formats Threading can normalize.
///
/// This is a format dispatch, not a second provider policy. `AgentCapabilities.transcriptReplay`
/// is the public answer to whether replay exists; this closed adapter set is the compiler-checked
/// implementation behind that answer. `AgentCapabilitiesTests` holds the two in exact agreement,
/// so granting the capability without an adapter or leaving an unadvertised adapter behind fails.
enum TranscriptReplayFormat: CaseIterable, Sendable {
    case claude
    case codex

    init?(kind: AgentKind) {
        guard kind.supports(.transcriptReplay) else { return nil }
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok, .openCode, .cursor: return nil
        }
    }

    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}

// MARK: - Persisted tool calls

/// One tool call as its transcript recorded it, dated by that record.
struct TranscriptToolCall: Equatable, Sendable {
    let callID: String
    let tool: ToolIdentity
    let input: [String: JSONValue]
    let date: Date
}

/// One whole-file replay: what to render, whether older events were dropped by the window, and
/// what the format probe made of the file.
struct TranscriptReplayResult: Sendable {
    let events: [StreamEvent]
    let isTruncated: Bool
    /// Nil for a format that has no probe yet (Claude).
    let format: TranscriptFormatVerdict?
}

/// A resumable pass over a transcript's tool calls: what it read, and where to start next time.
struct TranscriptToolCallScan: Equatable, Sendable {
    let calls: [TranscriptToolCall]

    /// The absolute byte position just past the last record folded in. A caller that persists it
    /// alongside the work it counted can re-read the same file without counting anything twice.
    let endOffset: UInt64
}

enum TranscriptRunProgressEvent: Sendable {
    case turnStarted
    case toolUse(id: String, tool: ToolIdentity, input: [String: JSONValue])
    case result(ToolResult)
}

struct TranscriptRunProgressScan: Sendable {
    let events: [TranscriptRunProgressEvent]
    let endOffset: UInt64
}

/// One bounded, presentation-neutral row admitted to the rebuildable search index. It retains
/// provider byte offsets, not raw JSON or a filesystem path.
struct TranscriptSearchNormalizedRecord: Equatable, Sendable {
    let recordID: String
    let sourceStartOffset: UInt64
    let sourceEndOffset: UInt64
    let ordinal: Int
    let kind: SearchHitKind
    let author: SearchAuthor?
    let title: String
    let body: String
    let timestamp: Date?
    let hasError: Bool
    let bodyWasTruncated: Bool
}

struct TranscriptSearchNormalization: Equatable, Sendable {
    let records: [TranscriptSearchNormalizedRecord]
    let endOffset: UInt64
    let containsTruncatedBody: Bool
}

/// Rebuilds a past conversation from the transcript its agent keeps on disk.
///
/// A resumed session picks up with its full context, but the CLI replays none of it down the
/// stream — so without this the agent remembers everything while the screen shows nothing. The
/// terminal never had this problem: its scrollback was the record. Drawing the conversation
/// ourselves means we have to reconstruct it.
///
/// Output is `[StreamEvent]`, deliberately: replayed and live content then travel the same
/// rendering path, and there is no second set of views to keep in step with the first.
enum TranscriptReplay {

    static let maximumSearchBodyUTF8Bytes = 256 * 1_024

    /// Reads a session's transcript off the main thread and calls back with what to render.
    ///
    /// `isTruncated` reports that older turns were dropped, so the view can say so rather than
    /// implying the conversation began where the replay does.
    @MainActor
    static func load(
        for session: AgentSession,
        in project: Project,
        completion: @escaping @MainActor @Sendable (
            _ events: [StreamEvent], _ isTruncated: Bool
        ) -> Void
    ) {
        guard TranscriptReplayFormat(kind: session.kind) != nil,
              let agentSessionID = session.resumeState.transcriptID else {
            completion([], false)
            return
        }

        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else {
            completion([], false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = SessionTranscript.url(
                sessionID: agentSessionID,
                for: session,
                in: project,
                account: account
            ), FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { completion([], false) }
                return
            }

            let (events, isTruncated) = read(at: url, kind: session.kind)
            DispatchQueue.main.async { completion(events, isTruncated) }
        }
    }

    /// Normalizes searchable dialogue and bounded tool subjects from one resumable source window.
    /// Reasoning and raw tool output are deliberately absent from this projection.
    static func searchRecords(
        at url: URL,
        kind: AgentKind,
        from offset: UInt64 = 0,
        scanLimit: Int = ReplayDefaults.scanLimit
    ) -> TranscriptSearchNormalization {
        guard let format = TranscriptReplayFormat(kind: kind) else {
            return TranscriptSearchNormalization(
                records: [], endOffset: offset, containsTruncatedBody: false
            )
        }
        var normalized: [TranscriptSearchNormalizedRecord] = []
        var didTruncate = false
        let end = JSONLReader.forEachRecordWithOffsets(
            at: url,
            from: offset,
            limit: scanLimit
        ) { record, start, end in
            guard let event = event(from: record, format: format) else { return true }
            let stamp = timestamp(of: record)

            func append(
                ordinal: Int,
                kind: SearchHitKind,
                author: SearchAuthor?,
                title: String,
                body rawBody: String,
                hasError: Bool = false
            ) {
                let body = boundedSearchBody(rawBody)
                guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                didTruncate = didTruncate || body.wasTruncated
                normalized.append(TranscriptSearchNormalizedRecord(
                    recordID: "\(start):\(ordinal)",
                    sourceStartOffset: start,
                    sourceEndOffset: end,
                    ordinal: ordinal,
                    kind: kind,
                    author: author,
                    title: title,
                    body: body.text,
                    timestamp: stamp,
                    hasError: hasError,
                    bodyWasTruncated: body.wasTruncated
                ))
            }

            switch event {
            case .userMessage(let text):
                append(
                    ordinal: 0,
                    kind: .conversationMessage(.you),
                    author: .you,
                    title: "",
                    body: ConversationPrompt.replaying(text).text
                )

            case .assistantMessage(let blocks):
                for (ordinal, block) in blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        append(
                            ordinal: ordinal,
                            kind: .conversationMessage(.agent),
                            author: .agent,
                            title: "",
                            body: text
                        )
                    case .toolUse(_, let tool, let input):
                        let summary = PermissionRequest(
                            sessionID: SessionID(), tool: tool, input: input
                        ).oneLineSummary
                        append(
                            ordinal: ordinal,
                            kind: .toolSummary,
                            author: nil,
                            title: tool.rawName,
                            body: summary.isEmpty ? tool.rawName : "\(tool.rawName) \(summary)"
                        )
                    case .thinking:
                        break
                    }
                }

            case .transcriptNotice(let text):
                append(
                    ordinal: 0,
                    kind: .toolSummary,
                    author: nil,
                    title: "",
                    body: text
                )

            case .toolResults(let results):
                // Raw results are excluded. Only an error's fixed-size opening line is useful as
                // a searchable work receipt, and it remains labelled as a tool summary.
                for (ordinal, result) in results.enumerated() where result.isError {
                    let firstLine = result.text.split(whereSeparator: \.isNewline).first.map(String.init)
                    append(
                        ordinal: ordinal,
                        kind: .toolSummary,
                        author: nil,
                        title: "",
                        body: firstLine ?? "",
                        hasError: true
                    )
                }

            case .initialised, .textDelta, .thinkingDelta, .runPlanUpdated, .backgroundWork,
                 .turnFinished, .unknown:
                break
            }
            return true
        }
        return TranscriptSearchNormalization(
            records: normalized,
            endOffset: end,
            containsTruncatedBody: didTruncate
        )
    }

    private static func boundedSearchBody(_ text: String) -> (text: String, wasTruncated: Bool) {
        guard text.utf8.count > maximumSearchBodyUTF8Bytes else { return (text, false) }
        var data = Data(text.utf8.prefix(maximumSearchBodyUTF8Bytes))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return (String(data: data, encoding: .utf8) ?? "", true)
    }

    // MARK: - Private Methods

    /// Reads one transcript file synchronously. Internal rather than private so the tests can
    /// point it at a fixture: `load` needs a real session, a real project and the on-disk
    /// layout of an installed CLI, none of which a test should have to fake to check that a
    /// record maps to the right event.
    static func read(at url: URL, kind: AgentKind) -> ([StreamEvent], Bool) {
        let replay = replay(at: url, kind: kind)
        return (replay.events, replay.isTruncated)
    }

    /// `read` with the format verdict beside the events, and the rolling window as a parameter.
    ///
    /// The window is `ReplayDefaults.maximumEvents` because each event becomes a view; a caller
    /// that renders nothing — the handoff snapshot — must not inherit a rendering bound as if
    /// it were a context bound. That is exactly how a continued conversation came to hold the
    /// last 400 events of a Codex session, all of them tool calls and their output, and none of
    /// the user's messages.
    static func replay(
        at url: URL,
        kind: AgentKind,
        maximumEvents: Int = ReplayDefaults.maximumEvents
    ) -> TranscriptReplayResult {
        guard let format = TranscriptReplayFormat(kind: kind) else {
            return TranscriptReplayResult(events: [], isTruncated: false, format: nil)
        }
        var events: [StreamEvent] = []
        var dropped = 0

        // Both formats stamp every record, and dropping those stamps is what left every
        // replayed turn without an end: nothing on disk says "turn finished", but the gap
        // between a turn's opening user record and its last record does. A synthetic
        // `.turnFinished` per boundary is what lets a resumed conversation fold its settled
        // turns and settle tool calls that never reported back — the same events, so replay
        // and live cannot diverge.
        var turnStartedAt: Date?
        var turnIsOpen = false
        var lastEventAt: Date?
        var lastContextTokens: Int?
        var lastContextWindow: Int?
        // Carried across turns on purpose, like the context readings above: both CLIs restate
        // effort only when a turn reports it, so a turn that reported none ran at whatever the
        // last one did.
        var lastEffort: String?

        func endOpenTurn() {
            guard turnIsOpen else { return }
            turnIsOpen = false

            var metrics = TurnMetrics.empty
            if let started = turnStartedAt, let ended = lastEventAt,
               ended > started {
                metrics.duration = ended.timeIntervalSince(started)
            }
            metrics.contextTokens = lastContextTokens
            metrics.contextWindow = lastContextWindow
            metrics.effort = lastEffort
            events.append(.turnFinished(text: nil, outcome: .completed, metrics: metrics))
        }

        let verdict = forEachRecordEvent(
            at: url,
            format: format,
            scanLimit: ReplayDefaults.scanLimit
        ) { record, event in
            // Context facts ride records the event mapping skips — Codex's `token_count`
            // produces no row at all — so they are read before the mapping can bail.
            if let context = contextReading(of: record, format: format) {
                lastContextTokens = context.tokens
                if let window = context.window { lastContextWindow = window }
            }
            if let effort = effortReading(of: record, format: format) { lastEffort = effort }

            guard let event else { return true }

            if case .userMessage = event {
                endOpenTurn()
                turnIsOpen = true
                turnStartedAt = timestamp(of: record)
            }
            if let stamp = timestamp(of: record) { lastEventAt = stamp }

            events.append(event)

            // A rolling window rather than a head-first cap: what matters in a conversation
            // being resumed is how it ended, not how it began.
            if events.count > maximumEvents {
                events.removeFirst()
                dropped += 1
            }

            return true
        }
        endOpenTurn()

        // Drawn where the conversation should have been, so a format Threading cannot read
        // looks like what it is rather than like an agent that only ever ran commands.
        if case .codexDialogueUnreadable(let drift)? = verdict {
            events.insert(.transcriptNotice(drift.notice), at: 0)
        }

        return TranscriptReplayResult(events: events, isTruncated: dropped > 0, format: verdict)
    }

    /// Streams a transcript's records in order with the event each maps to, and returns what the
    /// format probe made of the whole file — nil for a format that has no probe yet.
    ///
    /// Every whole-file reader goes through here so the probe sees exactly what the reader saw:
    /// a verdict computed on one pass and a reduction made on another could disagree about the
    /// same file.
    static func forEachRecordEvent(
        at url: URL,
        kind: AgentKind,
        scanLimit: Int = ReplayDefaults.scanLimit,
        _ body: (_ record: [String: Any], _ event: StreamEvent?) -> Bool
    ) -> TranscriptFormatVerdict? {
        guard let format = TranscriptReplayFormat(kind: kind) else { return nil }
        return forEachRecordEvent(at: url, format: format, scanLimit: scanLimit, body)
    }

    private static func forEachRecordEvent(
        at url: URL,
        format: TranscriptReplayFormat,
        scanLimit: Int,
        _ body: (_ record: [String: Any], _ event: StreamEvent?) -> Bool
    ) -> TranscriptFormatVerdict? {
        var probe: CodexRolloutFormatProbe?
        switch format {
        case .claude: probe = nil
        case .codex: probe = CodexRolloutFormatProbe()
        }

        JSONLReader.forEachRecord(at: url, limit: scanLimit) { record in
            let event = self.event(from: record, format: format)
            probe?.observe(record: record, event: event)
            return body(record, event)
        }

        guard let probe else { return nil }
        let verdict = probe.verdict
        report(verdict, transcript: url)
        return verdict
    }

    /// Says so, once per read, when a file's dialogue could not be read: the log for whoever is
    /// debugging, the journal for a support report. Neither carries conversation content.
    private static func report(_ verdict: TranscriptFormatVerdict, transcript: URL) {
        guard case .codexDialogueUnreadable(let drift) = verdict else { return }
        ThreadingLogger.agent.error(
            "Codex rollout format unreadable cli_version=\(drift.cliVersion ?? "unknown", privacy: .public) verified_through=\(CodexRolloutFormat.newestVerifiedCLIVersion, privacy: .public) unfamiliar_items=\(drift.unfamiliarItemTypes.joined(separator: ","), privacy: .public) unread_assistant_messages=\(drift.unreadAssistantMessages, privacy: .public) path=\(transcript.path, privacy: .private(mask: .hash))"
        )
        EventLog.shared.record(.session, "Codex rollout format unreadable", drift.logFields)
    }

    /// The tool calls a transcript records from `offset` onward, each with the time its own
    /// record carries.
    ///
    /// This is `read`'s sibling for the Activity panel rather than for the conversation view, and
    /// the two differences are the whole reason it exists. It resumes, because a session's work is
    /// folded in repeatedly while the session runs and re-counting the calls already folded in
    /// would inflate every reading. And it keeps each record's own timestamp, which `[StreamEvent]`
    /// cannot carry — replay stamps its whole reduction `distantPast` for exactly that reason,
    /// which is honest for a footprint and useless for recency.
    ///
    /// Everything else is shared: the same closed format set, the same record-to-event mapping,
    /// so a runtime whose conversation replays correctly reports its work correctly too.
    static func toolCalls(
        at url: URL,
        kind: AgentKind,
        from offset: UInt64,
        limit: Int = ReplayDefaults.workScanCalls
    ) -> TranscriptToolCallScan {
        guard let format = TranscriptReplayFormat(kind: kind) else {
            return TranscriptToolCallScan(calls: [], endOffset: offset)
        }

        var calls: [TranscriptToolCall] = []
        // Records that carry a tool call do not all carry a stamp — Codex writes the call and its
        // time on separate lines — so the newest stamp seen stands in. It is never in the future
        // of the call it dates, which is what the heat reading needs.
        var lastStamp: Date?

        let endOffset = JSONLReader.forEachRecord(
            at: url,
            from: offset,
            limit: ReplayDefaults.scanLimit
        ) { record in
            if let stamp = timestamp(of: record) { lastStamp = stamp }
            guard case .assistantMessage(let blocks)? = event(from: record, format: format) else {
                return true
            }

            let date = timestamp(of: record) ?? lastStamp ?? Date.distantPast
            for block in blocks {
                guard case .toolUse(let callID, let tool, let input) = block else { continue }
                calls.append(TranscriptToolCall(
                    callID: callID, tool: tool, input: input, date: date
                ))
            }
            // Bounded per pass rather than per file: a first hydration of a very long
            // conversation stops here and the next pass continues from the position returned,
            // so no reading is lost and no single pass is unbounded.
            return calls.count < limit
        }

        return TranscriptToolCallScan(calls: calls, endOffset: endOffset)
    }

    /// Incrementally reads only the records capable of changing a run checklist. User-message
    /// boundaries are retained so a first scan of a long existing transcript cannot surface the
    /// previous turn's final plan as the current turn's plan.
    static func runProgressEvents(
        at url: URL,
        kind: AgentKind,
        from offset: UInt64,
        limit: Int = ReplayDefaults.workScanCalls
    ) -> TranscriptRunProgressScan {
        guard let format = TranscriptReplayFormat(kind: kind) else {
            return TranscriptRunProgressScan(events: [], endOffset: offset)
        }

        var events: [TranscriptRunProgressEvent] = []
        let endOffset = JSONLReader.forEachRecord(
            at: url,
            from: offset,
            limit: ReplayDefaults.scanLimit
        ) { record in
            guard let stream = event(from: record, format: format) else { return true }
            switch stream {
            case .userMessage:
                events.append(.turnStarted)
            case .assistantMessage(let blocks):
                for block in blocks {
                    guard case .toolUse(let id, let tool, let input) = block,
                          tool == .plan || tool == .todoWrite
                            || tool == .taskCreate || tool == .taskUpdate else { continue }
                    events.append(.toolUse(id: id, tool: tool, input: input))
                }
            case .toolResults(let results):
                events.append(contentsOf: results.map(TranscriptRunProgressEvent.result))
            default:
                break
            }
            return events.count < limit
        }
        return TranscriptRunProgressScan(events: events, endOffset: endOffset)
    }

    /// The assistant prose in the newest transcript turn, in conversational order.
    ///
    /// Terminal TUIs do not necessarily let the emulator perform wrapping. Codex, for example,
    /// lays markdown out to the current width and paints each visual row with cursor movement, so
    /// `BufferLine.isWrapped` cannot reconstruct the source sentence. The transcript is the one
    /// place that still has it intact.
    ///
    /// Reads backwards under a byte budget and stops at the newest real user-message boundary.
    /// Tool results, reasoning and duplicated response-item messages are excluded by the same
    /// provider normalization replay uses, so attachment detection cannot turn incidental tool
    /// output into something the assistant presented to the user.
    static func latestAssistantTexts(
        at url: URL,
        kind: AgentKind,
        scanLimit: Int
    ) -> [String] {
        guard scanLimit > 0, let format = TranscriptReplayFormat(kind: kind) else { return [] }

        var newestFirst: [String] = []
        JSONLReader.forEachRecordFromEnd(at: url, limit: scanLimit) { record in
            guard let event = event(from: record, format: format) else { return true }

            switch event {
            case .userMessage:
                return false
            case .assistantMessage(let blocks):
                newestFirst += blocks.reversed().compactMap { block in
                    guard case .text(let text) = block, !text.isEmpty else { return nil }
                    return text
                }
            default:
                break
            }
            return true
        }

        return newestFirst.reversed()
    }

    /// The reasoning effort a turn actually ran at, where the record says.
    ///
    /// Read beside `contextReading` and for the same reason: the fact rides records the event
    /// mapping skips — Codex's `turn_context` produces no row at all — so it has to be taken
    /// before the mapping can bail.
    ///
    /// **This is more authoritative than the launch-time setting.** `AgentModels.defaultEffort`
    /// answers what a session *would* request by reading the account's config, which is the only
    /// answer available before a turn runs; it cannot see a mid-session change, so a conversation
    /// switched with `/effort` replayed at its original setting. The transcript records what each
    /// turn was actually given.
    ///
    /// Claude stamps `effort` at the top level of every assistant record. Sidechains are excluded
    /// on the same rule as the context reading: a subagent's turn is not this conversation's.
    /// Codex writes it as `payload.effort` on a `turn_context` record, and restates it in
    /// `thread_settings` when a setting is applied — the turn's own value is preferred, since the
    /// applied settings describe the thread rather than the turn that followed.
    private static func effortReading(
        of record: [String: Any],
        format: TranscriptReplayFormat
    ) -> String? {
        func nonEmpty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return text
        }

        switch format {
        case .claude:
            guard record["type"] as? String == "assistant",
                  record["isSidechain"] as? Bool != true
            else { return nil }
            return nonEmpty(record["effort"])

        case .codex:
            guard let payload = record["payload"] as? [String: Any] else { return nil }
            if let effort = nonEmpty(payload["effort"]) { return effort }
            guard let settings = payload["thread_settings"] as? [String: Any] else { return nil }
            return nonEmpty(settings["reasoning_effort"])
        }
    }

    /// How full the model's window was as of this record, where the record says.
    ///
    /// Claude writes a `usage` object on every assistant record — `input_tokens` excludes
    /// cache reads, so the parts are summed. Codex writes `token_count` records whose
    /// `last_token_usage.total_tokens` is the most recent request's size (the running
    /// `total_token_usage` exceeds the window on any long session, and must not be used),
    /// with `model_context_window` beside it.
    private static func contextReading(
        of record: [String: Any],
        format: TranscriptReplayFormat
    ) -> (tokens: Int, window: Int?)? {
        switch format {
        case .claude:
            guard record["type"] as? String == "assistant",
                  record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return nil }
            let input = contextTerm(usage["input_tokens"])
            let cacheRead = contextTerm(usage["cache_read_input_tokens"])
            let cacheCreation = contextTerm(usage["cache_creation_input_tokens"])
            guard input != nil || cacheRead != nil || cacheCreation != nil else { return nil }
            let output = contextTerm(usage["output_tokens"])
            guard let tokens = sum(of: [input, cacheRead, cacheCreation, output]) else {
                return nil
            }
            return (tokens, nil)

        case .codex:
            guard let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let tokens = contextTerm(last["total_tokens"])?.count else { return nil }
            return (tokens, contextTerm(info["model_context_window"])?.count)
        }
    }

    /// One term of a context reading: the key was absent (`nil`), it held a count, or it held a
    /// number this app cannot hold.
    private enum ContextTerm {
        case tokens(Int)
        case unreadable

        /// The count, where an unreadable term costs only itself — right for the context window
        /// beside a Codex reading, which is an adjunct and absent often enough already. It is
        /// the wrong rule for a term of the sum, which `sum(of:)` handles instead.
        var count: Int? {
            guard case .tokens(let value) = self else { return nil }
            return value
        }
    }

    /// One `usage` term, read the way `NSNumber.intValue` read it before — a boolean counts as
    /// one token and a fractional count truncates toward zero, both preserved — except that a
    /// number outside `Int` is `.unreadable` rather than a wrapped negative.
    ///
    /// A value that is not a number at all stays *absent*, which is the answer the `as? NSNumber`
    /// cast this replaced already gave. A quoted count is a separate finding of its own and is
    /// deliberately neither fixed nor made worse here.
    private static func contextTerm(_ value: Any?) -> ContextTerm? {
        guard let number = value as? NSNumber else { return nil }
        guard let count = WireInteger.wholeInt(number) else { return .unreadable }
        return .tokens(count)
    }

    /// The terms added up, or nil when no number here is worth showing anyone.
    ///
    /// **A term that is there and unreadable makes the whole reading unknown, and the addition
    /// must not be allowed to trap.** This is where the crash was: `int64Value` handed two
    /// wrapped negatives to Swift's `+` and the overflow trapped the process — reachable by
    /// opening a conversation whose transcript file holds an oversized `*_tokens` value, and
    /// repeatable every time it was opened. Overflow-safe addition removes the trap; refusing
    /// the reading is what makes the answer honest afterwards, because dropping the bad term
    /// would understate how full the window is with nothing to say it had, and clamping it would
    /// invent a number the provider never sent. Every caller already treats a missing reading as
    /// ordinary, so refusing costs one status line and no correctness.
    private static func sum(of terms: [ContextTerm?]) -> Int? {
        var total = 0
        for term in terms {
            switch term {
            case nil:
                continue
            case .unreadable?:
                return nil
            case .tokens(let count)?:
                let (added, overflowed) = total.addingReportingOverflow(count)
                guard !overflowed else { return nil }
                total = added
            }
        }
        return total
    }

    /// When a record was written. Shared with import, which asks the same question of the same
    /// two formats from the other end of the file.
    private static func timestamp(of record: [String: Any]) -> Date? {
        TranscriptTimestamp.of(record)
    }

    /// Maps one transcript record to something worth drawing, or nil to skip it.
    private static func event(
        from record: [String: Any],
        format: TranscriptReplayFormat
    ) -> StreamEvent? {
        switch format {
        case .claude:
            return claudeEvent(from: record)
        case .codex:
            return codexEvent(from: record)
        }
    }

    /// Maps one Claude transcript record to something worth drawing, or nil to skip it.
    private static func claudeEvent(from record: [String: Any]) -> StreamEvent? {
        // Records Claude writes about itself rather than about the conversation: mode
        // changes, titles, file snapshots, deferred-tool deltas. None of it is dialogue.
        guard let type = record["type"] as? String,
              type == "user" || type == "assistant" else { return nil }

        // `isMeta` marks text the CLI injected on the user's behalf — the local-command
        // caveat, for one — which was never typed and should not appear as though it was.
        guard record["isMeta"] as? Bool != true else { return nil }

        // Sidechains are subagent conversations. They belong to a run of the Task tool, not
        // to this thread, and interleaving them would make the transcript read as nonsense.
        guard record["isSidechain"] as? Bool != true else { return nil }

        guard let message = record["message"] as? [String: Any] else { return nil }

        if type == "assistant" {
            // Per element. `as? [[String: Any]]` here answered one `null` in `content` by
            // discarding the array, so a whole assistant turn left no trace in the replayed
            // conversation — a loss that reads as "the agent said nothing".
            let content = WireList.objects(
                message["content"],
                site: WireListSite.claudeAssistantContent,
                log: ThreadingLogger.agent
            ) ?? []
            let blocks = content.compactMap(StreamEvent.contentBlock)
            return blocks.isEmpty ? nil : .assistantMessage(blocks: blocks)
        }

        return ClaudeTranscriptUserRecord.event(from: message, scope: .parent)
    }

    /// Codex records dialogue as `event_msg` and tool activity as `response_item`. Response
    /// items also contain copies of messages, so only their tool shapes are accepted here —
    /// otherwise every user and assistant message would be replayed twice.
    ///
    /// Dialogue has two shapes, both read: the `user_message`/`agent_message` events of releases
    /// up to 0.146, and the `item_completed` envelope of 0.147 and later. See
    /// `CodexRolloutFormat` for the measurement, and `CodexRolloutFormatProbe` for what happens
    /// when a third shape arrives.
    static func codexEvent(from record: [String: Any]) -> StreamEvent? {
        guard let recordType = record[CodexRolloutFormat.Key.type] as? String,
              let payload = record[CodexRolloutFormat.Key.payload] as? [String: Any]
        else { return nil }

        if recordType == CodexRolloutFormat.RecordType.responseItem {
            return codexToolEvent(from: payload)
        }

        guard recordType == CodexRolloutFormat.RecordType.eventMessage,
              let type = payload[CodexRolloutFormat.Key.type] as? String else { return nil }

        switch type {
        case CodexRolloutFormat.EventType.legacyUserMessage:
            guard let text = payload["message"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .userMessage(trimmed)

        case CodexRolloutFormat.EventType.legacyAgentMessage:
            guard let text = payload["message"] as? String, !text.isEmpty else { return nil }
            return .assistantMessage(blocks: [.text(text)])

        case CodexRolloutFormat.EventType.legacyAgentReasoning:
            guard let text = payload[CodexRolloutFormat.Key.text] as? String, !text.isEmpty
            else { return nil }
            return .assistantMessage(blocks: [.thinking(text)])

        case CodexRolloutFormat.EventType.itemCompleted:
            return codexItemEvent(from: payload[CodexRolloutFormat.Key.item])

        default:
            return nil
        }
    }

    /// The 0.147+ dialogue shape: an `item_completed` event carrying one typed item.
    ///
    /// Only the conversational items map here. A `CommandExecution`, `FileChange` or
    /// `McpToolCall` item restates a tool call that the paired `response_item` records already
    /// replay, and mapping both would draw every tool row twice — the same duplicate rule as the
    /// `response_item` message copies, from the other side.
    private static func codexItemEvent(from value: Any?) -> StreamEvent? {
        guard let item = value as? [String: Any],
              let type = item[CodexRolloutFormat.Key.type] as? String else { return nil }

        switch type {
        case CodexRolloutFormat.ItemType.userMessage:
            guard let text = CodexRolloutFormat.text(of: item[CodexRolloutFormat.Key.content])
            else { return nil }
            return .userMessage(text)

        case CodexRolloutFormat.ItemType.agentMessage:
            guard let text = CodexRolloutFormat.text(of: item[CodexRolloutFormat.Key.content])
            else { return nil }
            return .assistantMessage(blocks: [.text(text)])

        case CodexRolloutFormat.ItemType.reasoning:
            // `summary_text` is the visible summary; `raw_content` is the encrypted chain and
            // empty in every measured file.
            guard let summaries = item[CodexRolloutFormat.Key.summaryText] as? [String]
            else { return nil }
            let text = summaries.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .assistantMessage(blocks: [.thinking(text)])

        case CodexRolloutFormat.ItemType.contextCompaction:
            // The same line the live stream draws when Codex compacts, so a replayed
            // conversation reads as the live one did.
            return .transcriptNotice(L10n.string("Context compacted."))

        default:
            return nil
        }
    }

    /// Rebuilds the tool row Codex showed while the turn was live. Current rollouts persist
    /// orchestrated tools as a call and a later output joined by `call_id`; older function-call
    /// records use the same pairing, so accepting both keeps existing sessions useful too.
    private static func codexToolEvent(from payload: [String: Any]) -> StreamEvent? {
        guard let type = payload["type"] as? String else { return nil }

        switch type {
        case "custom_tool_call", "function_call":
            guard let id = (payload["call_id"] as? String) ?? (payload["id"] as? String),
                  let persistedName = payload["name"] as? String else { return nil }

            let rawInput = payload["input"] ?? payload["arguments"]
            let input = codexToolInput(persistedName: persistedName, value: rawInput)
            // Per member. A replayed rollout is a record of what already happened, so dropping
            // the whole row is the one answer that cannot be right: the tool call did run, and a
            // reader comparing the replay against the live conversation would find it missing
            // with nothing to explain the gap.
            let typedInput = JSONValue.convertingObject(from: input)
            let name = codexToolName(persistedName: persistedName, value: rawInput)
            return .assistantMessage(blocks: [
                .toolUse(id: id, tool: ToolIdentity(name), input: typedInput)
            ])

        case "custom_tool_call_output", "function_call_output":
            guard let id = payload["call_id"] as? String else { return nil }
            let value = payload["output"] ?? payload["result"] ?? payload["error"]
            return .toolResults([
                ToolResult(
                    toolUseID: id,
                    text: codexToolOutput(value),
                    isError: CodexToolCallWireStatus(payload["status"] as? String) == .failed
                        || payload["error"] != nil
                )
            ])

        default:
            return nil
        }
    }

    /// Turns Codex's persisted tool name into the vocabulary used by the live stream adapter.
    /// A `custom_tool_call` named `exec` is the orchestration wrapper; the actual tool appears
    /// inside its JavaScript input as `tools.exec_command(...)`.
    private static func codexToolName(persistedName: String, value: Any?) -> String {
        let nestedName = (value as? String).flatMap(codexNestedToolName)

        switch nestedName ?? persistedName {
        case "exec", "exec_command":
            return "Bash"
        case "apply_patch", "file_change":
            return "Edit"
        case "web_search":
            return "WebSearch"
        case "view_image":
            return "Read"
        case "update_plan":
            return "Plan"
        default:
            return nestedName ?? persistedName
        }
    }

    /// Produces the arguments expected by `PermissionRequest.summary` and `EditDiff`, so
    /// replayed rows use the same concise subject line as live ones rather than exposing the
    /// orchestration wrapper.
    ///
    /// **Codex and Claude do not name their arguments alike**, and passing Codex's through
    /// unchanged is why every replayed `exec_command` rendered as a bare `$ Bash` with no
    /// command beside it: the summary reads `command`, Codex writes `cmd`. Found by rendering
    /// a real rollout and looking at it — no parser test could see it, because the parsing was
    /// correct and only the vocabulary was wrong.
    private static func codexToolInput(persistedName: String, value: Any?) -> [String: Any] {
        let raw: [String: Any]

        if let dictionary = value as? [String: Any] {
            raw = dictionary
        } else if let text = value as? String, let dictionary = jsonDictionary(text) {
            raw = dictionary
        } else if let text = value as? String {
            // `apply_patch` is not JSON at all: its argument is the patch itself.
            if persistedName == "apply_patch" || persistedName == "file_change" {
                return CodexPatch.toolInput(patch: text)
            }
            switch codexNestedToolName(text) {
            case "exec_command" where persistedName == "exec":
                if let command = javascriptStringProperty("cmd", in: text) {
                    return ["command": command]
                }
            case "update_plan" where persistedName == "exec":
                // Code mode persists one orchestration call rather than a nested function-call
                // record. Its argument is still a data literal, so parse only that literal —
                // never evaluate the surrounding model-authored JavaScript.
                if let plan = javascriptDataArgument(tool: "update_plan", in: text) {
                    return plan
                }
            case "apply_patch", "file_change":
                // The wrapper assigns the patch to a variable and passes it positionally —
                // `const patch = "*** Begin Patch…"; text(await tools.apply_patch(patch))` —
                // so there is no property to read it from. Found by the render harness: these
                // edits drew no path and no diff, while `apply_patch` called directly did.
                if let patch = javascriptPatchLiteral(in: text) {
                    return CodexPatch.toolInput(patch: patch)
                }
            default:
                break
            }
            return ["input": text]
        } else {
            return [:]
        }

        return normalised(raw, persistedName: persistedName)
    }

    /// Renames Codex's arguments to the ones the renderer already understands, leaving the rest
    /// in place so nothing is lost for tools with no rule.
    private static func normalised(
        _ input: [String: Any],
        persistedName: String
    ) -> [String: Any] {
        var input = input

        if let command = input["cmd"] as? String {
            input["command"] = command
        }
        if let path = (input["path"] ?? input["file_path"]) as? String {
            input["file_path"] = path
        }
        if let patch = input["patch"] as? String {
            return CodexPatch.toolInput(patch: patch)
        }
        if let query = (input["query"] ?? input["q"]) as? String {
            input["query"] = query
        }

        return input
    }

    private static func codexNestedToolName(_ source: String) -> String? {
        firstCapture(#"tools\.([A-Za-z0-9_]+)\s*\("#, in: source)
    }

    /// The patch inside a generated wrapper, found by what it *is* rather than by the name it
    /// was bound to — the variable is arbitrary, but a patch always opens `*** Begin Patch`.
    private static func javascriptPatchLiteral(in source: String) -> String? {
        let pattern = #"("\*\*\* Begin Patch(?:\\.|[^"\\])*")"#
        guard let literal = firstCapture(pattern, in: source),
              let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// Extracts a JSON-style quoted string from the generated JavaScript and lets JSONDecoder
    /// handle escapes. If Codex changes wrapper syntax, the row still renders with raw input.
    private static func javascriptStringProperty(_ property: String, in source: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        let pattern = #"\b"# + escapedProperty + #"\s*:\s*("(?:\\.|[^"\\])*")"#
        guard let literal = firstCapture(pattern, in: source),
              let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// Reads the first data-only object passed to a generated code-mode tool invocation.
    ///
    /// The wrapper is model-authored JavaScript and must never be evaluated in the app. This
    /// deliberately small parser admits only JSON's values plus JavaScript's unquoted object
    /// keys and trailing commas — exactly the serializer shape measured in Codex rollouts.
    private static func javascriptDataArgument(
        tool: String,
        in source: String
    ) -> [String: Any]? {
        var parser = JavaScriptDataLiteralParser(source: source)
        return parser.objectArgument(toTool: tool)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func jsonDictionary(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Tool output can be a string or a sequence of typed text blocks. Blocks already carry
    /// their own newlines, so concatenate rather than inserting formatting Codex did not emit.
    private static func codexToolOutput(_ value: Any?) -> String {
        if let text = value as? String { return text }

        // Per element, but only where this is a block list at all: a JSON array of scalars is
        // not tool output written as typed blocks, and it still falls through to the dump below
        // rather than being answered as an empty string.
        if let blocks = WireList.objectsIfListed(
            value, site: WireListSite.codexToolOutput, log: ThreadingLogger.agent
        ) {
            let text = blocks.compactMap { $0["text"] as? String }.joined()

            // The orchestration layer prefixes command output with its own completion and
            // timing lines. Live structured Codex events expose only the aggregated output, so
            // remove that envelope to keep a replayed row identical to the one originally shown.
            if text.hasPrefix("Script completed\n"),
               let marker = text.range(of: "\nOutput:\n") {
                return String(text[marker.upperBound...])
            }

            return text
        }

        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

}

/// A bounded parser for the data-literal subset Codex writes inside code-mode wrappers.
/// It has no evaluator, identifiers-as-values, property access, calls, interpolation or getters;
/// unexpected syntax simply falls back to the raw tool input already used by replay.
private struct JavaScriptDataLiteralParser {
    private let source: String
    private var index: String.Index
    private var remainingValues = 20_000
    private static let maximumDepth = 32

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func objectArgument(toTool tool: String) -> [String: Any]? {
        let escaped = NSRegularExpression.escapedPattern(for: tool)
        guard let expression = try? NSRegularExpression(
            pattern: #"tools\."# + escaped + #"\s*\("#
        ), let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ), let range = Range(match.range, in: source) else { return nil }

        index = range.upperBound
        guard let value = parseValue(depth: 0) as? [String: Any] else { return nil }
        skipWhitespace()
        guard consume(")") else { return nil }
        return value
    }

    private mutating func parseValue(depth: Int) -> Any? {
        guard depth <= Self.maximumDepth, remainingValues > 0 else { return nil }
        remainingValues -= 1
        skipWhitespace()
        guard index < source.endIndex else { return nil }

        switch source[index] {
        case "{": return parseObject(depth: depth + 1)
        case "[": return parseArray(depth: depth + 1)
        case "\"": return parseJSONString()
        case "-", "0"..."9": return parseNumber()
        default:
            if consumeKeyword("true") { return true }
            if consumeKeyword("false") { return false }
            if consumeKeyword("null") { return NSNull() }
            return nil
        }
    }

    private mutating func parseObject(depth: Int) -> [String: Any]? {
        guard consume("{") else { return nil }
        skipWhitespace()
        if consume("}") { return [:] }

        var result: [String: Any] = [:]
        while true {
            skipWhitespace()
            guard let key = parseKey() else { return nil }
            skipWhitespace()
            guard consume(":"), let value = parseValue(depth: depth) else { return nil }
            result[key] = value
            skipWhitespace()
            if consume("}") { return result }
            guard consume(",") else { return nil }
            skipWhitespace()
            if consume("}") { return result }
        }
    }

    private mutating func parseArray(depth: Int) -> [Any]? {
        guard consume("[") else { return nil }
        skipWhitespace()
        if consume("]") { return [] }

        var result: [Any] = []
        while true {
            guard let value = parseValue(depth: depth) else { return nil }
            result.append(value)
            skipWhitespace()
            if consume("]") { return result }
            guard consume(",") else { return nil }
            skipWhitespace()
            if consume("]") { return result }
        }
    }

    private mutating func parseKey() -> String? {
        if index < source.endIndex, source[index] == "\"" { return parseJSONString() }
        guard index < source.endIndex, isIdentifierStart(source[index]) else { return nil }
        let start = index
        advance()
        while index < source.endIndex, isIdentifierContinuation(source[index]) { advance() }
        return String(source[start..<index])
    }

    private mutating func parseJSONString() -> String? {
        guard index < source.endIndex, source[index] == "\"" else { return nil }
        let start = index
        advance()
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            advance()
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = String(source[start..<index])
                guard let data = literal.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(String.self, from: data)
            }
        }
        return nil
    }

    private mutating func parseNumber() -> Any? {
        let start = index
        if consume("-") {}
        while index < source.endIndex, source[index].isNumber { advance() }
        if consume(".") {
            guard index < source.endIndex, source[index].isNumber else { return nil }
            while index < source.endIndex, source[index].isNumber { advance() }
        }
        if index < source.endIndex, (source[index] == "e" || source[index] == "E") {
            advance()
            if index < source.endIndex, (source[index] == "+" || source[index] == "-") {
                advance()
            }
            guard index < source.endIndex, source[index].isNumber else { return nil }
            while index < source.endIndex, source[index].isNumber { advance() }
        }
        let text = String(source[start..<index])
        if !text.contains(".") && !text.contains("e") && !text.contains("E"),
           let integer = Int(text) { return integer }
        return Double(text)
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace { advance() }
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard index < source.endIndex, source[index] == character else { return false }
        advance()
        return true
    }

    private mutating func consumeKeyword(_ keyword: String) -> Bool {
        guard source[index...].hasPrefix(keyword) else { return false }
        let end = source.index(index, offsetBy: keyword.count)
        guard end == source.endIndex || !isIdentifierContinuation(source[end]) else { return false }
        index = end
        return true
    }

    private mutating func advance() {
        index = source.index(after: index)
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}

// MARK: - Claude User Records

/// Separates user dialogue from the XML-shaped control records Claude persists as user messages.
///
/// This is deliberately an allowlist at the transcript boundary, not an XML cleaner. Unknown
/// tags remain literal user text. Known envelopes are accepted only in the complete shapes
/// measured from Claude 2.1.220 transcripts, so code, HTML and a user-authored `<word>` cannot
/// disappear merely because it uses angle brackets.
enum ClaudeTranscriptUserRecord {

    enum Scope {
        case parent
        case child
    }

    /// A user record is either something typed, a batch of tool results, or provider chrome.
    static func event(
        from message: [String: Any],
        scope: Scope
    ) -> StreamEvent? {
        // Per element. A `null` beside the tool results took every result with it, and the
        // record then had no text either, so the whole user turn disappeared from the replay.
        if let content = WireList.objects(
            message["content"], site: WireListSite.claudeUserContent, log: ThreadingLogger.agent
        ) {
            let results = content.compactMap(StreamEvent.toolResult)
            if !results.isEmpty { return .toolResults(results) }
        }

        guard let text = text(from: message) else { return nil }
        switch presentation(of: text, scope: scope) {
        case .user(let value):
            return .userMessage(value)
        case .notice(let value):
            return .transcriptNotice(value)
        case .suppressed:
            return nil
        }
    }

    /// The actual task prompt from a child's opening record, with Claude's fork instructions
    /// removed. Used by the cheap metadata index without replaying the whole conversation.
    static func userText(from message: [String: Any]) -> String? {
        guard let text = text(from: message),
              case .user(let value) = presentation(of: text, scope: .child) else {
            return nil
        }
        return value
    }

    private enum Presentation {
        case user(String)
        case notice(String)
        case suppressed
    }

    private static func text(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            return nonempty(text)
        }

        // Per element, for the reason the caller above is: the text blocks that *are* readable
        // are what the person typed, and refusing them removed the prompt from the transcript.
        guard let content = WireList.objects(
            message["content"], site: WireListSite.claudeUserText, log: ThreadingLogger.agent
        ) else {
            return nil
        }
        return nonempty(content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n"))
    }

    private static func presentation(
        of text: String,
        scope: Scope
    ) -> Presentation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fork children receive 928 characters of provider instructions followed by the real
        // task in the same text block. Dropping the record loses the task; stripping any other
        // leading tag risks deleting user content. It is child-only as well as shape-specific:
        // a parent user is still free to discuss this literal tag.
        if scope == .child, let fork = consumeLeadingEnvelope(
            tag: "fork-boilerplate",
            from: trimmed
        ) {
            return nonempty(fork.remainder).map(Presentation.user) ?? .suppressed
        }

        // A local slash command is one record containing these three envelopes in this order.
        // Its name is useful history; its transport message and arguments are not another turn.
        if let name = consumeLeadingEnvelope(tag: "command-name", from: trimmed),
           let message = consumeLeadingEnvelope(
               tag: "command-message",
               from: name.remainder
           ),
           let arguments = consumeLeadingEnvelope(
               tag: "command-args",
               from: message.remainder
           ),
           nonempty(arguments.remainder) == nil {
            guard let command = nonempty(name.body) else { return .user(trimmed) }
            let invocation = nonempty(arguments.body)
                .map { "\(command) \($0)" }
                ?? command
            return .notice(invocation)
        }

        // Some Claude releases persist the message/arguments half separately. It duplicates
        // the command-name record above and has no standalone conversational meaning.
        if let message = consumeLeadingEnvelope(tag: "command-message", from: trimmed),
           let arguments = consumeLeadingEnvelope(
               tag: "command-args",
               from: message.remainder
           ),
           nonempty(arguments.remainder) == nil {
            return .suppressed
        }

        // These are complete provider control records. Structured live adapters already turn
        // task notifications into lifecycle events; command output and reminders are CLI chrome.
        for tag in [
            "task-notification",
            "local-command-stdout",
            "local-command-caveat",
            "system-reminder"
        ] {
            if let envelope = consumeLeadingEnvelope(tag: tag, from: trimmed),
               nonempty(envelope.remainder) == nil {
                return .suppressed
            }
        }

        return .user(trimmed)
    }

    private static func consumeLeadingEnvelope(
        tag: String,
        from text: String
    ) -> (body: String, remainder: String)? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<\(tag)>"
        let closing = "</\(tag)>"
        guard candidate.hasPrefix(opening),
              let closingRange = candidate.range(
                  of: closing,
                  range: candidate.index(
                      candidate.startIndex,
                      offsetBy: opening.count
                  )..<candidate.endIndex
              ) else {
            return nil
        }

        let bodyStart = candidate.index(
            candidate.startIndex,
            offsetBy: opening.count
        )
        let body = String(candidate[bodyStart..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(candidate[closingRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, remainder)
    }

    private static func nonempty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Replay Defaults

enum ReplayDefaults {
    /// Read the whole file rather than a prefix: the end of a conversation is what is wanted,
    /// and it is by definition at the end.
    static let scanLimit = 64 * 1024 * 1024

    /// How many tool calls one observed-work pass folds in before stopping and returning its
    /// position. A long-running conversation here reaches a few hundred; the cap exists so a
    /// first hydration of an imported year-long transcript arrives in bounded pieces rather than
    /// as one unbounded array, and costs nothing when it is never reached.
    static let workScanCalls = 5_000

    /// Rendered items kept. Each is a view, so a very long conversation would otherwise cost
    /// thousands of them at launch for turns nobody is going to scroll back to.
    static let maximumEvents = 400
}
