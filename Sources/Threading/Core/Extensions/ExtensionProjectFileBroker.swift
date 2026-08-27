import CryptoKit
import Foundation
import ThreadingExtensionKit

/// Resolves the two roots a file query is allowed to name.
///
/// A protocol rather than a direct `ProjectStore` reach so the broker stays testable and so the
/// one rule that matters is stated in one place: a session workspace resolves **only** for a
/// session that belongs to the named project, and the broker never asks what is selected.
///
/// The identifiers are typed rather than `String` because the two are adjacent UUIDs that decide
/// a filesystem root: as strings, a call site naming them the wrong way round compiled. The
/// strings are parsed once, in `ExtensionProjectFileBroker.page(for:…)`, where they arrive from
/// the wire; nothing below that seam ever sees an unparsed identifier.
@MainActor
protocol ExtensionProjectFileRootProviding: AnyObject {
    func projectCheckoutRoot(projectID: ProjectID) -> URL?
    func sessionWorkspaceRoot(projectID: ProjectID, sessionID: SessionID) -> URL?
}

enum ExtensionProjectFileError: Error, Equatable, LocalizedError {
    case unknownProject
    case unknownSessionWorkspace
    case invalidCursor
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unknownProject:
            return L10n.string("No project with that identifier is open.")
        case .unknownSessionWorkspace:
            return L10n.string("That session does not belong to this project.")
        case .invalidCursor:
            return L10n.string("The page marker no longer matches this query.")
        case .unavailable:
            return L10n.string("Project files are unavailable.")
        }
    }
}

/// Bounded, capability-gated project-file enumeration and handle resolution.
///
/// Everything about this type is the same idea stated four ways: **the extension never holds a
/// path**. It supplies a project ID and a suffix filter, receives opaque handles plus the metadata
/// an asset browser genuinely cannot work without, and a handle is only ever redeemed by the host
/// itself when a renderer opens the document.
///
/// Handles are bound to the extension's **process generation** and revoked with it, exactly like
/// the bearer token: a handle minted by a generation that has since crashed, reloaded or been
/// disabled resolves to nothing. Containment is checked again at open, so replacing a file with a
/// symlink out of the checkout after enumeration cannot turn a handle into an out-of-root read.
@MainActor
final class ExtensionProjectFileBroker {

    static let shared = ExtensionProjectFileBroker()

