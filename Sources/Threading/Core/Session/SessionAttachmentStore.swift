#if os(Linux)
import Crypto
#else
import CryptoKit
#endif
import Foundation
import ThreadingExtensionKit

// MARK: - Attachment

/// An inspectable file that passed between the two parties in one session: an image, a PDF,
/// generated HTML, an archive, or an open document format.
///
/// Attachments inside the checkout are references, not copies. The project file remains
/// authoritative, so replacing an image or PDF at the same path updates every preview without
/// growing a second cache. A file from anywhere else is copied into the store's own directory
/// instead — see `SessionAttachmentStore` for why that exception exists and where it stops.
struct SessionAttachment: Equatable, Identifiable, Sendable {

    typealias Kind = SessionAttachmentKind

    /// Which side of the conversation put the file in front of the other.
    ///
    /// The distinction is not decorative: the pane mixed the two silently, because a terminal
    /// scan reads the whole buffer and cannot tell a path the agent printed from one the user
    /// typed. Everything discovered by scanning is therefore `agent` — the session surfaced it —
    /// and `user` is reserved for a deliberate handoff from the composer, which is the thing
    /// someone means when they ask where the picture they sent went.
    enum Origin: String, Codable, Sendable {
        case agent
        case user
    }

    /// How this file is placed against the session's durable turn ledger.
    ///
    /// Agent output is recorded while its turn is current. A user attachment is normally filed
    /// just before the provider admits the turn that will carry it, so it points forward instead.
    /// Local-only actions in the Attachments pane point at neither: comparing a dropped picture
    /// must not make the next unrelated prompt claim it. `turnID` upgrades either temporal answer
    /// to the exact provider-neutral user-turn identity whenever the submission path has one.
    enum TurnPlacement: String, Codable, Sendable {
        case current
        case next
        case none
    }

    /// Opaque identity used by notifications and remote fetches. A path remains presentation
    /// metadata; it is neither authority nor identity once two captures can come from one file.
    var id: String

    let sessionID: SessionID

    /// The directory `relativePath` is resolved against: the checkout for a referenced file, the
    /// store's own directory for a copied one.
    let root: URL
    let url: URL
    let relativePath: String

    /// The file as it was named when it was recorded, and the key a second mention is matched
    /// against. A copy's own path is minted per attachment, so matching on that would file every
    /// regenerated chart as a new row instead of refreshing the one already there.
    let sourcePath: String
    let kind: Kind
    var origin: Origin
    var agentSources: [AttachmentAgentSource]

    /// Whether this row only exists because the checkout rule was widened.
    ///
    /// True for a *scanned* file that lives outside the project and was admitted under
    /// `allowsFilesOutsideProject`. It is the read gate's key: narrowing the scope again must
    /// hide these everywhere at once — the pane, the MCP tools and the paired phone — without
    /// depending on any of them noticing a setting changed. A declared file is never marked,
    /// because a handoff was never governed by the rule in the first place.
    let isOutsideProject: Bool
    /// Generated display output is copied once and never refreshed underneath its row.
    let isImmutableSnapshot: Bool
    var turnID: String?
    var turnPlacement: TurnPlacement
    let referencedAt: Date

    init(
        sessionID: SessionID,
        id: String = UUID().uuidString.lowercased(),
        root: URL,
        url: URL,
        relativePath: String,
        sourcePath: String,
        kind: Kind,
        origin: Origin,
        agentSources: [AttachmentAgentSource]? = nil,
        isOutsideProject: Bool = false,
        isImmutableSnapshot: Bool = false,
        turnID: String? = nil,
        turnPlacement: TurnPlacement = .current,
        referencedAt: Date
    ) {
        self.sessionID = sessionID
        self.id = id
        self.root = root
        self.url = url
        self.relativePath = relativePath
        self.sourcePath = sourcePath
        self.kind = kind
        self.origin = origin
        self.agentSources = agentSources ?? (origin == .agent ? [.main] : [])
        self.isOutsideProject = isOutsideProject
        self.isImmutableSnapshot = isImmutableSnapshot
        self.turnID = turnID
        self.turnPlacement = turnPlacement
        self.referencedAt = referencedAt
    }

    var name: String { url.lastPathComponent }

    /// The two picture rows a `.comparison` holds against each other, read from its source key.
    var comparedAttachmentIDs: (old: String, new: String)? {
        guard kind == .comparison else { return nil }
        return Self.comparedAttachmentIDs(inSourcePath: sourcePath)
    }

    /// One row per compared pair: the same two pictures compared again refresh this key's row
    /// rather than stacking a copy of it.
    static func comparisonSourcePath(old: String, new: String) -> String {
        "\(comparisonSourcePrefix)\(old)|\(new)"
    }

    static func comparedAttachmentIDs(inSourcePath path: String) -> (old: String, new: String)? {
        guard path.hasPrefix(comparisonSourcePrefix) else { return nil }
        let ids = path.dropFirst(comparisonSourcePrefix.count).split(separator: "|")
        guard ids.count == 2 else { return nil }
        return (String(ids[0]), String(ids[1]))
    }

    private static let comparisonSourcePrefix = "comparison:"
}

/// A supported file the scan found outside the project and did **not** admit.
///
/// Held in memory only, and only as a path: it is what lets the pane say *how many* files the
/// narrow scope is costing this session without the app taking custody of one byte, and it is
/// what the widening admits immediately instead of waiting for the path to be printed again.
/// Persisting it would be the thing the scope rule exists to prevent — a durable list of paths
/// outside the project, written for files nobody handed over.
struct WithheldAttachmentReference: Equatable {
    let path: String
    let kind: SessionAttachment.Kind
    var context: AttachmentReferenceContext = .main
}

/// Raised after one session's attachment list changes.
struct SessionAttachmentsDidChange: AppEvent {
    static let name = Notification.Name("sessionAttachmentsDidChange")
    let sessionID: SessionID
}

// MARK: - Store

/// The session-scoped set of visual files that passed between the user and the agent.
///
/// Main-thread only, like `ProjectStore` and the display pane. There are **two doors in, and
/// they are not the same door**, which is the correction at the centre of this type:
///
/// - **Scanned** (`recordReferences`) — paths found by reading live output. Text is not a
///   handoff: a build log, a `cat`, a repository's own fixtures can name any path on disk, so a
///   scanned path is admitted only from inside the checkout. That rule is doing more than
///   suppressing noise. Membership in this list is exactly what the paired-phone endpoint will
///   serve, so without it one `find ~ -name '*.png'` printed in a terminal would enumerate the
///   user's pictures into a fetchable list. `allowsFilesOutsideProject` widens it deliberately —
///   see below.
/// - **Declared** (`record(declared:…)`) — a file handed over on purpose: an agent's
///   `display_image` or comparison, or an image the user attached to their prompt. The
///   containment rule does not apply, because by then there is nothing left for it to protect —
///   the bytes have been opened, decoded and drawn on the user's own screen.
///
/// Enforcing the scanned rule at *admission* was the bug. It is a rule about what may leave over
/// the wire, and applying it to declared files silently dropped the one signal in the system that
/// unambiguously means *here is a picture*: agents work in one-off places — `$TMPDIR`, `/tmp`, a
/// scratch directory — and so does this project, whose own render tests write every screenshot
/// they produce to `$TMPDIR/ThreadingRenders`. None of it could ever reach the pane.
///
/// A declared file from outside the checkout is **copied in** rather than referenced, which is
/// the one place attachments are not references. Nothing else owns a temporary file; the list
/// outlives the turn that named it; and reading prunes entries whose file has gone — so a
/// reference into `$TMPDIR` comes back as an empty pane once the reaper has run, which is the
/// vanishing-attachments bug in a new costume. Copying also preserves what the containment rule
/// was really providing: every file in the list sits somewhere the app controls, the checkout or
/// its own store, so the remote endpoint stays a reader of its own data.
///
/// **The scanned rule is a default, not a law — `allowsFilesOutsideProject` is the user's own
/// answer to it.** Off, the scan refuses an outside path and remembers it as a
/// `WithheldAttachmentReference`: a path, in memory, never persisted and never served, so the
/// pane can say what the rule is costing this session. On, an outside path is admitted through
/// the same custody path a declared file takes — copied in, marked `isOutsideProject` — because
/// widening what may be listed must not also widen what the remote endpoint reaches outside the
/// app's own directories. Narrowing it again hides those rows at **read**: everything that can
/// serve an attachment goes through `attachments(for:)`, so one gate closes the pane, the MCP
/// tools and the phone together, whether or not anything was on screen to notice. The bytes stay
/// in custody until the row leaves for an ordinary reason, so the answer can be changed back
/// without silently destroying what it already took.
///
/// The list is **persisted** per session, beside the panel layout it belongs with. Detection
/// only sees live output — a terminal's recent buffer, a conversation's streamed turns — so a
/// list held only in memory emptied on every relaunch while the Attachments *tab* dutifully
/// came back, which read as attachments appearing and vanishing at random. References are still
/// re-validated against the filesystem on every read, so a file that has since been deleted
/// drops out (and the pruned list is written back) rather than offering a dead row.
@MainActor
final class SessionAttachmentStore {

    struct ScannedRecordResult {
        let attachments: [SessionAttachment]
        let custodyWorkerNanoseconds: UInt64
        let mainActorNanoseconds: UInt64

