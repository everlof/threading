import Foundation

/// One HTTP/2 header field. Names are lower-case on the wire (RFC 9113 §8.2.1).
public struct HTTP2Header: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public enum HPACKError: Error, Equatable, Sendable {
    case truncated
    case integerOverflow
    case invalidIndex(Int)
    case invalidHuffman
    case tableSizeUpdateTooLarge(Int)
    case headerListTooLarge(maximum: Int)
    case invalidUTF8
}

// MARK: - Encoder

/// The request-side encoder. It never indexes and never Huffman-codes: both are optional for an
/// encoder (RFC 7541 §6.2.2, §5.2), and a client sending a handful of short gRPC headers gains
/// nothing from either while the decoder at the other end keeps no state on our behalf.
public enum HPACKEncoder {
    public static func encode(_ headers: [HTTP2Header]) -> [UInt8] {
        var output: [UInt8] = []
        for header in headers {
            if let index = HPACKStaticTable.exactIndex(name: header.name, value: header.value) {
                HPACKInteger.encode(index, prefixBits: 7, firstByteFlags: 0x80, into: &output)
                continue
            }
            // Literal Header Field without Indexing (0000xxxx), name indexed when possible.
            if let nameIndex = HPACKStaticTable.nameIndex(header.name) {
                HPACKInteger.encode(nameIndex, prefixBits: 4, firstByteFlags: 0x00, into: &output)
            } else {
                output.append(0x00)
                encodeString(header.name, into: &output)
            }
            encodeString(header.value, into: &output)
        }
        return output
    }

    private static func encodeString(_ string: String, into output: inout [UInt8]) {
        let bytes = Array(string.utf8)
        HPACKInteger.encode(bytes.count, prefixBits: 7, firstByteFlags: 0x00, into: &output)
        output.append(contentsOf: bytes)
    }
}

// MARK: - Decoder

/// The response-side decoder: full RFC 7541, because the peer chooses the representation. Its
/// dynamic table is bounded by the size this client advertised, and a decoded header list is
/// bounded too, so a hostile or confused peer cannot make it grow without limit.
public struct HPACKDecoder: Sendable {
    public static let defaultMaximumTableSize = 4_096

    private var dynamicTable: [HTTP2Header] = []
    private var dynamicTableSize = 0
    private var maximumTableSize: Int
    private let advertisedMaximumTableSize: Int
    private let maximumHeaderListSize: Int

    public init(
        maximumTableSize: Int = HPACKDecoder.defaultMaximumTableSize,
        maximumHeaderListSize: Int = 64 * 1024
    ) {
        self.maximumTableSize = maximumTableSize
        self.advertisedMaximumTableSize = maximumTableSize
        self.maximumHeaderListSize = maximumHeaderListSize
    }

    public mutating func decode(_ block: [UInt8]) throws -> [HTTP2Header] {
        var reader = ByteCursor(block)
        var headers: [HTTP2Header] = []
        var listSize = 0
        while !reader.isAtEnd {
            let first = try reader.peek()
            let header: HTTP2Header
            if first & 0x80 != 0 {
                let index = try HPACKInteger.decode(prefixBits: 7, from: &reader)
                header = try entry(at: index)
            } else if first & 0x40 != 0 {
                header = try literal(prefixBits: 6, from: &reader)
                insert(header)
            } else if first & 0x20 != 0 {
                let size = try HPACKInteger.decode(prefixBits: 5, from: &reader)
                guard size <= advertisedMaximumTableSize else { throw HPACKError.tableSizeUpdateTooLarge(size) }
                maximumTableSize = size
                evict()
                continue
            } else {
                // Without indexing (0000) and never indexed (0001) decode alike.
                header = try literal(prefixBits: 4, from: &reader)
            }
            listSize += header.name.utf8.count + header.value.utf8.count + 32
            guard listSize <= maximumHeaderListSize else {
                throw HPACKError.headerListTooLarge(maximum: maximumHeaderListSize)
            }
            headers.append(header)
        }
        return headers
    }

    var dynamicTableSizeForTesting: Int { dynamicTableSize }

    private func entry(at index: Int) throws -> HTTP2Header {
        if index >= 1, index <= HPACKStaticTable.entries.count {
            return HPACKStaticTable.entries[index - 1]
        }
        let dynamicIndex = index - HPACKStaticTable.entries.count - 1
        guard dynamicIndex >= 0, dynamicIndex < dynamicTable.count else { throw HPACKError.invalidIndex(index) }
        return dynamicTable[dynamicIndex]
    }