    /// Directories whose contents belong to somebody else's project. Not descended into, for the
    /// reason `ArtifactScanner` gives: a `node_modules` holding a thousand nested `node_modules`
    /// is one answer, not a thousand.
    static let excludedDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", "dist", "build", "out",
        "target", "third_party", "external", "deps", "DerivedData", "venv",
        ".build", ".git", ".svn", ".hg", ".venv", "__pycache__"
    ]

    /// The bound on **one page's** walk, not on the enumeration. Comfortably past the largest
    /// result page, because most entries a walk visits do not match the filter, and well short of
    /// "enumerate the user's source" — and a page that spends it returns a cursor rather than
    /// pretending it reached the end.
    static let maximumVisitedEntries = 20_000
    static let maximumWalkDepth = 12
    /// How much of a candidate the host reads to form a content hint. Never returned.
    static let contentHintPrefixBytes = 4_096

    private struct Handle {
        let extensionIdentifier: String
        let generation: String
        let root: URL
        let relativePath: String
    }

    private struct CursorPayload: Codable {
        let generation: String
        let root: String
        let query: String
        let after: String
    }

    var rootProvider: ExtensionProjectFileRootProviding?

    private var handles: [String: Handle] = [:]

    /// Everything one generation ever minted, so revocation is a single removal rather than a
    /// sweep of a dictionary that grows with every page.
    private var handlesByGeneration: [String: Set<String>] = [:]

    private init() {}

    // MARK: - Enumeration

    func page(
        for query: ExtensionFileQuery,
        extensionIdentifier: String,
        generation: String
    ) async throws -> ExtensionFilePage {
        try query.validate()
        guard let rootProvider else { throw ExtensionProjectFileError.unavailable }

        // The one place the wire's identifier strings are parsed. An id that is not a UUID is
        // refused here rather than deep inside a lookup that happens to miss, and the resolver
        // below is reached only with typed values — so the project and the session can no longer
        // be handed over the wrong way round.
        //
        // `UUID(uuidString:)` accepts either case and normalizes, which is exactly what the
        // lowercased string comparison this replaced did, so an extension holding an uppercase
        // spelling keeps resolving.
        guard let projectID = ProjectID(uuidString: query.projectID) else {
            throw ExtensionProjectFileError.unknownProject
        }

        let root: URL
        switch query.scope {
        case .projectCheckout:
            guard let resolved = rootProvider.projectCheckoutRoot(projectID: projectID) else {
                throw ExtensionProjectFileError.unknownProject
            }
            root = resolved
        case .sessionWorkspace(let rawSessionID):
            guard rootProvider.projectCheckoutRoot(projectID: projectID) != nil else {
                throw ExtensionProjectFileError.unknownProject
            }
            // The session id is parsed after the project check so an unparseable one is still
            // the workspace's refusal rather than the project's, exactly as a lookup miss was.
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let resolved = rootProvider.sessionWorkspaceRoot(
                      projectID: projectID,
                      sessionID: sessionID
                  ) else {
                throw ExtensionProjectFileError.unknownSessionWorkspace
            }
            root = resolved
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fingerprint = Self.fingerprint(for: query)
        var after = ""
        if let cursor = query.cursor {
            guard let payload = Self.decodeCursor(cursor),
                  payload.generation == generation,
                  payload.root == resolvedRoot.path,
                  payload.query == fingerprint else {
                throw ExtensionProjectFileError.invalidCursor
            }
            after = payload.after
        }

        let extensions = Set(query.fileExtensions)
        let limit = query.maximumResults
        // The walk itself is off the main actor: a checkout is externally sized, and `stat`ing
        // twenty thousand entries is not frame-cheap at any cardinality worth supporting.
        let found = await Task.detached(priority: .userInitiated) {
            Self.walk(
                root: resolvedRoot,
                extensions: extensions,
                after: after,
                limit: limit
            )
        }.value

        var page: [ExtensionFileHandle] = []
        page.reserveCapacity(found.matches.count)
        for match in found.matches {
            let id = mintHandle(
                extensionIdentifier: extensionIdentifier,
                generation: generation,
                root: resolvedRoot,
                relativePath: match.relativePath
            )
            page.append(ExtensionFileHandle(
                id: id,
                name: match.name,
                relativePath: match.relativePath,
                byteSize: match.byteSize,
                modifiedAt: match.modifiedAt,
                contentHint: match.contentHint
            ))
        }

        let nextCursor = found.hasMore && !found.matches.isEmpty
            ? Self.encodeCursor(CursorPayload(
                generation: generation,
                root: resolvedRoot.path,
                query: fingerprint,
                after: found.matches[found.matches.count - 1].relativePath
            ))
            : nil
        return ExtensionFilePage(handles: page, nextCursor: nextCursor)
    }

    // MARK: - Resolution

    /// Reads a handle's document, revalidating containment first.
    ///
    /// The second check is not paranoia about the first: enumeration and rendering are separated
    /// by however long the user took to click, and a file replaced with a symlink out of the
    /// checkout in between would otherwise be read through a handle that was honestly minted.
    func documentData(
        forHandle id: String,
        extensionIdentifier: String,
        maximumBytes: Int
    ) -> Data? {
        guard let url = resolvedURL(forHandle: id, extensionIdentifier: extensionIdentifier) else {
            return nil
        }
        return try? BoundedFileReader.read(url, maximumBytes: maximumBytes)
    }

    func resolvedURL(forHandle id: String, extensionIdentifier: String) -> URL? {
        guard let handle = handles[id],
              handle.extensionIdentifier == extensionIdentifier else { return nil }

        let candidate = handle.root
            .appendingPathComponent(handle.relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(handle.root.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return candidate
    }

    // MARK: - Lifetime

    /// Called when a generation ends — disable, reload, crash, uninstall, shutdown. Handles die
    /// with the bearer token they were minted beside.
    func revoke(generation: String) {
        guard let minted = handlesByGeneration.removeValue(forKey: generation) else { return }
        for id in minted { handles.removeValue(forKey: id) }
    }

    func revokeAll(extensionIdentifier: String) {
        let doomed = handles.filter { $0.value.extensionIdentifier == extensionIdentifier }
        for (id, handle) in doomed {
            handles.removeValue(forKey: id)
            handlesByGeneration[handle.generation]?.remove(id)
        }
    }

    var liveHandleCountForTesting: Int { handles.count }

    // MARK: - Minting

    private func mintHandle(
        extensionIdentifier: String,
        generation: String,
        root: URL,
        relativePath: String
    ) -> String {
        // Deterministic per (generation, root, path), so paging the same query twice does not
        // leak an unbounded set of handles for the same files — and still opaque, because the
        // digest is over the absolute root the extension never sees.
        let digest = SHA256.hash(
            data: Data("\(generation)\u{0}\(root.path)\u{0}\(relativePath)".utf8)
        )
        let id = digest.map { String(format: "%02x", $0) }.joined()
        handles[id] = Handle(
            extensionIdentifier: extensionIdentifier,
            generation: generation,
            root: root,
            relativePath: relativePath
        )
        handlesByGeneration[generation, default: []].insert(id)
        return id
    }

    // MARK: - Cursor

    private static func fingerprint(for query: ExtensionFileQuery) -> String {
        // Sorted, so two queries that ask the same thing in a different order share a cursor.
        "\(query.projectID)|\(query.scope.fingerprint)|"
            + query.fileExtensions.sorted().joined(separator: ",")
    }

    private static func encodeCursor(_ payload: CursorPayload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return data.base64EncodedString()
    }

    private static func decodeCursor(_ cursor: String) -> CursorPayload? {
        guard let data = Data(base64Encoded: cursor) else { return nil }
        return try? JSONDecoder().decode(CursorPayload.self, from: data)
    }

    // MARK: - Walk

    struct Match: Sendable {
        let name: String
        let relativePath: String
        let byteSize: Int
        let modifiedAt: Date
        let contentHint: ExtensionFileContentHint?
    }

    private struct WalkResult: Sendable {
        let matches: [Match]
        let hasMore: Bool
    }

    /// A bounded, lexically ordered walk.
    ///
    /// The order is what makes the cursor honest: pages are taken by *continuing past a relative
    /// path*, not by an index, so a file added or removed between pages shifts nothing already
    /// delivered. `FileManager`'s enumerator has no order at all, so the walk sorts each
    /// directory's own entries and descends in that order.
    private nonisolated static func walk(
        root: URL,
        extensions: Set<String>,
        after: String,
        limit: Int
    ) -> WalkResult {
        let fileManager = FileManager.default
        var matches: [Match] = []
        var visited = 0
        var isFull = false
        var didExhaustVisits = false

        func descend(_ directory: URL, relativePrefix: String, depth: Int) {
            guard depth <= maximumWalkDepth, !isFull, !didExhaustVisits else { return }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
            ) else { return }

            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard !isFull else { return }
                // Running out of visit budget is **not** the end of the walk: the cursor is a
                // path, so the next page resumes exactly where this one stopped. Treating it as
                // the end would be a silent cap — a caller would read a partial list as the whole
                // project and never know a ceiling had been reached.
                guard visited < maximumVisitedEntries else {
                    didExhaustVisits = true
                    return
                }
                visited += 1
                let name = entry.lastPathComponent
                let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"

                guard let values = try? entry.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ]) else { continue }

                // A symlink is refused rather than followed. Resolving one is how a link named
                // `assets` walks out of the checkout and into the user's home directory, and the
                // containment check at open would then be defending against a handle this walk
                // had already decided was inside.
                if values.isSymbolicLink == true { continue }

                if values.isDirectory == true {
                    guard !excludedDirectories.contains(name) else { continue }
                    // A whole subtree that sorts before the cursor is skipped without being
                    // opened: `after` is a path, so string order decides both files and folders.
                    if !after.isEmpty, !after.hasPrefix(relativePath + "/"),
                       relativePath + "/" < after {
                        continue
                    }
                    descend(entry, relativePrefix: relativePath, depth: depth + 1)
                    continue
                }

                guard values.isRegularFile == true,
                      extensions.contains(entry.pathExtension.lowercased()),
                      after.isEmpty || relativePath > after else {
                    continue
                }
                guard matches.count < limit else {
                    isFull = true
                    return
                }
                matches.append(Match(
                    name: name,
                    relativePath: relativePath,
                    byteSize: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    contentHint: contentHint(for: entry)
                ))
            }
        }

        descend(root, relativePrefix: "", depth: 0)
        return WalkResult(
            matches: matches,
            hasMore: isFull || didExhaustVisits
        )
    }

    /// The host's own read of a bounded prefix. The prefix never leaves this function; only the
    /// hint it produced crosses the boundary.
    private nonisolated static func contentHint(for url: URL) -> ExtensionFileContentHint? {
        let suffix = url.pathExtension.lowercased()
        if suffix == "lottie" { return .dotLottie }
        if suffix == "svg" { return .svg }
        if suffix == "mmd" || suffix == "mermaid" { return .mermaid }
        if suffix == "dot" || suffix == "gv" { return .graphviz }
        guard suffix == "json" || suffix == "yaml" || suffix == "yml" else { return nil }
        guard let prefix = MediaContentProbe.prefix(
            of: url,
            maximumBytes: contentHintPrefixBytes
        ) else { return nil }
        return MediaContentProbe.hint(forPrefix: prefix, fileExtension: suffix)
    }
}
