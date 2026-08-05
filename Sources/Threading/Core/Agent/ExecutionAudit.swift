import CryptoKit
import Foundation

// MARK: - Canonical Record

/// One factual execution event emitted by an agent transport or by Threading's own executor.
///
/// This is deliberately not a transcript. It never stores prompts, reasoning, or assistant prose,
/// and it never asks a model to summarize an action. `summary` is a deterministic projection of
/// the operation and its arguments; `input` and `output` are the actual decoded tool envelopes.
struct ExecutionAuditRecord: Codable, Equatable, Sendable, Identifiable {
    enum Source: String, Codable, CaseIterable, Sendable {
        /// A provider's native structured event stream (stream-json, app-server, or ACP).
        case providerStream = "provider_stream"
        /// The JSON-RPC request received and response returned by Threading's MCP server.
        case threadingMCP = "threading_mcp"
        /// Threading's permission broker, immediately before and after its decision.
        case permissionBroker = "permission_broker"

        var displayName: String {
            switch self {
            case .providerStream: return L10n.string("Provider")
            case .threadingMCP: return L10n.string("Threading MCP")
            case .permissionBroker: return L10n.string("Permission")
            }
        }

        /// The timeline rail is intentionally narrow beside the exact JSON or live browser.
        /// Keep its source token unambiguous without hiding the fidelity label at the line end.
        var compactDisplayName: String {
            switch self {
            case .providerStream: return L10n.string("Provider")
            case .threadingMCP: return L10n.string("MCP")
            case .permissionBroker: return L10n.string("Permission")
            }
        }
    }

    enum Category: String, Codable, CaseIterable, Sendable {
        case browser
        case shell
        case filesystem
        case network
        case permission
        case subagent
        case lifecycle
        case tool

        var displayName: String {
            switch self {
            case .browser: return L10n.string("Browser")
            case .shell: return L10n.string("Shell")
            case .filesystem: return L10n.string("Filesystem")
            case .network: return L10n.string("Network")
            case .permission: return L10n.string("Permission")
            case .subagent: return L10n.string("Subagent")
            case .lifecycle: return L10n.string("Lifecycle")
            case .tool: return L10n.string("Tool")
            }
        }

        var symbolName: String {
            switch self {
            case .browser: return "globe"
            case .shell: return "terminal"
            case .filesystem: return "doc"
            case .network: return "network"
            case .permission: return "hand.raised"
            case .subagent: return "person.2"
            case .lifecycle: return "circle.dotted"
            case .tool: return "wrench.and.screwdriver"
            }
        }
    }

    enum Phase: String, Codable, Sendable {
        case requested
        case progressed
        case completed
        case failed
        case allowed
        case denied
        case interrupted

        var displayName: String {
            switch self {
            case .requested: return L10n.string("Requested")
            case .progressed: return L10n.string("Updated")
            case .completed: return L10n.string("Completed")
            case .failed: return L10n.string("Failed")
            case .allowed: return L10n.string("Allowed")
            case .denied: return L10n.string("Denied")
            case .interrupted: return L10n.string("Interrupted")
            }
        }
    }

    enum Fidelity: String, Codable, Sendable {
        /// Exact after decoding the provider or JSON-RPC envelope into typed JSON.
        case exact
        /// Exact except for every path enumerated in `redactions`.
        case exactWithRedactions = "exact_with_redactions"
        /// A provider adapter supplied a lossy text projection rather than its original shape.
        case canonicalized

        var displayName: String {
            switch self {
            case .exact: return L10n.string("Exact")
            case .exactWithRedactions: return L10n.string("Exact · redacted")
            case .canonicalized: return L10n.string("Canonicalized")
            }
        }
    }

    struct Redaction: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Sendable {
            // Kept so ledgers written before ordinary browser input became exact still decode.
            case typedText = "typed_text"
            case formValue = "form_value"
            case credential
            case imageBytes = "image_bytes"
        }

