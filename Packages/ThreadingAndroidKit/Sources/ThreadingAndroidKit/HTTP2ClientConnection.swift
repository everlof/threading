import Foundation

public enum HTTP2Event: Equatable, Sendable {
    case headers(streamID: UInt32, headers: [HTTP2Header], endStream: Bool)
    case data(streamID: UInt32, bytes: [UInt8], endStream: Bool)
    case streamReset(streamID: UInt32, errorCode: UInt32)
    case goAway(lastStreamID: UInt32, errorCode: UInt32)
    case pingAcknowledged([UInt8])
}

/// The client half of one cleartext HTTP/2 connection (h2c with prior knowledge, RFC 9113 §3.3),
/// as a state machine with no I/O of its own: bytes go in through `receive`, bytes to write come
/// out of `takeOutput`. One owner drives it from one queue; that is what makes every protocol
/// decision here deterministic under test.
///
/// Inbound flow control replenishes as soon as a DATA frame is delivered. The consumer above is
/// latest-frame-wins and drops what it cannot use, so withholding window would only stall the
/// stream behind a frame nobody wants; the bound on memory is the frame size and the caller's
/// message ceiling, not the window.
public struct HTTP2ClientConnection {
    public static let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let defaultWindowSize = 65_535
    static let maximumWindowSize = Int(Int32.max)

    public struct Configuration: Sendable {
        /// The largest frame this client accepts. Larger than the protocol default because a
        /// single framebuffer message is megabytes.
        public var maximumFrameSize: Int
        public var initialWindowSize: Int
        public var maximumHeaderListSize: Int
        public var maximumConcurrentStreams: Int

        public init(
            maximumFrameSize: Int = 1 << 20,
            initialWindowSize: Int = 16 << 20,
            maximumHeaderListSize: Int = 64 * 1024,
            maximumConcurrentStreams: Int = 64
        ) {
            self.maximumFrameSize = maximumFrameSize
            self.initialWindowSize = initialWindowSize
            self.maximumHeaderListSize = maximumHeaderListSize
            self.maximumConcurrentStreams = maximumConcurrentStreams
        }
    }

    private struct Stream {
        var sendWindow: Int
        var pending: [UInt8] = []
        var pendingEndStream = false
        var localClosed = false
        var remoteClosed = false
    }

    private struct HeaderAssembly {
        let streamID: UInt32
        let endStream: Bool
        var block: [UInt8]
    }

    private let configuration: Configuration
    private var reader: HTTP2FrameReader
    private var decoder: HPACKDecoder
    private var output: [UInt8] = []
    private var streams: [UInt32: Stream] = [:]
    private var nextStreamID: UInt32 = 1
    private var peerMaximumFrameSize = HTTP2Frame.defaultMaximumFrameSize
    private var peerInitialWindowSize = HTTP2ClientConnection.defaultWindowSize
    private var connectionSendWindow = HTTP2ClientConnection.defaultWindowSize
    private var assembly: HeaderAssembly?
    private var started = false
    public private(set) var isClosed = false

    public init(configuration: Configuration = Configuration()) {
        precondition(configuration.maximumFrameSize >= HTTP2Frame.defaultMaximumFrameSize
                     && configuration.maximumFrameSize <= HTTP2Frame.largestMaximumFrameSize)
        precondition(configuration.initialWindowSize >= Self.defaultWindowSize
                     && configuration.initialWindowSize <= Self.maximumWindowSize)
        self.configuration = configuration
        self.reader = HTTP2FrameReader(maximumFrameSize: configuration.maximumFrameSize)
        self.decoder = HPACKDecoder(maximumHeaderListSize: configuration.maximumHeaderListSize)
    }

    public var openStreamCount: Int { streams.count }

