import Foundation

// MARK: - Claude

/// Claude's JSONL usage adapter. It emits one record per assistant response and leaves global
/// deduplication to `UsageLedgerBuilder`, where cache hits and newly parsed files meet.
enum ClaudeUsageAdapter {
    static func records(
        inTranscriptAt url: URL,
        accountID: String,
        accountName: String
    ) -> [UsageLedgerRecord] {
        let marker = Array(UsageIndexDefaults.usageMarker.utf8)
        let sessionID = url.deletingPathExtension().lastPathComponent
        var lineNumber = 0
        var found: [UsageLedgerRecord] = []

        JSONLReader.forEachLine(at: url, limit: .max) { line in
            lineNumber += 1
            guard TranscriptUsageIndex.contains(marker, in: line),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object[UsageIndexDefaults.messageKey] as? [String: Any],
                  let usage = message[UsageIndexDefaults.usageKey] as? [String: Any]
            else { return true }

            let messageID = message[UsageIndexDefaults.idKey] as? String ?? ""
            let requestID = object[UsageIndexDefaults.requestKey] as? String ?? ""
            let identity: String
            if messageID.isEmpty && requestID.isEmpty {
                identity = "claude|\(url.path)|\(lineNumber)"
            } else {
                identity = "claude|\(messageID)|\(requestID)"
            }

            let timestamp = object[UsageIndexDefaults.timestampKey] as? String ?? ""
            let reported = double(object["costUSD"])
                ?? double(message["costUSD"])
                ?? double(object["cost_usd"])
            let cacheCreation = usage[UsageIndexDefaults.cacheWriteDetailKey]
                as? [String: Any]

            // A count this app cannot hold makes the line unreadable, and an unreadable line
            // produces no record — the same answer this loop already gives one whose JSON does
            // not parse. Writing `0` into the field instead would put a number in the bill the
            // account was never charged, and nothing downstream could tell it from a response
            // that genuinely used no cached input.
            guard let uncachedInput = count(usage[UsageIndexDefaults.inputKey]),
                  let cachedInput = count(usage[UsageIndexDefaults.cacheReadKey]),
                  let cacheWrite = count(usage[UsageIndexDefaults.cacheWriteKey]),
                  let cacheWrite1h = count(cacheCreation?[UsageIndexDefaults.cacheWrite1hKey]),
                  let output = count(usage[UsageIndexDefaults.outputKey])
            else { return true }

            found.append(UsageLedgerRecord(
                identity: identity,
                sessionID: sessionID,
                at: UsageLedgerDate.parse(timestamp),
                origin: .direct(.claude),
                accountID: accountID,
                accountName: accountName,
                model: message[UsageIndexDefaults.modelKey] as? String
                    ?? UsageIndexDefaults.unknownModel,
                workingDirectory: object[UsageIndexDefaults.cwdKey] as? String ?? "",
                tokens: UsageTokenCounts(
                    uncachedInput: uncachedInput,
                    cachedInput: cachedInput,
                    cacheWrite: cacheWrite,
                    cacheWrite1h: cacheWrite1h,
                    output: output
                ),
                reportedCostUSD: reported
            ))
            return true
        }

        return found
    }
}

// MARK: - Codex

