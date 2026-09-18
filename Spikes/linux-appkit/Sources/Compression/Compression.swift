import CZlib
import Foundation

/// Apple's Compression framework, reduced to the two symbols Threading actually uses, on top of
/// zlib.
///
/// `ThreadingRemoteKit/GzipWriter.swift` calls `compression_encode_buffer` with
/// `COMPRESSION_ZLIB`. That is the entire dependency — and it is worth noticing *why* the spike
/// had to deal with it at all: the persistence slice never compresses anything, but `GzipWriter`
/// lives in the same module as the types it does need, and a module compiles whole. That is the
/// file-granularity finding one level up.
///
/// **The naming is a trap and this is the substance of the shim.** Apple's `COMPRESSION_ZLIB`
/// produces a *raw DEFLATE* stream with no zlib header or trailer — which is exactly what a gzip
/// container wants, and why `GzipWriter` can add its own 18 bytes of framing around the result.
/// zlib's own `compress2()` does the opposite: it writes a zlib header. Using it here would
/// produce a stream that looks compressed, passes every length check in the caller, and is not
/// valid gzip. So this goes through `deflateInit2_` with a negative window size, which is zlib's
/// way of saying "no header".
public typealias compression_algorithm = Int32

public let COMPRESSION_ZLIB: compression_algorithm = 0x205

/// Returns the number of bytes written, or 0 if the output did not fit — the same contract the
/// caller already checks for.
public func compression_encode_buffer(
    _ destination: UnsafeMutablePointer<UInt8>,
    _ destinationSize: Int,
    _ source: UnsafePointer<UInt8>,
    _ sourceSize: Int,
    _ scratch: UnsafeMutableRawPointer?,
    _ algorithm: compression_algorithm
) -> Int {
    guard algorithm == COMPRESSION_ZLIB, destinationSize > 0, sourceSize >= 0 else { return 0 }

    var stream = z_stream()
    let version = ZLIB_VERSION
    let initialized = version.withCString { versionPointer in
        deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,               // negative window size: raw DEFLATE, no zlib header or trailer.
            8,                 // the library's default memory level.
            Z_DEFAULT_STRATEGY,
            versionPointer,
            Int32(MemoryLayout<z_stream>.size)
        )
    }
    guard initialized == Z_OK else { return 0 }
    defer { deflateEnd(&stream) }

    return withExtendedLifetime(stream) { () -> Int in
        stream.next_in = UnsafeMutablePointer(mutating: source)
        stream.avail_in = uInt(sourceSize)
        stream.next_out = destination
        stream.avail_out = uInt(destinationSize)

        let result = deflate(&stream, Z_FINISH)
        // Anything other than a complete stream means it did not fit, which the caller treats as
        // "not worth compressing" rather than as an error.
        guard result == Z_STREAM_END else { return 0 }
        return destinationSize - Int(stream.avail_out)
    }
}
