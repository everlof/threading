import Foundation

// MARK: - Server-Sent Event Reader

/// Reassembles `text/event-stream` frames from an arbitrary byte stream.
///
/// Only `data:` matters. The app writes `event: message` before every frame and nothing on this
/// side reads it; `id:` and `retry:` never appear; a `:`-prefixed line is the standard's
/// keep-alive comment. A frame ends at a blank line, and its `data:` lines are joined with
/// newlines — which is the standard's rule and also the reason the join happens here rather than
/// at the caller: an over-long frame has to be recognised and dropped *before* it becomes a
/// message, not after.
///
/// The stream is unbounded by construction, so nothing is retained past one frame, and a frame
/// that grows past `BridgeDefaults.maximumMessageBytes` is abandoned at its terminator rather
/// than buffered to the end.
struct ServerSentEventReader {

    // MARK: - Properties

    /// Bytes of the line currently being read.
    private var partialLine = Data()
    /// The `data:` payloads of the frame currently being read.
    private var frameLines: [Data] = []
    private var frameBytes = 0
    private var isFrameOversized = false

    // MARK: - Public Methods

    /// Feeds bytes in and calls `emit` once per complete frame that carried data.
    ///
    /// - Parameter report: called once for a frame dropped as oversized, so the condition is
    ///   visible in diagnostics rather than silently costing a notification.
    mutating func consume(
        _ bytes: Data,
        emit: (Data) -> Void,
        report: (String) -> Void = { _ in }
    ) {
        for byte in bytes {
            guard byte == Self.lineFeed else {
                appendToLine(byte)
                continue
            }
            let line = Self.trimmingCarriageReturn(partialLine)
            partialLine = Data()
            finish(line: line, emit: emit, report: report)
        }
    }

    // MARK: - Private Methods

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let dataFieldName = Data("data".utf8)

    private mutating func appendToLine(_ byte: UInt8) {
        // A line longer than one whole message can never become one, so the bytes are counted
        // and dropped rather than accumulated.
        guard partialLine.count < BridgeDefaults.maximumMessageBytes else {
            isFrameOversized = true
            return
        }
        partialLine.append(byte)
    }

    private mutating func finish(
        line: Data,
        emit: (Data) -> Void,
        report: (String) -> Void
    ) {
        guard !line.isEmpty else {
            dispatchFrame(emit: emit, report: report)
            return
        }
        // A comment: the standard's keep-alive, and the only line that begins with the separator.
        guard line.first != Self.colon else { return }

        guard let separator = line.firstIndex(of: Self.colon) else { return }
        let name = Data(line[line.startIndex..<separator])
        guard name == Self.dataFieldName else { return }

        var value = line[line.index(after: separator)...]
        if value.first == Self.space { value = value.dropFirst() }

        guard frameBytes + value.count <= BridgeDefaults.maximumMessageBytes else {
            isFrameOversized = true
            return
        }
        frameBytes += value.count
        frameLines.append(Data(value))
    }

    private mutating func dispatchFrame(emit: (Data) -> Void, report: (String) -> Void) {
        defer {
            frameLines.removeAll(keepingCapacity: true)
            frameBytes = 0
            isFrameOversized = false
        }

        guard !isFrameOversized else {
            report("dropped an event larger than \(BridgeDefaults.maximumMessageBytes) bytes")
            return
        }
        // A blank line with nothing before it is a stream separator, not an empty event.
        guard !frameLines.isEmpty else { return }

        var payload = Data()
        for (index, line) in frameLines.enumerated() {
            if index > 0 { payload.append(Self.lineFeed) }
            payload.append(line)
        }
        guard !payload.isEmpty else { return }
        emit(payload)
    }

    private static func trimmingCarriageReturn(_ line: Data) -> Data {
        guard line.last == carriageReturn else { return line }
        return Data(line.dropLast())
    }
}
