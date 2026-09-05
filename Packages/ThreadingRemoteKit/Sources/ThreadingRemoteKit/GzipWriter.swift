import Compression
import Foundation

/// Wraps a body in the gzip container (RFC 1952) so an HTTP response can carry
/// `Content-Encoding: gzip` and every `URLSession` — which advertises `gzip` by default and
/// inflates transparently — receives the plain bytes.
///
/// Apple's `Compression` framework produces the raw DEFLATE stream and nothing else; the ten-byte
/// header and the eight-byte CRC-32/size trailer around it are what make it gzip rather than
/// ZIP method 8, and `ZipArchiveWriter` already owns the checksum. Deliberately small: no
/// streaming, no levels, no reader. A body the encoder cannot shrink is reported as nil so the
/// caller sends it uncompressed instead of paying the header for nothing.
public enum GzipWriter {

    // MARK: - Format

    private enum Format {
        static let magic: [UInt8] = [0x1f, 0x8b]
        static let deflate: UInt8 = 8
        static let noFlags: UInt8 = 0
        static let noTimestamp: [UInt8] = [0, 0, 0, 0]
        static let noExtraFlags: UInt8 = 0
        /// "Unknown" operating system, which is what every gzip written by a library says.
        static let unknownOS: UInt8 = 255
    }

    // MARK: - Public Methods

    /// The gzip container for `data`, or nil when compression would not make it smaller.
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty, let deflated = deflate(data) else { return nil }

        var gzip = Data(capacity: deflated.count + 18)
        gzip.append(contentsOf: Format.magic)
        gzip.append(Format.deflate)
        gzip.append(Format.noFlags)
        gzip.append(contentsOf: Format.noTimestamp)
        gzip.append(Format.noExtraFlags)
        gzip.append(Format.unknownOS)
        gzip.append(deflated)
        gzip.append(littleEndian: ZipArchiveWriter.crc32(data))
        gzip.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return gzip
    }

    // MARK: - Private Methods

    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        // The gzip framing costs 18 bytes; a stream that did not save at least that much is
        // not worth wrapping.
        guard written > 0, written + 18 < data.count else { return nil }
        deflated.removeSubrange(written...)
        return deflated
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