/// Codex rollouts are stateful: session metadata supplies the directory, turn context supplies
/// the active model, and later `token_count` records carry one response's usage. Input includes
/// cached input on this wire, so the adapter normalizes it before returning.
enum CodexUsageAdapter {
    static func records(
        inRolloutAt url: URL,
        accountID: String,
        accountName: String
    ) -> [UsageLedgerRecord] {
        let markers = CodexMarkers.all.map { Array($0.utf8) }
        var sessionID = url.deletingPathExtension().lastPathComponent
        var workingDirectory = ""
        var model = UsageIndexDefaults.unknownModel
        var previousSignature: String?
        var lineNumber = 0
        var found: [UsageLedgerRecord] = []

        JSONLReader.forEachLine(at: url, limit: .max) { line in
            lineNumber += 1
            guard markers.contains(where: { TranscriptUsageIndex.contains($0, in: line) }),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { return true }

            switch type {
            case "session_meta":
                sessionID = payload["session_id"] as? String
                    ?? payload["id"] as? String
                    ?? sessionID
                workingDirectory = payload["cwd"] as? String ?? workingDirectory

            case "turn_context":
                workingDirectory = payload["cwd"] as? String ?? workingDirectory
                model = payload["model"] as? String ?? model

            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { return true }

                // As in the Claude adapter above: a count outside `Int64` makes this record
                // unreadable rather than a record of zero tokens.
                guard let input = count(last["input_tokens"]),
                      let cached = count(last["cached_input_tokens"]),
                      let output = count(last["output_tokens"]),
                      let reasoning = count(last["reasoning_output_tokens"])
                else { return true }
                let stamp = object["timestamp"] as? String ?? ""

                // Codex may restate an unchanged last response as surrounding events arrive.
                // Its cumulative total is the durable discriminator when present. Older records
                // without one include the event timestamp, so two later calls with coincidentally
                // equal token counts are retained rather than silently undercounted.
                let signature: String
                if let total = info["total_token_usage"] as? [String: Any] {
                    signature = [
                        "total",
                        String(signatureNumber(total["input_tokens"])),
                        String(signatureNumber(total["cached_input_tokens"])),
                        String(signatureNumber(total["output_tokens"])),
                        String(signatureNumber(total["reasoning_output_tokens"])),
                        model
                    ].joined(separator: "|")
                } else {
                    signature = "last|\(stamp)|\(input)|\(cached)|\(output)|\(reasoning)|\(model)"
                }
                guard signature != previousSignature else { return true }
                previousSignature = signature

                let identity = stamp.isEmpty
                    ? "codex|\(sessionID)|line|\(lineNumber)"
                    : "codex|\(sessionID)|\(stamp)|\(signature)"
                found.append(UsageLedgerRecord(
                    identity: identity,
                    sessionID: sessionID,
                    at: UsageLedgerDate.parse(stamp),
                    origin: .direct(.codex),
                    accountID: accountID,
                    accountName: accountName,
                    model: model,
                    workingDirectory: workingDirectory,
                    tokens: UsageTokenCounts(
                        inputIncludingCached: input,
                        cachedInput: cached,
                        output: output,
                        reasoning: reasoning
                    )
                ))

            default:
                break
            }
            return true
        }

        return found
    }

    static func rollouts(inAccountAt configPath: String) -> [URL] {
        let sessions = URL(fileURLWithPath: configPath)
            .appendingPathComponent(CodexBackfillDefaults.sessionsDirectory)
        guard let walker = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return (walker.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == AgentDefaults.transcriptExtension }
    }

    private enum CodexMarkers {
        static let all = ["\"session_meta\"", "\"turn_context\"", "\"token_count\""]
    }
}

// MARK: - OpenCode

/// Reads the supported OpenCode export shape. OpenCode owns the runtime while `providerID`
/// identifies the biller, so OpenRouter and direct-provider routes remain distinct series.
enum OpenCodeUsageAdapter {
    enum Failure: Error, Equatable {
        case unfamiliarExport
        /// The export was the shape this adapter knows, but one of its messages could not be
        /// read — it was not an object, or one of its token counts is a number outside `Int64` —
        /// so the bill it describes cannot be totalled. Separate from `unfamiliarExport` because
        /// the two ask for different things: an unfamiliar export means this adapter is looking
        /// at the wrong document, while this means it is looking at the right one and cannot
        /// finish reading it.
        case unreadableMessage(index: Int)
    }

    /// Reads one OpenCode session export into ledger records.
    ///
    /// **Refuses the whole export for one unreadable message, and that is the decision rather
    /// than an accident of the cast.** Everything else in this sweep recovers, because a
    /// half-read catalog or content list still says something true about itself. A usage total
    /// does not: it is a single number a person reads as *the* cost of that session, with no
    /// place on the figure to say a message was skipped. Silently returning a smaller total
    /// would present an undercount as fact.
    ///
    /// Refusing is not the same as losing the data quietly. `TranscriptUsageService` catches
    /// this and marks that runtime's coverage `.partial`/`.failed` with a detail line, so the
    /// Usage page says the reading is incomplete instead of showing a confident wrong number.
    /// Recovering here would replace a visible gap with an invisible one.
    ///
    /// A per-message skip *is* still made for a message that is readable and simply not a
    /// billable assistant turn — that is the export saying so, not this reader failing to read.
    static func records(
        fromExport data: Data,
        accountID: String = "opencode",
        accountName: String = "OpenCode"
    ) throws -> [UsageLedgerRecord] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = root["messages"] as? [Any]
        else { throw Failure.unfamiliarExport }

        // Named element by element so the refusal can say *which* message stopped it. The plain
        // `as? [[String: Any]]` this replaced answered nil for a `null` element and for a
        // missing key alike, so every failure arrived as "unfamiliar export" and there was
        // nothing in the log to distinguish an OpenCode version bump from one bad row.
        let messages: [[String: Any]] = try rawMessages.enumerated().map { index, raw in
            guard let message = raw as? [String: Any] else {
                throw Failure.unreadableMessage(index: index)
            }
            return message
        }