        let path: String
        let reason: Reason
    }

    let id: UUID
    let sessionID: SessionID
    let sequence: Int
    let timestamp: Date
    let source: Source
    let provider: String?
    let category: Category
    let phase: Phase
    let operation: String
    let callID: String?
    let summary: String
    let input: JSONValue?
    let output: JSONValue?
    let durationMilliseconds: Int?
    let fidelity: Fidelity
    let redactions: [Redaction]
    let previousDigest: String?
    let digest: String
}

/// An execution-bearing provider object captured before the native-conversation adapter turns it
/// into presentation text. Values are decoded JSON, never prose summarized by a model.
struct ProviderExecutionEvent: Equatable, Sendable {
    let category: ExecutionAuditRecord.Category
    let phase: ExecutionAuditRecord.Phase
    let operation: String?
    let callID: String
    let input: JSONValue?
    let output: JSONValue?
    let fidelity: ExecutionAuditRecord.Fidelity
}

struct ExecutionAuditDidChange: AppEvent {
    static let name = Notification.Name("executionAuditDidChange")
    let sessionID: SessionID
}

enum ExecutionAuditIntegrity: Equatable, Sendable {
    /// Every retained record and link verifies from the start of the ledger.
    case verified
    /// Retained records verify, but bounded rotation removed the beginning of the chain.
    case partial
    /// At least one retained record, link, or JSON line does not verify.
    case broken
}

struct ExecutionAuditReadResult: Equatable, Sendable {
    let records: [ExecutionAuditRecord]
    let integrity: ExecutionAuditIntegrity
    let malformedLineCount: Int
}

// MARK: - Store

/// Append-only, hash-linked storage for execution audit records.
///
/// Each session has its own bounded JSONL chain. A completed record is never rewritten. Rotation
/// may remove the oldest segment; the reader reports that honestly as `.partial` instead of
/// pretending the retained suffix begins a complete history.
final class ExecutionAuditStore: @unchecked Sendable {
    static let shared = ExecutionAuditStore()

    private struct ChainState {
        var sequence: Int
        var digest: String?
    }

    private struct PendingTool: Sendable {
        let operation: String
        let category: ExecutionAuditRecord.Category
        let startedAt: Date
    }

    private struct SealPayload: Encodable {
        let id: UUID
        let sessionID: SessionID
        let sequence: Int
        let timestamp: Date
        let source: ExecutionAuditRecord.Source
        let provider: String?
        let category: ExecutionAuditRecord.Category
        let phase: ExecutionAuditRecord.Phase
        let operation: String
        let callID: String?
        let summary: String
        let input: JSONValue?
        let output: JSONValue?
        let durationMilliseconds: Int?
        let fidelity: ExecutionAuditRecord.Fidelity
        let redactions: [ExecutionAuditRecord.Redaction]
        let previousDigest: String?

        init(record: ExecutionAuditRecord) {
            id = record.id
            sessionID = record.sessionID
            sequence = record.sequence
            timestamp = record.timestamp
            source = record.source
            provider = record.provider
            category = record.category
            phase = record.phase
            operation = record.operation
            callID = record.callID
            summary = record.summary
            input = record.input
            output = record.output
            durationMilliseconds = record.durationMilliseconds
            fidelity = record.fidelity
            redactions = record.redactions
            previousDigest = record.previousDigest
        }
    }

    private let directory: URL
    private let maximumSegmentBytes: Int
    private let retainedRotatedSegments: Int
    private let queue = DispatchQueue(label: "com.threading.execution-audit")
    private var chainStates: [SessionID: ChainState] = [:]
    private var pendingTools: [SessionID: [String: PendingTool]] = [:]

    init(
        directory: URL? = nil,
        maximumSegmentBytes: Int = 4 * 1_024 * 1_024,
        retainedRotatedSegments: Int = 3
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.maximumSegmentBytes = max(1_024, maximumSegmentBytes)
        self.retainedRotatedSegments = max(0, retainedRotatedSegments)
    }