    /// Queues the connection preface, this client's settings and the connection-level window.
    public mutating func start() {
        guard !started else { return }
        started = true
        output += Self.preface
        var settings: [UInt8] = []
        func setting(_ identifier: HTTP2SettingsIdentifier, _ value: Int) {
            settings += BigEndian.bytes(identifier.rawValue) + BigEndian.bytes(UInt32(value))
        }
        setting(.enablePush, 0)
        setting(.initialWindowSize, configuration.initialWindowSize)
        setting(.maxFrameSize, configuration.maximumFrameSize)
        setting(.maxHeaderListSize, configuration.maximumHeaderListSize)
        output += HTTP2Frame(type: .settings, streamID: 0, payload: settings).encoded()
        let increment = configuration.initialWindowSize - Self.defaultWindowSize
        if increment > 0 { output += Self.windowUpdate(streamID: 0, increment: increment) }
    }

    /// Opens a client stream with its request headers. The block is split into HEADERS and
    /// CONTINUATION frames at the peer's frame size.
    public mutating func openStream(headers: [HTTP2Header], endStream: Bool) throws -> UInt32 {
        guard started, !isClosed else { throw HTTP2Error.connectionClosed(errorCode: 0) }
        guard streams.count < configuration.maximumConcurrentStreams else { throw HTTP2Error.tooManyStreams }
        guard nextStreamID <= 0x7FFF_FFFF else { throw HTTP2Error.tooManyStreams }
        let streamID = nextStreamID
        nextStreamID += 2
        streams[streamID] = Stream(sendWindow: peerInitialWindowSize, localClosed: endStream)
        let block = HPACKEncoder.encode(headers)
        var offset = 0
        var first = true
        repeat {
            let end = min(block.count, offset + peerMaximumFrameSize)
            let isLast = end == block.count
            let flags = (isLast ? HTTP2Flag.endHeaders : 0) | (first && endStream ? HTTP2Flag.endStream : 0)
            output += HTTP2Frame(
                type: first ? .headers : .continuation, flags: flags, streamID: streamID,
                payload: Array(block[offset..<end])
            ).encoded()
            offset = end
            first = false
        } while offset < block.count
        return streamID
    }

    /// Queues request body bytes, writing as much as the peer's windows allow now and the rest as
    /// WINDOW_UPDATEs arrive.
    public mutating func send(_ bytes: [UInt8], on streamID: UInt32, endStream: Bool) throws {
        guard var stream = streams[streamID], !stream.localClosed, !stream.pendingEndStream else {
            throw HTTP2Error.streamClosed(streamID)
        }
        stream.pending += bytes
        stream.pendingEndStream = endStream
        streams[streamID] = stream
        flush(streamID)
    }

    public mutating func reset(_ streamID: UInt32, errorCode: UInt32 = 0x8) {
        guard streams.removeValue(forKey: streamID) != nil else { return }
        output += HTTP2Frame(type: .resetStream, streamID: streamID, payload: BigEndian.bytes(errorCode)).encoded()
    }

    public mutating func ping(_ payload: [UInt8]) {
        precondition(payload.count == 8)
        output += HTTP2Frame(type: .ping, streamID: 0, payload: payload).encoded()
    }

    public mutating func goAway(errorCode: UInt32 = 0) {
        guard !isClosed else { return }
        isClosed = true
        output += HTTP2Frame(
            type: .goAway, streamID: 0, payload: BigEndian.bytes(UInt32(0)) + BigEndian.bytes(errorCode)
        ).encoded()
    }

