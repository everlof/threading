import Foundation

// MARK: - Attachment

/// A visual file that passed between the two parties in one session.
///
/// Attachments inside the checkout are references, not copies. The project file remains
/// authoritative, so replacing an image or PDF at the same path updates every preview without
/// growing a second cache. A file from anywhere else is copied into the store's own directory
/// instead — see `SessionAttachmentStore` for why that exception exists and where it stops.
struct SessionAttachment: Equatable, Identifiable {

    enum Kind: String, Codable {
        case image
        case pdf
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

    /// Relative paths are stable across a moved checkout and are safe to put on the remote wire.
    var id: String { relativePath }

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
    let referencedAt: Date

    var name: String { url.lastPathComponent }
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
///   user's pictures into a fetchable list.
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
        guard NSClassFromString("XCTestCase") == nil else { return SessionAttachmentStore() }
        return SessionAttachmentStore(
            loadPayload: { StateManager.shared.loadAttachmentsPayload(for: $0) },
            savePayload: { StateManager.shared.saveAttachmentsPayload($0, for: $1) },
            retainPersisted: { StateManager.shared.retainAttachments(sessionIDs: $0) },
            copiesDirectory: { StateManager.shared.attachmentCopiesDirectory }
        )
    }()

    private var attachmentsBySession: [SessionID: [SessionAttachment]] = [:]
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

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        loadPayload: ((SessionID) -> String?)? = nil,
        savePayload: ((String, SessionID) -> Void)? = nil,
        retainPersisted: ((Set<SessionID>) -> Void)? = nil,
        copiesDirectory: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.loadPayload = loadPayload
        self.savePayload = savePayload
        self.retainPersisted = retainPersisted
        self.copiesDirectory = copiesDirectory
    }

    // MARK: Recording — the scanned door

    /// Records the supported files named in live output. In-checkout only; see the type's note.
    @discardableResult
    func recordReferences(
        in text: String,
        sessionID: SessionID,
        projectRoot: URL,
        currentDirectory: URL? = nil
    ) -> [SessionAttachment] {
        let urls = AttachmentReferenceDetector.resolve(
            text: text,
            projectRoot: projectRoot,
            currentDirectory: currentDirectory,
            fileManager: fileManager
        )
        return record(urls: urls, sessionID: sessionID, projectRoot: projectRoot)
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
        let made = urls.compactMap {
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
            let superseded = current.filter { $0.sourcePath == attachment.sourcePath }
            current.removeAll { $0.sourcePath == attachment.sourcePath }
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

    func attachments(for sessionID: SessionID) -> [SessionAttachment] {
        loadIfNeeded(sessionID)
        guard let stored = attachmentsBySession[sessionID] else { return [] }
        let current = stored.compactMap {
            referencedAttachment(
                at: $0.url,
                sessionID: sessionID,
                root: $0.root,
                origin: $0.origin,
                sourcePath: $0.sourcePath,
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

    func retainOnly(sessionIDs: Set<SessionID>) {
        attachmentsBySession = attachmentsBySession.filter { sessionIDs.contains($0.key) }
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

        attachmentsBySession[sessionID] = document.entries.map { entry in
            let root = URL(fileURLWithPath: entry.root, isDirectory: true)
            let url = root.appendingPathComponent(entry.relativePath)
            return SessionAttachment(
                sessionID: sessionID,
                root: root,
                url: url,
                relativePath: entry.relativePath,
                // A payload written before provenance was recorded has no source of its own, and
                // its own path is the key it was already deduplicated by.
                sourcePath: entry.sourcePath ?? url.path,
                kind: entry.kind,
                origin: entry.origin ?? .agent,
                referencedAt: entry.referencedAt
            )
        }
    }

    private func persist(_ attachments: [SessionAttachment], for sessionID: SessionID) {
        guard let savePayload else { return }
        let entries = attachments.map {
            PersistedSessionAttachment(
                root: $0.root.path,
                relativePath: $0.relativePath,
                sourcePath: $0.sourcePath,
                kind: $0.kind,
                origin: $0.origin,
                referencedAt: $0.referencedAt
            )
        }
        guard let data = try? Self.encoder.encode(
            PersistedSessionAttachments(entries: entries)
        ) else { return }
        savePayload(String(decoding: data, as: UTF8.self), sessionID)
    }

    // MARK: Validation

    /// A file kept as a reference, proven to be a regular supported file inside `root`.
    private func referencedAttachment(
        at url: URL,
        sessionID: SessionID,
        root: URL,
        origin: SessionAttachment.Origin,
        sourcePath: String? = nil,
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
            root: base,
            url: file,
            relativePath: relativePath,
            sourcePath: sourcePath ?? file.path,
            kind: kind,
            origin: origin,
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

        guard let kind = AttachmentReferenceDetector.kind(for: file),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let root = copiesRoot(for: sessionID) else {
            return nil
        }

        // A second mention of the same source reuses the slot it already has, so the row keeps
        // its identity — and therefore its place on the remote wire — while the bytes are
        // refreshed underneath it.
        let name = preferredName.map { sanitized($0, matching: file) } ?? file.lastPathComponent
        let existing = attachmentsBySession[sessionID]?.first {
            $0.sourcePath == file.path && AttachmentReferenceDetector.contains($0.url, inside: root)
        }
        let relativePath = existing?.relativePath ?? "\(UUID().uuidString)/\(name)"
        let destination = root.appendingPathComponent(relativePath)

        guard copy(file, to: destination) else { return nil }

        return SessionAttachment(
            sessionID: sessionID,
            root: root,
            url: destination,
            relativePath: relativePath,
            sourcePath: file.path,
            kind: kind,
            origin: origin,
            referencedAt: referencedAt
        )
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
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: file, to: destination)
            return true
        } catch {
            ThreadingLogger.session.error(
                "Failed to keep attachment \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Removes the bytes behind rows that have left the list. A referenced file is untouched —
    /// it belongs to the checkout, and evicting a row is not a reason to delete the user's file.
    private func discardCopies(in attachments: [SessionAttachment]) {
        for attachment in attachments {
            guard let root = copiesRoot(for: attachment.sessionID),
                  AttachmentReferenceDetector.contains(attachment.url, inside: root),
                  // The copy's own directory, not the file: one attachment owns one directory.
                  let slot = attachment.relativePath.split(separator: "/").first else {
                continue
            }
            try? fileManager.removeItem(at: root.appendingPathComponent(String(slot)))
        }
    }

    private func discardCopiesOutside(_ sessionIDs: Set<SessionID>) {
        guard let directory = copiesDirectory?() else { return }
        let kept = Set(sessionIDs.map(\.uuidString))
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where !kept.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Reference Detection

/// Extracts only image/PDF-shaped paths, then lets the filesystem decide whether each one is real.
enum AttachmentReferenceDetector {

    private static let extensions = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "pdf"
    ]
    private static let extensionAlternation = extensions.joined(separator: "|")

    /// Quoted and Markdown forms admit spaces. The plain form deliberately does not: prose around
    /// an unquoted path is otherwise indistinguishable from the path itself.
    private static let patterns: [NSRegularExpression] = [
        expression(#"\]\(([^)\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)\)"#),
        expression(#"[`"]([^`"\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)[`"]"#),
        expression(#"'([^'\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)'"#),
        expression(#"((?:file://)?[^\s<>"'`()\[\]{}]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)"#)
    ]

    static func resolve(
        text: String,
        projectRoot: URL,
        currentDirectory: URL?,
        fileManager: FileManager = .default
    ) -> [URL] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var seen: Set<String> = []
        var result: [URL] = []

        for candidate in candidates(in: text) {
            for proposed in proposedURLs(
                for: candidate,
                projectRoot: root,
                currentDirectory: currentDirectory
            ) {
                let file = proposed.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard contains(file, inside: root),
                      kind(for: file) != nil,
                      fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      seen.insert(file.path).inserted else {
                    continue
                }
                result.append(file)
                break
            }
        }
        return result
    }

    static func kind(for url: URL) -> SessionAttachment.Kind? {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { return nil }
        return ext == "pdf" ? .pdf : .image
    }

    static func contains(_ file: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/")
    }

    private static func candidates(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var candidates: [String] = []

        for pattern in patterns {
            for match in pattern.matches(in: text, range: range) {
                let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: text) else { continue }
                let candidate = clean(String(text[swiftRange]))
                if !candidate.isEmpty, seen.insert(candidate).inserted {
                    candidates.append(candidate)
                }
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

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // These are compile-time-owned patterns. A failed pattern should make detection inert,
        // not take down the session displaying untrusted terminal text.
        (try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )) ?? (try! NSRegularExpression(pattern: "(?!)"))
    }
}

// MARK: - Terminal Observation

/// Debounces terminal repaints and inspects SwiftTerm's bounded recent rendered buffer.
///
/// Reading the emulator buffer avoids treating ANSI cursor commands as path text while retaining
/// recent scrollback that has moved just above the viewport. A path is recorded only when it
/// enters the scanned window, so an unrelated later repaint does not keep moving an old file to
/// the top of the list.
@MainActor
final class TerminalAttachmentObserver {

    private let sessionID: SessionID
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let text: () -> String
    private let isEnabled: () -> Bool
    private let now: () -> Date
    nonisolated(unsafe) private var pendingScan: DispatchWorkItem?
    private var lastScan: Date?
    private var pathsInLastScan: Set<String> = []

    init(
        sessionID: SessionID,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        text: @escaping () -> String,
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.text = text
        self.isEnabled = isEnabled
        self.now = now
    }

    deinit {
        pendingScan?.cancel()
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

        let work = DispatchWorkItem { [weak self] in self?.scanNow() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionAttachmentDefaults.terminalQuietInterval,
            execute: work
        )
    }

    func scanNow() {
        pendingScan?.cancel()
        pendingScan = nil
        lastScan = now()
        guard isEnabled() else {
            pathsInLastScan.removeAll()
            return
        }
        guard let root = projectRoot() else { return }
        let urls = AttachmentReferenceDetector.resolve(
            text: text(),
            projectRoot: root,
            currentDirectory: currentDirectory()
        )
        let currentPaths = Set(urls.map(\.path))
        let newlyVisible = urls.filter { !pathsInLastScan.contains($0.path) }
        pathsInLastScan = currentPaths
        guard !newlyVisible.isEmpty else { return }
        _ = SessionAttachmentStore.shared.record(
            urls: newlyVisible,
            sessionID: sessionID,
            projectRoot: root
        )
    }
}

// MARK: - Defaults

enum SessionAttachmentDefaults {
    static let maximumPerSession = 32
    static let terminalQuietInterval: TimeInterval = 0.65
    /// How stale the last scan may be before busy output scans again instead of re-arming the
    /// quiet debounce. The scan reads a bounded buffer, so the cap costs a regex pass every
    /// couple of seconds during sustained output and nothing when the terminal is idle.
    static let terminalBusyScanInterval: TimeInterval = 2.0
    static let maximumTerminalScanBytes = 256 * 1024
}