    /// Records only execution-bearing stream events. Text deltas, prompts, reasoning, assistant
    /// prose, and transcript replay never enter this store.
    func record(
        streamEvent: StreamEvent,
        sessionID: SessionID,
        provider: AgentKind
    ) {
        switch streamEvent {
        case .initialised(_, let model):
            var input: [String: JSONValue] = [:]
            if let model { input["model"] = .string(model) }
            append(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: .lifecycle,
                phase: .completed,
                operation: "session.initialised",
                input: .object(input),
                fidelity: .exact
            )

        case .backgroundWork(let inFlight):
            append(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: .subagent,
                phase: .completed,
                operation: "background_work.updated",
                output: .object([
                    "in_flight": .array(inFlight.map(JSONValue.string))
                ]),
                fidelity: .exact
            )

        case .turnFinished(_, let isError, let metrics):
            var output: [String: JSONValue] = ["is_error": .bool(isError)]
            if let duration = metrics.duration {
                output["duration_ms"] = .integer(Int64((duration * 1_000).rounded()))
            }
            if let tokens = metrics.outputTokens { output["output_tokens"] = .integer(Int64(tokens)) }
            if let effort = metrics.effort { output["effort"] = .string(effort) }
            if let tokens = metrics.contextTokens { output["context_tokens"] = .integer(Int64(tokens)) }
            if let window = metrics.contextWindow { output["context_window"] = .integer(Int64(window)) }
            append(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: .lifecycle,
                phase: isError ? .failed : .completed,
                operation: "turn.finished",
                output: .object(output),
                fidelity: .exact
            )

        case .assistantMessage, .toolResults, .textDelta, .thinkingDelta, .userMessage,
             .transcriptNotice, .runPlanUpdated, .unknown:
            break
        }
    }

    /// Records a provider-native tool object. Request/result correlation is still owned here so
    /// adapters cannot disagree about durations, names on terminal updates, or chain ordering.
    func record(
        providerEvent event: ProviderExecutionEvent,
        sessionID: SessionID,
        provider: AgentKind
    ) {
        let operation = event.operation ?? "tool.update"
        switch event.phase {
        case .requested:
            let category = event.category
            queue.sync {
                pendingTools[sessionID, default: [:]][pendingKey(
                    source: .providerStream,
                    callID: event.callID
                )] = PendingTool(operation: operation, category: category, startedAt: Date())
            }
            append(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: category,
                phase: .requested,
                operation: operation,
                callID: event.callID,
                input: event.input,
                output: event.output,
                fidelity: event.fidelity
            )

        case .progressed:
            let pending: PendingTool? = queue.sync {
                pendingTools[sessionID]?[pendingKey(
                    source: .providerStream,
                    callID: event.callID
                )]
            }
            append(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: pending?.category ?? event.category,
                phase: .progressed,
                operation: pending?.operation ?? operation,
                callID: event.callID,
                input: event.input,
                output: event.output,
                fidelity: event.fidelity
            )

        case .completed, .failed, .allowed, .denied, .interrupted:
            recordToolResult(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                operation: event.operation,
                callID: event.callID,
                output: event.output ?? .null,
                isError: event.phase != .completed && event.phase != .allowed,
                fidelity: event.fidelity
            )
        }
    }

    func recordToolRequest(
        sessionID: SessionID,
        source: ExecutionAuditRecord.Source,
        provider: String?,
        operation: String,
        callID: String,
        input: JSONValue,
        fidelity: ExecutionAuditRecord.Fidelity
    ) {
        let category = Self.category(for: operation)
        queue.sync {
            pendingTools[sessionID, default: [:]][pendingKey(source: source, callID: callID)] =
                PendingTool(operation: operation, category: category, startedAt: Date())
        }
        append(
            sessionID: sessionID,
            source: source,
            provider: provider,
            category: category,
            phase: .requested,
            operation: operation,
            callID: callID,
            input: input,
            fidelity: fidelity
        )
    }