    public mutating func takeOutput() -> [UInt8] {
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    /// Feeds inbound bytes and returns the events they complete. A thrown error is a connection
    /// error: the caller closes the transport.
    public mutating func receive(_ bytes: [UInt8]) throws -> [HTTP2Event] {
        reader.append(bytes)
        var events: [HTTP2Event] = []
        while let frame = try reader.nextFrame() {
            try handle(frame, events: &events)
        }
        return events
    }

    // MARK: - Private

    private mutating func handle(_ frame: HTTP2Frame, events: inout [HTTP2Event]) throws {
        if let assembly, frame.type != .continuation || frame.streamID != assembly.streamID {
            throw HTTP2Error.protocolError("A header block was interrupted by another frame.")
        }
        guard let type = frame.type else { return } // Unknown frame types are ignored (§4.1).
        switch type {
        case .settings:
            guard frame.streamID == 0 else { throw HTTP2Error.protocolError("SETTINGS on a stream.") }
            if frame.hasFlag(HTTP2Flag.ack) { return }
            try applySettings(frame.payload)
            output += HTTP2Frame(type: .settings, flags: HTTP2Flag.ack, streamID: 0).encoded()

        case .ping:
            guard frame.payload.count == 8 else { throw HTTP2Error.protocolError("PING must carry 8 octets.") }
            if frame.hasFlag(HTTP2Flag.ack) {
                events.append(.pingAcknowledged(frame.payload))
            } else {
                output += HTTP2Frame(type: .ping, flags: HTTP2Flag.ack, streamID: 0, payload: frame.payload).encoded()
            }

        case .windowUpdate:
            guard frame.payload.count == 4 else { throw HTTP2Error.protocolError("Malformed WINDOW_UPDATE.") }
            let increment = Int(BigEndian.uint32(frame.payload, at: 0) & 0x7FFF_FFFF)
            if frame.streamID == 0 {
                guard increment > 0 else { throw HTTP2Error.protocolError("Zero connection window increment.") }
                connectionSendWindow += increment
                guard connectionSendWindow <= Self.maximumWindowSize else {
                    throw HTTP2Error.flowControl("Connection window overflow.")
                }
                for streamID in streams.keys.sorted() { flush(streamID) }
            } else if var stream = streams[frame.streamID] {
                stream.sendWindow += increment
                streams[frame.streamID] = stream
                flush(frame.streamID)
            }

        case .headers:
            var payload = try Self.unpadded(frame)
            if frame.hasFlag(HTTP2Flag.priority) {
                guard payload.count >= 5 else { throw HTTP2Error.protocolError("Truncated priority.") }
                payload.removeFirst(5)
            }
            let pending = HeaderAssembly(
                streamID: frame.streamID, endStream: frame.hasFlag(HTTP2Flag.endStream), block: payload
            )
            if frame.hasFlag(HTTP2Flag.endHeaders) {
                try completeHeaders(pending, events: &events)
            } else {
                assembly = pending
            }

        case .continuation:
            guard var pending = assembly else { throw HTTP2Error.protocolError("Unexpected CONTINUATION.") }
            pending.block += frame.payload
            guard pending.block.count <= configuration.maximumHeaderListSize else {
                throw HTTP2Error.protocolError("Header block too large.")
            }
            if frame.hasFlag(HTTP2Flag.endHeaders) {
                assembly = nil
                try completeHeaders(pending, events: &events)
            } else {
                assembly = pending
            }

        case .data:
            let payload = try Self.unpadded(frame)
            // Replenish what the whole frame consumed, padding included (§6.9.1).
            if !frame.payload.isEmpty {
                output += Self.windowUpdate(streamID: 0, increment: frame.payload.count)
            }
            guard streams[frame.streamID] != nil else { return } // Data for a stream we reset.
            let endStream = frame.hasFlag(HTTP2Flag.endStream)
            if !frame.payload.isEmpty, !endStream {
                output += Self.windowUpdate(streamID: frame.streamID, increment: frame.payload.count)
            }
            events.append(.data(streamID: frame.streamID, bytes: payload, endStream: endStream))
            if endStream { closeRemote(frame.streamID) }

        case .resetStream:
            guard frame.payload.count == 4 else { throw HTTP2Error.protocolError("Malformed RST_STREAM.") }
            if streams.removeValue(forKey: frame.streamID) != nil {
                events.append(.streamReset(streamID: frame.streamID, errorCode: BigEndian.uint32(frame.payload, at: 0)))
            }

        case .goAway:
            guard frame.payload.count >= 8 else { throw HTTP2Error.protocolError("Malformed GOAWAY.") }
            isClosed = true
            let lastStreamID = BigEndian.uint32(frame.payload, at: 0) & 0x7FFF_FFFF
            let errorCode = BigEndian.uint32(frame.payload, at: 4)
            // Streams above the last one the server processed will never be answered.
            for streamID in streams.keys where streamID > lastStreamID {
                streams.removeValue(forKey: streamID)
                events.append(.streamReset(streamID: streamID, errorCode: errorCode))
            }
            events.append(.goAway(lastStreamID: lastStreamID, errorCode: errorCode))

        case .pushPromise:
            throw HTTP2Error.protocolError("PUSH_PROMISE after push was disabled.")

        case .priority:
            return
        }
    }

    private mutating func completeHeaders(_ pending: HeaderAssembly, events: inout [HTTP2Event]) throws {
        let headers = try decoder.decode(pending.block)
        guard streams[pending.streamID] != nil else { return }
        events.append(.headers(streamID: pending.streamID, headers: headers, endStream: pending.endStream))
        if pending.endStream { closeRemote(pending.streamID) }
    }

    private mutating func closeRemote(_ streamID: UInt32) {
        guard var stream = streams[streamID] else { return }
        stream.remoteClosed = true
        if stream.localClosed { streams.removeValue(forKey: streamID) } else { streams[streamID] = stream }
    }

    private mutating func applySettings(_ payload: [UInt8]) throws {
        guard payload.count % 6 == 0 else { throw HTTP2Error.protocolError("Malformed SETTINGS.") }
        for offset in stride(from: 0, to: payload.count, by: 6) {
            let identifier = BigEndian.uint16(payload, at: offset)
            let value = Int(BigEndian.uint32(payload, at: offset + 2))
            switch HTTP2SettingsIdentifier(rawValue: identifier) {
            case .initialWindowSize?:
                guard value <= Self.maximumWindowSize else { throw HTTP2Error.flowControl("Initial window too large.") }
                let delta = value - peerInitialWindowSize
                peerInitialWindowSize = value
                for streamID in streams.keys { streams[streamID]?.sendWindow += delta }
            case .maxFrameSize?:
                guard value >= HTTP2Frame.defaultMaximumFrameSize, value <= HTTP2Frame.largestMaximumFrameSize else {
                    throw HTTP2Error.protocolError("Invalid SETTINGS_MAX_FRAME_SIZE.")
                }
                peerMaximumFrameSize = value
            default:
                continue
            }
        }
        for streamID in streams.keys.sorted() { flush(streamID) }
    }

    private mutating func flush(_ streamID: UInt32) {
        guard var stream = streams[streamID], !stream.localClosed else { return }
        while !stream.pending.isEmpty {
            let allowed = min(stream.pending.count, stream.sendWindow, connectionSendWindow, peerMaximumFrameSize)
            guard allowed > 0 else { break }
            let chunk = Array(stream.pending.prefix(allowed))
            stream.pending.removeFirst(allowed)
            stream.sendWindow -= allowed
            connectionSendWindow -= allowed
            let ends = stream.pending.isEmpty && stream.pendingEndStream
            output += HTTP2Frame(type: .data, flags: ends ? HTTP2Flag.endStream : 0, streamID: streamID, payload: chunk).encoded()
            if ends { stream.localClosed = true }
        }
        if stream.pending.isEmpty, stream.pendingEndStream, !stream.localClosed {
            output += HTTP2Frame(type: .data, flags: HTTP2Flag.endStream, streamID: streamID).encoded()
            stream.localClosed = true
        }
        if stream.localClosed, stream.remoteClosed {
            streams.removeValue(forKey: streamID)
        } else {
            streams[streamID] = stream
        }
    }

    private static func unpadded(_ frame: HTTP2Frame) throws -> [UInt8] {
        guard frame.hasFlag(HTTP2Flag.padded) else { return frame.payload }
        guard let padLength = frame.payload.first.map(Int.init), padLength < frame.payload.count else {
            throw HTTP2Error.protocolError("Padding exceeds the frame.")
        }
        return Array(frame.payload[1..<(frame.payload.count - padLength)])
    }

    private static func windowUpdate(streamID: UInt32, increment: Int) -> [UInt8] {
        HTTP2Frame(type: .windowUpdate, streamID: streamID, payload: BigEndian.bytes(UInt32(increment))).encoded()
    }
}
