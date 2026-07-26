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
final class SessionAttachmentStore {

    static let shared = SessionAttachmentStore()

    private var attachmentsBySession: [SessionID: [SessionAttachment]] = [:]
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
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

        var current = attachmentsBySession[sessionID] ?? []
        for attachment in made {
            current.removeAll { $0.relativePath == attachment.relativePath }
            current.insert(attachment, at: 0)
        }
        if current.count > SessionAttachmentDefaults.maximumPerSession {
            current.removeLast(current.count - SessionAttachmentDefaults.maximumPerSession)
        }
        attachmentsBySession[sessionID] = current
        NotificationCenter.default.post(SessionAttachmentsDidChange(sessionID: sessionID))
        return made
    }

    // MARK: Reading

    func attachments(for sessionID: SessionID) -> [SessionAttachment] {
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
final class TerminalAttachmentObserver {

    private let sessionID: SessionID
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let text: () -> String
    private let isEnabled: () -> Bool
    private var pendingScan: DispatchWorkItem?
    private var pathsInLastScan: Set<String> = []

    init(
        sessionID: SessionID,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        text: @escaping () -> String,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.text = text
        self.isEnabled = isEnabled
    }

    deinit {
        pendingScan?.cancel()
    }

    func noteOutput() {
        pendingScan?.cancel()
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
    static let maximumTerminalScanBytes = 256 * 1024
}
