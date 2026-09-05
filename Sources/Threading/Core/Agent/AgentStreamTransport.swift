import Foundation

enum AgentStreamTransportFailure: Error, Equatable, Sendable {
    case inputBackpressure
    case invalidOutboundJSON
    case outboundLineTooLarge(Int)
    case outputLineTooLarge(Int)
    case writeFailed(String)

    var userFacingDescription: String {
        switch self {
        case .inputBackpressure:
            return "The agent input stream stopped accepting messages."
        case .invalidOutboundJSON:
            return "Threading could not encode a message for the agent."
        case .outboundLineTooLarge:
            return "A message was too large for the agent transport."
        case .outputLineTooLarge:
            return "The agent sent a response larger than the transport limit."
        case .writeFailed(let description):
            return description
        }
    }
}

enum AgentStreamTransportDefaults {
    /// Tool results can legitimately be large, but a newline-free stream must not grow forever.
    static let maximumLineBytes = 16 * 1_024 * 1_024
    static let maximumPendingWrites = 64
}

/// Bounded pipe ownership shared by every persistent native agent transport.
///
/// FileHandle callbacks, newline framing, JSON parsing, stderr capture and stdin writes all stay
/// off the main actor. Only a fully parsed, immutable value crosses to the session. The class is
/// `@unchecked Sendable` for one named reason: FileHandle predates Sendable. Its handles and all
/// mutable transport state are confined to the two queues below; the lock guards admission only.
final class AgentStreamTransport<Line: Sendable>: @unchecked Sendable {
    typealias Parser = @Sendable (Data) -> Line?

    private final class OutboundJSONObject: @unchecked Sendable {
        /// A newly constructed Swift value graph. Arrays, dictionaries and strings have value
        /// semantics and JSONSerialization only reads them on the writer queue.
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let maximumLineBytes: Int
    private let maximumErrorBytes: Int
    private let maximumPendingWrites: Int
    private let parser: Parser
    private let onLine: @MainActor @Sendable (Line) -> Void
    private let onMalformedLine: @MainActor @Sendable () -> Void
    private let onFailure: @MainActor @Sendable (AgentStreamTransportFailure) -> Void

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let admissionLock = NSLock()
    private let callbackLock = NSLock()
    private var pendingWriteCount = 0
    private var acceptsWrites = true
    private var acceptsCallbacks = true
    private var deliversCallbacks = true

    /// Read-queue confined.
    private var buffer = Data()
    private var readOffset = 0
    private var errorBuffer = Data()
    private var didReportFailure = false

    init(
        label: String,
        input: FileHandle,
        output: FileHandle,
        error: FileHandle,
        maximumLineBytes: Int = AgentStreamTransportDefaults.maximumLineBytes,
        maximumErrorBytes: Int,
        maximumPendingWrites: Int = AgentStreamTransportDefaults.maximumPendingWrites,
        parser: @escaping Parser,
        onLine: @escaping @MainActor @Sendable (Line) -> Void,
        onMalformedLine: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (AgentStreamTransportFailure) -> Void
    ) {
        self.input = input
        self.output = output
        self.error = error
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumErrorBytes = max(0, maximumErrorBytes)
        self.maximumPendingWrites = max(1, maximumPendingWrites)
        self.parser = parser
        self.onLine = onLine
        self.onMalformedLine = onMalformedLine
        self.onFailure = onFailure
        readQueue = DispatchQueue(label: "\(label).read", qos: .userInitiated)
        writeQueue = DispatchQueue(label: "\(label).write", qos: .userInitiated)
    }

    func start() {
        output.readabilityHandler = { [weak self] handle in
            self?.enqueueRead(from: handle, isError: false)
        }
        error.readabilityHandler = { [weak self] handle in
            self?.enqueueRead(from: handle, isError: true)
        }
    }

    /// Admission is synchronous and constant-time; encoding and the possibly blocking pipe write
    /// are not. `true` means this transport owns the message, not that the child has read it yet.
    func writeJSONObject(_ object: [String: Any]) -> Bool {
        admissionLock.lock()
        guard acceptsWrites else {
            admissionLock.unlock()
            return false
        }
        guard pendingWriteCount < maximumPendingWrites else {
            admissionLock.unlock()
            readQueue.async { [weak self] in self?.fail(.inputBackpressure) }
            return false
        }
        pendingWriteCount += 1
        admissionLock.unlock()

        let outbound = OutboundJSONObject(object)
        writeQueue.async { [weak self] in self?.write(outbound) }
        return true
    }

    /// Closes stdin behind every write already admitted. Used for graceful EOF and teardown;
    /// FileHandle.close may itself wait on descriptor state, so it belongs to the writer lane.
    func closeInput() {
        admissionLock.lock()
        acceptsWrites = false
        admissionLock.unlock()
        writeQueue.async { [input] in try? input.close() }
    }

