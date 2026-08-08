import Foundation

struct WorkspaceFileReference: Equatable, Hashable, Sendable {
    /// Always relative to the selected session's execution checkout.
    let path: String
}

struct WorkspaceFileMentionQuery: Equatable, Sendable {
    let term: String
    let replacementRange: NSRange

    /// A mention starts only at a token boundary. `mail@example.com` and prose containing an @
    /// remain ordinary text; a leading or whitespace-delimited `@path` opens file completion.
    static func parse(text: String, caretUTF16Offset: Int) -> WorkspaceFileMentionQuery? {
        let utf16 = Array(text.utf16)
        guard caretUTF16Offset >= 0, caretUTF16Offset <= utf16.count else { return nil }
        var start = caretUTF16Offset
        while start > 0 {
            let scalar = utf16[start - 1]
            guard scalar != 0x20, scalar != 0x09, scalar != 0x0A, scalar != 0x0D else { break }
            start -= 1
        }
        guard start < caretUTF16Offset, utf16[start] == 0x40 else { return nil }
        if start > 0 {
            let previous = utf16[start - 1]
            guard previous == 0x20 || previous == 0x09 || previous == 0x0A || previous == 0x0D else {
                return nil
            }
        }
        let range = NSRange(location: start + 1, length: caretUTF16Offset - start - 1)
        guard let swiftRange = Range(range, in: text) else { return nil }
        return WorkspaceFileMentionQuery(
            term: String(text[swiftRange]),
            replacementRange: NSRange(location: start, length: caretUTF16Offset - start)
        )
    }
}

enum WorkspaceFileSearchFailure: Error, Equatable, Sendable {
    case sessionUnavailable
    case checkoutUnavailable
    case repositoryUnavailable
    case indexTooLarge(limit: Int)
    case fileUnavailable(path: String)
}

enum WorkspaceFileSearchDefaults {
    static let maximumIndexedPaths = 100_000
    static let maximumResults = 64
    static let maximumGitOutputBytes = 16 * 1_024 * 1_024
}

/// A checkout-aware, cached file query. Root resolution stays in the host adapter, and only
/// project-relative references cross this boundary; callers never receive a filesystem URL.
@MainActor
final class WorkspaceFileSearchPlane {
    typealias RootResolver = @MainActor (SessionID) -> URL?
    typealias Completion = @MainActor @Sendable (Result<[WorkspaceFileReference], WorkspaceFileSearchFailure>) -> Void
    typealias ValidationCompletion = @MainActor @Sendable (Result<Void, WorkspaceFileSearchFailure>) -> Void

    private let rootResolver: RootResolver
    private let index: WorkspaceFileIndex

    init(
        rootResolver: @escaping RootResolver,
        index: WorkspaceFileIndex = WorkspaceFileIndex()
    ) {
        self.rootResolver = rootResolver
        self.index = index
    }

    func search(sessionID: SessionID, query: String, completion: @escaping Completion) {
        guard let root = rootResolver(sessionID) else {
            completion(.failure(.sessionUnavailable))
            return
        }
        index.search(root: root, query: query) { result in
            Task { @MainActor in completion(result) }
        }
    }

    func validate(
        sessionID: SessionID,
        references: [WorkspaceFileReference],
        completion: @escaping ValidationCompletion
    ) {
        guard let root = rootResolver(sessionID) else {
            completion(.failure(.sessionUnavailable))
            return
        }
        index.validate(root: root, references: references) { result in
            Task { @MainActor in completion(result) }
        }
    }

    func invalidate(sessionID: SessionID) {
        guard let root = rootResolver(sessionID) else { return }
        index.invalidate(root: root)
    }
}

/// Queue-confined cache: `git ls-files` is paid once per checkout, never once per keystroke.
final class WorkspaceFileIndex: @unchecked Sendable {
    typealias Loader = @Sendable (URL) throws -> [String]

    private let queue = DispatchQueue(label: "codes.threading.workspace-file-index", qos: .userInitiated)
    private let generationLock = NSLock()
    private let loader: Loader
    private var pathsByRoot: [String: [String]] = [:]
    private var searchGenerationByRoot: [String: UInt] = [:]

    init(loader: Loader? = nil) {
        self.loader = loader ?? { root in try WorkspaceFileIndex.gitVisiblePaths(root: root) }
    }

