import Compression
import Foundation

/// Writes a ZIP archive in memory.
///
/// Nothing in the app read or wrote one before the compare export needed to hand someone a
/// document *and* the two files it draws as one attachment. A package dependency for a format
/// whose three records have not changed since 1993 is the worse trade: this writes the local
/// header, the central directory and the end record, and nothing else.
///
/// Deliberately not general — no Zip64, no encryption, no directory entries, no reading. The
/// 32-bit fields are *checked* rather than silently truncated: the compare tab caps each side
/// at `CompareDefaults.maximumBytes`, so a legitimate export cannot reach them, and an
/// illegitimate one says so instead of writing an archive that unzips to nonsense.
enum ZipArchive {

    // MARK: - Entry

    /// One file in the archive.
    struct Entry: Sendable {
        /// Where the file lands when the archive is expanded: `/`-separated, relative, and with
        /// no `..` component. The initializer is the only place that can be violated.
        let path: String
        let data: Data

        init(path: String, data: Data) {
            self.path = ZipArchive.sanitize(path)
            self.data = data
        }
    }

    enum Failure: LocalizedError {
        case entryTooLarge(path: String)
        case tooManyEntries(count: Int)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let path):
                return L10n.format("“%@” is too large to put in a zip archive.", path)
            case .tooManyEntries(let count):
                return L10n.format("%lld files is more than a zip archive can hold.", count)
            }
        }
    }

    // MARK: - Format

    /// The record signatures and fixed fields, named rather than repeated as magic numbers.
    private enum Format {
        static let localHeaderSignature: UInt32 = 0x0403_4b50
        static let centralHeaderSignature: UInt32 = 0x0201_4b50
        static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

        /// 2.0 — the version that introduced deflate, which is the newest feature used here.
        static let versionNeeded: UInt16 = 20
        /// Unix (3) in the high byte, the same 2.0 in the low one.
        static let versionMadeBy: UInt16 = 0x0314

        /// Bit 11: the name and comment are UTF-8. Without it a name outside ASCII is read in
        /// the extractor's own code page, which is how a Swedish filename becomes mojibake.
        static let utf8NameFlag: UInt16 = 1 << 11

        static let stored: UInt16 = 0
        static let deflated: UInt16 = 8

        /// `0644` for a file, in the high 16 bits where Unix permissions live.
        static let unixFileAttributes: UInt32 = 0o100_644 << 16

        /// The oldest moment MS-DOS can name — what a date before 1980 clamps to.
        static let earliestYear = 1980
    }

    // MARK: - Public Methods

    /// Packs `entries` into one archive.
    ///
    /// `modified` stamps every entry, because a zip records a modification time per file and an
    /// export is one moment: the two sides being compared may be years apart on disk, and
    /// carrying that in would date the *export* to whenever the older file was last written.
    static func archive(_ entries: [Entry], modified: Date) throws -> Data {
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
            guard name.count <= Int(UInt16.max) else {
                throw Failure.entryTooLarge(path: entry.path)
            }

            let payload = compress(entry.data)
            guard payload.bytes.count <= Int(UInt32.max) else {
                throw Failure.entryTooLarge(path: entry.path)
            }
            let crc = crc32(entry.data)
            let offset = body.count

            // Local file header, then the bytes. No data descriptor: the sizes are known
            // before the header is written, which is the whole reason this builds in memory.
            body.append(littleEndian: Format.localHeaderSignature)
            body.append(littleEndian: Format.versionNeeded)
            body.append(littleEndian: Format.utf8NameFlag)
            body.append(littleEndian: payload.method)
            body.append(littleEndian: stamp.time)
            body.append(littleEndian: stamp.date)
            body.append(littleEndian: crc)
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
            directory.append(littleEndian: crc)
            directory.append(littleEndian: UInt32(payload.bytes.count))
            directory.append(littleEndian: UInt32(entry.data.count))
            directory.append(littleEndian: UInt16(name.count))
            directory.append(littleEndian: UInt16(0))  // extra field
            directory.append(littleEndian: UInt16(0))  // comment
            directory.append(littleEndian: UInt16(0))  // disk number
            directory.append(littleEndian: UInt16(0))  // internal attributes
            directory.append(littleEndian: Format.unixFileAttributes)
            directory.append(littleEndian: UInt32(offset))
            directory.append(name)
        }

        guard body.count + directory.count <= Int(UInt32.max) else {
            throw Failure.entryTooLarge(path: entries.last?.path ?? "")
        }

        var archive = body
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(littleEndian: Format.endOfCentralDirectorySignature)
        archive.append(littleEndian: UInt16(0))  // this disk
        archive.append(littleEndian: UInt16(0))  // disk the directory starts on
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt32(directory.count))
        archive.append(littleEndian: UInt32(directoryOffset))
        archive.append(littleEndian: UInt16(0))  // comment
        return archive
    }

    // MARK: - Private Methods

    /// Deflates, and keeps the result only if it is actually smaller.
    ///
    /// The two images in an export are already-compressed PNGs, where deflate reliably spends
    /// time to produce more bytes than it was given; the document beside them is HTML, where it
    /// saves most of the file. Storing the ones that do not shrink is what lets both live in the
    /// same archive without a rule about which is which.
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
                // `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) — the stream ZIP method 8 wants,
                // with no zlib header of its own to strip.
                return compression_encode_buffer(
                    destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }

        // 0 means "it did not fit in the buffer", which for a buffer the size of the input is
        // the same answer as "it did not help".
        guard written > 0, written < data.count else { return (data, Format.stored) }
        deflated.removeSubrange(written...)
        return (deflated, Format.deflated)
    }

    /// The archive path an entry is written at: no leading slash, no `..`, `/`-separated.
    ///
    /// A zip that expands outside the folder it was extracted into is the oldest bug this
    /// format has. Nothing here builds a path from user input today — which is exactly when to
    /// put the rule in, rather than after something does.
    private static func sanitize(_ path: String) -> String {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
        return components.joined(separator: "/")
    }

    /// MS-DOS packed date and time: seconds in units of two, years from 1980.
    private static func dosTimestamp(from date: Date) -> (date: UInt16, time: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(parts.year ?? Format.earliestYear, Format.earliestYear)
        let packedDate =
            UInt16((year - Format.earliestYear) << 9)
            | UInt16((parts.month ?? 1) << 5)
            | UInt16(parts.day ?? 1)
        let packedTime =
            UInt16((parts.hour ?? 0) << 11)
            | UInt16((parts.minute ?? 0) << 5)
            | UInt16((parts.second ?? 0) / 2)
        return (packedDate, packedTime)
    }

    // MARK: - CRC-32

    /// The standard reflected CRC-32 table (polynomial 0xEDB88320), built once.
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    /// Exposed to the test target: a CRC nobody checks is a CRC nobody notices is wrong, and
    /// the known vector for "123456789" is the cheapest way to notice.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-Endian Appends

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