    /// Gives up this launch's pipe callbacks without closing a descriptor the background host is
    /// still pumping. The owning session drops the transport immediately afterwards.
    func detach() {
        admissionLock.lock()
        acceptsWrites = false
        admissionLock.unlock()
        callbackLock.lock()
        acceptsCallbacks = false
        deliversCallbacks = false
        output.readabilityHandler = nil
        error.readabilityHandler = nil
        callbackLock.unlock()
    }

    /// Stops admitting work and returns the bounded diagnostic after already-admitted read work.
    /// The completion is delivered on main so a session can finish teardown without a sync wait.
    func finish(_ completion: @escaping @MainActor @Sendable (String) -> Void) {
        admissionLock.lock()
        acceptsWrites = false
        admissionLock.unlock()
        callbackLock.lock()
        acceptsCallbacks = false
        output.readabilityHandler = nil
        error.readabilityHandler = nil
        readQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion("") }
                }
                return
            }
            if let trailingOutput = try? output.readToEnd(), !trailingOutput.isEmpty {
                consume(trailingOutput)
            }
            if let trailingError = try? error.readToEnd(), !trailingError.isEmpty {
                captureError(trailingError)
            }
            let diagnostic = String(decoding: errorBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(diagnostic) }
            }
        }
        callbackLock.unlock()
    }

    /// Callback admission and final drain share one lock. The callback consumes the readable
    /// bytes before it returns, then queues only their processing. Deferring `availableData` to
    /// the serial lane can leave a pipe readable without producing another readiness edge; a
    /// child that writes more than the pipe capacity would then block forever. A callback either
    /// reads and enters the serial lane before `finish`, or stops and lets the final drain read
    /// those bytes; it cannot queue a chunk behind the teardown completion.
    private func enqueueRead(from handle: FileHandle, isError: Bool) {
        callbackLock.lock()
        guard acceptsCallbacks else {
            callbackLock.unlock()
            return
        }
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
            callbackLock.unlock()
            return
        }
        readQueue.async { [weak self] in
            guard let self else { return }
            if isError { captureError(chunk) } else { consume(chunk) }
        }
        callbackLock.unlock()
    }

    private func consume(_ chunk: Data) {
        guard !didReportFailure else { return }
        buffer.append(chunk)

        while let newline = buffer[readOffset...].firstIndex(of: 0x0A) {
            let length = newline - readOffset
            guard length <= maximumLineBytes else {
                fail(.outputLineTooLarge(length))
                return
            }
            let lineData = Data(buffer[readOffset..<newline])
            readOffset = buffer.index(after: newline)
            guard let line = parser(lineData) else {
                deliverMalformedLine()
                continue
            }
            deliver(line)
        }

        let pendingBytes = buffer.count - readOffset
        guard pendingBytes <= maximumLineBytes else {
            fail(.outputLineTooLarge(pendingBytes))
            return
        }

        // Compact once per substantial batch rather than once per line. That turns a burst of
        // small JSON records from repeated whole-buffer copies into one prefix removal.
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1_024 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }

    private func captureError(_ chunk: Data) {
        guard errorBuffer.count < maximumErrorBytes else { return }
        errorBuffer.append(chunk.prefix(maximumErrorBytes - errorBuffer.count))
    }

    private func write(_ outbound: OutboundJSONObject) {
        defer {
            admissionLock.lock()
            pendingWriteCount -= 1
            admissionLock.unlock()
        }
        guard JSONSerialization.isValidJSONObject(outbound.value),
              var data = try? JSONSerialization.data(withJSONObject: outbound.value) else {
            failFromWriteQueue(.invalidOutboundJSON)
            return
        }
        data.append(0x0A)
        guard data.count <= maximumLineBytes else {
            failFromWriteQueue(.outboundLineTooLarge(data.count))
            return
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            failFromWriteQueue(.writeFailed(error.localizedDescription))
        }
    }

    private func failFromWriteQueue(_ failure: AgentStreamTransportFailure) {
        readQueue.async { [weak self] in self?.fail(failure) }
    }

    /// Read-queue confined so a read limit and a write error can report only one terminal fault.
    private func fail(_ failure: AgentStreamTransportFailure) {
        guard !didReportFailure else { return }
        didReportFailure = true
        admissionLock.lock()
        acceptsWrites = false
        admissionLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, callbacksRemainDeliverable else { return }
            MainActor.assumeIsolated { self.onFailure(failure) }
        }
    }

    private func deliver(_ line: Line) {
        DispatchQueue.main.async { [weak self] in
            guard let self, callbacksRemainDeliverable else { return }
            MainActor.assumeIsolated { self.onLine(line) }
        }
    }

    private func deliverMalformedLine() {
        DispatchQueue.main.async { [weak self] in
            guard let self, callbacksRemainDeliverable else { return }
            MainActor.assumeIsolated { self.onMalformedLine() }
        }
    }

    private var callbacksRemainDeliverable: Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return deliversCallbacks
    }
}
