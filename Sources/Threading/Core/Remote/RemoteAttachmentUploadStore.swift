import Foundation
import ThreadingRemoteKit
import UniformTypeIdentifiers

// MARK: - Staged Upload

/// One file a composing client has handed over but has not yet named in a prompt.
struct RemoteStagedAttachmentUpload: Equatable {
    /// Host-minted. The client learns this id and nothing else about where the bytes landed.
    let id: String
    let sessionID: String
    /// The device the upload is bound to. Appending and claiming both re-check it, so an id
    /// leaked to another connection names a slot that connection may not touch.
    let deviceID: String
    /// Where the assembled bytes are being written, under the app's own temporary directory.
    let url: URL
    /// What the whole file will be once every chunk has arrived.
    let declaredBytes: Int
    let chunkCount: Int
    private(set) var receivedBytes: Int
    /// The next chunk index the transfer expects. Chunks are strictly ordered because the file
    /// is appended to, not seeked into: an out-of-order chunk would leave a hole no later read
    /// could tell from real bytes.
    private(set) var nextChunkIndex: Int
    /// Extended on every accepted chunk, not fixed at creation. A slow, large, honest transfer
    /// must not be reaped underneath itself while it is still making progress.
    private(set) var expiresAt: Date
    /// Whether a submission currently has this file out on loan.
    ///
    /// A claim cannot delete the upload, because at claim time nobody yet knows whether the
    /// prompt will be accepted: the session may be dormant, another composer may have sent
    /// first, the agent may be mid-turn. Deleting on the way out would leak the bytes on every
    /// refusal *and* break the retry the phone offers, since its strip deliberately survives a
    /// rejection. So a claim only marks, and the outcome decides.
    var isClaimed = false

    var isComplete: Bool { nextChunkIndex >= chunkCount && receivedBytes == declaredBytes }

    fileprivate mutating func accept(byteCount: Int, at now: Date, ttl: TimeInterval) {
        receivedBytes += byteCount
        nextChunkIndex += 1
        renew(at: now, ttl: ttl)
    }

    fileprivate mutating func renew(at now: Date, ttl: TimeInterval) {
        expiresAt = now.addingTimeInterval(ttl)
    }
}

/// One report screenshot already lent to session creation.
///
/// The server keeps the id only so it can discard the staging duplicate after the application
/// has either taken custody or refused the launch. The path is never returned to the phone.
struct RemoteClaimedReportScreenshot {
    let uploadID: String
    let url: URL
}

// MARK: - Store

/// Bytes in flight between a paired client's composer and a prompt that names them.
///
/// This is the one place a remote client can *write* a file the Mac will keep, so its whole job
/// is saying no. Four separate bounds, because each answers a different way of going wrong:
///
/// - **Per file** (`RemoteAccessDefaults.maximumAttachmentBytes`) — the same 24 MB ceiling the
///   download side already enforces. Declared up front so an oversized transfer is refused on its
///   first chunk instead of after most of it is on disk.
/// - **Per session and overall** — a client that opens uploads and never finishes them is the
///   cheapest way to fill a disk. Beginning an upload past either cap is refused outright rather
///   than evicting somebody else's staged file, which would be a denial of service with extra
///   steps.
/// - **Per upload, in time** — an abandoned transfer is reaped. Someone attaches a picture, gets
///   distracted and never sends; nothing else in the system would ever delete that file.
///
/// The type gate is deliberately *not* the client's filename. The extension is re-derived from
/// the declared uniform type, and `AttachmentReferenceDetector.kind(for:)` — the same function
/// that decides what the attachments pane will show — has to recognise the result. A client
/// therefore cannot land a `.command` or a `.dylib` by calling it `photo.png`, and cannot land
/// anything the host has no business previewing.
///
/// Confined to `RemoteAccessServer`'s serial queue, like its sibling `mutationReplayCache`. No
/// lock, because there is no second thread: chunks arrive on that queue and `claim` runs there
/// too, before the submit hops to the main actor with resolved file URLs in hand.
struct RemoteAttachmentUploadStore {

    // MARK: - Properties

    private var uploads: [String: RemoteStagedAttachmentUpload] = [:]
    private let root: URL
    private let fileManager: FileManager
    private let makeID: () -> String