        static let empty = ScannedRecordResult(
            attachments: [],
            custodyWorkerNanoseconds: 0,
            mainActorNanoseconds: 0
        )
    }

    struct ListSnapshot {
        let attachments: [SessionAttachment]
        let countOfFilesOutsideProject: Int
    }

    private struct StagedCopy: Sendable {
        let source: URL
        let url: URL
        let relativePath: String
        let kind: SessionAttachment.Kind
    }

    private struct StagedCopyBatch: Sendable {
        let copies: [StagedCopy]
        let workerNanoseconds: UInt64
    }

    private struct OutsideProjectStaging: Sendable {
        let urls: [URL]
        let sessionID: SessionID
        let root: URL
        let context: AttachmentReferenceContext?
        let referencedAt: Date
        let copyFile: @Sendable (URL, URL) throws -> Void

        nonisolated func stage() -> StagedCopyBatch {
            SessionAttachmentStore.stageScannedCopies(urls, in: root, copyFile: copyFile)
        }
    }

    // Replaceable for hosted shell fixtures that supply a deterministic clock and scratch custody.
    static var shared: SessionAttachmentStore = makePlatformDefault()
    private nonisolated static let synchronousHostCustodyWorker = DispatchQueue(
        label: "threading.attachments.synchronous-host-custody", qos: .utility)

    private var attachmentsBySession: [SessionID: [SessionAttachment]] = [:]
    private var withheldBySession: [SessionID: [WithheldAttachmentReference]] = [:]
    private var loadedSessions: Set<SessionID> = []
    private let fileManager: FileManager
    private let now: () -> Date
    private let loadPayload: ((SessionID) -> String?)?
    private let savePayload: ((String, SessionID) -> Void)?
    private let persistPreparedRows: (@Sendable ([SessionAttachment], SessionID) -> Void)?
    private let retainPersisted: ((Set<SessionID>) -> Void)?
    private let removePersisted: ((SessionID) -> Void)?
    private let stageCopy: @Sendable (URL, URL) throws -> Void

    /// Where a declared file from outside the checkout is copied to. Absent means the store may
    /// only hold references, so a declared file it cannot take custody of is refused rather than
    /// listed as a path that will rot — the invariant holds either way.
    private let copiesDirectory: (() -> URL)?

    /// The one external directory persisted references may name for a session. The root stored
    /// in SQLite is evidence, not authority: accepting an arbitrary absolute root from a damaged
    /// row would turn a harmless relative path into a remote-readable file anywhere on disk.
    private let referenceRoot: ((SessionID) -> URL?)?

