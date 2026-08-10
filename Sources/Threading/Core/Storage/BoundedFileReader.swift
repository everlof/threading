import Foundation

enum BoundedFileReadError: Error, Equatable {
    case notRegularFile
    case exceedsLimit(maximumBytes: Int)
}

/// Reads a regular file without first trusting its reported size.
///
/// A metadata preflight is useful for a quick refusal but is not an authority: the file can grow
/// between `resourceValues` and `Data(contentsOf:)`, and the latter allocates the new whole size.
/// Every externally selected or provider-named file which needs bytes should cross this boundary
/// instead. One byte past the limit distinguishes an exact-limit file from a truncated one.
enum BoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw BoundedFileReadError.notRegularFile }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        // The limit is a refusal boundary, not an expected allocation size. Keep the initial
        // reservation small so callers with a generous safety cap do not pay that cap up front.
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw BoundedFileReadError.exceedsLimit(maximumBytes: maximumBytes)
        }
        return data
    }
}

enum BoundedDirectoryReadError: LocalizedError, Equatable {
    case exceedsLimit(maximumEntries: Int)

    var errorDescription: String? {
        switch self {
        case .exceedsLimit(let maximumEntries):
            return "The directory contains more than \(maximumEntries) entries."
        }
    }
}

/// Enumerates one directory level without first materializing every name.
///
/// The allowance counts every visible entry before a caller applies its own filename filter. A
/// directory full of irrelevant names must not make discovery unbounded or hide recognized state
/// beyond the part a caller happened to inspect.
enum BoundedDirectoryReader {
    static func shallowContents(
        of directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey] = [],
        maximumEntries: Int,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        precondition(maximumEntries >= 0 && maximumEntries < Int.max)

        var enumerationError: Swift.Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw enumerationError ?? CocoaError(.fileReadNoSuchFile)
        }

        var urls: [URL] = []
        urls.reserveCapacity(min(maximumEntries, 64))
        while let entry = enumerator.nextObject() {
            guard let url = entry as? URL else { continue }
            guard urls.count < maximumEntries else {
                throw BoundedDirectoryReadError.exceedsLimit(
                    maximumEntries: maximumEntries
                )
            }
            urls.append(url)
        }
        if let enumerationError { throw enumerationError }
        return urls
    }
}
