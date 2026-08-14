import Compression
import Foundation

/// A bounded, read-only ZIP central-directory reader.
///
/// Every ceiling is stated by the caller, because the two archives Threading opens are not the
/// same shape of risk: a classic skin is a hobbyist's download, and a `.lottie` container may have
/// been written by an agent thirty seconds ago. What they share is the attack, so they share the
/// reader: entry count, per-entry size, total expanded size, encryption, unsupported compression
/// and path traversal are all refused here rather than in each caller.
///
/// Deliberately central-directory-only and non-streaming. An archive is read once, entirely from a
/// `Data` the caller already bounded, so there is no partially-expanded state for a malformed
/// archive to leave behind.
struct BoundedZipArchive {

    struct Limits: Equatable, Sendable {
        var maximumEntryCount: Int
        var maximumEntryBytes: Int
        var maximumExpandedBytes: Int

        init(
            maximumEntryCount: Int,
            maximumEntryBytes: Int,
            maximumExpandedBytes: Int
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumEntryBytes = maximumEntryBytes
            self.maximumExpandedBytes = maximumExpandedBytes
        }
    }

    enum Failure: Error, Equatable {
        case invalidArchive
        case encryptedArchive
        case unsupportedCompression
        case tooManyEntries
        case expandedArchiveTooLarge
    }

    struct Entry: Equatable {
        let name: String
        let expandedSize: Int
        fileprivate let flags: UInt16
        fileprivate let method: UInt16
        fileprivate let checksum: UInt32
        fileprivate let compressedSize: Int
        fileprivate let localHeaderOffset: Int
    }

    private let bytes: Data
    let entries: [Entry]

    init(data: Data, limits: Limits) throws {
        bytes = data
        guard let end = Self.endRecordOffset(in: data),
              let disk = data.zipUInt16(at: end + 4),
              let directoryDisk = data.zipUInt16(at: end + 6),
              let entriesOnDisk = data.zipUInt16(at: end + 8),
              let entryCount = data.zipUInt16(at: end + 10),
              let directorySize = data.zipUInt32(at: end + 12),
              let directoryOffset = data.zipUInt32(at: end + 16),
              disk == 0,
              directoryDisk == 0,
              entriesOnDisk == entryCount,
              entryCount != UInt16.max,
              directorySize != UInt32.max,
              directoryOffset != UInt32.max else {
            throw Failure.invalidArchive
        }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw Failure.tooManyEntries
        }

        let start = Int(directoryOffset)
        let size = Int(directorySize)
        guard start >= 0, size >= 0, start <= data.count,
              size <= data.count - start, start + size <= end else {
            throw Failure.invalidArchive
        }

        var parsed: [Entry] = []
        var cursor = start
        var expandedTotal = 0
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= start + size,
                  data.zipUInt32(at: cursor) == 0x0201_4B50,
                  let flags = data.zipUInt16(at: cursor + 8),
                  let method = data.zipUInt16(at: cursor + 10),
                  let checksum = data.zipUInt32(at: cursor + 16),
                  let compressed = data.zipUInt32(at: cursor + 20),
                  let expanded = data.zipUInt32(at: cursor + 24),
                  let nameLength = data.zipUInt16(at: cursor + 28),
                  let extraLength = data.zipUInt16(at: cursor + 30),
                  let commentLength = data.zipUInt16(at: cursor + 32),
                  let localOffset = data.zipUInt32(at: cursor + 42) else {
                throw Failure.invalidArchive
            }
            guard compressed != UInt32.max, expanded != UInt32.max,
                  localOffset != UInt32.max else {
                throw Failure.invalidArchive
            }

