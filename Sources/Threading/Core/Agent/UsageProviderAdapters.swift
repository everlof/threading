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
                    uncachedInput: integer(usage[UsageIndexDefaults.inputKey]),
                    cachedInput: integer(usage[UsageIndexDefaults.cacheReadKey]),
                    cacheWrite: integer(usage[UsageIndexDefaults.cacheWriteKey]),
                    cacheWrite1h: integer(
                        cacheCreation?[UsageIndexDefaults.cacheWrite1hKey]
                    ),
                    output: integer(usage[UsageIndexDefaults.outputKey])
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

                let input = integer(last["input_tokens"])
                let cached = integer(last["cached_input_tokens"])
                let output = integer(last["output_tokens"])
                let reasoning = integer(last["reasoning_output_tokens"])
                let stamp = object["timestamp"] as? String ?? ""

                // Codex may restate an unchanged last response as surrounding events arrive.
                // Its cumulative total is the durable discriminator when present. Older records
                // without one include the event timestamp, so two later calls with coincidentally
                // equal token counts are retained rather than silently undercounted.
                let signature: String
                if let total = info["total_token_usage"] as? [String: Any] {
                    signature = [
                        "total",
                        String(integer(total["input_tokens"])),
                        String(integer(total["cached_input_tokens"])),
                        String(integer(total["output_tokens"])),
                        String(integer(total["reasoning_output_tokens"])),
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
    }

    static func records(
        fromExport data: Data,
        accountID: String = "opencode",
        accountName: String = "OpenCode"
    ) throws -> [UsageLedgerRecord] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else { throw Failure.unfamiliarExport }

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
                    uncachedInput: integer(tokens["input"]),
                    cachedInput: integer(cache?["read"]),
                    cacheWrite: integer(cache?["write"]),
                    output: integer(tokens["output"]),
                    reasoning: integer(tokens["reasoning"])
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

private func integer(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return max(0, number.int64Value) }
    if let string = value as? String, let number = Int64(string) { return max(0, number) }
    return 0
}

private func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}
