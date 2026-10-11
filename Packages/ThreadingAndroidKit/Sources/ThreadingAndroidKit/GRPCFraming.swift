import Foundation

/// A gRPC status (https://grpc.github.io/grpc/core/md_doc_statuscodes.html) as it ends a call.
public struct GRPCStatus: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: Int, Sendable {
        case ok = 0, cancelled, unknown, invalidArgument, deadlineExceeded, notFound, alreadyExists
        case permissionDenied, resourceExhausted, failedPrecondition, aborted, outOfRange
        case unimplemented, internalError, unavailable, dataLoss, unauthenticated
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String = "") {
        self.code = code
        self.message = message
    }

    public var isOK: Bool { code == .ok }
    public var description: String { message.isEmpty ? "gRPC \(code)" : "gRPC \(code): \(message)" }

    /// Reads the status a response's trailers (or a trailers-only response's headers) carry.
    /// `grpc-message` is percent-encoded on the wire.
    public static func from(trailers: [HTTP2Header]) -> GRPCStatus? {
        guard let raw = trailers.last(where: { $0.name == "grpc-status" })?.value, let value = Int(raw) else {
            return nil
        }
        let message = trailers.last(where: { $0.name == "grpc-message" })?.value.removingPercentEncoding ?? ""
        guard let code = Code(rawValue: value) else {
            return GRPCStatus(code: .unknown, message: "unrecognised gRPC status \(value)" + (message.isEmpty ? "" : ": \(message)"))
        }
        return GRPCStatus(code: code, message: message)
    }
}

/// gRPC's length-prefixed message framing over an HTTP/2 stream: one compression flag, a 32-bit
/// big-endian length, the message. Messages above `maximumMessageSize` are refused before they
/// are buffered.
public struct GRPCMessageDeframer: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case messageTooLarge(Int)
        case compressedMessage
    }

    private var buffer: [UInt8] = []
    private var consumed = 0
    public let maximumMessageSize: Int

    public init(maximumMessageSize: Int) {
        self.maximumMessageSize = maximumMessageSize
    }

    public static func frame(_ message: [UInt8]) -> [UInt8] {
        [0] + BigEndian.bytes(UInt32(message.count)) + message
    }

    public mutating func append(_ bytes: [UInt8]) throws -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var messages: [[UInt8]] = []
        while buffer.count - consumed >= 5 {
            guard buffer[consumed] == 0 else { throw Failure.compressedMessage }
            let length = Int(BigEndian.uint32(buffer, at: consumed + 1))
            guard length <= maximumMessageSize else { throw Failure.messageTooLarge(length) }
            guard buffer.count - consumed - 5 >= length else { break }
            let start = consumed + 5
            messages.append(Array(buffer[start..<(start + length)]))
            consumed = start + length
        }
        if consumed > 0, consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed > 1 << 20 {
            buffer.removeFirst(consumed)
            consumed = 0
        }
        return messages
    }

    /// Bytes buffered toward an incomplete message; a stream that ends with any is truncated.
    public var hasPartialMessage: Bool { buffer.count > consumed }
}

public enum GRPCRequestHeaders {
    /// The request headers of one gRPC call over cleartext HTTP/2.
    public static func make(authority: String, path: String, metadata: [HTTP2Header]) -> [HTTP2Header] {
        [
            HTTP2Header(":method", "POST"),
            HTTP2Header(":scheme", "http"),
            HTTP2Header(":path", path),
            HTTP2Header(":authority", authority),
            HTTP2Header("content-type", "application/grpc"),
            HTTP2Header("te", "trailers"),
            HTTP2Header("user-agent", "threading-android/1"),
        ] + metadata
    }
}