    /// Whether a *scanned* file outside the project may be listed. Read on every admission and
    /// every read rather than cached: the answer is a user setting that can change at any moment,
    /// and a stale copy of it is the difference between a rule and a suggestion. The default is
    /// the narrow answer, so a store built without one behaves exactly as it always did.
    private let allowsFilesOutsideProject: () -> Bool

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        loadPayload: ((SessionID) -> String?)? = nil,
        savePayload: ((String, SessionID) -> Void)? = nil,
        persistPreparedRows: (@Sendable ([SessionAttachment], SessionID) -> Void)? = nil,
        retainPersisted: ((Set<SessionID>) -> Void)? = nil,
        removePersisted: ((SessionID) -> Void)? = nil,
        copiesDirectory: (() -> URL)? = nil,
        referenceRoot: ((SessionID) -> URL?)? = nil,
        allowsFilesOutsideProject: @escaping () -> Bool = { false },
        stageCopy: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager().copyItem(at: $0, to: $1)
        }
    ) {
        self.fileManager = fileManager
        self.now = now
        self.loadPayload = loadPayload
        self.savePayload = savePayload
        self.persistPreparedRows = persistPreparedRows
        self.retainPersisted = retainPersisted
        self.removePersisted = removePersisted
        self.copiesDirectory = copiesDirectory
        self.referenceRoot = referenceRoot
        self.allowsFilesOutsideProject = allowsFilesOutsideProject
        self.stageCopy = stageCopy
    }

    // MARK: Recording — the scanned door

    /// Records the supported files named in live output.
    ///
    /// In-checkout files are admitted as references, as they always were. A file outside the
    /// project is admitted only under the widened scope, and by copy rather than by reference —
    /// otherwise the list would name files the app has no custody of, which is the property the
    /// containment rule was really providing. Refused ones are remembered as withheld.
    @discardableResult
    func recordReferences(
        in text: String,
        sessionID: SessionID,
        projectRoot: URL,
        currentDirectory: URL? = nil
    ) -> [SessionAttachment] {
        record(
            resolved: AttachmentReferenceDetector.resolve(
                text: text,
                projectRoot: projectRoot,
                currentDirectory: currentDirectory,
                fileManager: fileManager
            ),
            sessionID: sessionID,
            projectRoot: projectRoot
        )
    }

    /// The same door for a caller that has already resolved — the terminal observer, which sorts
    /// the newly visible paths from the ones it saw in its previous window before recording.
    @discardableResult
    func record(
        resolved resolution: AttachmentReferenceDetector.Resolution,
        sessionID: SessionID,
        projectRoot: URL
    ) -> [SessionAttachment] {
        var made = record(
            urls: resolution.insideProject,
            sessionID: sessionID,
            projectRoot: projectRoot
        )

        guard !resolution.outsideProject.isEmpty else { return made }
        guard allowsFilesOutsideProject() else {
            noteWithheld(resolution.outsideProject, for: sessionID)
            return made
        }
        made += admitOutsideProject(resolution.outsideProject, sessionID: sessionID)
        return made
    }

    /// The scanned door for interactive callers. Filesystem resolution has already happened on
    /// a worker; this keeps taking custody there too. Each outside file is copied into a unique,
    /// unpublished session slot, then the main actor publishes that slot (or atomically folds it
    /// into a row that won the same-source race while copying). The list is still main-actor
    /// state and no path becomes remotely fetchable before admission.
    func recordScanned(
        resolved resolution: AttachmentReferenceDetector.Resolution,
        sessionID: SessionID,
        projectRoot: URL,
        context: AttachmentReferenceContext = .main,
        shouldAdmit: @escaping @MainActor () -> Bool = { true }
    ) async -> ScannedRecordResult {
        let insideMainStarted = DispatchTime.now().uptimeNanoseconds
        guard shouldAdmit() else {
            return ScannedRecordResult(
                attachments: [],
                custodyWorkerNanoseconds: 0,
                mainActorNanoseconds: DispatchTime.now().uptimeNanoseconds - insideMainStarted
            )
        }
        let inside = recordResolvedInsideProject(
            resolution.insideProject,
            sessionID: sessionID,
            projectRoot: resolution.resolvedProjectRoot
                ?? projectRoot.standardizedFileURL.resolvingSymlinksInPath(),
            context: context
        )
        let insideMainNanoseconds = DispatchTime.now().uptimeNanoseconds - insideMainStarted
        let outside = await stageAndAdmitOutsideProject(
            resolution.outsideProject,
            sessionID: sessionID,
            context: context,
            shouldAdmit: shouldAdmit
        )
        return ScannedRecordResult(
            attachments: inside + outside.attachments,
            custodyWorkerNanoseconds: outside.custodyWorkerNanoseconds,
            mainActorNanoseconds: insideMainNanoseconds + outside.mainActorNanoseconds
        )
    }

    /// Takes custody of paths remembered while the scope was narrow without copying them in the
    /// button action. The caller's predicate binds the work to the pane/settings generation that
    /// requested it, so hiding the rows again while staging cannot publish a stale answer.
    func admitWithheldFilesOutsideProjectAsync(
        for sessionID: SessionID,
        shouldAdmit: @escaping @MainActor () -> Bool = { true }
    ) async -> ScannedRecordResult {
        guard allowsFilesOutsideProject(),
              let withheld = withheldBySession[sessionID],
              !withheld.isEmpty else {
            return .empty
        }
        return await stageAndAdmitOutsideProject(
            withheld.map { URL(fileURLWithPath: $0.path) },
            sessionID: sessionID,
            context: nil,
            shouldAdmit: shouldAdmit
        )
    }

    /// The same scanned door for a host whose UI actor is driven by a synchronous event loop.
    /// Its worker returns through the host's receipt mailbox, so custody never waits for a
    /// suspended main-actor task that the loop cannot resume.
    func recordPreparedScanned(
        _ insideRows: [SessionAttachment],
        outsideProject: [URL],
        sessionID: SessionID,
        context: AttachmentReferenceContext = .main,
        delivery: ConversationCallbackDelivery,
        shouldAdmit: @escaping @MainActor @Sendable () -> Bool = { true },
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard shouldAdmit() else { completion(); return }
        _ = admitPreparedScanned(insideRows, for: sessionID)
        let started = DispatchTime.now().uptimeNanoseconds
        guard let request = prepareOutsideProjectStaging(
            outsideProject, sessionID: sessionID, context: context,
            shouldAdmit: shouldAdmit
        ) else { completion(); return }
        let firstMainNanoseconds = DispatchTime.now().uptimeNanoseconds - started
        Self.synchronousHostCustodyWorker.async { [self] in
            let staged = request.stage()
            delivery.receive { [self] in
                _ = self.finishOutsideProjectStaging(
                    request, staged: staged, shouldAdmit: shouldAdmit,
                    cancelled: false, firstMainNanoseconds: firstMainNanoseconds)
                completion()
            }
        }
    }

    /// Widens already refused paths on a synchronous UI host. Only the copied bytes run on the
    /// worker; the scope is checked again before a row can be published.
    func admitWithheldFilesOutsideProject(
        for sessionID: SessionID,
        delivery: ConversationCallbackDelivery,
        shouldAdmit: @escaping @MainActor @Sendable () -> Bool = { true },
        completion: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        guard allowsFilesOutsideProject(),
              let withheld = withheldBySession[sessionID], !withheld.isEmpty else {
            completion()
            return
        }
        let urls = withheld.map { URL(fileURLWithPath: $0.path) }
        let started = DispatchTime.now().uptimeNanoseconds
        guard let request = prepareOutsideProjectStaging(
            urls, sessionID: sessionID, context: nil, shouldAdmit: shouldAdmit
        ) else { completion(); return }
        let firstMainNanoseconds = DispatchTime.now().uptimeNanoseconds - started
        Self.synchronousHostCustodyWorker.async { [self] in
            let staged = request.stage()
            delivery.receive { [self] in
                _ = self.finishOutsideProjectStaging(
                    request, staged: staged, shouldAdmit: shouldAdmit,
                    cancelled: false, firstMainNanoseconds: firstMainNanoseconds)
                completion()
            }
        }
    }

    /// The worker-owned half shared by live scans and the pane's explicit scope widening.
    private func stageAndAdmitOutsideProject(
        _ outsideProject: [URL],
        sessionID: SessionID,
        context: AttachmentReferenceContext?,
        shouldAdmit: @escaping @MainActor () -> Bool
    ) async -> ScannedRecordResult {
        let firstMainStarted = DispatchTime.now().uptimeNanoseconds
        guard let request = prepareOutsideProjectStaging(
            outsideProject, sessionID: sessionID, context: context,
            shouldAdmit: shouldAdmit
        ) else { return .empty }
        let firstMainNanoseconds = DispatchTime.now().uptimeNanoseconds - firstMainStarted
        let stagingTask = Task.detached(priority: .userInitiated) { request.stage() }
        let staged = await withTaskCancellationHandler {
            await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
        return finishOutsideProjectStaging(
            request, staged: staged, shouldAdmit: shouldAdmit,
            cancelled: Task.isCancelled, firstMainNanoseconds: firstMainNanoseconds)
    }

    private func prepareOutsideProjectStaging(
        _ urls: [URL], sessionID: SessionID,
        context: AttachmentReferenceContext?,
        shouldAdmit: @MainActor () -> Bool
    ) -> OutsideProjectStaging? {
        guard shouldAdmit(), !urls.isEmpty else { return nil }
        if let context { attributeExistingReferences(urls, for: sessionID, context: context) }
        guard allowsFilesOutsideProject() else {
            if let context { noteWithheld(urls, for: sessionID, context: context) }
            return nil
        }
        loadIfNeeded(sessionID)
        let admissible = Array(urls.suffix(SessionAttachmentDefaults.maximumPerSession))
        guard let root = copiesRoot(for: sessionID) else {
            removeWithheldAttempts(admissible, for: sessionID)
            return nil
        }
        return OutsideProjectStaging(
            urls: admissible, sessionID: sessionID, root: root,
            context: context, referencedAt: now(), copyFile: stageCopy)
    }

    private func finishOutsideProjectStaging(
        _ request: OutsideProjectStaging, staged: StagedCopyBatch,
        shouldAdmit: @MainActor () -> Bool, cancelled: Bool,
        firstMainNanoseconds: UInt64
    ) -> ScannedRecordResult {
        let secondMainStarted = DispatchTime.now().uptimeNanoseconds
        guard !cancelled, shouldAdmit() else {
            discard(staged)
            return ScannedRecordResult(
                attachments: [],
                custodyWorkerNanoseconds: staged.workerNanoseconds,
                mainActorNanoseconds: firstMainNanoseconds
                    + (DispatchTime.now().uptimeNanoseconds - secondMainStarted)
            )
        }
        guard allowsFilesOutsideProject() else {
            discard(staged)
            if let context = request.context {
                noteWithheld(request.urls, for: request.sessionID, context: context)
            }
            return ScannedRecordResult(
                attachments: [],
                custodyWorkerNanoseconds: staged.workerNanoseconds,
                mainActorNanoseconds: firstMainNanoseconds
                    + (DispatchTime.now().uptimeNanoseconds - secondMainStarted)
            )
        }

        let outside = finishStagedCopies(
            staged.copies,
            attempted: request.urls,
            sessionID: request.sessionID,
            root: request.root,
            context: request.context,
            referencedAt: request.referencedAt
        )
        return ScannedRecordResult(
            attachments: outside,
            custodyWorkerNanoseconds: staged.workerNanoseconds,
            mainActorNanoseconds: firstMainNanoseconds
                + (DispatchTime.now().uptimeNanoseconds - secondMainStarted)
        )
    }

    /// Takes custody of scanned files from outside the project. The declared door's own machinery,
    /// with the one difference that matters downstream: these rows carry `isOutsideProject`, so
    /// narrowing the scope again can find them without guessing from their location.
    @discardableResult
    private func admitOutsideProject(
        _ urls: [URL],
        sessionID: SessionID
    ) -> [SessionAttachment] {
        loadIfNeeded(sessionID)
        let timestamp = now()
        // Only a capful can survive `admit`, and taking custody is *copying bytes on the main
        // thread* — so a scan that names 512 files outside the project must not copy 512 files
        // to keep 32 and delete 480. Newest wins there, and the newest are at the end here, so
        // the tail is exactly the set that would have been left. Measured: this is most of the
        // difference between the two scopes (`attachment-stress`).
        let admissible = urls.suffix(SessionAttachmentDefaults.maximumPerSession)
        let contexts = Dictionary(uniqueKeysWithValues:
            (withheldBySession[sessionID] ?? []).map { ($0.path, $0.context) })
        let made = admissible.compactMap { url -> SessionAttachment? in
            // Straight to custody, not through `declaredAttachment`: these are outside the
            // checkout by construction, and copying is the whole reason they may be listed.
            guard var attachment = copiedAttachment(
                at: url,
                sessionID: sessionID,
                origin: .agent,
                preferredName: nil,
                isOutsideProject: true,
                referencedAt: timestamp
            ) else { return nil }
            let context = contexts[url.path] ?? .main
            attachment.agentSources = context.sources
            attachment.turnID = context.turnID
            return attachment
        }
        // Cleared *before* admitting, not after, and that ordering is load-bearing: `admit`
        // announces the change synchronously, an open pane answers by refreshing, and a refresh
        // admits whatever is still withheld. Leaving these in hand across the post meant the
        // pane re-entered with the same work to do and recursed until the stack ran out. State
        // first, then the announcement — a listener may only ever see a finished store.
        //
        // A path attempted and refused (a file that has since gone, custody that could not be
        // taken) is dropped rather than retried, so the pane cannot go on offering to reveal
        // something that will not arrive. The next scan that names it offers it again.
        removeWithheldAttempts(Array(admissible), for: sessionID)
        return admit(made, for: sessionID)
    }

    /// Copies into unique, not-yet-listed slots. A task may be cancelled between files; anything
    /// it already produced is returned so the main actor can remove those unpublished bytes.
    private nonisolated static func stageScannedCopies(
        _ urls: [URL],
        in root: URL,
        copyFile: @Sendable (URL, URL) throws -> Void
    ) -> StagedCopyBatch {
        let started = DispatchTime.now().uptimeNanoseconds
        let fileManager = FileManager()
        var copies: [StagedCopy] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            let source = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let kind = AttachmentReferenceDetector.kind(for: source),
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            let relativePath = "\(UUID().uuidString)/\(source.lastPathComponent)"
            let destination = root.appendingPathComponent(relativePath)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyFile(source, destination)
                copies.append(StagedCopy(
                    source: source,
                    url: destination,
                    relativePath: relativePath,
                    kind: kind
                ))
            } catch {
                try? fileManager.removeItem(at: destination.deletingLastPathComponent())
                ThreadingLogger.session.error(
                    "Failed to stage attachment \(source.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return StagedCopyBatch(
            copies: copies,
            workerNanoseconds: DispatchTime.now().uptimeNanoseconds - started
        )
    }

    /// Reconciles a staged batch with state that may have changed while its bytes were copying.
    /// A same-source winner keeps its opaque identity and slot; otherwise the unique staged slot
    /// simply becomes visible, which makes cold admission a state mutation rather than file I/O.
    private func finishStagedCopies(
        _ staged: [StagedCopy],
        attempted: [URL],
        sessionID: SessionID,
        root: URL,
        context: AttachmentReferenceContext?,
        referencedAt: Date
    ) -> [SessionAttachment] {
        var made: [SessionAttachment] = []
        var existingBySource: [String: SessionAttachment] = [:]
        for existing in attachmentsBySession[sessionID] ?? [] where !existing.isImmutableSnapshot {
            guard existingBySource[existing.sourcePath] == nil,
                  Self.ownedCopySlot(for: existing, in: root) != nil else {
                continue
            }
            existingBySource[existing.sourcePath] = existing
        }
        let withheldContexts = Dictionary(uniqueKeysWithValues:
            (withheldBySession[sessionID] ?? []).map { ($0.path, $0.context) })
        for copy in staged {
            let attribution = context ?? withheldContexts[copy.source.path] ?? .main
            let existing = existingBySource[copy.source.path]

            let destination: URL
            let relativePath: String
            let id: String
            let origin: SessionAttachment.Origin
            let isOutsideProject: Bool
            if let existing {
                destination = root.appendingPathComponent(existing.relativePath)
                relativePath = existing.relativePath
                id = existing.id
                // A later textual mention does not turn an explicit user/agent handoff into a
                // scope-governed discovery. Identity includes the authority under which the row
                // entered the store, not only its opaque remote key.
                origin = existing.origin
                isOutsideProject = existing.isOutsideProject
                guard install(copy, over: destination) else { continue }
            } else {
                destination = copy.url
                relativePath = copy.relativePath
                id = UUID().uuidString.lowercased()
                origin = .agent
                isOutsideProject = true
                guard fileManager.fileExists(atPath: destination.path) else { continue }
            }

            made.append(SessionAttachment(
                sessionID: sessionID,
                id: id,
                root: root,
                url: destination,
                relativePath: relativePath,
                sourcePath: copy.source.path,
                kind: copy.kind,
                origin: origin,
                agentSources: attribution.sources,
                isOutsideProject: isOutsideProject,
                turnID: attribution.turnID,
                referencedAt: referencedAt
            ))
        }

        // State first, announcement second. `admit` posts synchronously and an open pane may
        // immediately ask to admit withheld rows again.
        removeWithheldAttempts(attempted, for: sessionID)
        return admit(made, for: sessionID, discardingCopiesOnWorker: true)
    }

    private func removeWithheldAttempts(_ urls: [URL], for sessionID: SessionID) {
        let attempted = Set(urls.map(\.path))
        withheldBySession[sessionID]?.removeAll { attempted.contains($0.path) }
    }

    /// Detector resolutions have already proved these URLs regular, supported and contained on
    /// their worker. Repeating those `stat`s on the actor made the mixed cold edge pay for every
    /// project row twice. Admission still rechecks pure containment and derives its own opaque
    /// row; the authoritative read path handles a file disappearing during the handoff.
    private func recordResolvedInsideProject(
        _ urls: [URL],
        sessionID: SessionID,
        projectRoot: URL,
        context: AttachmentReferenceContext
    ) -> [SessionAttachment] {
        let made = SessionAttachmentScannedRowPreparation.insideProject(
            urls, sessionID: sessionID, projectRoot: projectRoot,
            context: context, referencedAt: now()
        )
        return admit(made, for: sessionID)
    }

    /// A native host whose UI actor owns a synchronous event loop can publish rows prepared on
    /// a worker without running path probes or a suspended actor task in that event loop.
    @discardableResult
    func admitPreparedScanned(_ rows: [SessionAttachment], for sessionID: SessionID)
        -> [SessionAttachment] {
        let bounded = Array(rows.suffix(SessionAttachmentDefaults.maximumPerSession))
        guard bounded.allSatisfy({
            $0.sessionID == sessionID && !$0.isOutsideProject
                && AttachmentReferenceDetector.contains($0.url, inside: $0.root)
        }) else {
            return []
        }
        return admit(bounded, for: sessionID, discardingCopiesOnWorker: true)
    }

    /// Only a same-source race reaches this path. The expensive copy already happened; these
    /// same-volume renames retain the old bytes until the new staged file is standing.
    private func install(_ staged: StagedCopy, over destination: URL) -> Bool {
        let directory = destination.deletingLastPathComponent()
        let backup = directory.appendingPathComponent(".threading-backup-\(UUID().uuidString)")
        var movedStandingCopy = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedStandingCopy = true
            }
            try fileManager.moveItem(at: staged.url, to: destination)
            try? fileManager.removeItem(at: staged.url.deletingLastPathComponent())
            if movedStandingCopy {
                do {
                    try fileManager.removeItem(at: backup)
                } catch {
                    ThreadingLogger.session.warning(
                        "Attachment replacement left a stale backup source=\(backup.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
            return true
        } catch {
            if movedStandingCopy, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? fileManager.removeItem(at: staged.url.deletingLastPathComponent())
            ThreadingLogger.session.error(
                "Failed to install staged attachment \(staged.source.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    /// Staged slots have never been published, so cancellation and a scope change may clean them
    /// on a utility worker without racing a reader of the attachment list.
    private func discard(_ batch: StagedCopyBatch) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager()
            for copy in batch.copies {
                try? fileManager.removeItem(at: copy.url.deletingLastPathComponent())
            }
        }
    }

    /// Records already-resolved in-checkout files. Scanning resolves its own, so this is for a
    /// caller that has done the resolving and accepts the same containment rule.
    @discardableResult
    func record(
        urls: [URL],
        sessionID: SessionID,
        projectRoot: URL
    ) -> [SessionAttachment] {
        let timestamp = now()
        // The cap decides how many of these can exist, so proving more than a capful of them
        // against the filesystem is work for rows the same call will evict. Newest wins in
        // `admit`, and the newest are at the end. Measured at both doors: a build printing five
        // hundred paths was paying five hundred `stat`s to keep thirty-two of them.
        let made = urls.suffix(SessionAttachmentDefaults.maximumPerSession).compactMap {
            referencedAttachment(
                at: $0,
                sessionID: sessionID,
                root: projectRoot,
                origin: .agent,
                referencedAt: timestamp
            )
        }
        return admit(made, for: sessionID)
    }

    /// Single-file convenience retained for callers that already resolved an in-checkout path.
    @discardableResult
    func record(
        url: URL,
        sessionID: SessionID,
        projectRoot: URL
    ) -> SessionAttachment? {
        record(
            urls: [url],
            sessionID: sessionID,
            projectRoot: projectRoot
        ).first
    }

    // MARK: Recording — the declared door

    /// Records a file handed over on purpose, from wherever it happens to live.
    ///
    /// `preferredName` renames the copy this may take, for the one caller whose file has no name
    /// worth showing: a pasted screenshot arrives as `threading-attachment-<UUID>.png`, and a row
    /// reading that tells the person who pasted it nothing at all.
    @discardableResult
    func record(
        declared urls: [URL],
        sessionID: SessionID,
        projectRoot: URL,
        origin: SessionAttachment.Origin,
        preferredName: String? = nil,
        turnID: String? = nil,
        turnPlacement: SessionAttachment.TurnPlacement = .current
    ) -> [SessionAttachment] {
        // Loaded before anything is built: a second mention of the same source is matched against
        // the list as it stands, so a regenerated chart overwrites its copy in place.
        loadIfNeeded(sessionID)

        let timestamp = now()
        let made = urls.compactMap {
            declaredAttachment(
                at: $0,
                sessionID: sessionID,
                projectRoot: projectRoot,
                origin: origin,
                preferredName: preferredName,
                turnID: turnID,
                turnPlacement: turnPlacement,
                referencedAt: timestamp
            )
        }
        return admit(made, for: sessionID)
    }

    /// The single-file form, which is every declared caller but a comparison.
    @discardableResult
    func record(
        declared url: URL,
        sessionID: SessionID,
        projectRoot: URL,
        origin: SessionAttachment.Origin,
        preferredName: String? = nil,
        turnID: String? = nil,
        turnPlacement: SessionAttachment.TurnPlacement = .current
    ) -> SessionAttachment? {
        record(
            declared: [url],
            sessionID: sessionID,
            projectRoot: projectRoot,
            origin: origin,
            preferredName: preferredName,
            turnID: turnID,
            turnPlacement: turnPlacement
        ).first
    }

    /// Captures one displayed file as immutable attachment bytes.
    ///
    /// Unlike an ordinary declared attachment this always takes custody, including for a file
    /// already inside the checkout, and never reuses the source's previous row. A build can write
    /// `progress.png` ten times and every notification still opens the version it announced.
    @discardableResult
    func recordSnapshot(
        of url: URL,
        sessionID: SessionID,
        origin: SessionAttachment.Origin,
        preferredName: String? = nil
    ) -> SessionAttachment? {
        loadIfNeeded(sessionID)
        let attachment = copiedAttachment(
            at: url,
            sessionID: sessionID,
            origin: origin,
            preferredName: preferredName,
            isOutsideProject: false,
            referencedAt: now(),
            isImmutableSnapshot: true
        )
        return attachment.flatMap { admit([$0], for: sessionID).first }
    }

    /// Captures bytes the caller already validated. This prevents the preview and its durable
    /// attachment from becoming two different revisions when an agent rewrites the source path
    /// between decoding and custody.
    @discardableResult
    func recordSnapshot(
        _ data: Data,
        of url: URL,
        sessionID: SessionID,
        origin: SessionAttachment.Origin,
        preferredName: String? = nil
    ) -> SessionAttachment? {
        loadIfNeeded(sessionID)
        let attachment = copiedAttachment(
            at: url,
            sessionID: sessionID,
            origin: origin,
            preferredName: preferredName,
            isOutsideProject: false,
            referencedAt: now(),
            isImmutableSnapshot: true,
            snapshotData: data
        )
        return attachment.flatMap { admit([$0], for: sessionID).first }
    }

    /// Records generated HTML in the same custody store and chronology as images and PDFs.
    @discardableResult
    func recordGeneratedHTML(
        _ html: String,
        title: String?,
        sessionID: SessionID,
        origin: SessionAttachment.Origin = .agent
    ) -> SessionAttachment? {
        recordGenerated(
            Data(html.utf8),
            title: title,
            fallbackTitle: "Document",
            fileExtension: "html",
            kind: .html,
            sessionID: sessionID,
            origin: origin
        )
    }

    /// Records a text comparison's unified diff, frozen as it was when the agent showed it.
    ///
    /// The Compare tab re-reads its two files and lives only in the Mac's panel; this is the same
    /// comparison as a file in the session's chronology, which is what a paired phone and a
    /// notification's `target_ref` can reach. A snapshot rather than a pair of references because
    /// the "before" side is routinely a scratch copy in `$TMPDIR` that is gone by the next turn.
    @discardableResult
    func recordGeneratedDiff(
        _ diff: Data,
        title: String,
        sessionID: SessionID,
        origin: SessionAttachment.Origin = .agent
    ) -> SessionAttachment? {
        recordGenerated(
            diff,
            title: title,
            fallbackTitle: "Comparison",
            fileExtension: "diff",
            kind: .diff,
            sessionID: sessionID,
            origin: origin
        )
    }

    /// Records that two of this session's pictures were compared, as one row per pair.
    ///
    /// Unlike a kept diff this is *not* a snapshot: it names the two picture rows, which follow
    /// their files exactly as the Compare tab does, so comparing the same pair again rewrites this
    /// row in its slot and lifts it to the top instead of adding another. `manifest` is the
    /// `RemoteImageComparisonDTO` a phone reads; the caller encodes it off the main actor.
    @discardableResult
    func recordImageComparison(
        _ manifest: Data,
        name: String,
        old: SessionAttachment,
        new: SessionAttachment,
        sessionID: SessionID
    ) -> SessionAttachment? {
        loadIfNeeded(sessionID)
        guard let root = copiesRoot(for: sessionID) else { return nil }

        let sourcePath = SessionAttachment.comparisonSourcePath(old: old.id, new: new.id)
        let existing = attachmentsBySession[sessionID]?.first { $0.sourcePath == sourcePath }
        let relativePath = existing?.relativePath
            ?? "\(UUID().uuidString)/\(Self.safeGeneratedName(name)).comparison"
        let destination = root.appendingPathComponent(relativePath)
        guard writeSnapshot(manifest, to: destination, sourceName: name) else { return nil }

        let attachment = SessionAttachment(
            sessionID: sessionID,
            id: existing?.id ?? UUID().uuidString.lowercased(),
            root: root,
            url: destination,
            relativePath: relativePath,
            sourcePath: sourcePath,
            kind: .comparison,
            origin: .agent,
            referencedAt: now()
        )
        return admit([attachment], for: sessionID).first
    }

    /// Writes bytes the app produced into custody as one immutable row. Never deduplicated: each
    /// call is its own moment, so a notification opens the version it announced.
    private func recordGenerated(
        _ data: Data,
        title: String?,
        fallbackTitle: String,
        fileExtension: String,
        kind: SessionAttachment.Kind,
        sessionID: SessionID,
        origin: SessionAttachment.Origin
    ) -> SessionAttachment? {
        loadIfNeeded(sessionID)
        guard let root = copiesRoot(for: sessionID) else { return nil }

        let id = UUID().uuidString.lowercased()
        let suppliedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = suppliedTitle.isEmpty ? fallbackTitle : Self.safeGeneratedName(suppliedTitle)
        let relativePath = "\(UUID().uuidString)/\(base).\(fileExtension)"
        let destination = root.appendingPathComponent(relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            ThreadingLogger.session.error(
                "Failed to keep generated \(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        let attachment = SessionAttachment(
            sessionID: sessionID,
            id: id,
            root: root,
            url: destination,
            relativePath: relativePath,
            sourcePath: "generated-\(kind.rawValue):\(id)",
            kind: kind,
            origin: origin,
            isImmutableSnapshot: true,
            referencedAt: now()
        )
        return admit([attachment], for: sessionID).first
    }

    // MARK: The scope the scanned door is held to

    /// Remembers a refused path so the pane can say what the narrow scope is costing.
    ///
    /// Bounded like the list itself, newest first, and deduplicated against what is already
    /// listed: a file the user declared from `$TMPDIR` is in the pane already, and counting it
    /// again as withheld would offer to reveal something that is not hidden.
    private func noteWithheld(
        _ urls: [URL], for sessionID: SessionID,
        context: AttachmentReferenceContext = .main
    ) {
        loadIfNeeded(sessionID)
        let listed = Set((attachmentsBySession[sessionID] ?? []).map(\.sourcePath))
        var current = withheldBySession[sessionID] ?? []
        // By set rather than by scanning the list per path: a scan may offer a capful of
        // candidates and this runs on the main thread with the rest of them.
        var held = Set(current.map(\.path))
        var changed = false

        // Only the newest capful can survive, so the rest are not built at all. Inserting each
        // of a scan's 512 candidates at the front of a growing array and *then* truncating to 32
        // is quadratic in what an agent happened to print, and it showed: it made refusing a
        // buffer twice as expensive as admitting one (`attachment-stress`).
        for url in urls.suffix(SessionAttachmentDefaults.maximumWithheldPerSession) {
            if let index = current.firstIndex(where: { $0.path == url.path }) {
                let merged = current[index].context.merging(context)
                changed = changed || merged != current[index].context
                current[index].context = merged
                continue
            }
            guard !listed.contains(url.path),
                  held.insert(url.path).inserted,
                  let kind = AttachmentReferenceDetector.kind(for: url) else {
                continue
            }
            current.insert(WithheldAttachmentReference(path: url.path, kind: kind, context: context), at: 0)
            changed = true
        }
        guard changed else { return }

        if current.count > SessionAttachmentDefaults.maximumWithheldPerSession {
            current.removeLast(
                current.count - SessionAttachmentDefaults.maximumWithheldPerSession
            )
        }
        withheldBySession[sessionID] = current
        // The pane's footer is drawn from this count, so a refusal is a change to what the
        // session has to show even though nothing entered the list.
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
    }

    /// Referencing an already admitted file adds provenance without widening file authority or
    /// recopying a deliberate handoff while outside-project discovery is disabled.
    private func attributeExistingReferences(
        _ urls: [URL], for sessionID: SessionID, context: AttachmentReferenceContext
    ) {
        loadIfNeeded(sessionID)
        guard var rows = attachmentsBySession[sessionID] else { return }
        let paths = Set(urls.map(\.path))
        var changed = false
        for index in rows.indices where !rows[index].isImmutableSnapshot && paths.contains(rows[index].sourcePath) {
            let merged = AttachmentAgentSource.merged(rows[index].agentSources, context.sources)
            guard merged != rows[index].agentSources else { continue }
            rows[index].agentSources = merged
            changed = true
        }
        guard changed else { return }
        attachmentsBySession[sessionID] = rows
        persist(rows, for: sessionID)
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
    }

    /// How many files this session would list if the scope were the other way round.
    ///
    /// The one number the pane needs, and the reason it can stay quiet: zero means the setting
    /// changes nothing here, so there is nothing worth saying. Under the narrow scope it counts
    /// what was refused plus anything admitted while the scope was wide and now hidden; under
    /// the wide scope it counts what narrowing would take away.
    func countOfFilesOutsideProject(for sessionID: SessionID) -> Int {
        listSnapshot(for: sessionID).countOfFilesOutsideProject
    }

    /// Everything the narrow scope refused for this session, newest first.
    func withheldReferences(for sessionID: SessionID) -> [WithheldAttachmentReference] {
        withheldBySession[sessionID] ?? []
    }

    func sessionsWithWithheldReferences() -> [SessionID] {
        withheldBySession.compactMap { $0.value.isEmpty ? nil : $0.key }
    }

    /// Takes custody of what was refused, for the moment the user widens the scope.
    ///
    /// Without this, widening only takes effect for paths printed *again* — the terminal's
    /// buffer is not re-read on a settings change, so the pane would answer an explicit "yes,
    /// show me those" with an unchanged list until the agent happened to mention them.
    @discardableResult
    func admitWithheldFilesOutsideProject(for sessionID: SessionID) -> [SessionAttachment] {
        guard allowsFilesOutsideProject(),
              let withheld = withheldBySession[sessionID],
              !withheld.isEmpty else {
            return []
        }
        return admitOutsideProject(
            withheld.map { URL(fileURLWithPath: $0.path) },
            sessionID: sessionID
        )
    }

    // MARK: Recording — admission

    /// Files newest-first, capped, persisted, announced — the half both doors share.
    private func admit(
        _ made: [SessionAttachment],
        for sessionID: SessionID,
        discardingCopiesOnWorker: Bool = false
    ) -> [SessionAttachment] {
        guard !made.isEmpty else { return [] }

        // Loaded first, so a reference arriving before the pane was ever opened lands on top
        // of the persisted history rather than replacing it.
        loadIfNeeded(sessionID)
        let current = attachmentsBySession[sessionID] ?? []
        var discarded: [SessionAttachment] = []

        // Sequentially filtering and front-inserting one row at a time made a full replacement
        // quadratic twice over: every new source scanned the growing list to prove it was new,
        // then scanned it again to remove nothing. Derive the same winners once. The last mutable
        // row for a source wins; immutable snapshots all survive; reversing the survivors is the
        // exact chronology produced by repeated insert-at-front.
        var winningMutableIndex: [String: Int] = [:]
        for (index, attachment) in made.enumerated() where !attachment.isImmutableSnapshot {
            winningMutableIndex[attachment.sourcePath] = index
        }
        let currentBySource = Dictionary(
            current.filter { !$0.isImmutableSnapshot }.map { ($0.sourcePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let attributed = made.map { incoming -> SessionAttachment in
            guard !incoming.isImmutableSnapshot,
                  let previous = currentBySource[incoming.sourcePath] else { return incoming }
            var merged = incoming
            merged.id = previous.id
            merged.turnID = incoming.turnID ?? previous.turnID
            merged.agentSources = AttachmentAgentSource.merged(previous.agentSources, incoming.agentSources)
            if previous.origin == .user {
                merged.origin = .user
                merged.turnID = previous.turnID
                merged.turnPlacement = previous.turnPlacement
            }
            return merged
        }
        let survivingMade = attributed.enumerated().compactMap { index, attachment in
            attachment.isImmutableSnapshot || winningMutableIndex[attachment.sourcePath] == index
                ? attachment
                : nil
        }
        let winnersBySource = Dictionary(
            uniqueKeysWithValues: survivingMade.lazy
                .filter { !$0.isImmutableSnapshot }
                .map { ($0.sourcePath, $0) }
        )
        let survivingCurrent = current.filter { attachment in
            guard !attachment.isImmutableSnapshot,
                  let winner = winnersBySource[attachment.sourcePath] else {
                return true
            }
            // A copy that kept its slot is the same file on disk, now overwritten; only one that
            // lost its slot leaves bytes behind.
            if attachment.relativePath != winner.relativePath {
                discarded.append(attachment)
            }
            return false
        }
        for (index, attachment) in made.enumerated()
            where !attachment.isImmutableSnapshot
                && winningMutableIndex[attachment.sourcePath] != index {
            guard let winner = winnersBySource[attachment.sourcePath],
                  attachment.relativePath != winner.relativePath else {
                continue
            }
            discarded.append(attachment)
        }

        var admitted = Array(survivingMade.reversed()) + survivingCurrent
        if admitted.count > SessionAttachmentDefaults.maximumPerSession {
            discarded.append(
                contentsOf: admitted.suffix(
                    admitted.count - SessionAttachmentDefaults.maximumPerSession
                )
            )
            admitted.removeLast(admitted.count - SessionAttachmentDefaults.maximumPerSession)
        }
        attachmentsBySession[sessionID] = admitted
        if discardingCopiesOnWorker {
            discardCopiesOnWorker(in: discarded)
        } else {
            discardCopies(in: discarded)
        }
        persist(admitted, for: sessionID)
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
        return attributed
    }

    // MARK: Reading

    /// The session's list, as everything downstream of this type is allowed to see it.
    ///
    /// The scope gate lives here rather than at admission because *here* is the one place the
    /// pane, the MCP tools and the phone's endpoint all pass through. A row admitted while the
    /// scope was wide keeps its bytes and its slot, and simply stops being visible — so turning
    /// the setting off is immediate and total, and turning it back on costs nothing.
    /// The pane needs the visible rows and the scope-band count from the same validated state.
    /// Returning both prevents a refresh from `stat`ing the full capped list once for each fact.
    func listSnapshot(for sessionID: SessionID) -> ListSnapshot {
        let current = validated(sessionID)
        let listedOutside = current.filter(\.isOutsideProject)
        if allowsFilesOutsideProject() {
            return ListSnapshot(
                attachments: current,
                countOfFilesOutsideProject: listedOutside.count
            )
        }

        let alreadyCounted = Set(listedOutside.map(\.sourcePath))
        let withheld = (withheldBySession[sessionID] ?? [])
            .filter { !alreadyCounted.contains($0.path) }
        return ListSnapshot(
            attachments: current.filter { !$0.isOutsideProject },
            countOfFilesOutsideProject: listedOutside.count + withheld.count
        )
    }

    func attachments(for sessionID: SessionID) -> [SessionAttachment] {
        listSnapshot(for: sessionID).attachments
    }

    /// A search projection of state this launch has already paid to load and validate.
    ///
    /// Universal Search may span thousands of sessions. Making its presentation path call
    /// `attachments(for:)` for every one would synchronously hydrate SQLite payloads and stat
    /// every referenced file on the main actor. A missing value therefore means "not loaded",
    /// not "empty"; the provider reports that coverage honestly. Activation still passes
    /// through `attachment(for:id:)`, which revalidates the selected file before opening it.
    func loadedAttachmentsSnapshot(for sessionID: SessionID) -> [SessionAttachment]? {
        guard loadedSessions.contains(sessionID) else { return nil }
        let stored = attachmentsBySession[sessionID] ?? []
        return allowsFilesOutsideProject()
            ? stored
            : stored.filter { !$0.isOutsideProject }
    }

    /// The stored list with every entry re-proven against the filesystem, scope not applied.
    private func validated(_ sessionID: SessionID) -> [SessionAttachment] {
        loadIfNeeded(sessionID)
        guard let stored = attachmentsBySession[sessionID] else { return [] }
        let current = stored.compactMap {
            referencedAttachment(
                at: $0.url,
                sessionID: sessionID,
                root: $0.root,
                origin: $0.origin,
                agentSources: $0.agentSources,
                sourcePath: $0.sourcePath,
                isOutsideProject: $0.isOutsideProject,
                id: $0.id,
                isImmutableSnapshot: $0.isImmutableSnapshot,
                turnID: $0.turnID,
                turnPlacement: $0.turnPlacement,
                referencedAt: $0.referencedAt
            )
        }
        if current != stored {
            attachmentsBySession[sessionID] = current
            persist(current, for: sessionID)
        }
        return current
    }

    func attachment(
        for sessionID: SessionID,
        relativePath: String
    ) -> SessionAttachment? {
        attachments(for: sessionID).first { $0.relativePath == relativePath }
    }

    func attachment(for sessionID: SessionID, id: String) -> SessionAttachment? {
        attachments(for: sessionID).first { $0.id == id }
    }

    /// Pins already-recorded prompt files to the provider-neutral turn identity minted by the
    /// native submission path. Recording has to happen before admission, while the turn id is
    /// only known after admission, so this is deliberately one small atomic upgrade rather than
    /// a second attachment record (which would copy bytes and reorder rows).
    func associate(
        attachmentIDs: [String],
        withTurnID turnID: String,
        for sessionID: SessionID
    ) {
        guard !attachmentIDs.isEmpty, !turnID.isEmpty else { return }
        loadIfNeeded(sessionID)
        let ids = Set(attachmentIDs)
        guard var attachments = attachmentsBySession[sessionID] else { return }
        var changed = false
        for index in attachments.indices where ids.contains(attachments[index].id) {
            let attachment = attachments[index]
            guard attachment.turnID != turnID else { continue }
            attachments[index] = SessionAttachment(
                sessionID: attachment.sessionID,
                id: attachment.id,
                root: attachment.root,
                url: attachment.url,
                relativePath: attachment.relativePath,
                sourcePath: attachment.sourcePath,
                kind: attachment.kind,
                origin: attachment.origin,
                agentSources: attachment.agentSources,
                isOutsideProject: attachment.isOutsideProject,
                isImmutableSnapshot: attachment.isImmutableSnapshot,
                turnID: turnID,
                turnPlacement: attachment.turnPlacement,
                referencedAt: attachment.referencedAt
            )
            changed = true
        }
        guard changed else { return }
        attachmentsBySession[sessionID] = attachments
        persist(attachments, for: sessionID)
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
    }

    func retainOnly(sessionIDs: Set<SessionID>) {
        attachmentsBySession = attachmentsBySession.filter { sessionIDs.contains($0.key) }
        withheldBySession = withheldBySession.filter { sessionIDs.contains($0.key) }
        loadedSessions = loadedSessions.intersection(sessionIDs)
        retainPersisted?(sessionIDs)
        discardCopiesOutside(sessionIDs)
    }

    /// Drops one deleted session without filtering every in-memory entry or enumerating every
    /// attachment directory. Owned bytes can leave on a utility worker after their references
    /// have disappeared from the main-thread store.
    func removeSession(_ sessionID: SessionID) {
        attachmentsBySession.removeValue(forKey: sessionID)
        withheldBySession.removeValue(forKey: sessionID)
        loadedSessions.remove(sessionID)
        removePersisted?(sessionID)

        guard let directory = copiesRoot(for: sessionID) else { return }
        Task.detached(priority: .utility) {
            try? FileManager().removeItem(at: directory)
        }
    }

    /// Drops a removed project's in-memory references and owned copies as one batch. The project
    /// removal deleted its sessions' attachment rows in its own transaction (the table has no
    /// foreign key for a cascade to follow), so issuing one redundant SQLite delete per session
    /// here would only put commit latency back on AppKit.
    func removeSessionsAfterProjectDeletion(_ sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        var directories: [URL] = []
        directories.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            attachmentsBySession.removeValue(forKey: sessionID)
            withheldBySession.removeValue(forKey: sessionID)
            loadedSessions.remove(sessionID)
            if let directory = copiesRoot(for: sessionID) { directories.append(directory) }
        }
        Task.detached(priority: .utility) {
            let fileManager = FileManager()
            for directory in directories {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    // MARK: Persistence

    /// A later provider descriptor can name a child that was initially known only by id. Repair
    /// that metadata without rereading files, changing chronology or recopying attachments.
    func updateAgentSource(_ source: AttachmentAgentSource, for sessionID: SessionID) {
        guard let threadID = source.threadID else { return }
        loadIfNeeded(sessionID)
        var rows = attachmentsBySession[sessionID] ?? []
        var changed = false
        for index in rows.indices {
            guard let sourceIndex = rows[index].agentSources.firstIndex(where: { $0.threadID == threadID }),
                  rows[index].agentSources[sourceIndex] != source else { continue }
            rows[index].agentSources[sourceIndex] = source
            changed = true
        }
        if var withheld = withheldBySession[sessionID] {
            for index in withheld.indices {
                guard let sourceIndex = withheld[index].context.sources.firstIndex(where: { $0.threadID == threadID }) else { continue }
                withheld[index].context.sources[sourceIndex] = source
            }
            withheldBySession[sessionID] = withheld
        }
        guard changed else { return }
        attachmentsBySession[sessionID] = rows
        persist(rows, for: sessionID)
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
    }

    /// Fills a session's list from the store once. Entries are not validated here — reading
    /// already validates on every access, and a file deleted while the app was closed should
    /// fall out the same way as one deleted while it ran.
    private func loadIfNeeded(_ sessionID: SessionID) {
        guard !loadedSessions.contains(sessionID) else { return }
        // A worker-backed host installs a prepared snapshot later. An early read must not
        // claim the session was loaded with no rows and make that receipt disappear.
        guard persistPreparedRows == nil || loadPayload != nil else { return }
        loadedSessions.insert(sessionID)
        guard attachmentsBySession[sessionID] == nil,
              let payload = loadPayload?(sessionID),
              let rows = try? SessionAttachmentPersistenceCodec.restore(
                  payload,
                  sessionID: sessionID,
                  referenceRoot: referenceRoot?(sessionID),
                  copiesRoot: copiesRoot(for: sessionID)
              )
        else { return }
        attachmentsBySession[sessionID] = rows
    }

    /// Installs a worker-decoded, authority-checked snapshot before this session is read.
    /// Linux uses this on a worker receipt; repeated or late receipts cannot replace live edits.
    @discardableResult
    func installPrepared(_ rows: [SessionAttachment], for sessionID: SessionID) -> Bool {
        guard !loadedSessions.contains(sessionID) else { return false }
        let live = attachmentsBySession[sessionID] ?? []
        let liveIDs = Set(live.map(\.id))
        let liveSources = Set(live.map(\.sourcePath))
        let older = rows.filter {
            !liveIDs.contains($0.id) && !liveSources.contains($0.sourcePath)
        }
        let merged = Array((older + live).suffix(SessionAttachmentDefaults.maximumPerSession))
        loadedSessions.insert(sessionID)
        attachmentsBySession[sessionID] = merged
        if !live.isEmpty { persist(merged, for: sessionID) }
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
        return true
    }

    private func persist(_ attachments: [SessionAttachment], for sessionID: SessionID) {
        if let persistPreparedRows {
            persistPreparedRows(attachments, sessionID)
            return
        }
        guard let savePayload else { return }
        guard let payload = try? SessionAttachmentPersistenceCodec.serialize(attachments) else { return }
        savePayload(payload, sessionID)
    }

    // MARK: Validation

    /// A file kept as a reference, proven to be a regular supported file inside `root`.
    private func referencedAttachment(
        at url: URL,
        sessionID: SessionID,
        root: URL,
        origin: SessionAttachment.Origin,
        agentSources: [AttachmentAgentSource]? = nil,
        sourcePath: String? = nil,
        isOutsideProject: Bool = false,
        id: String? = nil,
        isImmutableSnapshot: Bool = false,
        turnID: String? = nil,
        turnPlacement: SessionAttachment.TurnPlacement = .current,
        referencedAt: Date
    ) -> SessionAttachment? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard AttachmentReferenceDetector.contains(file, inside: base),
              let kind = AttachmentReferenceDetector.kind(for: file),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }

        let rootPrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let relativePath = String(file.path.dropFirst(rootPrefix.count))
        guard !relativePath.isEmpty else { return nil }

        return SessionAttachment(
            sessionID: sessionID,
            id: id ?? UUID().uuidString.lowercased(),
            root: base,
            url: file,
            relativePath: relativePath,
            sourcePath: sourcePath ?? file.path,
            kind: kind,
            origin: origin,
            agentSources: agentSources,
            isOutsideProject: isOutsideProject,
            isImmutableSnapshot: isImmutableSnapshot,
            turnID: turnID,
            turnPlacement: turnPlacement,
            referencedAt: referencedAt
        )
    }

    /// A file handed over on purpose: referenced when it is already in the checkout, copied into
    /// the store's own directory when it is not.
    private func declaredAttachment(
        at url: URL,
        sessionID: SessionID,
        projectRoot: URL,
        origin: SessionAttachment.Origin,
        preferredName: String?,
        turnID: String?,
        turnPlacement: SessionAttachment.TurnPlacement,
        referencedAt: Date
    ) -> SessionAttachment? {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let checkout = projectRoot.standardizedFileURL.resolvingSymlinksInPath()

        if AttachmentReferenceDetector.contains(file, inside: checkout) {
            return referencedAttachment(
                at: file,
                sessionID: sessionID,
                root: checkout,
                origin: origin,
                turnID: turnID,
                turnPlacement: turnPlacement,
                referencedAt: referencedAt
            )
        }

        return copiedAttachment(
            at: file,
            sessionID: sessionID,
            origin: origin,
            preferredName: preferredName,
            isOutsideProject: false,
            turnID: turnID,
            turnPlacement: turnPlacement,
            referencedAt: referencedAt
        )
    }

    /// The custody half: bytes taken into the store's own directory, wherever they came from.
    ///
    /// Shared by the two callers that need it for different reasons — a declared file that is
    /// simply not in the checkout, and a scanned one admitted under the widened scope — so the
    /// rule that every listed file sits somewhere the app controls has exactly one implementation.
    private func copiedAttachment(
        at url: URL,
        sessionID: SessionID,
        origin: SessionAttachment.Origin,
        preferredName: String?,
        isOutsideProject: Bool,
        turnID: String? = nil,
        turnPlacement: SessionAttachment.TurnPlacement = .current,
        referencedAt: Date,
        isImmutableSnapshot: Bool = false,
        snapshotData: Data? = nil
    ) -> SessionAttachment? {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()

        guard let kind = AttachmentReferenceDetector.kind(for: file),
              let root = copiesRoot(for: sessionID) else {
            return nil
        }
        if snapshotData == nil {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
        }

        // A second mention of the same source reuses the slot it already has, so the row keeps
        // its identity — and therefore its place on the remote wire — while the bytes are
        // refreshed underneath it.
        let name = preferredName.map { sanitized($0, matching: file) } ?? file.lastPathComponent
        let existing = isImmutableSnapshot ? nil : attachmentsBySession[sessionID]?.first {
            !$0.isImmutableSnapshot && $0.sourcePath == file.path
                && AttachmentReferenceDetector.contains($0.url, inside: root)
        }
        let relativePath = existing?.relativePath ?? "\(UUID().uuidString)/\(name)"
        let destination = root.appendingPathComponent(relativePath)

        let stored = if let snapshotData {
            writeSnapshot(snapshotData, to: destination, sourceName: file.lastPathComponent)
        } else {
            copy(file, to: destination)
        }
        guard stored else { return nil }

        return SessionAttachment(
            sessionID: sessionID,
            id: existing?.id ?? UUID().uuidString.lowercased(),
            root: root,
            url: destination,
            relativePath: relativePath,
            sourcePath: file.path,
            kind: kind,
            origin: origin,
            isOutsideProject: isOutsideProject,
            isImmutableSnapshot: isImmutableSnapshot,
            turnID: turnID,
            turnPlacement: turnPlacement,
            referencedAt: referencedAt
        )
    }

    private static func safeGeneratedName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let result = value.unicodeScalars.map {
            forbidden.contains($0) ? "-" : String($0)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(result.prefix(80))
        return bounded.isEmpty ? "Document" : bounded
    }

    // MARK: Copies

    private func copiesRoot(for sessionID: SessionID) -> URL? {
        copiesDirectory?().appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Keeps the name readable and the extension truthful: the preview and the remote content
    /// type are both chosen from the extension, so a rename may not change it.
    private func sanitized(_ name: String, matching file: URL) -> String {
        let base = URL(fileURLWithPath: name)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        guard !base.isEmpty else { return file.lastPathComponent }
        return "\(base).\(file.pathExtension)"
    }

    private func copy(_ file: URL, to destination: URL) -> Bool {
        let directory = destination.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent(".threading-copy-\(UUID().uuidString)")
        let backup = directory.appendingPathComponent(".threading-backup-\(UUID().uuidString)")
        var movedStandingCopy = false
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: file, to: candidate)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedStandingCopy = true
            }
            try fileManager.moveItem(at: candidate, to: destination)
            if movedStandingCopy {
                do {
                    try fileManager.removeItem(at: backup)
                } catch {
                    ThreadingLogger.session.warning(
                        "Attachment replacement left a stale backup source=\(backup.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
            return true
        } catch {
            try? fileManager.removeItem(at: candidate)
            if movedStandingCopy {
                if !fileManager.fileExists(atPath: destination.path) {
                    do {
                        try fileManager.moveItem(at: backup, to: destination)
                    } catch {
                        ThreadingLogger.session.fault(
                            "Attachment rollback left its previous copy at \(backup.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                        )
                    }
                } else {
                    ThreadingLogger.session.fault(
                        "Attachment replacement conflicted; its previous copy remains recoverable at \(backup.path, privacy: .private(mask: .hash))"
                    )
                }
            }
            ThreadingLogger.session.error(
                "Failed to keep attachment \(file.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    private func writeSnapshot(_ data: Data, to destination: URL, sourceName: String) -> Bool {
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            ThreadingLogger.session.error(
                "Failed to keep attachment \(sourceName, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    /// Removes the bytes behind rows that have left the list. A referenced file is untouched —
    /// it belongs to the checkout, and evicting a row is not a reason to delete the user's file.
    private func discardCopies(in attachments: [SessionAttachment]) {
        Self.discardCopySlots(copySlots(in: attachments))
    }

    /// An async admission has already done its expensive file work on a worker. Once its new
    /// list is installed, evicted slots are no longer remotely addressable, so deleting those
    /// private bytes can follow on a utility worker instead of stalling that admission.
    private func discardCopiesOnWorker(in attachments: [SessionAttachment]) {
        let slots = copySlots(in: attachments)
        guard !slots.isEmpty else { return }
        Task.detached(priority: .utility) {
            Self.discardCopySlots(slots)
        }
    }

    /// Resolves owned slot directories while still on the store's actor. The detached deleter
    /// receives only immutable URLs and never consults or mutates attachment state.
    private func copySlots(in attachments: [SessionAttachment]) -> [URL] {
        var roots: [SessionID: URL] = [:]
        return attachments.compactMap { attachment -> URL? in
            let root: URL
            if let known = roots[attachment.sessionID] {
                root = known
            } else {
                guard let resolved = copiesRoot(for: attachment.sessionID) else { return nil }
                roots[attachment.sessionID] = resolved
                root = resolved
            }
            return Self.ownedCopySlot(for: attachment, in: root)
        }
    }

    /// Rows are minted as `slot/name` beneath a trusted per-session root. Re-proving that shape
    /// from immutable state is enough before cleanup and avoids standardising the same 64 URLs
    /// on the event loop. Explicit component checks retain the traversal guard a raw prefix would
    /// lose for a damaged persisted relative path.
    private nonisolated static func ownedCopySlot(
        for attachment: SessionAttachment,
        in root: URL
    ) -> URL? {
        let components = attachment.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }),
              attachment.root == root,
              let slot = components.first else {
            return nil
        }
        return root.appendingPathComponent(String(slot), isDirectory: true)
    }

    private nonisolated static func discardCopySlots(_ slots: [URL]) {
        guard !slots.isEmpty else { return }
        let fileManager = FileManager()
        var failureCount = 0
        for slot in slots {
            do {
                try fileManager.removeItem(at: slot)
            } catch {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            ThreadingLogger.session.warning(
                "Attachment copy cleanup incomplete failures=\(failureCount, privacy: .public) candidates=\(slots.count, privacy: .public)"
            )
        }
    }

    private func discardCopiesOutside(_ sessionIDs: Set<SessionID>) {
        guard let directory = copiesDirectory?() else { return }
        let kept = Set(sessionIDs.map(\.uuidString))
        Task.detached(priority: .utility) {
            let fileManager = FileManager()
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            } catch {
                ThreadingLogger.session.warning(
                    "Attachment copy cleanup could not enumerate directory=\(directory.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                return
            }
            var failureCount = 0
            for url in contents where !kept.contains(url.lastPathComponent) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    failureCount += 1
                }
            }
            if failureCount > 0 {
                ThreadingLogger.session.warning(
                    "Attachment orphan cleanup incomplete failures=\(failureCount, privacy: .public) candidates=\(contents.count, privacy: .public)"
                )
            }
        }
    }
}

// MARK: - Persisted document codec

/// The Mac store and Linux's bounded persistence worker use the same document and trust rule.
/// Callers provide the live roots; a root embedded in SQLite is evidence, never authority.
enum SessionAttachmentPersistenceCodec {
    static func restore(
        _ payload: String,
        sessionID: SessionID,
        referenceRoot: URL?,
        copiesRoot: URL?
    ) throws -> [SessionAttachment] {
        let document = try JSONDecoder().decode(
            PersistedSessionAttachments.self, from: Data(payload.utf8)
        )
        let trusted = [referenceRoot, copiesRoot]
            .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath() }
        return document.entries.compactMap { entry in
            let candidate = URL(fileURLWithPath: entry.root, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard trusted.contains(candidate) else { return nil }
            let url = candidate.appendingPathComponent(entry.relativePath)
            // A future kind is re-derived from the file; one unreadable row does not discard
            // the rest of a compatible document.
            guard let kind = entry.kind ?? AttachmentReferenceDetector.kind(for: url) else {
                return nil
            }
            return SessionAttachment(
                sessionID: sessionID,
                id: entry.id ?? legacyID(sessionID: sessionID,
                                          root: entry.root, relativePath: entry.relativePath),
                root: candidate,
                url: url,
                relativePath: entry.relativePath,
                sourcePath: entry.sourcePath ?? url.path,
                kind: kind,
                origin: entry.origin ?? .agent,
                agentSources: entry.agentSources,
                isOutsideProject: entry.isOutsideProject ?? false,
                isImmutableSnapshot: entry.isImmutableSnapshot ?? false,
                turnID: entry.turnID,
                turnPlacement: entry.turnPlacement
                    ?? ((entry.origin ?? .agent) == .user ? .next : .current),
                referencedAt: entry.referencedAt
            )
        }
    }

    static func serialize(_ attachments: [SessionAttachment]) throws -> String {
        let entries = attachments.map {
            PersistedSessionAttachment(
                id: $0.id,
                root: $0.root.path,
                relativePath: $0.relativePath,
                sourcePath: $0.sourcePath,
                kind: $0.kind,
                origin: $0.origin,
                agentSources: $0.agentSources,
                isOutsideProject: $0.isOutsideProject ? true : nil,
                isImmutableSnapshot: $0.isImmutableSnapshot ? true : nil,
                turnID: $0.turnID,
                turnPlacement: $0.turnPlacement,
                referencedAt: $0.referencedAt
            )
        }
        let data = try JSONEncoder().encode(PersistedSessionAttachments(entries: entries))
        return String(decoding: data, as: UTF8.self)
    }

    private static func legacyID(
        sessionID: SessionID, root: String, relativePath: String
    ) -> String {
        let value = "\(sessionID.uuidString)|\(root)|\(relativePath)"
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Converts a worker-checked detector result into the same mutable reference rows on both
/// desktop hosts. File-kind probes stay on the caller's worker for native Linux output.
enum SessionAttachmentScannedRowPreparation {
    static func insideProject(
        _ urls: [URL],
        sessionID: SessionID,
        projectRoot: URL,
        context: AttachmentReferenceContext,
        referencedAt: Date
    ) -> [SessionAttachment] {
        let rootPrefix = projectRoot.path.hasSuffix("/")
            ? projectRoot.path
            : projectRoot.path + "/"
        return urls.suffix(SessionAttachmentDefaults.maximumPerSession).compactMap { url in
            guard AttachmentReferenceDetector.contains(url, inside: projectRoot),
                  let kind = AttachmentReferenceDetector.kind(for: url) else {
                return nil
            }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { return nil }
            return SessionAttachment(
                sessionID: sessionID,
                id: UUID().uuidString.lowercased(),
                root: projectRoot,
                url: url,
                relativePath: relativePath,
                sourcePath: url.path,
                kind: kind,
                origin: .agent,
                agentSources: context.sources,
                turnID: context.turnID,
                referencedAt: referencedAt
            )
        }
    }
}

// MARK: - Defaults

enum SessionAttachmentDefaults {
    static let maximumPerSession = 64

    /// The diagram-source cap, far under the general preview ceiling: source lands in a text view,
    /// and a text view is bounded by what it must lay out, not by what the disk can hold. Any real
    /// dot or Mermaid file is kilobytes. The DOT/GV text preview and the Mermaid reader share it.
    static let maximumSourcePreviewBytes = 512 * 1024

    /// How many refused paths one session remembers. Smaller than the list itself on purpose:
    /// this is a *hint* about a setting, not a queue, and "12 files outside this project" and
    /// "everything an afternoon of `find` printed" are the same sentence to the person reading it.
    static let maximumWithheldPerSession = 32
    static let terminalQuietInterval: TimeInterval = 0.65
    /// How stale the last scan may be before busy output scans again instead of re-arming the
    /// quiet debounce. The scan reads a bounded buffer, so the cap costs a regex pass every
    /// couple of seconds during sustained output and nothing when the terminal is idle.
    static let terminalBusyScanInterval: TimeInterval = 2.0
    static let maximumTerminalScanBytes = 256 * 1024
    /// How many already-offered paths an observer remembers. Covers far more history than the
    /// read window while staying bounded, which the previous whole-scrollback set was not.
    static let rememberedScannedPaths = 512
}

enum TranscriptAttachmentDefaults {
    /// A tail large enough for a tool-heavy final turn without walking a conversation-sized file.
    static let transcriptScanBytes = 2 * 1024 * 1024
    /// The first read is normally complete; the later reads close the hook-vs-writer flush race.
    static let stabilityDelays: [TimeInterval] = [0, 0.5, 1.5]
}