    // MARK: - Initialization

    init(
        root: URL = RemoteAttachmentUploadDefaults.stagingRoot,
        fileManager: FileManager = FileManager(),
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.fileManager = fileManager
        self.makeID = makeID
    }

    // MARK: - Public Methods

    /// Accepts one chunk, beginning the upload when the request carries no id yet.
    ///
    /// Returns nil for every refusal — an unrecognised id, a foreign device, a chunk out of
    /// order, a declared size or type the host will not take. The caller answers all of them
    /// with the same 400, because distinguishing them for the network would describe the host's
    /// staging state to something that failed to prove it owns any of it.
    mutating func accept(
        _ request: RemoteAttachmentUploadRequestDTO,
        sessionID: String,
        deviceID: String,
        now: Date = Date()
    ) -> RemoteAttachmentUploadResponseDTO? {
        guard let chunk = Data(base64Encoded: request.chunk, options: []) else { return nil }

        if let id = request.uploadID {
            return append(chunk, toUploadWithID: id, request: request, deviceID: deviceID, now: now)
        }
        return begin(chunk, request: request, sessionID: sessionID, deviceID: deviceID, now: now)
    }

    /// Stages and immediately claims the small JPEG carried by an atomic report-session create.
    ///
    /// Unlike an ordinary composer upload, there is no client-visible upload id and no interval
    /// in which a draft may name it. Session creation is the prompt that claims these bytes, so
    /// the store makes the loan before the main-actor launch transaction begins. Nil leaves no
    /// staged file behind.
    mutating func stageAndClaimReportScreenshot(
        _ jpegData: Data,
        deviceID: String
    ) -> RemoteClaimedReportScreenshot? {
        let screenshot = RemoteReportScreenshotDTO(jpegBase64: jpegData.base64EncodedString())
        guard RemoteReportScreenshotPolicy.jpegData(from: screenshot) == jpegData else {
            return nil
        }

        let stagingScope = "report-opening-\(UUID().uuidString.lowercased())"
        let request = RemoteAttachmentUploadRequestDTO(
            name: "report-screenshot.jpg",
            mediaType: UTType.jpeg.identifier,
            totalBytes: jpegData.count,
            chunkIndex: 0,
            chunkCount: 1,
            chunk: screenshot.jpegBase64
        )
        guard let accepted = accept(
            request,
            sessionID: stagingScope,
            deviceID: deviceID
        ), accepted.isComplete else {
            return nil
        }
        guard let claimed = claim(
            ids: [accepted.uploadID],
            sessionID: stagingScope,
            deviceID: deviceID
        )?.first else {
            _ = discard(
                id: accepted.uploadID,
                sessionID: stagingScope,
                deviceID: deviceID
            )
            return nil
        }
        return RemoteClaimedReportScreenshot(uploadID: accepted.uploadID, url: claimed)
    }

    /// Lends the completed uploads a prompt named, in the order it named them.
    ///
    /// All-or-nothing: naming one id the caller does not own, one that never finished, one twice,
    /// or one another submission already has out, yields nil and lends nothing. A prompt that
    /// quietly dropped a picture and sent the words anyway would be worse than a refusal the
    /// composer can show.
    ///
    /// The caller **must** answer with `release` or `discardClaimed`. Until it does, these files
    /// are pinned: they cannot be claimed again and their deadline no longer matters, because a
    /// reap mid-submission would delete bytes a prompt is on its way to naming.
    mutating func claim(
        ids: [String],
        sessionID: String,
        deviceID: String
    ) -> [URL]? {
        guard !ids.isEmpty else { return [] }
        guard Set(ids).count == ids.count else { return nil }

        var claimed: [URL] = []
        for id in ids {
            guard let upload = uploads[id],
                  upload.sessionID == sessionID,
                  upload.deviceID == deviceID,
                  upload.isComplete,
                  !upload.isClaimed else { return nil }
            claimed.append(upload.url)
        }
        // Marked only once every id has been checked, so a refusal leaves the staged set exactly
        // as it was and the composer can send the same draft again.
        for id in ids { uploads[id]?.isClaimed = true }
        return claimed
    }

