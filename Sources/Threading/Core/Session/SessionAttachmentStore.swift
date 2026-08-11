import CryptoKit
import Foundation

// MARK: - Attachment

/// An inspectable file that passed between the two parties in one session: an image, a PDF,
/// generated HTML, an archive, or an open document format.
///
/// Attachments inside the checkout are references, not copies. The project file remains
/// authoritative, so replacing an image or PDF at the same path updates every preview without
/// growing a second cache. A file from anywhere else is copied into the store's own directory
/// instead — see `SessionAttachmentStore` for why that exception exists and where it stops.
struct SessionAttachment: Equatable, Identifiable {

    enum Kind: String, Codable {
        case image
        case pdf
        case html
        case archive
        case document
        /// Diagram *source* — Graphviz dot, Mermaid. Text, not pixels: the pane previews the
        /// source itself, since rendering would take a diagram engine the app does not carry.
        case diagram
    }

    /// Which side of the conversation put the file in front of the other.
    ///
    /// The distinction is not decorative: the pane mixed the two silently, because a terminal
    /// scan reads the whole buffer and cannot tell a path the agent printed from one the user
    /// typed. Everything discovered by scanning is therefore `agent` — the session surfaced it —
    /// and `user` is reserved for a deliberate handoff from the composer, which is the thing
    /// someone means when they ask where the picture they sent went.
    enum Origin: String, Codable {
        case agent
        case user
    }