    private func literal(prefixBits: Int, from reader: inout ByteCursor) throws -> HTTP2Header {
        let nameIndex = try HPACKInteger.decode(prefixBits: prefixBits, from: &reader)
        let name = nameIndex == 0 ? try Self.string(from: &reader) : try entry(at: nameIndex).name
        return HTTP2Header(name, try Self.string(from: &reader))
    }

    private static func string(from reader: inout ByteCursor) throws -> String {
        let huffman = try reader.peek() & 0x80 != 0
        let length = try HPACKInteger.decode(prefixBits: 7, from: &reader)
        let raw = try reader.read(length)
        let bytes = huffman ? try HPACKHuffman.decode(raw) : raw
        guard let string = String(bytes: bytes, encoding: .utf8) else { throw HPACKError.invalidUTF8 }
        return string
    }

    private mutating func insert(_ header: HTTP2Header) {
        let size = header.name.utf8.count + header.value.utf8.count + 32
        guard size <= maximumTableSize else {
            // An entry larger than the table empties it (RFC 7541 §4.4).
            dynamicTable.removeAll()
            dynamicTableSize = 0
            return
        }
        dynamicTable.insert(header, at: 0)
        dynamicTableSize += size
        evict()
    }

    private mutating func evict() {
        while dynamicTableSize > maximumTableSize, let last = dynamicTable.popLast() {
            dynamicTableSize -= last.name.utf8.count + last.value.utf8.count + 32
        }
    }
}

// MARK: - Primitives

enum HPACKInteger {
    static func encode(_ value: Int, prefixBits: Int, firstByteFlags: UInt8, into output: inout [UInt8]) {
        let limit = (1 << prefixBits) - 1
        if value < limit {
            output.append(firstByteFlags | UInt8(value))
            return
        }
        output.append(firstByteFlags | UInt8(limit))
        var remainder = value - limit
        while remainder >= 128 {
            output.append(UInt8(remainder % 128 + 128))
            remainder /= 128
        }
        output.append(UInt8(remainder))
    }

    static func decode(prefixBits: Int, from reader: inout ByteCursor) throws -> Int {
        let limit = (1 << prefixBits) - 1
        var value = Int(try reader.next() & UInt8(limit))
        guard value == limit else { return value }
        var shift = 0
        while true {
            let byte = try reader.next()
            guard shift <= 28 else { throw HPACKError.integerOverflow }
            value += Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { return value }
        }
    }
}

enum HPACKHuffman {
    /// A binary decoding tree built once from the RFC table: node pairs indexed by bit, with a
    /// leaf storing `-(symbol + 1)`.
    private static let tree: [[Int32]] = {
        var nodes: [[Int32]] = [[0, 0]]
        for symbol in 0..<HPACKHuffmanTable.codes.count {
            let code = HPACKHuffmanTable.codes[symbol]
            let length = Int(HPACKHuffmanTable.lengths[symbol])
            var node = 0
            for bitIndex in stride(from: length - 1, through: 0, by: -1) {
                let bit = Int((code >> UInt32(bitIndex)) & 1)
                if bitIndex == 0 {
                    nodes[node][bit] = -Int32(symbol + 1)
                } else {
                    if nodes[node][bit] == 0 {
                        nodes.append([0, 0])
                        nodes[node][bit] = Int32(nodes.count - 1)
                    }
                    node = Int(nodes[node][bit])
                }
            }
        }
        return nodes
    }()