    /// Gives back uploads whose prompt was not accepted, so the person can simply press send
    /// again. Their ordinary lifetime resumes from here.
    mutating func release(ids: [String], now: Date = Date()) {
        for id in ids {
            uploads[id]?.isClaimed = false
            uploads[id]?.renew(at: now, ttl: RemoteAttachmentUploadDefaults.stagedLifetime)
        }
    }

    /// Drops uploads whose prompt was accepted. The host has taken custody of the bytes by now,
    /// so what is left in staging is a duplicate nothing will ever come back for.
    mutating func discardClaimed(ids: [String]) {
        for id in ids {
            guard let upload = uploads.removeValue(forKey: id) else { continue }
            remove(upload)
        }
    }

    /// Deletes an upload the client abandoned on purpose — a thumbnail removed from the strip.
    mutating func discard(id: String, sessionID: String, deviceID: String) -> Bool {
        guard let upload = uploads[id],
              upload.sessionID == sessionID,
              upload.deviceID == deviceID else { return false }
        uploads.removeValue(forKey: id)
        remove(upload)
        return true
    }

    /// Drops uploads nobody came back for. Called on the same sweep as the mutation replay cache.
    mutating func reap(now: Date = Date()) {
        let stale = uploads.filter { !$0.value.isClaimed && $0.value.expiresAt <= now }
        guard !stale.isEmpty else { return }
        for (id, upload) in stale {
            uploads.removeValue(forKey: id)
            remove(upload)
        }
    }

    /// Empties staging when the server stops or authorization is revoked wholesale. The staged
    /// bytes were admitted by a credential that no longer exists, so they do not outlive it.
    mutating func discardAll() {
        uploads.removeAll(keepingCapacity: false)
        try? fileManager.removeItem(at: root)
    }

    mutating func discardAll(sessionID: String) {
        for (id, upload) in uploads where upload.sessionID == sessionID {
            uploads.removeValue(forKey: id)
            remove(upload)
        }
    }

    var stagedCount: Int { uploads.count }

    // MARK: - Private Methods

    private mutating func begin(
        _ chunk: Data,
        request: RemoteAttachmentUploadRequestDTO,
        sessionID: String,
        deviceID: String,
        now: Date
    ) -> RemoteAttachmentUploadResponseDTO? {
        guard request.chunkIndex == 0,
              request.chunkCount >= 1,
              request.chunkCount <= RemoteAttachmentUploadDefaults.maximumChunks,
              request.totalBytes > 0,
              request.totalBytes <= RemoteAccessDefaults.maximumAttachmentBytes,
              chunk.count <= request.totalBytes,
              uploads.count < RemoteAttachmentUploadDefaults.maximumStagedUploads,
              uploads.values.filter({ $0.sessionID == sessionID }).count
                  < RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession,
              let fileExtension = Self.stagedExtension(forMediaType: request.mediaType) else {
            return nil
        }

        // A single chunk that already claims the whole file must actually be the whole file:
        // otherwise a one-chunk upload could be marked complete while short.
        guard request.chunkCount > 1 || chunk.count == request.totalBytes else { return nil }

        let id = makeID()
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(ComposerAttachmentDefaults.generatedPrefix)\(id).\(fileExtension)"
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try chunk.write(to: url, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }

        var upload = RemoteStagedAttachmentUpload(
            id: id,
            sessionID: sessionID,
            deviceID: deviceID,
            url: url,
            declaredBytes: request.totalBytes,
            chunkCount: request.chunkCount,
            receivedBytes: 0,
            nextChunkIndex: 0,
            expiresAt: now
        )
        upload.accept(
            byteCount: chunk.count,
            at: now,
            ttl: RemoteAttachmentUploadDefaults.stagedLifetime
        )

        // The kind check reads the bytes for an ambiguous extension, so it can only run once
        // something is on disk. A one-chunk upload is finished here and answerable now; a
        // multi-chunk one is checked again when its last chunk lands.
        if upload.isComplete, !Self.isPreviewable(upload.url) {
            try? fileManager.removeItem(at: directory)
            return nil
        }

        uploads[id] = upload
        return response(for: upload)
    }

