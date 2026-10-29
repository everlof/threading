#if os(Linux)
import Foundation
@testable import CoreSlice

/// The Linux attachment document uses the production store and SQLite row. All codec, path
/// authority and database work runs on one utility lane, never in an SDL input or layout turn.
final class LinuxAttachmentPersistence: @unchecked Sendable {
    private let storePath: String
    private let copiesRoot: URL
    private let worker = DispatchQueue(label: "threading.linux.attachments", qos: .utility)
    private let rootLock = NSLock()
    private var projectRoots: [SessionID: URL] = [:]
    private var agentKinds: [SessionID: AgentKind] = [:]
    /// Worker-owned. A save cannot replace old rows until their checked load is installed.
    private var writeReady: Set<SessionID> = []

    init(storePath: String) {
        self.storePath = storePath
        copiesRoot = URL(fileURLWithPath: storePath, isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    /// Prepares one selected session before it can be read or scanned. A future or corrupt
    /// document throws rather than being silently replaced by the next newly found file.
    func load(sessionID: SessionID) async throws -> [SessionAttachment] {
        return try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    let (projectRoot, kind, payload) = try LinuxStoreMutation.withDatabase(at: storePath) {
                        database -> (URL, AgentKind, String?) in
                        guard let record = try database.sessionRecord(id: sessionID) else {
                            throw WindowFailure("attachment session is unavailable")
                        }
                        let root = URL(fileURLWithPath:
                            record.session.workingDirectory(in: record.project), isDirectory: true)
                        return (root, record.session.kind,
                                try database.attachmentsPayload(for: sessionID))
                    }
                    let rows = try payload.map {
                        try SessionAttachmentPersistenceCodec.restore(
                            $0, sessionID: sessionID, referenceRoot: projectRoot,
                            copiesRoot: copiesRoot.appendingPathComponent(sessionID.uuidString,
                                                                         isDirectory: true)
                        )
                    } ?? []
                    setProjectRoot(projectRoot, kind: kind, for: sessionID)
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func makeStore() -> SessionAttachmentStore {
        SessionAttachmentStore(
            persistPreparedRows: { [self] rows, id in save(rows, for: id) },
            removePersisted: { [self] id in remove(id) },
            copiesDirectory: { [self] in copiesRoot },
            referenceRoot: { [self] id in projectRoot(for: id) },
            allowsFilesOutsideProject: { LinuxGeneralSettings.includesAttachmentsOutsideProject }
        )
    }

    func setProjectRoot(_ root: URL, kind: AgentKind? = nil, for sessionID: SessionID) {
        rootLock.lock()
        projectRoots[sessionID] = root
        if let kind { agentKinds[sessionID] = kind }
        rootLock.unlock()
    }

    func markPreparedInstalled(for sessionID: SessionID) {
        worker.async { [self] in writeReady.insert(sessionID) }
    }

    func executionRoot(for sessionID: SessionID) -> URL? {
        projectRoot(for: sessionID)
    }

    func agentKind(for sessionID: SessionID) -> AgentKind? {
        rootLock.lock()
        defer { rootLock.unlock() }
        return agentKinds[sessionID]
    }

    private func projectRoot(for sessionID: SessionID) -> URL? {
        rootLock.lock()
        defer { rootLock.unlock() }
        return projectRoots[sessionID]
    }

    private func save(_ rows: [SessionAttachment], for sessionID: SessionID) {
        worker.async { [self] in
            do {
                guard writeReady.contains(sessionID) else { return }
                guard let projectRoot = projectRoot(for: sessionID) else {
                    throw WindowFailure("attachment project root is unavailable")
                }
                let payload = try SessionAttachmentPersistenceCodec.serialize(rows)
                try LinuxStoreMutation.withDatabase(at: storePath) { database in
                    if let existing = try database.attachmentsPayload(for: sessionID) {
                        _ = try SessionAttachmentPersistenceCodec.restore(
                            existing, sessionID: sessionID, referenceRoot: projectRoot,
                            copiesRoot: copiesRoot.appendingPathComponent(sessionID.uuidString,
                                                                         isDirectory: true)
                        )
                    }
                    try database.saveAttachmentsPayload(payload, for: sessionID)
                }
            } catch {
                FileHandle.standardError.write(Data("Attachment save refused: \(error)\n".utf8))
            }
        }
    }

    private func remove(_ sessionID: SessionID) {
        worker.async { [self] in
            do {
                try LinuxStoreMutation.withDatabase(at: storePath) {
                    try $0.deleteAttachments(for: sessionID)
                }
            } catch {
                FileHandle.standardError.write(Data("Attachment removal failed: \(error)\n".utf8))
            }
        }
    }

    /// Called after the SDL window closes, while no further attachment writes can arrive.
    func finishPendingWrites() async {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume() }
        }
    }
}
#endif
