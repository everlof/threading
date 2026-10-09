#if canImport(Compression)
import Compression
#else
import ThreadingRemoteZlib
#endif
import Foundation

/// Raw DEFLATE for the ZIP and gzip containers. Output is bounded by the input size.
enum RawDeflate {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        #if !canImport(Compression)
        guard data.count <= Int(UInt32.max) else { return nil }
        #endif

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
#if canImport(Compression)
                // `COMPRESSION_ZLIB` produces the raw DEFLATE stream required by ZIP method 8.
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
#else
                var stream = z_stream()
                guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS,
                                    8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
                defer { deflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: sourceBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = destinationBase
                stream.avail_out = uInt(capacity)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
                return Int(stream.total_out)
#endif
            }
        }

        guard written > 0, written < data.count else { return nil }
        deflated.removeSubrange(written...)
        return deflated
    }
}