    private mutating func append(
        _ chunk: Data,
        toUploadWithID id: String,
        request: RemoteAttachmentUploadRequestDTO,
        deviceID: String,
        now: Date
    ) -> RemoteAttachmentUploadResponseDTO? {
        guard var upload = uploads[id], upload.deviceID == deviceID else { return nil }

        // A client that lost the response re-sends the chunk the host already has. Answering
        // with the current state rather than appending is what makes a retry safe.
        if request.chunkIndex == upload.nextChunkIndex - 1 { return response(for: upload) }

        guard request.chunkIndex == upload.nextChunkIndex,
              request.chunkCount == upload.chunkCount,
              request.totalBytes == upload.declaredBytes,
              upload.receivedBytes + chunk.count <= upload.declaredBytes,
              let handle = try? FileHandle(forWritingTo: upload.url) else { return nil }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
            try handle.close()
        } catch {
            try? handle.close()
            uploads.removeValue(forKey: id)
            remove(upload)
            return nil
        }

        upload.accept(
            byteCount: chunk.count,
            at: now,
            ttl: RemoteAttachmentUploadDefaults.stagedLifetime
        )

        if upload.nextChunkIndex >= upload.chunkCount {
            // The declared size and the type are both only provable once assembly is done. A
            // transfer that ends short, or whose assembled bytes are not something the host
            // previews, leaves nothing behind.
            guard upload.isComplete, Self.isPreviewable(upload.url) else {
                uploads.removeValue(forKey: id)
                remove(upload)
                return nil
            }
        }

        uploads[id] = upload
        return response(for: upload)
    }

    private func response(
        for upload: RemoteStagedAttachmentUpload
    ) -> RemoteAttachmentUploadResponseDTO {
        RemoteAttachmentUploadResponseDTO(
            uploadID: upload.id,
            receivedBytes: upload.receivedBytes,
            isComplete: upload.isComplete
        )
    }

    private func remove(_ upload: RemoteStagedAttachmentUpload) {
        try? fileManager.removeItem(at: upload.url.deletingLastPathComponent())
    }

    /// The extension the host is prepared to write, derived from the declared type rather than
    /// from the client's filename.
    ///
    /// Two gates in one step. `UTType` refuses a type identifier it does not know, and the
    /// preferred extension it answers is the system's, not the network's — so a name is never
    /// what decides the file's extension. The result still has to be an extension the
    /// attachments pane recognises, which is checked against the assembled bytes in
    /// `isPreviewable`.
    static func stagedExtension(forMediaType mediaType: String) -> String? {
        let trimmed = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= RemoteAttachmentUploadDefaults.maximumMediaTypeBytes,
              let type = UTType(trimmed),
              let candidate = type.preferredFilenameExtension?.lowercased(),
              !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return candidate
    }

    /// Whether the attachments pane would recognise the assembled file.
    ///
    /// The same question the scanner asks, so an upload can never put a row in the pane that the
    /// pane has nothing to draw. For an ambiguous extension this reads a bounded prefix of the
    /// file, which is why it runs after the last chunk rather than on the declared type alone.
    static func isPreviewable(_ url: URL) -> Bool {
        AttachmentReferenceDetector.kind(for: url) != nil
    }
}

// MARK: - Constants

enum RemoteAttachmentUploadDefaults {
    static let directoryName = "threading-remote-uploads"

    /// Where uploads are assembled. One definition so a test can point the store somewhere
    /// disposable without the production path ever reading a different answer.
    static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(directoryName, isDirectory: true)

    /// How long a staged file waits for the prompt that names it, extended by every chunk.
    /// Longer than the five-minute mutation replay window on purpose: attaching a picture and
    /// then writing the message around it is ordinary, and losing it mid-sentence is not.
    static let stagedLifetime: TimeInterval = 30 * 60

    /// In flight at once across every session, and within one. Small, because these are files
    /// waiting on a person to finish typing, not a queue. The per-session figure is the shared
    /// one, because the phone bounds its strip by the same number.
    static let maximumStagedUploads = 24
    static let maximumStagedUploadsPerSession = RemoteAttachmentUploadLimits.maximumPerMessage

    /// 24 MB of payload cannot arrive in fewer chunks than this once base64 and the request
    /// ceiling are accounted for; the bound exists so a declared chunk count cannot be absurd.
    static let maximumChunks = 128

    static let maximumMediaTypeBytes = 256
}