    func recordToolResult(
        sessionID: SessionID,
        source: ExecutionAuditRecord.Source,
        provider: String?,
        operation suppliedOperation: String?,
        callID: String,
        output: JSONValue,
        isError: Bool,
        fidelity: ExecutionAuditRecord.Fidelity
    ) {
        let pending: PendingTool? = queue.sync {
            pendingTools[sessionID]?.removeValue(forKey: pendingKey(source: source, callID: callID))
        }
        let operation = suppliedOperation ?? pending?.operation ?? "tool.result"
        append(
            sessionID: sessionID,
            source: source,
            provider: provider,
            category: pending?.category ?? Self.category(for: operation),
            phase: isError ? .failed : .completed,
            operation: operation,
            callID: callID,
            output: output,
            durationMilliseconds: pending.map {
                max(0, Int(Date().timeIntervalSince($0.startedAt) * 1_000))
            },
            fidelity: fidelity
        )
    }

    func recordPermissionRequest(_ request: PermissionRequest) {
        append(
            sessionID: request.sessionID,
            source: .permissionBroker,
            provider: nil,
            category: .permission,
            phase: .requested,
            operation: request.toolName,
            input: .object(request.input),
            fidelity: .exact
        )
    }

    func recordPermissionDecision(_ decision: PermissionDecision, for request: PermissionRequest) {
        let phase: ExecutionAuditRecord.Phase
        let reason: String
        switch decision {
        case .allow(let value):
            phase = .allowed
            reason = value
        case .deny(let value):
            phase = .denied
            reason = value
        }
        append(
            sessionID: request.sessionID,
            source: .permissionBroker,
            provider: nil,
            category: .permission,
            phase: phase,
            operation: request.toolName,
            output: .object(["reason": .string(reason)]),
            fidelity: .exact
        )
    }