    func search(
        root: URL,
        query: String,
        completion: @escaping @Sendable (Result<[WorkspaceFileReference], WorkspaceFileSearchFailure>) -> Void
    ) {
        let rootKey = root.standardizedFileURL.path
        let generation = nextSearchGeneration(for: rootKey)
        queue.async { [self] in
            guard isLatestSearch(generation, for: rootKey) else {
                completion(.success([]))
                return
            }
            do {
                let paths = try indexedPaths(root: root)
                guard isLatestSearch(generation, for: rootKey) else {
                    completion(.success([]))
                    return
                }
                let ranked = Self.rank(paths: paths, query: query)
                guard isLatestSearch(generation, for: rootKey) else {
                    completion(.success([]))
                    return
                }
                completion(.success(ranked))
            } catch let failure as WorkspaceFileSearchFailure {
                completion(.failure(failure))
            } catch {
                completion(.failure(.repositoryUnavailable))
            }
        }
    }

    func validate(
        root: URL,
        references: [WorkspaceFileReference],
        completion: @escaping @Sendable (Result<Void, WorkspaceFileSearchFailure>) -> Void
    ) {
        queue.async { [self] in
            do {
                // Refresh deliberately: drafts can outlive renames/deletions and a cached roster
                // is not evidence that a file still exists at send time.
                pathsByRoot.removeValue(forKey: root.standardizedFileURL.path)
                let paths = Set(try indexedPaths(root: root))
                for reference in references {
                    guard paths.contains(reference.path),
                          Self.isContainedRegularFile(path: reference.path, root: root) else {
                        throw WorkspaceFileSearchFailure.fileUnavailable(path: reference.path)
                    }
                }
                completion(.success(()))
            } catch let failure as WorkspaceFileSearchFailure {
                completion(.failure(failure))
            } catch {
                completion(.failure(.repositoryUnavailable))
            }
        }
    }

    func invalidate(root: URL) {
        _ = nextSearchGeneration(for: root.standardizedFileURL.path)
        queue.async { [self] in
            pathsByRoot.removeValue(forKey: root.standardizedFileURL.path)
        }
    }

    private func nextSearchGeneration(for root: String) -> UInt {
        generationLock.lock()
        defer { generationLock.unlock() }
        let next = (searchGenerationByRoot[root] ?? 0) &+ 1
        searchGenerationByRoot[root] = next
        return next
    }

    private func isLatestSearch(_ generation: UInt, for root: String) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return searchGenerationByRoot[root] == generation
    }

    private func indexedPaths(root: URL) throws -> [String] {
        let key = root.standardizedFileURL.path
        if let cached = pathsByRoot[key] { return cached }
        guard FileManager.default.fileExists(atPath: key) else {
            throw WorkspaceFileSearchFailure.checkoutUnavailable
        }
        let loaded = try loader(root)
        guard loaded.count <= WorkspaceFileSearchDefaults.maximumIndexedPaths else {
            throw WorkspaceFileSearchFailure.indexTooLarge(
                limit: WorkspaceFileSearchDefaults.maximumIndexedPaths
            )
        }
        let safe = loaded.filter { Self.isContainedRegularFile(path: $0, root: root) }
        pathsByRoot[key] = safe
        return safe
    }

    static func rank(paths: [String], query rawQuery: String) -> [WorkspaceFileReference] {
        let query = rawQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        return paths.compactMap { path -> (Int, String)? in
            guard !query.isEmpty else { return (0, path) }
            let folded = path.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            let name = (path as NSString).lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            let score: Int
            if name == query { score = 0 }
            else if name.hasPrefix(query) { score = 10 }
            else if folded.hasPrefix(query) { score = 20 }
            else if name.contains(query) { score = 30 }
            else if folded.contains(query) { score = 40 }
            else { return nil }
            return (score, path)
        }
        .sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1.count != right.1.count { return left.1.count < right.1.count }
            return left.1.localizedStandardCompare(right.1) == .orderedAscending
        }
        .prefix(WorkspaceFileSearchDefaults.maximumResults)
        .map { WorkspaceFileReference(path: $0.1) }
    }

    private static func gitVisiblePaths(root: URL) throws -> [String] {
        let data = try GitProcess.run(
            GitReviewCommands.common + GitReviewCommands.repositoryFiles(),
            in: root,
            maximumOutput: WorkspaceFileSearchDefaults.maximumGitOutputBytes
        )
        return GitDiffParser.decode(data)
            .split(separator: "\u{00}", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func isContainedRegularFile(path: String, root: URL) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return false
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot.appendingPathComponent(path)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(prefix),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
