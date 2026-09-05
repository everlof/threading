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

        /// How a turn's outcome files in the ledger.
        ///
        /// `interrupted` existed here from the start and no turn could ever reach it: the
        /// terminal event carried one boolean, so a turn the user stopped was recorded as a
        /// failure. The three outcomes map one-to-one.
        init(turnOutcome: TurnOutcome) {
            switch turnOutcome {
            case .completed: self = .completed
            case .failed: self = .failed
            case .stopped: self = .interrupted
            }
        }

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
            /// The provider handed the adapter a value JSON cannot express, so the ledger holds
            /// its type in place of it. Unlike the reasons above this is not a privacy decision:
            /// it is the one honest thing to say about a member that could not be read. It is
            /// still a redaction in the sense the fidelity label means — the native shape is
            /// retained with a specific value replaced, and the path says which.
            case unconvertible
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

    /// A segment is 4 MiB by default, so an unbounded rotation count would also be an unbounded
    /// per-session disk and read-work promise. Production has always retained three; eight leaves
    /// room for explicit test/support policies while keeping the filename namespace closed.
    static let maximumRetainedRotatedSegments = 8

    private struct ChainState {
        var sequence: Int
        var digest: String?
    }

    private struct PendingTool: Sendable {
        let operation: String
        let category: ExecutionAuditRecord.Category
        let startedAt: Date
    }

    private struct AppendPayload: Sendable {
        let sessionID: SessionID
        let source: ExecutionAuditRecord.Source
        let provider: String?
        let category: ExecutionAuditRecord.Category
        let phase: ExecutionAuditRecord.Phase
        let operation: String
        let callID: String?
        let input: JSONValue?
        let output: JSONValue?
        let durationMilliseconds: Int?
        let fidelity: ExecutionAuditRecord.Fidelity
    }

    private enum StorageFailure: Error {
        case directory(Error)
        case encoding(Error)
        case recordTooLarge(Int)
        case rotation(Error)
        case fileCreation
        case fileOpen(Error)
        case write(Error)

        var stage: String {
            switch self {
            case .directory: return "directory"
            case .encoding: return "encoding"
            case .recordTooLarge: return "record_too_large"
            case .rotation: return "rotation"
            case .fileCreation: return "file_creation"
            case .fileOpen: return "file_open"
            case .write: return "write"
            }
        }

        var diagnostic: String? {
            switch self {
            case .directory(let error), .encoding(let error), .rotation(let error),
                 .fileOpen(let error), .write(let error):
                return error.localizedDescription
            case .recordTooLarge(let bytes):
                return "encoded record has \(bytes) bytes"
            case .fileCreation:
                return nil
            }
        }
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
    /// One line per failing stage and session, not one line per streamed tool event. A disk-full
    /// failure can otherwise turn the diagnostic intended to explain it into its own flood.
    private var appendFailureStages: [SessionID: String] = [:]
    /// Verification happens whenever the inspector reloads. Report a broken signature once until
    /// its shape changes or verifies again, rather than faulting once per visible refresh.
    private var readProblemSignatures: [SessionID: String] = [:]

    init(
        directory: URL? = nil,
        maximumSegmentBytes: Int = 4 * 1_024 * 1_024,
        retainedRotatedSegments: Int = 3
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.maximumSegmentBytes = max(1_024, maximumSegmentBytes)
        self.retainedRotatedSegments = min(
            max(0, retainedRotatedSegments),
            Self.maximumRetainedRotatedSegments
        )
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
            enqueueAppend(
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
            enqueueAppend(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: .subagent,
                phase: .completed,
                operation: "background_work.updated",
                output: .object([
                    "in_flight": .array(inFlight.map { JSONValue.string($0.id) })
                ]),
                fidelity: .exact
            )

        case .turnFinished(_, let outcome, let metrics):
            // Both facts, because the ledger is a record rather than a rendering: `is_error`
            // stays for readers already keyed on it, and `outcome` is what tells an audit that
            // a turn ended because somebody pressed Stop.
            var output: [String: JSONValue] = [
                "is_error": .bool(outcome.isError),
                "outcome": .string(outcome.auditName)
            ]
            if let duration = metrics.duration {
                output["duration_ms"] = .integer(Int64((duration * 1_000).rounded()))
            }
            if let tokens = metrics.outputTokens { output["output_tokens"] = .integer(Int64(tokens)) }
            if let effort = metrics.effort { output["effort"] = .string(effort) }
            if let tokens = metrics.contextTokens { output["context_tokens"] = .integer(Int64(tokens)) }
            if let window = metrics.contextWindow { output["context_window"] = .integer(Int64(window)) }
            enqueueAppend(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: .lifecycle,
                phase: .init(turnOutcome: outcome),
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
            enqueueToolRequest(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                operation: operation,
                callID: event.callID,
                input: event.input,
                output: event.output,
                fidelity: event.fidelity,
                category: category
            )

        case .progressed:
            let payload = AppendPayload(
                sessionID: sessionID,
                source: .providerStream,
                provider: provider.rawValue,
                category: event.category,
                phase: .progressed,
                operation: operation,
                callID: event.callID,
                input: event.input,
                output: event.output,
                durationMilliseconds: nil,
                fidelity: event.fidelity
            )
            queue.async { [self] in
                let pending = pendingTools[sessionID]?[pendingKey(
                    source: .providerStream,
                    callID: event.callID
                )]
                var resolved = payload
                if let pending {
                    resolved = AppendPayload(
                        sessionID: payload.sessionID,
                        source: payload.source,
                        provider: payload.provider,
                        category: pending.category,
                        phase: payload.phase,
                        operation: pending.operation,
                        callID: payload.callID,
                        input: payload.input,
                        output: payload.output,
                        durationMilliseconds: nil,
                        fidelity: payload.fidelity
                    )
                }
                publish(appendOnQueue(resolved), sessionID: sessionID)
            }

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
        enqueueToolRequest(
            sessionID: sessionID,
            source: source,
            provider: provider,
            operation: operation,
            callID: callID,
            input: input,
            output: nil,
            fidelity: fidelity,
            category: category
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
        queue.async { [self] in
            let pending = pendingTools[sessionID]?.removeValue(
                forKey: pendingKey(source: source, callID: callID)
            )
            let operation = suppliedOperation ?? pending?.operation ?? "tool.result"
            let payload = AppendPayload(
                sessionID: sessionID,
                source: source,
                provider: provider,
                category: pending?.category ?? Self.category(for: operation),
                phase: isError ? .failed : .completed,
                operation: operation,
                callID: callID,
                input: nil,
                output: output,
                durationMilliseconds: pending.map {
                    max(0, Int(Date().timeIntervalSince($0.startedAt) * 1_000))
                },
                fidelity: fidelity
            )
            publish(appendOnQueue(payload), sessionID: sessionID)
        }
    }

    func recordPermissionRequest(_ request: PermissionRequest) {
        enqueueAppend(
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
        enqueueAppend(
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
        let payload = AppendPayload(
            sessionID: sessionID,
            source: source,
            provider: provider,
            category: category,
            phase: phase,
            operation: operation,
            callID: callID,
            input: input,
            output: output,
            durationMilliseconds: durationMilliseconds,
            fidelity: suppliedFidelity
        )
        let record = queue.sync { appendOnQueue(payload) }
        publish(record, sessionID: sessionID)
        return record
    }

    /// Production streams never wait for sanitization, hashing, rotation or disk. The sync
    /// `append` entry point remains for explicit tooling and tests that need the returned seal;
    /// every live event source enters through this ordered writer lane.
    private func enqueueAppend(
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
        fidelity: ExecutionAuditRecord.Fidelity
    ) {
        let payload = AppendPayload(
            sessionID: sessionID,
            source: source,
            provider: provider,
            category: category,
            phase: phase,
            operation: operation,
            callID: callID,
            input: input,
            output: output,
            durationMilliseconds: durationMilliseconds,
            fidelity: fidelity
        )
        queue.async { [self] in
            publish(appendOnQueue(payload), sessionID: sessionID)
        }
    }

    private func enqueueToolRequest(
        sessionID: SessionID,
        source: ExecutionAuditRecord.Source,
        provider: String?,
        operation: String,
        callID: String,
        input: JSONValue?,
        output: JSONValue?,
        fidelity: ExecutionAuditRecord.Fidelity,
        category: ExecutionAuditRecord.Category
    ) {
        let payload = AppendPayload(
            sessionID: sessionID,
            source: source,
            provider: provider,
            category: category,
            phase: .requested,
            operation: operation,
            callID: callID,
            input: input,
            output: output,
            durationMilliseconds: nil,
            fidelity: fidelity
        )
        queue.async { [self] in
            pendingTools[sessionID, default: [:]][pendingKey(source: source, callID: callID)] =
                PendingTool(operation: operation, category: category, startedAt: Date())
            publish(appendOnQueue(payload), sessionID: sessionID)
        }
    }

    /// Queue-confined: this includes every operation whose cost grows with payload or history.
    private func appendOnQueue(_ payload: AppendPayload) -> ExecutionAuditRecord? {
        let sessionID = payload.sessionID
        let operation = payload.operation
        let sanitized = ExecutionAuditSanitizer.sanitize(
            operation: operation,
            input: payload.input,
            output: payload.output
        )
        let fidelity: ExecutionAuditRecord.Fidelity = sanitized.redactions.isEmpty
            ? payload.fidelity
            : .exactWithRedactions

        // A provider payload that would not convert is a defect somewhere upstream of the
        // ledger, and the record alone only shows it to whoever opens that row. Counting it
        // here puts it where a bug report can find it without one.
        let unconvertibleCount = sanitized.redactions.filter { $0.reason == .unconvertible }.count
        if unconvertibleCount > 0 {
            ThreadingLogger.audit.error(
                """
                execution audit: \(unconvertibleCount, privacy: .public) unconvertible \
                member(s) in \(operation, privacy: .public) for \
                \(sessionID, privacy: .public)
                """
            )
        }

        do {
            try ensureDirectory()
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
                source: payload.source,
                provider: payload.provider,
                category: payload.category,
                phase: payload.phase,
                operation: operation,
                callID: payload.callID,
                summary: summary,
                input: sanitized.input,
                output: sanitized.output,
                durationMilliseconds: payload.durationMilliseconds,
                fidelity: fidelity,
                redactions: sanitized.redactions,
                previousDigest: state.digest,
                digest: ""
            )
            guard let digest = Self.digest(SealPayload(record: placeholder)) else {
                reportAppendFailure(.encoding(ExecutionAuditStoreError.seal), for: sessionID)
                return nil
            }
            let sealed = ExecutionAuditRecord(
                id: id,
                sessionID: sessionID,
                sequence: sequence,
                timestamp: timestamp,
                source: payload.source,
                provider: payload.provider,
                category: payload.category,
                phase: payload.phase,
                operation: operation,
                callID: payload.callID,
                summary: summary,
                input: sanitized.input,
                output: sanitized.output,
                durationMilliseconds: payload.durationMilliseconds,
                fidelity: fidelity,
                redactions: sanitized.redactions,
                previousDigest: state.digest,
                digest: digest
            )
            try appendLocked(sealed, sessionID: sessionID)
            state.sequence = sequence
            state.digest = digest
            chainStates[sessionID] = state
            reportAppendRecovery(for: sessionID)
            return sealed
        } catch let failure as StorageFailure {
            reportAppendFailure(failure, for: sessionID)
            return nil
        } catch {
            reportAppendFailure(.write(error), for: sessionID)
            return nil
        }
    }

    private func publish(_ record: ExecutionAuditRecord?, sessionID: SessionID) {
        if record != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(ExecutionAuditDidChange(sessionID: sessionID))
            }
        }
    }

    func read(sessionID: SessionID) -> ExecutionAuditReadResult {
        queue.sync { readLocked(sessionID: sessionID) }
    }

    /// Deletes the bounded ledger when the owning Threading session is deleted. Provider-owned
    /// transcript files are intentionally outside this store and remain governed by the provider.
    func remove(sessionID: SessionID) {
        queue.sync {
            removeLocked(sessionIDs: [sessionID])
        }
    }

    /// Queues a project's bounded ledger cleanup behind any admitted writes. A later read uses
    /// the same serial queue and therefore still observes the deletion, while project removal no
    /// longer performs filesystem work for every session on the main actor.
    func removeInBackground(sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        queue.async { [self] in
            removeLocked(sessionIDs: sessionIDs)
        }
    }

    private func removeLocked(sessionIDs: Set<SessionID>) {
        let manager = FileManager.default
        for sessionID in sessionIDs {
            chainStates.removeValue(forKey: sessionID)
            pendingTools.removeValue(forKey: sessionID)
            appendFailureStages.removeValue(forKey: sessionID)
            readProblemSignatures.removeValue(forKey: sessionID)

            // The store owns a closed set of names for one session. Address those names directly
            // instead of enumerating every other session's ledger (and accepting arbitrary
            // `baseName.*` files as ours) whenever a session is deleted.
            let urls = [currentURL(for: sessionID)]
                + (1...Self.maximumRetainedRotatedSegments).map {
                    rotatedURL(for: sessionID, index: $0)
                }
            for url in urls where manager.fileExists(atPath: url.path) {
                do {
                    try manager.removeItem(at: url)
                } catch {
                    ThreadingLogger.audit.error(
                        "Execution audit deletion failed for \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
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

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StorageFailure.directory(error)
        }
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

    private func appendLocked(_ record: ExecutionAuditRecord, sessionID: SessionID) throws {
        let encoder = Self.encoder
        let encoded: Data
        do {
            encoded = try encoder.encode(record)
        } catch {
            throw StorageFailure.encoding(error)
        }
        var line = encoded
        line.append(0x0A)
        guard line.count <= maximumSegmentBytes else {
            throw StorageFailure.recordTooLarge(line.count)
        }
        try rotateIfNeeded(sessionID: sessionID, incomingBytes: line.count)

        let url = currentURL(for: sessionID)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { throw StorageFailure.fileCreation }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw StorageFailure.fileOpen(error)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            throw StorageFailure.write(error)
        }
    }

    private func rotateIfNeeded(sessionID: SessionID, incomingBytes: Int) throws {
        let file = currentURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let currentBytes: Int
        do {
            currentBytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw StorageFailure.rotation(error)
        }
        guard currentBytes > 0,
              currentBytes > maximumSegmentBytes - incomingBytes else {
            return
        }
        let manager = FileManager.default
        do {
            if retainedRotatedSegments == 0 {
                try manager.removeItem(at: file)
                return
            }
            let oldest = rotatedURL(for: sessionID, index: retainedRotatedSegments)
            if manager.fileExists(atPath: oldest.path) {
                try manager.removeItem(at: oldest)
            }
            if retainedRotatedSegments > 1 {
                for index in stride(from: retainedRotatedSegments - 1, through: 1, by: -1) {
                    let source = rotatedURL(for: sessionID, index: index)
                    guard manager.fileExists(atPath: source.path) else { continue }
                    try manager.moveItem(
                        at: source,
                        to: rotatedURL(for: sessionID, index: index + 1)
                    )
                }
            }
            try manager.moveItem(at: file, to: rotatedURL(for: sessionID, index: 1))
        } catch {
            throw StorageFailure.rotation(error)
        }
    }

    private func readLocked(sessionID: SessionID) -> ExecutionAuditReadResult {
        var records: [ExecutionAuditRecord] = []
        var malformed = 0
        let urls = stride(from: retainedRotatedSegments, through: 1, by: -1)
            .map { rotatedURL(for: sessionID, index: $0) }
            + [currentURL(for: sessionID)]

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try BoundedFileReader.read(url, maximumBytes: maximumSegmentBytes)
            } catch {
                malformed += 1
                continue
            }
            guard !data.isEmpty else { continue }
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
        let result = ExecutionAuditReadResult(
            records: records,
            integrity: integrity,
            malformedLineCount: malformed
        )
        reportReadProblem(result, for: sessionID)
        return result
    }

    private func reportAppendFailure(_ failure: StorageFailure, for sessionID: SessionID) {
        guard appendFailureStages[sessionID] != failure.stage else { return }
        appendFailureStages[sessionID] = failure.stage
        if let diagnostic = failure.diagnostic {
            ThreadingLogger.audit.error(
                "Execution audit append failed at \(failure.stage, privacy: .public) for \(sessionID.uuidString, privacy: .public): \(diagnostic, privacy: .private(mask: .hash))"
            )
        } else {
            ThreadingLogger.audit.error(
                "Execution audit append failed at \(failure.stage, privacy: .public) for \(sessionID.uuidString, privacy: .public)"
            )
        }
    }

    private func reportAppendRecovery(for sessionID: SessionID) {
        guard let stage = appendFailureStages.removeValue(forKey: sessionID) else { return }
        ThreadingLogger.audit.notice(
            "Execution audit append recovered after \(stage, privacy: .public) for \(sessionID.uuidString, privacy: .public)"
        )
    }

    private func reportReadProblem(
        _ result: ExecutionAuditReadResult,
        for sessionID: SessionID
    ) {
        guard result.integrity == .broken else {
            readProblemSignatures.removeValue(forKey: sessionID)
            return
        }
        let signature = "broken:\(result.malformedLineCount)"
        guard readProblemSignatures[sessionID] != signature else { return }
        readProblemSignatures[sessionID] = signature
        ThreadingLogger.audit.fault(
            "Execution audit verification failed for \(sessionID.uuidString, privacy: .public); malformed=\(result.malformedLineCount, privacy: .public)"
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

private enum ExecutionAuditStoreError: LocalizedError {
    case seal

    var errorDescription: String? {
        switch self {
        case .seal: return "record seal could not be encoded"
        }
    }
}

// MARK: - Explicit Redaction

private enum ExecutionAuditSanitizer {
    struct Result {
        let input: JSONValue?
        let output: JSONValue?
        let redactions: [ExecutionAuditRecord.Redaction]
    }

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
                let reason: ExecutionAuditRecord.Redaction.Reason?
                if CredentialVocabulary.isCredentialKey(key) {
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

        case .unconvertible(let describedType):
            // The adapter already kept the member's place; the ledger names it by path so the
            // loss is a listed fact rather than something a reader has to notice in the payload.
            redactions.append(.init(path: path, reason: .unconvertible))
            return .string(JSONValue.unconvertibleMarker(describedType))

        case .string, .integer, .number, .bool, .null:
            return value
        }
    }
}