    @discardableResult
    func append(
        sessionID: SessionID,
        source: ExecutionAuditRecord.Source,
        provider: String?,
        category: ExecutionAuditRecord.Category,
        phase: ExecutionAuditRecord.Phase,
        operation: String,
        callID: String? = nil,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        durationMilliseconds: Int? = nil,
        fidelity suppliedFidelity: ExecutionAuditRecord.Fidelity
    ) -> ExecutionAuditRecord? {
        let sanitized = ExecutionAuditSanitizer.sanitize(
            operation: operation,
            input: input,
            output: output
        )
        let fidelity: ExecutionAuditRecord.Fidelity = sanitized.redactions.isEmpty
            ? suppliedFidelity
            : .exactWithRedactions

        let record: ExecutionAuditRecord? = queue.sync {
            ensureDirectory()
            var state = stateLocked(for: sessionID)
            let timestamp = Date()
            let id = UUID()
            let sequence = state.sequence + 1
            let summary = Self.summary(operation: operation, input: sanitized.input)
            let placeholder = ExecutionAuditRecord(
                id: id,
                sessionID: sessionID,
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                provider: provider,
                category: category,
                phase: phase,
                operation: operation,
                callID: callID,
                summary: summary,
                input: sanitized.input,
                output: sanitized.output,
                durationMilliseconds: durationMilliseconds,
                fidelity: fidelity,
                redactions: sanitized.redactions,
                previousDigest: state.digest,
                digest: ""
            )
            guard let digest = Self.digest(SealPayload(record: placeholder)) else { return nil }
            let sealed = ExecutionAuditRecord(
                id: id,
                sessionID: sessionID,
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                provider: provider,
                category: category,
                phase: phase,
                operation: operation,
                callID: callID,
                summary: summary,
                input: sanitized.input,
                output: sanitized.output,
                durationMilliseconds: durationMilliseconds,
                fidelity: fidelity,
                redactions: sanitized.redactions,
                previousDigest: state.digest,
                digest: digest
            )
            guard appendLocked(sealed, sessionID: sessionID) else { return nil }
            state.sequence = sequence
            state.digest = digest
            chainStates[sessionID] = state
            return sealed
        }

        if record != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(ExecutionAuditDidChange(sessionID: sessionID))
            }
        }
        return record
    }

    func read(sessionID: SessionID) -> ExecutionAuditReadResult {
        queue.sync { readLocked(sessionID: sessionID) }
    }

    /// Deletes the bounded ledger when the owning Threading session is deleted. Provider-owned
    /// transcript files are intentionally outside this store and remain governed by the provider.
    func remove(sessionID: SessionID) {
        queue.sync {
            chainStates.removeValue(forKey: sessionID)
            pendingTools.removeValue(forKey: sessionID)

            let baseName = "\(sessionID.uuidString).audit.jsonl"
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for url in urls where url.lastPathComponent == baseName
                || url.lastPathComponent.hasPrefix("\(baseName).") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Storage

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("ExecutionAudit", isDirectory: true)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func currentURL(for sessionID: SessionID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).audit.jsonl")
    }

    private func rotatedURL(for sessionID: SessionID, index: Int) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).audit.jsonl.\(index)")
    }

    private func stateLocked(for sessionID: SessionID) -> ChainState {
        if let state = chainStates[sessionID] { return state }
        let last = readLocked(sessionID: sessionID).records.last
        let state = ChainState(sequence: last?.sequence ?? 0, digest: last?.digest)
        chainStates[sessionID] = state
        return state
    }

    private func appendLocked(_ record: ExecutionAuditRecord, sessionID: SessionID) -> Bool {
        let encoder = Self.encoder
        guard var line = try? encoder.encode(record) else { return false }
        line.append(0x0A)
        rotateIfNeeded(sessionID: sessionID, incomingBytes: line.count)

        let url = currentURL(for: sessionID)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    private func rotateIfNeeded(sessionID: SessionID, incomingBytes: Int) {
        let file = currentURL(for: sessionID)
        let currentBytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard currentBytes > 0, currentBytes + incomingBytes > maximumSegmentBytes else { return }
        let manager = FileManager.default
        if retainedRotatedSegments == 0 {
            try? manager.removeItem(at: file)
            return
        }
        try? manager.removeItem(at: rotatedURL(for: sessionID, index: retainedRotatedSegments))
        if retainedRotatedSegments > 1 {
            for index in stride(from: retainedRotatedSegments - 1, through: 1, by: -1) {
                let source = rotatedURL(for: sessionID, index: index)
                guard manager.fileExists(atPath: source.path) else { continue }
                try? manager.moveItem(
                    at: source,
                    to: rotatedURL(for: sessionID, index: index + 1)
                )
            }
        }
        try? manager.moveItem(at: file, to: rotatedURL(for: sessionID, index: 1))
    }

    private func readLocked(sessionID: SessionID) -> ExecutionAuditReadResult {
        var records: [ExecutionAuditRecord] = []
        var malformed = 0
        let urls = stride(from: retainedRotatedSegments, through: 1, by: -1)
            .map { rotatedURL(for: sessionID, index: $0) }
            + [currentURL(for: sessionID)]

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                do {
                    records.append(try Self.decoder.decode(ExecutionAuditRecord.self, from: Data(line)))
                } catch {
                    malformed += 1
                }
            }
        }

        var integrity: ExecutionAuditIntegrity = records.first?.previousDigest == nil
            ? .verified
            : .partial
        var prior: ExecutionAuditRecord?
        for record in records {
            let digestMatches = Self.digest(SealPayload(record: record)) == record.digest
            let linkMatches = prior.map { record.previousDigest == $0.digest } ?? true
            let sequenceMatches = prior.map { record.sequence == $0.sequence + 1 } ?? true
            guard digestMatches, linkMatches, sequenceMatches else {
                integrity = .broken
                break
            }
            prior = record
        }
        if malformed > 0 { integrity = .broken }
        return ExecutionAuditReadResult(
            records: records,
            integrity: integrity,
            malformedLineCount: malformed
        )
    }

    /// Foundation's coders are mutable reference types. Returning a configured instance per use
    /// keeps independent stores and readers from sharing one across their serial queues.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func digest<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pendingKey(source: ExecutionAuditRecord.Source, callID: String) -> String {
        "\(source.rawValue):\(callID)"
    }

    // MARK: Deterministic Classification

    static func category(for operation: String) -> ExecutionAuditRecord.Category {
        let lowered = operation.lowercased()
        if lowered.hasPrefix("browser_") || lowered.contains("browser") { return .browser }

        switch ToolIdentity(operation) {
        case .bash: return .shell
        case .read, .write, .edit, .multiEdit, .notebookEdit, .notebookRead, .glob, .grep:
            return .filesystem
        case .webFetch, .webSearch:
            return .network
        case .task, .taskCreate, .taskUpdate, .taskList, .taskGet:
            return .subagent
        case .plan, .todoWrite, .todoRead, .toolSearch, .mcp, .unknown:
            break
        }
        if lowered.contains("agent") || lowered.contains("collab") { return .subagent }
        return .tool
    }

    private static func summary(operation: String, input: JSONValue?) -> String {
        guard let object = input?.objectValue else { return operation }
        let subject = PermissionRequest(
            sessionID: SessionID(),
            toolName: operation,
            input: object
        ).oneLineSummary
        return subject.isEmpty ? operation : "\(operation) · \(subject)"
    }
}