    /// Opaque identity used by notifications and remote fetches. A path remains presentation
    /// metadata; it is neither authority nor identity once two captures can come from one file.
    let id: String

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
    let origin: Origin

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
        isOutsideProject: Bool = false,
        isImmutableSnapshot: Bool = false,
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
        self.isOutsideProject = isOutsideProject
        self.isImmutableSnapshot = isImmutableSnapshot
        self.referencedAt = referencedAt
    }

    var name: String { url.lastPathComponent }
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

    /// Hosted tests exercise the shared store; the user's real database is not theirs to write.
    static let shared: SessionAttachmentStore = {
        guard NSClassFromString("XCTestCase") == nil else {
            // The user's own database and attachment directory are not a test's to write, but
            // *refusing custody* is not the same as not writing: a store with nowhere to copy to
            // silently drops every declared file from outside the checkout, so a hosted test
            // would exercise a store that behaves like neither of the two real ones. Scratch
            // custody under `$TMPDIR` keeps both halves — the app's data untouched, the code
            // path real. The scope is read from the same setting for the same reason.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ThreadingTestAttachments/\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            return SessionAttachmentStore(
                copiesDirectory: { scratch },
                referenceRoot: { sessionID in
                    ProjectStore.shared.workingDirectory(forSessionID: sessionID).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                },
                allowsFilesOutsideProject: { AppSettings.shared.includesAttachmentsOutsideProject }
            )
        }
        return SessionAttachmentStore(
            loadPayload: { StateManager.shared.loadAttachmentsPayload(for: $0) },
            savePayload: { StateManager.shared.saveAttachmentsPayload($0, for: $1) },
            retainPersisted: { StateManager.shared.retainAttachments(sessionIDs: $0) },
            copiesDirectory: { StateManager.shared.attachmentCopiesDirectory },
            referenceRoot: { sessionID in
                ProjectStore.shared.workingDirectory(forSessionID: sessionID).map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            },
            allowsFilesOutsideProject: { AppSettings.shared.includesAttachmentsOutsideProject }
        )
    }()

    private var attachmentsBySession: [SessionID: [SessionAttachment]] = [:]
    private var withheldBySession: [SessionID: [WithheldAttachmentReference]] = [:]
    private var loadedSessions: Set<SessionID> = []
    private let fileManager: FileManager
    private let now: () -> Date
    private let loadPayload: ((SessionID) -> String?)?
    private let savePayload: ((String, SessionID) -> Void)?
    private let retainPersisted: ((Set<SessionID>) -> Void)?

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
        retainPersisted: ((Set<SessionID>) -> Void)? = nil,
        copiesDirectory: (() -> URL)? = nil,
        referenceRoot: ((SessionID) -> URL?)? = nil,
        allowsFilesOutsideProject: @escaping () -> Bool = { false }
    ) {
        self.fileManager = fileManager
        self.now = now
        self.loadPayload = loadPayload
        self.savePayload = savePayload
        self.retainPersisted = retainPersisted
        self.copiesDirectory = copiesDirectory
        self.referenceRoot = referenceRoot
        self.allowsFilesOutsideProject = allowsFilesOutsideProject
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
        let made = admissible.compactMap {
            // Straight to custody, not through `declaredAttachment`: these are outside the
            // checkout by construction, and copying is the whole reason they may be listed.
            copiedAttachment(
                at: $0,
                sessionID: sessionID,
                origin: .agent,
                preferredName: nil,
                isOutsideProject: true,
                referencedAt: timestamp
            )
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
        let attempted = Set(admissible.map(\.path))
        withheldBySession[sessionID]?.removeAll { attempted.contains($0.path) }
        return admit(made, for: sessionID)
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
        preferredName: String? = nil
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
        preferredName: String? = nil
    ) -> SessionAttachment? {
        record(
            declared: [url],
            sessionID: sessionID,
            projectRoot: projectRoot,
            origin: origin,
            preferredName: preferredName
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
        loadIfNeeded(sessionID)
        guard let root = copiesRoot(for: sessionID) else { return nil }

        let id = UUID().uuidString.lowercased()
        let suppliedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = suppliedTitle.isEmpty ? "Document" : Self.safeGeneratedName(suppliedTitle)
        let relativePath = "\(UUID().uuidString)/\(base).html"
        let destination = root.appendingPathComponent(relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(html.utf8).write(to: destination, options: .atomic)
        } catch {
            ThreadingLogger.session.error(
                "Failed to keep generated HTML: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        let attachment = SessionAttachment(
            sessionID: sessionID,
            id: id,
            root: root,
            url: destination,
            relativePath: relativePath,
            sourcePath: "generated-html:\(id)",
            kind: .html,
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
    private func noteWithheld(_ urls: [URL], for sessionID: SessionID) {
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
            guard !listed.contains(url.path),
                  held.insert(url.path).inserted,
                  let kind = AttachmentReferenceDetector.kind(for: url) else {
                continue
            }
            current.insert(WithheldAttachmentReference(path: url.path, kind: kind), at: 0)
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

    /// How many files this session would list if the scope were the other way round.
    ///
    /// The one number the pane needs, and the reason it can stay quiet: zero means the setting
    /// changes nothing here, so there is nothing worth saying. Under the narrow scope it counts
    /// what was refused plus anything admitted while the scope was wide and now hidden; under
    /// the wide scope it counts what narrowing would take away.
    func countOfFilesOutsideProject(for sessionID: SessionID) -> Int {
        let listed = validated(sessionID).filter(\.isOutsideProject)
        guard !allowsFilesOutsideProject() else { return listed.count }

        let alreadyCounted = Set(listed.map(\.sourcePath))
        let withheld = (withheldBySession[sessionID] ?? [])
            .filter { !alreadyCounted.contains($0.path) }
        return listed.count + withheld.count
    }

    /// Everything the narrow scope refused for this session, newest first.
    func withheldReferences(for sessionID: SessionID) -> [WithheldAttachmentReference] {
        withheldBySession[sessionID] ?? []
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
        for sessionID: SessionID
    ) -> [SessionAttachment] {
        guard !made.isEmpty else { return [] }

        // Loaded first, so a reference arriving before the pane was ever opened lands on top
        // of the persisted history rather than replacing it.
        loadIfNeeded(sessionID)
        var current = attachmentsBySession[sessionID] ?? []
        for attachment in made {
            let superseded = attachment.isImmutableSnapshot
                ? []
                : current.filter {
                    !$0.isImmutableSnapshot && $0.sourcePath == attachment.sourcePath
                }
            if !attachment.isImmutableSnapshot {
                current.removeAll {
                    !$0.isImmutableSnapshot && $0.sourcePath == attachment.sourcePath
                }
            }
            // A copy that kept its slot is the same file on disk, now overwritten; only one that
            // lost its slot leaves bytes behind.
            discardCopies(in: superseded.filter { $0.relativePath != attachment.relativePath })
            current.insert(attachment, at: 0)
        }
        if current.count > SessionAttachmentDefaults.maximumPerSession {
            let evicted = current.suffix(current.count - SessionAttachmentDefaults.maximumPerSession)
            discardCopies(in: Array(evicted))
            current.removeLast(current.count - SessionAttachmentDefaults.maximumPerSession)
        }
        attachmentsBySession[sessionID] = current
        persist(current, for: sessionID)
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
        return made
    }

    // MARK: Reading

    /// The session's list, as everything downstream of this type is allowed to see it.
    ///
    /// The scope gate lives here rather than at admission because *here* is the one place the
    /// pane, the MCP tools and the phone's endpoint all pass through. A row admitted while the
    /// scope was wide keeps its bytes and its slot, and simply stops being visible — so turning
    /// the setting off is immediate and total, and turning it back on costs nothing.
    func attachments(for sessionID: SessionID) -> [SessionAttachment] {
        let current = validated(sessionID)
        guard !allowsFilesOutsideProject() else { return current }
        return current.filter { !$0.isOutsideProject }
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
                sourcePath: $0.sourcePath,
                isOutsideProject: $0.isOutsideProject,
                id: $0.id,
                isImmutableSnapshot: $0.isImmutableSnapshot,
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

    func retainOnly(sessionIDs: Set<SessionID>) {
        attachmentsBySession = attachmentsBySession.filter { sessionIDs.contains($0.key) }
        withheldBySession = withheldBySession.filter { sessionIDs.contains($0.key) }
        loadedSessions = loadedSessions.intersection(sessionIDs)
        retainPersisted?(sessionIDs)
        discardCopiesOutside(sessionIDs)
    }

    // MARK: Persistence

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Fills a session's list from the store once. Entries are not validated here — reading
    /// already validates on every access, and a file deleted while the app was closed should
    /// fall out the same way as one deleted while it ran.
    private func loadIfNeeded(_ sessionID: SessionID) {
        guard !loadedSessions.contains(sessionID) else { return }
        loadedSessions.insert(sessionID)
        guard attachmentsBySession[sessionID] == nil,
              let payload = loadPayload?(sessionID),
              let document = try? Self.decoder.decode(
                  PersistedSessionAttachments.self,
                  from: Data(payload.utf8)
              )
        else { return }

        attachmentsBySession[sessionID] = document.entries.compactMap { entry in
            guard let root = trustedPersistedRoot(entry.root, for: sessionID) else {
                return nil
            }
            let url = root.appendingPathComponent(entry.relativePath)
            // A kind this build has no case for — a payload from a newer build — re-derives
            // from the file itself, the authority every read already trusts. A row unknown both
            // ways holds nothing this build can show, and drops alone rather than taking the
            // session's list with it.
            guard let kind = entry.kind ?? AttachmentReferenceDetector.kind(for: url) else {
                return nil
            }
            return SessionAttachment(
                sessionID: sessionID,
                id: entry.id ?? Self.legacyID(
                    sessionID: sessionID,
                    root: entry.root,
                    relativePath: entry.relativePath
                ),
                root: root,
                url: url,
                relativePath: entry.relativePath,
                // A payload written before provenance was recorded has no source of its own, and
                // its own path is the key it was already deduplicated by.
                sourcePath: entry.sourcePath ?? url.path,
                kind: kind,
                origin: entry.origin ?? .agent,
                // A payload written before the scope was configurable holds only files that
                // passed the narrow rule, so absent reads as "inside" rather than as unknown.
                isOutsideProject: entry.isOutsideProject ?? false,
                isImmutableSnapshot: entry.isImmutableSnapshot ?? false,
                referencedAt: entry.referencedAt
            )
        }
    }

    private func persist(_ attachments: [SessionAttachment], for sessionID: SessionID) {
        guard let savePayload else { return }
        let entries = attachments.map {
            PersistedSessionAttachment(
                id: $0.id,
                root: $0.root.path,
                relativePath: $0.relativePath,
                sourcePath: $0.sourcePath,
                kind: $0.kind,
                origin: $0.origin,
                isOutsideProject: $0.isOutsideProject ? true : nil,
                isImmutableSnapshot: $0.isImmutableSnapshot ? true : nil,
                referencedAt: $0.referencedAt
            )
        }
        guard let data = try? Self.encoder.encode(
            PersistedSessionAttachments(entries: entries)
        ) else { return }
        savePayload(String(decoding: data, as: UTF8.self), sessionID)
    }

    // MARK: Validation

    /// Resolves a persisted root only against live authority. Both legitimate roots are known
    /// independently of the payload: the session's current checkout and its app-owned custody
    /// directory. This also makes a moved/deleted managed workspace prune its old references
    /// instead of retaining authority to a directory the session no longer owns.
    private func trustedPersistedRoot(_ path: String, for sessionID: SessionID) -> URL? {
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let trusted = [referenceRoot?(sessionID), copiesRoot(for: sessionID)]
            .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath() }
        return trusted.contains(candidate) ? candidate : nil
    }

    /// A file kept as a reference, proven to be a regular supported file inside `root`.
    private func referencedAttachment(
        at url: URL,
        sessionID: SessionID,
        root: URL,
        origin: SessionAttachment.Origin,
        sourcePath: String? = nil,
        isOutsideProject: Bool = false,
        id: String? = nil,
        isImmutableSnapshot: Bool = false,
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
            isOutsideProject: isOutsideProject,
            isImmutableSnapshot: isImmutableSnapshot,
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
                referencedAt: referencedAt
            )
        }

        return copiedAttachment(
            at: file,
            sessionID: sessionID,
            origin: origin,
            preferredName: preferredName,
            isOutsideProject: false,
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
            referencedAt: referencedAt
        )
    }

    private static func legacyID(
        sessionID: SessionID,
        root: String,
        relativePath: String
    ) -> String {
        let value = "\(sessionID.uuidString)|\(root)|\(relativePath)"
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        var failureCount = 0
        for attachment in attachments {
            guard let root = copiesRoot(for: attachment.sessionID),
                  AttachmentReferenceDetector.contains(attachment.url, inside: root),
                  // The copy's own directory, not the file: one attachment owns one directory.
                  let slot = attachment.relativePath.split(separator: "/").first else {
                continue
            }
            do {
                try fileManager.removeItem(at: root.appendingPathComponent(String(slot)))
            } catch {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            ThreadingLogger.session.warning(
                "Attachment copy cleanup incomplete failures=\(failureCount, privacy: .public) candidates=\(attachments.count, privacy: .public)"
            )
        }
    }

    private func discardCopiesOutside(_ sessionIDs: Set<SessionID>) {
        guard let directory = copiesDirectory?() else { return }
        let kept = Set(sessionIDs.map(\.uuidString))
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

// MARK: - Reference Detection

/// Extracts only supported-attachment-shaped paths — images, PDFs, HTML, archives and open
/// document formats — then lets the filesystem decide whether each one is real.
enum AttachmentReferenceDetector {

    /// Real files the text named, split by the one question the caller has to answer.
    ///
    /// The split is the detector's whole contribution to the scope rule: it reports what it
    /// found and where, and the store — which knows the user's answer — decides what that means.
    /// Sorting the two apart here rather than filtering at the call site is what lets a refused
    /// file still be counted.
    struct Resolution: Equatable, Sendable {
        var insideProject: [URL] = []
        var outsideProject: [URL] = []

        var isEmpty: Bool { insideProject.isEmpty && outsideProject.isEmpty }
    }

    /// One set per kind, and the kinds joined for the scan. `kind(for:)` maps each set
    /// explicitly — it used to answer `.image` for anything the list held that was not a PDF or
    /// HTML, which was correct only while images were the remainder, and one added extension
    /// away from the pane decoding a zip as a picture.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar"
    ]
    private static let documentExtensions: Set<String> = [
        "odt", "ods", "odp", "docx", "xlsx", "pptx", "rtf"
    ]
    /// `.dot` is also the legacy Word-template extension; the filesystem check keeps it honest,
    /// and a template named in a coding session's output is the rarer reading by far.
    private static let diagramExtensions: Set<String> = [
        "dot", "gv", "mmd", "mermaid"
    ]
    private static let extensions =
        imageExtensions.sorted() + ["pdf", "html", "htm"]
            + archiveExtensions.sorted() + documentExtensions.sorted()
            + diagramExtensions.sorted()
    /// Longest first, because the alternation is ordered and nothing after it requires a word
    /// boundary: with `tif` offered before `tiff`, `shot.tiff` matched as `shot.tif`, a file
    /// that does not exist, and the real one was never recorded.
    private static let extensionAlternation = extensions
        .sorted { $0.count > $1.count }
        .joined(separator: "|")

    /// Quoted and Markdown forms admit spaces. The plain form deliberately does not: prose around
    /// an unquoted path is otherwise indistinguishable from the path itself.
    private static let patterns: [NSRegularExpression] = [
        expression(#"\]\(([^)\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)\)"#),
        expression(#"[`"]([^`"\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)[`"]"#),
        expression(#"'([^'\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)'"#),
        expression(#"((?:file://)?[^\s<>"'`()\[\]{}]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)"#)
    ].compactMap { $0 }

    /// Every real supported file the text names, sorted by whether it lives in the project.
    ///
    /// Containment used to be checked *before* the filesystem, which made an outside path free to
    /// reject — it was rejected on a string. Reporting one costs a `stat`, because a path in prose
    /// is not evidence that a file exists and a count of files that are not there would be worse
    /// than saying nothing. `maximumCandidatesPerScan` is what keeps that bounded: a terminal
    /// printing thousands of paths is a normal afternoon, and both lists are capped downstream
    /// anyway, so the work per scan may not scale with what an agent happened to `cat`.
    static func resolve(
        text: String,
        projectRoot: URL,
        currentDirectory: URL?,
        fileManager: FileManager = .default
    ) -> Resolution {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var seen: Set<String> = []
        var result = Resolution()

        for candidate in candidates(in: text) {
            // A relative candidate is proposed against the working directory before the checkout,
            // and the checkout still wins when both hold a file of that name: `a.png` printed
            // from a session that has wandered into `/tmp` means the project's file if there is
            // one. Only when nothing inside answers does the outside match stand.
            var outside: URL?
            var matchedInside = false

            for proposed in proposedURLs(
                for: candidate,
                projectRoot: root,
                currentDirectory: currentDirectory
            ) {
                let file = proposed.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard kind(for: file) != nil,
                      fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }
                if contains(file, inside: root) {
                    if seen.insert(file.path).inserted { result.insideProject.append(file) }
                    matchedInside = true
                    break
                }
                if outside == nil { outside = file }
            }

            if !matchedInside, let outside, seen.insert(outside.path).inserted {
                result.outsideProject.append(outside)
            }
        }
        return result
    }

    /// The bound on both halves of a scan's work: matching stops here, and each candidate is
    /// proposed against at most two roots, so this is also the ceiling on `stat` calls.
    ///
    /// Comfortably above what any list can hold (`maximumPerSession`), because a candidate is
    /// not yet a file — most of them turn out not to exist — while still bounding the pass over
    /// a buffer whose size is decided by whatever an agent last printed.
    static let maximumCandidatesPerScan = 512

    static func kind(for url: URL) -> SessionAttachment.Kind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "html" || ext == "htm" { return .html }
        if archiveExtensions.contains(ext) { return .archive }
        if documentExtensions.contains(ext) { return .document }
        if diagramExtensions.contains(ext) { return .diagram }
        return nil
    }

    static func contains(_ file: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/")
    }

    /// Path-shaped text, deduplicated, and never more than the scan is allowed to consider.
    ///
    /// The cap is enforced *while matching* rather than by trimming the result. `matches(in:)`
    /// materialises every hit before anything can be discarded, so a terminal holding a thousand
    /// paths built a thousand `NSTextCheckingResult`s and a thousand bridged `String`s to keep
    /// the first few hundred — on the main thread, on a debounce, in a window that is drawing.
    /// Enumerating and stopping is the same answer for a fraction of the work.
    private static func candidates(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var candidates: [String] = []

        for pattern in patterns {
            guard candidates.count < maximumCandidatesPerScan else { break }
            pattern.enumerateMatches(in: text, range: range) { match, _, stop in
                guard let match else { return }
                let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: text) else { return }
                let candidate = clean(String(text[swiftRange]))
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { return }
                candidates.append(candidate)
                if candidates.count >= maximumCandidatesPerScan { stop.pointee = true }
            }
        }
        return candidates
    }

    private static func proposedURLs(
        for candidate: String,
        projectRoot: URL,
        currentDirectory: URL?
    ) -> [URL] {
        let withoutLocation = candidate.replacingOccurrences(
            of: #":\d+(?::\d+)?$"#,
            with: "",
            options: .regularExpression
        )
        let decoded = withoutLocation.removingPercentEncoding ?? withoutLocation

        if decoded.lowercased().hasPrefix("file://"),
           let url = URL(string: decoded), url.isFileURL {
            return [url]
        }

        let expanded = NSString(string: decoded).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return [URL(fileURLWithPath: expanded)]
        }

        var roots: [URL] = []
        if let currentDirectory { roots.append(currentDirectory) }
        roots.append(projectRoot)
        return roots.map { $0.appendingPathComponent(expanded) }
    }

    private static func clean(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\\ "#, with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
    }

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        // These are compile-time-owned patterns. A failed pattern should make detection inert,
        // not take down the session displaying untrusted terminal text.
        try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
    }
}

// MARK: - Terminal Observation

/// Debounces terminal repaints and inspects SwiftTerm's bounded recent logical buffer.
///
/// Reading the emulator buffer avoids treating ANSI cursor commands as path text while retaining
/// recent scrollback that has moved just above the viewport. A path is recorded only when it
/// enters the scanned window, so an unrelated later repaint does not keep moving an old file to
/// the top of the list.
@MainActor
final class TerminalAttachmentObserver {

    struct ScanMetrics: Equatable {
        let bytes: Int
        let workerNanoseconds: UInt64
        let applyNanoseconds: UInt64
        let found: Int
        let recorded: Int
    }

    typealias Recorder = @MainActor (
        AttachmentReferenceDetector.Resolution,
        SessionID,
        URL
    ) -> [SessionAttachment]

    private let sessionID: SessionID
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let text: () -> String
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let record: Recorder
    private var pendingScan: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var lastScan: Date?
    private var pathsInLastScan: Set<String> = []
    private var scanGeneration = 0

    private(set) var isScanInFlight = false
    private(set) var lastScanMetrics: ScanMetrics?

    init(
        sessionID: SessionID,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        text: @escaping () -> String,
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init,
        record: @escaping Recorder = { resolution, sessionID, root in
            SessionAttachmentStore.shared.record(
                resolved: resolution,
                sessionID: sessionID,
                projectRoot: root
            )
        }
    ) {
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.text = text
        self.isEnabled = isEnabled
        self.now = now
        self.record = record
    }

    deinit {
        pendingScan?.cancel()
        resolutionTask?.cancel()
    }

    /// Scans now when it may, defers only as long as it must.
    ///
    /// Waiting for quiet alone was the "attachments arrive when the agent pauses" feel: a busy
    /// stretch re-arms the debounce on every repaint, so a path printed early in a long build
    /// surfaced only when the output finally stopped. The first sighting scans immediately and
    /// sustained output re-scans on a cap; the trailing debounce still reads a burst's last
    /// lines after they have settled.
    func noteOutput() {
        pendingScan?.cancel()

        let timestamp = now()
        let dueForScan = lastScan.map {
            timestamp.timeIntervalSince($0) >= SessionAttachmentDefaults.terminalBusyScanInterval
        } ?? true
        if dueForScan {
            scanNow()
            return
        }

        let delay = UInt64(SessionAttachmentDefaults.terminalQuietInterval * 1_000_000_000)
        pendingScan = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingScan = nil
            self.scanNow()
        }
    }

    func scanNow() {
        pendingScan?.cancel()
        pendingScan = nil
        lastScan = now()
        scanGeneration += 1
        let generation = scanGeneration
        resolutionTask?.cancel()
        resolutionTask = nil
        isScanInFlight = false
        lastScanMetrics = nil
        guard isEnabled() else {
            pathsInLastScan.removeAll()
            return
        }
        guard let root = projectRoot() else { return }

        // Reading SwiftTerm's buffer is main-actor work. Everything after that is immutable text,
        // URLs and filesystem queries, so doing it on the queue the window draws on would turn a
        // bounded 20–55 ms regex pass into visible input and scroll latency.
        let scanned = text()
        let current = currentDirectory()
        let span = PerformanceRecorder.shared.begin(
            "attachments.scan",
            category: "attachments",
            metadata: ["bytes": String(scanned.utf8.count)]
        )
        isScanInFlight = true
        resolutionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let resolution = AttachmentReferenceDetector.resolve(
                text: scanned,
                projectRoot: root,
                currentDirectory: current
            )
            let ended = DispatchTime.now().uptimeNanoseconds
            guard !Task.isCancelled else {
                span.end(metadata: ["cancelled": "1"])
                return
            }
            await self?.finishScan(
                resolution,
                scannedBytes: scanned.utf8.count,
                workerNanoseconds: ended - started,
                generation: generation,
                projectRoot: root,
                span: span
            )
        }
    }

    private func finishScan(
        _ resolution: AttachmentReferenceDetector.Resolution,
        scannedBytes: Int,
        workerNanoseconds: UInt64,
        generation: Int,
        projectRoot root: URL,
        span: PerformanceSpan
    ) {
        guard generation == scanGeneration else {
            span.end(metadata: ["superseded": "1"])
            return
        }
        resolutionTask = nil
        isScanInFlight = false
        guard isEnabled() else {
            pathsInLastScan.removeAll()
            span.end(metadata: ["disabled": "1"])
            return
        }

        let applyStarted = DispatchTime.now().uptimeNanoseconds
        // Both halves are held to the same "newly visible" rule. A path outside the project is
        // refused rather than listed, but re-offering it on every repaint would still be work,
        // and would keep re-announcing a hint the user has already read.
        let newly = AttachmentReferenceDetector.Resolution(
            insideProject: resolution.insideProject.filter { !pathsInLastScan.contains($0.path) },
            outsideProject: resolution.outsideProject.filter { !pathsInLastScan.contains($0.path) }
        )
        pathsInLastScan = Set(
            (resolution.insideProject + resolution.outsideProject).map(\.path)
        )
        let recorded = newly.isEmpty ? [] : record(newly, sessionID, root)
        let applyEnded = DispatchTime.now().uptimeNanoseconds
        let found = newly.insideProject.count + newly.outsideProject.count
        lastScanMetrics = ScanMetrics(
            bytes: scannedBytes,
            workerNanoseconds: workerNanoseconds,
            applyNanoseconds: applyEnded - applyStarted,
            found: found,
            recorded: recorded.count
        )
        span.end(metadata: [
            "found": String(found),
            "recorded": String(recorded.count)
        ])
    }
}

// MARK: - Terminal Transcript Observation

/// Recovers assistant prose that a full-screen agent TUI painted as already-wrapped grid rows.
///
/// The ordinary terminal observer remains necessary for shell output, providers whose transcript
/// is not readable, and paths printed before a turn ends. It can join emulator-owned soft wraps,
/// but no emulator can infer that two independently painted rows came from one provider message.
/// Claude and Codex transcripts retain that message intact, so their completed terminal turns get
/// one bounded, background tail scan through the same provider normalization Native Chat replays.
///
/// A turn boundary schedules stability retries because the hook and the transcript writer are two
/// processes: the hook can arrive while the final record is still being flushed. Resolutions are
/// deduplicated within the turn before returning to the main actor, so retries neither recopy an
/// outside file nor move an existing row repeatedly.
@MainActor
final class TerminalTranscriptAttachmentObserver {

    typealias TranscriptURLLookup = @Sendable () -> URL?

    private let sessionID: SessionID
    private let kind: AgentKind
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let transcriptURL: () -> URL?
    private let transcriptLookup: () -> TranscriptURLLookup?
    private let isEnabled: () -> Bool

    private var generation = 0
    private var pendingScans: [Task<Void, Never>] = []
    private var pathsRecordedThisTurn: Set<String> = []

    init(
        sessionID: SessionID,
        kind: AgentKind,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        transcriptURL: @escaping () -> URL?,
        transcriptLookup: @escaping () -> TranscriptURLLookup? = { nil },
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.transcriptURL = transcriptURL
        self.transcriptLookup = transcriptLookup
        self.isEnabled = isEnabled
    }

    deinit {
        pendingScans.forEach { $0.cancel() }
    }

    /// Starts a new bounded scan generation for the turn that just settled.
    ///
    /// `lastAssistantMessage` is a provider-supplied fast path where a hook carries one. It is
    /// still combined with the transcript rather than treated as complete: a turn may contain
    /// several assistant text blocks around tool calls.
    func noteTurnFinished(lastAssistantMessage: String? = nil) {
        pendingScans.forEach { $0.cancel() }
        pendingScans.removeAll(keepingCapacity: true)
        generation += 1
        pathsRecordedThisTurn.removeAll(keepingCapacity: true)

        guard isEnabled() else { return }
        let thisGeneration = generation
        // Capture the provider identity before a terminating process clears its per-launch
        // caches. The file itself remains live for the delayed stability reads.
        let transcript = transcriptURL()
        // Codex's hook normally supplies the exact immutable rollout path. If hooks are absent,
        // capture a value-only lookup now and perform its account-tree enumeration off-main.
        let lookup = transcript == nil ? transcriptLookup() : nil

        for delay in TranscriptAttachmentDefaults.stabilityDelays {
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            let work = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.scan(
                    generation: thisGeneration,
                    transcript: transcript,
                    transcriptLookup: lookup,
                    lastAssistantMessage: lastAssistantMessage
                )
            }
            pendingScans.append(work)
        }
    }

    private func scan(
        generation expectedGeneration: Int,
        transcript: URL?,
        transcriptLookup: TranscriptURLLookup?,
        lastAssistantMessage: String?
    ) {
        guard generation == expectedGeneration,
              isEnabled(),
              let root = projectRoot() else { return }

        let current = currentDirectory()
        let kind = kind
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolvedTranscript = transcript ?? transcriptLookup?()
            var texts = resolvedTranscript.map {
                TranscriptReplay.latestAssistantTexts(
                    at: $0,
                    kind: kind,
                    scanLimit: TranscriptAttachmentDefaults.transcriptScanBytes
                )
            } ?? []
            if let lastAssistantMessage, !lastAssistantMessage.isEmpty {
                texts.append(lastAssistantMessage)
            }
            guard !texts.isEmpty else { return }

            let resolution = AttachmentReferenceDetector.resolve(
                text: texts.joined(separator: "\n"),
                projectRoot: root,
                currentDirectory: current
            )
            guard !resolution.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.generation == expectedGeneration,
                      self.isEnabled() else { return }

                let fresh = AttachmentReferenceDetector.Resolution(
                    insideProject: resolution.insideProject.filter {
                        self.pathsRecordedThisTurn.insert($0.path).inserted
                    },
                    outsideProject: resolution.outsideProject.filter {
                        self.pathsRecordedThisTurn.insert($0.path).inserted
                    }
                )
                guard !fresh.isEmpty else { return }
                SessionAttachmentStore.shared.record(
                    resolved: fresh,
                    sessionID: self.sessionID,
                    projectRoot: root
                )
            }
        }
    }
}

// MARK: - Defaults

enum SessionAttachmentDefaults {
    static let maximumPerSession = 64

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
}

enum TranscriptAttachmentDefaults {
    /// A tail large enough for a tool-heavy final turn without walking a conversation-sized file.
    static let transcriptScanBytes = 2 * 1024 * 1024
    /// The first read is normally complete; the later reads close the hook-vs-writer flush race.
    static let stabilityDelays: [TimeInterval] = [0, 0.5, 1.5]
}