        let rootInfo = root["info"] as? [String: Any]
        let rootDirectory = rootInfo?["directory"] as? String ?? ""
        let rootSessionID = rootInfo?["id"] as? String ?? "opencode"
        var found: [UsageLedgerRecord] = []

        for (index, message) in messages.enumerated() {
            guard let info = message["info"] as? [String: Any],
                  info["role"] as? String == "assistant",
                  let tokens = info["tokens"] as? [String: Any]
            else { continue }

            let cache = tokens["cache"] as? [String: Any]
            let providerID = info["providerID"] as? String
                ?? info["provider_id"] as? String
                ?? "opencode"
            let path = info["path"] as? [String: Any]
            let time = info["time"] as? [String: Any]
            let createdMilliseconds = double(time?["created"])
            let createdSeconds = createdMilliseconds.map {
                $0 > 10_000_000_000 ? $0 / 1_000 : $0
            }
            let messageID = info["id"] as? String ?? "\(rootSessionID)-\(index)"

            // A count outside `Int64` stops the whole export, for the reason stated above: this
            // adapter's answer is one total a person reads as *the* cost of the session, and it
            // has nowhere on the figure to say a number in it was invented. The Claude and Codex
            // loops skip the record instead, because theirs are per-line readers whose surface
            // already treats a skipped line as ordinary.
            guard let uncachedInput = count(tokens["input"]),
                  let cachedInput = count(cache?["read"]),
                  let cacheWrite = count(cache?["write"]),
                  let output = count(tokens["output"]),
                  let reasoning = count(tokens["reasoning"])
            else { throw Failure.unreadableMessage(index: index) }

            found.append(UsageLedgerRecord(
                identity: "opencode|\(messageID)",
                sessionID: info["sessionID"] as? String
                    ?? info["session_id"] as? String
                    ?? rootSessionID,
                at: createdSeconds.map(Date.init(timeIntervalSince1970:)),
                origin: .openCode(providerID: providerID),
                accountID: accountID,
                accountName: accountName,
                model: info["modelID"] as? String
                    ?? info["model_id"] as? String
                    ?? UsageIndexDefaults.unknownModel,
                workingDirectory: path?["cwd"] as? String ?? rootDirectory,
                tokens: UsageTokenCounts(
                    uncachedInput: uncachedInput,
                    cachedInput: cachedInput,
                    cacheWrite: cacheWrite,
                    output: output,
                    reasoning: reasoning
                ),
                reportedCostUSD: double(info["cost"])
            ))
        }

        return found
    }
}

// MARK: - Grok

/// Grok's currently measured ACP surface reports context occupancy (`used`/`size`), not an
/// input/output/cache bill, and its supported export is Markdown. Keeping that contract here is
/// deliberate: the Usage page includes Grok as partial coverage without manufacturing token
/// totals from characters. If the CLI begins exporting authoritative usage, its adapter belongs
/// behind this seam and no shared model or view changes.
enum GrokUsageAdapter {
    static let coverageDetail = "Grok reports live context occupancy but no historical token bill."
}

// MARK: - Shared Wire Numbers

/// One token count from the wire, or nil when the value is there and this app cannot hold it.
///
/// **Nil is reserved for a single answer: the value is a JSON number outside `Int64`.** Every
/// other reading is the one this has always given. An absent key is a count of none, which is
/// what a provider means by omitting it, and a quoted number `Int64` cannot parse still reads as
/// none — that last one is a separate finding, pinned by `ProviderWireTextCorpusTests`, and it is
/// deliberately neither fixed nor moved here: a string was never a JSON number, and what to do
/// about a provider that quotes its numbers is a different decision from this one.
///
/// The reading this replaced was `max(0, number.int64Value)`, which wrapped an oversized count to
/// a negative and then clamped that to `0` — so a response the account was billed twelve
/// quintillion input tokens for was filed as one that used none. See `WireInteger` for why
/// `int64Value` is a reinterpretation rather than a reading.
private func count(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
        guard let whole = WireInteger.whole(number) else { return nil }
        return max(0, whole)
    }
    if let string = value as? String, let number = Int64(string) { return max(0, number) }
    return 0
}

/// The deduplication discriminator's reading of a cumulative counter.
///
/// It reads the same wire numbers as `count(_:)` and deliberately does not refuse any of them,
/// because it is not a quantity anyone is shown. It is compared against the previous line's and
/// then spelled into the record's `identity`, which the parsed-file cache retains — so changing
/// what it produces would rename records the ledger already holds, and one response filed under
/// two names is counted twice. Refusing here would be worse still: it would drop a perfectly
/// readable `last_token_usage` bill because the *running total* beside it is out of range.
private func signatureNumber(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return max(0, number.int64Value) }
    if let string = value as? String, let number = Int64(string) { return max(0, number) }
    return 0
}

private func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}
