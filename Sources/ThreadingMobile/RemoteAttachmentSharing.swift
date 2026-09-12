import Foundation
import ThreadingRemoteKit

/// How the phone obtains one selected attachment before handing its device-local file URL to the
/// system share sheet.
///
/// The ordinary attachment route is intentionally capped at 24 MB. A larger movie is the one
/// exception already exposed by the Mac: it is copied to the temporary file in authenticated
/// one-megabyte ranges, so neither the phone nor the Mac materializes the complete recording.
enum RemoteAttachmentSharePlan: Equatable {
    case wholeFile
    case streamedVideo
    case unavailable

    static func resolve(
        kind: RemoteAttachmentKind,
        byteCount: Int64,
        offersVideoStreaming: Bool
    ) -> Self {
        guard byteCount >= 0 else { return .unavailable }
        if byteCount <= Int64(RemoteAttachmentUploadLimits.maximumBytesPerFile) {
            return .wholeFile
        }
        if kind == .video, offersVideoStreaming {
            return .streamedVideo
        }
        return .unavailable
    }
}

enum RemoteAttachmentShareError: LocalizedError {
    case unavailable
    case incompleteRange

    var errorDescription: String? {
        switch self {
        case .unavailable:
            MobileL10n.string("This attachment is too large to share from iPhone.")
        case .incompleteRange:
            MobileL10n.string("The attachment changed while it was being prepared.")
        }
    }
}

struct RemoteAttachmentStagedShareFile: Equatable, Sendable {
    let fileURL: URL
    let directoryURL: URL
}

/// Device-local custody for the selected share item.
///
/// Expected ordinary files are at most 24 MB. A recording may be much larger; that path retains
/// only one `RemoteAttachmentVideo.maximumChunkBytes` piece at a time and writes on a detached
/// worker. Exactly one temporary file exists for the active share sheet, and its directory is
/// removed when that sheet closes.
struct RemoteAttachmentShareStager: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL = FileManager.default.temporaryDirectory) {
        self.rootDirectory = rootDirectory
    }

    func stage(data: Data, named name: String) async throws -> RemoteAttachmentStagedShareFile {
        try await runOffMain {
            let destination = try makeDestination(named: name)
            do {
                let handle = try makeFile(at: destination.fileURL)
                defer { try? handle.close() }
                try Task.checkCancellation()
                try handle.write(contentsOf: data)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination.directoryURL)
                throw error
            }
        }
    }

    func stageStream(
        named name: String,
        byteCount: Int64,
        chunkByteCount: Int64 = Int64(RemoteAttachmentVideo.maximumChunkBytes),
        fetch: @escaping @Sendable (Range<Int64>) async throws -> Data
    ) async throws -> RemoteAttachmentStagedShareFile {
        try await runOffMain {
            guard byteCount >= 0, chunkByteCount > 0 else {
                throw RemoteAttachmentShareError.unavailable
            }
            let destination = try makeDestination(named: name)
            do {
                let handle = try makeFile(at: destination.fileURL)
                defer { try? handle.close() }
                var offset: Int64 = 0
                while offset < byteCount {
                    try Task.checkCancellation()
                    let upper = min(byteCount, offset + chunkByteCount)
                    let range = offset ..< upper
                    let data = try await fetch(range)
                    try Task.checkCancellation()
                    guard data.count == Int(range.count) else {
                        throw RemoteAttachmentShareError.incompleteRange
                    }
                    try handle.write(contentsOf: data)
                    offset = upper
                }
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination.directoryURL)
                throw error
            }
        }
    }

    static func safeFileName(_ name: String) -> String {
        let lastComponent = (name as NSString).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else {
            return MobileL10n.string("Attachment")
        }
        return lastComponent
    }

    private func runOffMain<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func makeDestination(named name: String) throws -> RemoteAttachmentStagedShareFile {
        let directory = rootDirectory.appendingPathComponent(
            "ThreadingMobileAttachmentShare-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return RemoteAttachmentStagedShareFile(
            fileURL: directory.appendingPathComponent(Self.safeFileName(name)),
            directoryURL: directory
        )
    }

    private func makeFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }
}

struct RemoteAttachmentShareRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let attachment: RemoteAttachmentDTO
    let client: RemoteClient
    let cachedData: Data?
    let loadsRemotely: Bool
    let offersVideoStreaming: Bool

    func prepare(
        using stager: RemoteAttachmentShareStager
    ) async throws -> RemoteAttachmentStagedShareFile {
        if let cachedData {
            return try await stager.stage(data: cachedData, named: attachment.name)
        }
        guard loadsRemotely else { throw RemoteAttachmentShareError.unavailable }

        switch RemoteAttachmentSharePlan.resolve(
            kind: attachment.kind,
            byteCount: attachment.byteCount,
            offersVideoStreaming: offersVideoStreaming
        ) {
        case .wholeFile:
            return try await MobileMediaDownloadLimiter.previews.run {
                let data = try await client.attachmentData(
                    sessionID: sessionID,
                    id: attachment.id
                )
                return try await stager.stage(data: data, named: attachment.name)
            }
        case .streamedVideo:
            return try await MobileMediaDownloadLimiter.previews.run {
                try await stager.stageStream(
                    named: attachment.name,
                    byteCount: attachment.byteCount
                ) { range in
                    try await client.attachmentVideoData(
                        sessionID: sessionID,
                        id: attachment.id,
                        range: range,
                        totalBytes: attachment.byteCount
                    )
                }
            }
        case .unavailable:
            throw RemoteAttachmentShareError.unavailable
        }
    }
}
