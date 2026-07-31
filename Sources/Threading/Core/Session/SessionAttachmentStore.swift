import Foundation

// MARK: - Attachment

/// A visual file an agent referred to in one session.
///
/// Attachments are references, not copies. The project file remains authoritative, so replacing
/// an image or PDF at the same path updates every preview without growing a second cache.
struct SessionAttachment: Equatable, Identifiable {

    enum Kind: String, Codable {
        case image
        case pdf
    }

    /// Relative paths are stable across a moved checkout and are safe to put on the remote wire.
    var id: String { relativePath }

    let sessionID: SessionID
    let projectRoot: URL
    let url: URL
    let relativePath: String
    let kind: Kind
    let referencedAt: Date

    var name: String { url.lastPathComponent }
}

/// Raised after one session's attachment list changes.
struct SessionAttachmentsDidChange: AppEvent {
    static let name = Notification.Name("sessionAttachmentsDidChange")
    let sessionID: SessionID
}

// MARK: - Store

/// The session-scoped set of visual files mentioned by terminal and native agents.
///
/// Main-thread only, like `ProjectStore` and the display pane. Paths are admitted only after
/// resolving symlinks and proving the result is a regular supported file inside the checkout.
/// This boundary matters twice: it keeps noisy terminal output from creating bogus rows, and it
/// keeps the paired-phone endpoint from becoming an arbitrary local-file reader.
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
            retainPersisted: { StateManager.shared.retainAttachments(sessionIDs: $0) }
        )
    }()

    private var attachmentsBySession: [SessionID: [SessionAttachment]] = [:]
    private var loadedSessions: Set<SessionID> = []
    private let fileManager: FileManager
    private let now: () -> Date
    private let loadPayload: ((SessionID) -> String?)?
    private let savePayload: ((String, SessionID) -> Void)?
    private let retainPersisted: ((Set<SessionID>) -> Void)?

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        loadPayload: ((SessionID) -> String?)? = nil,
        savePayload: ((String, SessionID) -> Void)? = nil,
        retainPersisted: ((Set<SessionID>) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.loadPayload = loadPayload
        self.savePayload = savePayload
        self.retainPersisted = retainPersisted
    }

    // MARK: Recording

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

    /// Records an already-resolved file, used by an explicit display-image tool call.
    @discardableResult
    func record(
        url: URL,
        sessionID: SessionID,
        projectRoot: URL
    ) -> SessionAttachment? {
        record(urls: [url], sessionID: sessionID, projectRoot: projectRoot).first
    }

    func record(
        urls: [URL],
        sessionID: SessionID,
        projectRoot: URL
    ) -> [SessionAttachment] {
        let timestamp = now()
        let made = urls.compactMap {
            validatedAttachment(
                at: $0,
                sessionID: sessionID,
                projectRoot: projectRoot,
                referencedAt: timestamp
            )
        }
        guard !made.isEmpty else { return [] }

        // Loaded first, so a reference arriving before the pane was ever opened lands on top
        // of the persisted history rather than replacing it.
        loadIfNeeded(sessionID)
        var current = attachmentsBySession[sessionID] ?? []
        for attachment in made {
            current.removeAll { $0.relativePath == attachment.relativePath }
            current.insert(attachment, at: 0)
        }
        if current.count > SessionAttachmentDefaults.maximumPerSession {
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
            validatedAttachment(
                at: $0.url,
                sessionID: sessionID,
                projectRoot: $0.projectRoot,
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
            let root = URL(fileURLWithPath: entry.projectRoot, isDirectory: true)
            return SessionAttachment(
                sessionID: sessionID,
                projectRoot: root,
                url: root.appendingPathComponent(entry.relativePath),
                relativePath: entry.relativePath,
                kind: entry.kind,
                referencedAt: entry.referencedAt
            )
        }
    }

    private func persist(_ attachments: [SessionAttachment], for sessionID: SessionID) {
        guard let savePayload else { return }
        let entries = attachments.map {
            PersistedSessionAttachment(
                projectRoot: $0.projectRoot.path,
                relativePath: $0.relativePath,
                kind: $0.kind,
                referencedAt: $0.referencedAt
            )
        }
        guard let data = try? Self.encoder.encode(
            PersistedSessionAttachments(entries: entries)
        ) else { return }
        savePayload(String(decoding: data, as: UTF8.self), sessionID)
    }

    // MARK: Validation

    private func validatedAttachment(
        at url: URL,
        sessionID: SessionID,
        projectRoot: URL,
        referencedAt: Date
    ) -> SessionAttachment? {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard AttachmentReferenceDetector.contains(file, inside: root),
              let kind = AttachmentReferenceDetector.kind(for: file),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relativePath = String(file.path.dropFirst(rootPrefix.count))
        guard !relativePath.isEmpty else { return nil }

        return SessionAttachment(
            sessionID: sessionID,
            projectRoot: root,
            url: file,
            relativePath: relativePath,
            kind: kind,
            referencedAt: referencedAt
        )
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