            let variableLength = Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard cursor + 46 + variableLength <= start + size else {
                throw Failure.invalidArchive
            }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + Int(nameLength))
            guard let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) else {
                throw Failure.invalidArchive
            }

            let expandedInt = Int(expanded)
            guard flags & 0x1 == 0 else { throw Failure.encryptedArchive }
            guard method == 0 || method == 8 else { throw Failure.unsupportedCompression }
            guard expandedInt <= limits.maximumEntryBytes,
                  Int(compressed) <= limits.maximumEntryBytes else {
                throw Failure.expandedArchiveTooLarge
            }
            guard expandedTotal <= limits.maximumExpandedBytes - expandedInt else {
                throw Failure.expandedArchiveTooLarge
            }
            expandedTotal += expandedInt

            parsed.append(Entry(
                name: name,
                expandedSize: expandedInt,
                flags: flags,
                method: method,
                checksum: checksum,
                compressedSize: Int(compressed),
                localHeaderOffset: Int(localOffset)
            ))
            cursor += 46 + variableLength
        }
        guard cursor == start + size else { throw Failure.invalidArchive }
        entries = parsed
    }

    /// The entry at an exact archive-relative path.
    ///
    /// Traversal is refused rather than normalized away: an archive naming `../../keys.json` is
    /// not a path to sanitize, it is an archive to distrust.
    func data(atPath path: String) throws -> Data? {
        let wanted = Self.normalized(path)
        guard !wanted.isEmpty else { return nil }
        guard let entry = entries.first(where: { Self.normalized($0.name) == wanted }) else {
            return nil
        }
        return try expand(entry)
    }

    /// The last entry whose *basename* matches, case-insensitively.
    ///
    /// The classic-skin idiom: those archives put their files anywhere and the last one wins.
    func data(forLastEntryNamed names: [String]) throws -> Data? {
        let wanted = Set(names.map { $0.lowercased() })
        guard let entry = entries.last(where: {
            wanted.contains(Self.basename($0.name))
        }) else { return nil }
        return try expand(entry)
    }

    /// Every entry whose archive-relative path is inside `directory`, traversal refused.
    func entries(inDirectory directory: String) -> [Entry] {
        let prefix = Self.normalized(directory) + "/"
        return entries.filter {
            let normalized = Self.normalized($0.name)
            return !normalized.isEmpty && normalized.hasPrefix(prefix)
        }
    }

    // MARK: - Expansion

    private func expand(_ entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw Failure.encryptedArchive }
        guard entry.method == 0 || entry.method == 8 else {
            throw Failure.unsupportedCompression
        }

        let offset = entry.localHeaderOffset
        guard offset >= 0, offset + 30 <= bytes.count,
              bytes.zipUInt32(at: offset) == 0x0403_4B50,
              let localFlags = bytes.zipUInt16(at: offset + 6),
              let localMethod = bytes.zipUInt16(at: offset + 8),
              let nameLength = bytes.zipUInt16(at: offset + 26),
              let extraLength = bytes.zipUInt16(at: offset + 28),
              localFlags & 0x1 == 0,
              localMethod == entry.method else {
            throw Failure.invalidArchive
        }
        let payloadStart = offset + 30 + Int(nameLength) + Int(extraLength)
        guard payloadStart <= bytes.count,
              entry.compressedSize <= bytes.count - payloadStart else {
            throw Failure.invalidArchive
        }
        let payload = bytes.subdata(
            in: payloadStart..<payloadStart + entry.compressedSize
        )

        let expanded: Data
        switch entry.method {
        case 0:
            guard payload.count == entry.expandedSize else { throw Failure.invalidArchive }
            expanded = payload
        default:
            expanded = try Self.inflate(payload, expectedSize: entry.expandedSize)
        }
        guard ZipArchive.crc32(expanded) == entry.checksum else {
            throw Failure.invalidArchive
        }
        return expanded
    }

    // MARK: - Paths

    /// An archive-relative path with separators normalized, or the empty string when the entry
    /// tries to leave the archive.
    static func normalized(_ name: String) -> String {
        let unified = name.replacingOccurrences(of: "\\", with: "/")
        guard !unified.hasPrefix("/") else { return "" }
        var components: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return "" }
            components.append(String(component))
        }
        return components.joined(separator: "/")
    }

    private static func basename(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init)?.lowercased() ?? ""
    }

    private static func endRecordOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let earliest = max(0, data.count - (65_535 + 22))
        var cursor = data.count - 22
        while cursor >= earliest {
            if data.zipUInt32(at: cursor) == 0x0605_4B50,
               let commentLength = data.zipUInt16(at: cursor + 20),
               cursor + 22 + Int(commentLength) == data.count {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            guard source.isEmpty else { throw Failure.invalidArchive }
            return Data()
        }
        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { output -> Int in
            guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return source.withUnsafeBytes { input -> Int in
                guard let inputBase = input.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    outputBase,
                    expectedSize,
                    inputBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Failure.invalidArchive }
        return destination
    }
}

private extension Data {
    func zipUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func zipUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
