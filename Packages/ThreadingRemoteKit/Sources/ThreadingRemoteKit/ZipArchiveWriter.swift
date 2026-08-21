import Compression
import Foundation

/// Writes a small, standards-compatible ZIP archive in memory on macOS and iOS.
///
/// Deliberately not general-purpose: there is no Zip64, encryption, directory entry, or reader.
/// Every field that the classic ZIP format stores as a 16- or 32-bit value is checked before it
/// is narrowed, so an oversized export fails instead of producing a corrupt archive.
public enum ZipArchiveWriter {

    // MARK: - Entry

    public struct Entry: Sendable {
        /// The relative, `/`-separated path written into the archive.
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = ZipArchiveWriter.sanitize(path)
            self.data = data
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case entryTooLarge(path: String)
        case tooManyEntries(count: Int)
    }

    // MARK: - Format

    private enum Format {
        static let localHeaderSignature: UInt32 = 0x0403_4b50
        static let centralHeaderSignature: UInt32 = 0x0201_4b50
        static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

        /// ZIP 2.0 introduced deflate, the newest feature this writer uses.
        static let versionNeeded: UInt16 = 20
        /// Unix (3) in the high byte and ZIP 2.0 in the low byte.
        static let versionMadeBy: UInt16 = 0x0314
        /// Bit 11 declares file names as UTF-8.
        static let utf8NameFlag: UInt16 = 1 << 11

        static let stored: UInt16 = 0
        static let deflated: UInt16 = 8
        /// A regular `0644` file, in the high 16 bits where Unix permissions live.
        static let unixFileAttributes: UInt32 = 0o100_644 << 16

        static let earliestYear = 1980
        static let latestYear = 2107
    }

    // MARK: - Public Methods

    public static func archive(_ entries: [Entry], modified: Date) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw Failure.tooManyEntries(count: entries.count)
        }

        let stamp = dosTimestamp(from: modified)
        var body = Data()
        var directory = Data()

        for entry in entries {
            guard entry.data.count <= Int(UInt32.max) else {
                throw Failure.entryTooLarge(path: entry.path)
            }
            let name = Data(entry.path.utf8)
            guard name.count <= Int(UInt16.max), body.count <= Int(UInt32.max) else {
                throw Failure.entryTooLarge(path: entry.path)
            }

            let payload = compress(entry.data)
            guard payload.bytes.count <= Int(UInt32.max) else {
                throw Failure.entryTooLarge(path: entry.path)
            }
            let checksum = crc32(entry.data)
            let offset = UInt32(body.count)

            body.append(littleEndian: Format.localHeaderSignature)
            body.append(littleEndian: Format.versionNeeded)
            body.append(littleEndian: Format.utf8NameFlag)
            body.append(littleEndian: payload.method)
            body.append(littleEndian: stamp.time)
            body.append(littleEndian: stamp.date)
            body.append(littleEndian: checksum)
            body.append(littleEndian: UInt32(payload.bytes.count))
            body.append(littleEndian: UInt32(entry.data.count))
            body.append(littleEndian: UInt16(name.count))
            body.append(littleEndian: UInt16(0))
            body.append(name)
            body.append(payload.bytes)

            directory.append(littleEndian: Format.centralHeaderSignature)
            directory.append(littleEndian: Format.versionMadeBy)
            directory.append(littleEndian: Format.versionNeeded)
            directory.append(littleEndian: Format.utf8NameFlag)
            directory.append(littleEndian: payload.method)
            directory.append(littleEndian: stamp.time)
            directory.append(littleEndian: stamp.date)
            directory.append(littleEndian: checksum)
            directory.append(littleEndian: UInt32(payload.bytes.count))
            directory.append(littleEndian: UInt32(entry.data.count))
            directory.append(littleEndian: UInt16(name.count))
            directory.append(littleEndian: UInt16(0))  // extra field
            directory.append(littleEndian: UInt16(0))  // comment
            directory.append(littleEndian: UInt16(0))  // disk number
            directory.append(littleEndian: UInt16(0))  // internal attributes
            directory.append(littleEndian: Format.unixFileAttributes)
            directory.append(littleEndian: offset)
            directory.append(name)
        }

        guard body.count <= Int(UInt32.max) - directory.count else {
            throw Failure.entryTooLarge(path: entries.last?.path ?? "")
        }

        var archive = body
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(littleEndian: Format.endOfCentralDirectorySignature)
        archive.append(littleEndian: UInt16(0))  // this disk
        archive.append(littleEndian: UInt16(0))  // disk the directory starts on
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt32(directory.count))
        archive.append(littleEndian: directoryOffset)
        archive.append(littleEndian: UInt16(0))  // comment
        return archive
    }

    /// The standard reflected CRC-32 used by ZIP entries.
    public static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum = (checksum >> 8)
                ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xFF)]
        }
        return checksum ^ 0xFFFF_FFFF
    }

    // MARK: - Private Methods

    private static func compress(_ data: Data) -> (bytes: Data, method: UInt16) {
        guard !data.isEmpty else { return (data, Format.stored) }

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
                // `COMPRESSION_ZLIB` produces the raw DEFLATE stream required by ZIP method 8.
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

        guard written > 0, written < data.count else { return (data, Format.stored) }
        deflated.removeSubrange(written...)
        return (deflated, Format.deflated)
    }

    private static func sanitize(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private static func dosTimestamp(from date: Date) -> (date: UInt16, time: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = min(
            max(parts.year ?? Format.earliestYear, Format.earliestYear),
            Format.latestYear
        )
        let packedDate = UInt16((year - Format.earliestYear) << 9)
            | UInt16((parts.month ?? 1) << 5)
            | UInt16(parts.day ?? 1)
        let packedTime = UInt16((parts.hour ?? 0) << 11)
            | UInt16((parts.minute ?? 0) << 5)
            | UInt16((parts.second ?? 0) / 2)
        return (packedDate, packedTime)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
