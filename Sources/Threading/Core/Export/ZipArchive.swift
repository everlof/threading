import Foundation
import ThreadingRemoteKit

/// The macOS app's localized facade over the cross-platform ZIP writer.
enum ZipArchive {

    struct Entry: Sendable {
        let path: String
        let data: Data

        init(path: String, data: Data) {
            let entry = ZipArchiveWriter.Entry(path: path, data: data)
            self.path = entry.path
            self.data = entry.data
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

    static func archive(_ entries: [Entry], modified: Date) throws -> Data {
        do {
            return try ZipArchiveWriter.archive(
                entries.map { ZipArchiveWriter.Entry(path: $0.path, data: $0.data) },
                modified: modified
            )
        } catch let failure as ZipArchiveWriter.Failure {
            switch failure {
            case .entryTooLarge(let path):
                throw Failure.entryTooLarge(path: path)
            case .tooManyEntries(let count):
                throw Failure.tooManyEntries(count: count)
            }
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ZipArchiveWriter.crc32(data)
    }
}