    static func decode(_ bytes: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 8 / 5)
        var node = 0
        var depth = 0
        var paddingIsAllOnes = true
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let bit = Int((byte >> UInt8(shift)) & 1)
                let next = tree[node][bit]
                depth += 1
                paddingIsAllOnes = paddingIsAllOnes && bit == 1
                if next < 0 {
                    let symbol = Int(-next - 1)
                    // EOS inside the string is a decoding error (RFC 7541 §5.2).
                    guard symbol < 256 else { throw HPACKError.invalidHuffman }
                    output.append(UInt8(symbol))
                    node = 0
                    depth = 0
                    paddingIsAllOnes = true
                } else if next == 0 {
                    throw HPACKError.invalidHuffman
                } else {
                    node = Int(next)
                }
            }
        }
        // Padding is the most significant bits of EOS: at most seven, all ones.
        guard node == 0 || (depth <= 7 && paddingIsAllOnes) else { throw HPACKError.invalidHuffman }
        return output
    }

    /// Used only by tests to produce Huffman input; the encoder sends raw literals.
    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var accumulator: UInt64 = 0
        var bits = 0
        for byte in bytes {
            let code = UInt64(HPACKHuffmanTable.codes[Int(byte)])
            let length = Int(HPACKHuffmanTable.lengths[Int(byte)])
            accumulator = (accumulator << UInt64(length)) | code
            bits += length
            while bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> UInt64(bits)) & 0xFF))
            }
        }
        if bits > 0 {
            output.append(UInt8(((accumulator << UInt64(8 - bits)) | ((1 << UInt64(8 - bits)) - 1)) & 0xFF))
        }
        return output
    }
}

/// RFC 7541 Appendix A.
enum HPACKStaticTable {
    static let entries: [HTTP2Header] = [
        HTTP2Header(":authority", ""), HTTP2Header(":method", "GET"), HTTP2Header(":method", "POST"),
        HTTP2Header(":path", "/"), HTTP2Header(":path", "/index.html"), HTTP2Header(":scheme", "http"),
        HTTP2Header(":scheme", "https"), HTTP2Header(":status", "200"), HTTP2Header(":status", "204"),
        HTTP2Header(":status", "206"), HTTP2Header(":status", "304"), HTTP2Header(":status", "400"),
        HTTP2Header(":status", "404"), HTTP2Header(":status", "500"), HTTP2Header("accept-charset", ""),
        HTTP2Header("accept-encoding", "gzip, deflate"), HTTP2Header("accept-language", ""),
        HTTP2Header("accept-ranges", ""), HTTP2Header("accept", ""),
        HTTP2Header("access-control-allow-origin", ""), HTTP2Header("age", ""), HTTP2Header("allow", ""),
        HTTP2Header("authorization", ""), HTTP2Header("cache-control", ""),
        HTTP2Header("content-disposition", ""), HTTP2Header("content-encoding", ""),
        HTTP2Header("content-language", ""), HTTP2Header("content-length", ""),
        HTTP2Header("content-location", ""), HTTP2Header("content-range", ""),
        HTTP2Header("content-type", ""), HTTP2Header("cookie", ""), HTTP2Header("date", ""),
        HTTP2Header("etag", ""), HTTP2Header("expect", ""), HTTP2Header("expires", ""),
        HTTP2Header("from", ""), HTTP2Header("host", ""), HTTP2Header("if-match", ""),
        HTTP2Header("if-modified-since", ""), HTTP2Header("if-none-match", ""),
        HTTP2Header("if-range", ""), HTTP2Header("if-unmodified-since", ""),
        HTTP2Header("last-modified", ""), HTTP2Header("link", ""), HTTP2Header("location", ""),
        HTTP2Header("max-forwards", ""), HTTP2Header("proxy-authenticate", ""),
        HTTP2Header("proxy-authorization", ""), HTTP2Header("range", ""), HTTP2Header("referer", ""),
        HTTP2Header("refresh", ""), HTTP2Header("retry-after", ""), HTTP2Header("server", ""),
        HTTP2Header("set-cookie", ""), HTTP2Header("strict-transport-security", ""),
        HTTP2Header("transfer-encoding", ""), HTTP2Header("user-agent", ""), HTTP2Header("vary", ""),
        HTTP2Header("via", ""), HTTP2Header("www-authenticate", ""),
    ]

    static func exactIndex(name: String, value: String) -> Int? {
        entries.firstIndex { $0.name == name && $0.value == value }.map { $0 + 1 }
    }

    static func nameIndex(_ name: String) -> Int? {
        entries.firstIndex { $0.name == name }.map { $0 + 1 }
    }
}

/// A bounds-checked reader over a byte array; every protocol parser here reads through one.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    func peek() throws -> UInt8 {
        guard offset < bytes.count else { throw HPACKError.truncated }
        return bytes[offset]
    }

    mutating func next() throws -> UInt8 {
        let byte = try peek()
        offset += 1
        return byte
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw HPACKError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