// MARK: - Explicit Redaction

private enum ExecutionAuditSanitizer {
    struct Result {
        let input: JSONValue?
        let output: JSONValue?
        let redactions: [ExecutionAuditRecord.Redaction]
    }

    private static let credentialKeys: Set<String> = [
        "password", "passwd", "passcode", "secret", "token", "access_token", "refresh_token",
        "accesstoken", "refreshtoken", "id_token", "session_token", "sessiontoken",
        "api_key", "apikey", "x_api_key", "client_secret", "private_key", "secret_key",
        "authorization", "proxy_authorization", "cookie", "set_cookie", "credential",
        "credentials", "cvv", "cvc", "security_code", "card_security_code", "pin"
    ]

    static func sanitize(operation _: String, input: JSONValue?, output: JSONValue?) -> Result {
        var redactions: [ExecutionAuditRecord.Redaction] = []
        let sanitizedInput = walk(
            input,
            path: "input",
            redactions: &redactions
        )
        let sanitizedOutput = walk(
            output,
            path: "output",
            redactions: &redactions
        )
        return Result(input: sanitizedInput, output: sanitizedOutput, redactions: redactions)
    }

    private static func walk(
        _ value: JSONValue?,
        path: String,
        redactions: inout [ExecutionAuditRecord.Redaction]
    ) -> JSONValue? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            let isImage = object["type"]?.stringValue == "image"
                || object["mimeType"]?.stringValue?.hasPrefix("image/") == true
            var result: [String: JSONValue] = [:]
            for key in object.keys.sorted() {
                let childPath = "\(path).\(key)"
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                let reason: ExecutionAuditRecord.Redaction.Reason?
                if credentialKeys.contains(normalized) {
                    reason = .credential
                } else if isImage && key == "data" {
                    reason = .imageBytes
                } else {
                    reason = nil
                }

                if let reason {
                    redactions.append(.init(path: childPath, reason: reason))
                    result[key] = .string("<redacted:\(reason.rawValue)>")
                } else {
                    result[key] = walk(
                        object[key],
                        path: childPath,
                        redactions: &redactions
                    ) ?? .null
                }
            }
            return .object(result)

        case .array(let array):
            return .array(array.enumerated().compactMap { index, child in
                walk(
                    child,
                    path: "\(path)[\(index)]",
                    redactions: &redactions
                )
            })

        case .string, .integer, .number, .bool, .null:
            return value
        }
    }
}
