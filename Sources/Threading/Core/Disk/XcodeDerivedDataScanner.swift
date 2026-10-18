import Darwin
import Foundation

/// Xcode's standard cache location is not a scratch root. Only its direct children are
/// candidates — neither the root nor shared caches nor arbitrary descendants are — and a child
/// is offered on one of two pieces of evidence Xcode itself wrote: its `info.plist` manifest, or,
/// when that is gone, its folder name in Xcode's hashed shape over contents that are nothing but
/// Xcode's own output directories (see `XcodeDerivedDataName`).
enum XcodeDerivedDataScanner {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    private enum Limits {
        static let rootEntries = 4_096
        static let measuredEntries = 1_000_000
        static let seconds: TimeInterval = 30
        static let processes = 16_384
        static let processNameBytes = 256
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN; Swift does not
        // import that expression macro.
        static let processPathBytes = 4 * Int(MAXPATHLEN)
    }

    /// These are alternative evidence beside info.plist, not names sufficient on their own.
    /// Xcode can leave only Logs/TestResults after cleaning, and shares ModuleCache.noindex
    /// between projects in this location instead of putting one in every child.
    private static let cacheDirectories: Set<String> = [
        "Build", "Index.noindex", "Logs", "TestResults", "SourcePackages",
        "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"
    ]
    private static let builders: Set<String> = [
        "Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService"
    ]

    static func contains(_ url: URL, root: URL) -> Bool {
        func isWithin(_ path: String, _ parent: String) -> Bool {
            path == parent || path.hasPrefix(parent + "/")
        }
        return isWithin(url.standardizedFileURL.path, root.standardizedFileURL.path)
            || isWithin(normalized(url).path, normalized(root).path)
    }

    /// A pass examines at most 4,096 immediate entries and one million measured entries total,
    /// with a 30-second cooperative deadline. Incomplete measurements are never published.
    static func scan(
        root: URL = defaultRoot,
        maximumEntries: Int = Limits.measuredEntries,
        candidates: XcodeWorkspaceCandidates = .empty
    ) -> [ReclaimableArtifact] {
        guard isRealDirectory(root),
              let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return [] }

        var budget = measurementBudget(maximumEntries: maximumEntries)
        var found: [ReclaimableArtifact] = []
        var examined = 0
        for case let url as URL in walker {
            walker.skipDescendants()
            examined += 1
            guard examined <= Limits.rootEntries, budget.consume() else { break }
            guard let artifact = vet(url, root: root, candidates: candidates, budget: &budget) else { continue }
            found.append(artifact)
        }
        if examined > Limits.rootEntries || budget.remainingEntries == 0 || Date() >= budget.deadline {
            ThreadingLogger.storage.warning("Xcode cache scan reached its work limit; incomplete trees were omitted")
        }
        return found.sorted { $0.byteCount > $1.byteCount }
    }

    static func vet(
        _ url: URL,
        root: URL = defaultRoot,
        candidates: XcodeWorkspaceCandidates = .empty
    ) -> ReclaimableArtifact? {
        var budget = measurementBudget()
        return vet(url, root: root, candidates: candidates, budget: &budget)
    }

    private static func vet(
        _ url: URL,
        root: URL,
        candidates: XcodeWorkspaceCandidates,
        budget: inout ArtifactMeasurementBudget
    ) -> ReclaimableArtifact? {
        guard let identity = identity(at: url, root: root),
              let measured = ArtifactScanner.measure(url, budget: &budget) else { return nil }

        let workspacePath: String?
        var lastAccessedDate: Date?
        switch identity {
        case .manifest(let manifest):
            workspacePath = manifest.workspacePath
            lastAccessedDate = manifest.lastAccessedDate
        case .name(let hash):
            workspacePath = candidates.byHash[hash]
        }

        return ReclaimableArtifact(
            url: url,
            kind: .xcodeDerivedData,
            byteCount: measured.bytes,
            modifiedAt: [measured.modifiedAt, lastAccessedDate].compactMap { $0 }.max(),
            checkoutPath: root.path,
            workspacePath: workspacePath
        )
    }

    /// Re-read both identity and use immediately before deleting. Cached age is only display
    /// data: a build may have started since the user opened the list. The process check is a
    /// conservative veto, never evidence that an arbitrary scratchpad is disposable.
    ///
    /// A folder found by its name has no manifest to re-read; its identity is the name and the
    /// shape, and both are checked again. Its workspace attribution was the scan's inference
    /// rather than Xcode's statement, so it is not what decides here — a manifest appearing does:
    /// that is Xcode building into it again, and the identity no longer matches.
    static func isSafeToRemove(
        _ artifact: ReclaimableArtifact,
        root: URL = defaultRoot,
        now: Date = Date(),
        hasActiveProcess: (URL) -> Bool = XcodeDerivedDataScanner.hasActiveProcess
    ) -> Bool {
        guard artifact.kind == .xcodeDerivedData,
              let initialIdentity = identity(at: artifact.url, root: root),
              !hasActiveProcess(artifact.url),
              let current = vet(artifact.url, root: root),
              !initialIdentity.isManifest || current.workspacePath == artifact.workspacePath,
              let modifiedAt = current.modifiedAt,
              now.timeIntervalSince(modifiedAt) >= ArtifactDefaults.inUseWindow else { return false }
        // Measurement can be long. Check processes and the identity again after walking.
        return !hasActiveProcess(artifact.url)
            && identity(at: artifact.url, root: root) == initialIdentity
    }

    /// What Xcode wrote that makes a child its own: the manifest when there is one, else the
    /// hashed name over nothing but Xcode's output directories.
    private enum Identity: Equatable {
        case manifest(DerivedDataManifest)
        case name(hash: String)

        var isManifest: Bool {
            if case .manifest = self { return true }
            return false
        }
    }

    private static func identity(at url: URL, root: URL) -> Identity? {
        if let manifest = manifest(at: url, root: root) { return .manifest(manifest) }
        return nameIdentity(at: url, root: root).map { .name(hash: $0) }
    }

    /// The hash of a direct child Xcode named and filled but left without a manifest, or nil.
    ///
    /// Strict about contents, because the name alone is 28 letters anybody could type: every
    /// entry must be one of Xcode's output directories, each a real directory, and an
    /// `info.plist` of any kind — even an unreadable or symlinked one — sends the child back to
    /// the manifest rule, which then refuses it. Measured on 2026-10-17, the 297 manifest-less
    /// children held only `Build`, `Logs`, `SourcePackages`, `TestResults` and `Index.noindex`.
    private static func nameIdentity(at url: URL, root: URL) -> String? {
        guard isRealDirectory(root), isRealDirectory(url),
              normalized(url.deletingLastPathComponent()) == normalized(root),
              let hash = XcodeDerivedDataName.hash(inFolderName: url.lastPathComponent),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }

        let outputs = entries.filter { $0 != finderMetadata }
        guard !outputs.isEmpty,
              !entries.contains(ScratchDefaults.derivedDataManifestName),
              outputs.allSatisfy({ cacheDirectories.contains($0) && isRealDirectory(url.appendingPathComponent($0)) })
        else { return nil }
        return hash
    }

    private static let finderMetadata = ".DS_Store"

    private static func manifest(at url: URL, root: URL) -> DerivedDataManifest? {
        guard isRealDirectory(root), isRealDirectory(url),
              normalized(url.deletingLastPathComponent()) == normalized(root) else { return nil }

        let manifestURL = url.appendingPathComponent(ScratchDefaults.derivedDataManifestName)
        guard let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              cacheDirectories.contains(where: { isRealDirectory(url.appendingPathComponent($0)) })
        else { return nil }

        return DerivedDataManifest.readManifest(inDirectory: url)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        // A URL retained in a finding may carry prefetched resource values from the scan.
        // Reconstruct it so a directory replaced by a symlink cannot reuse that old evidence.
        let freshURL = URL(fileURLWithPath: url.path)
        guard let values = try? freshURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func measurementBudget(
        maximumEntries: Int = Limits.measuredEntries
    ) -> ArtifactMeasurementBudget {
        ArtifactMeasurementBudget(
            remainingEntries: maximumEntries,
            deadline: Date().addingTimeInterval(Limits.seconds)
        )
    }

    /// Query only this user's processes, with fixed buffers and no child processes or argv
    /// reads. Keep all standard caches while Xcode/build services are alive, and keep a cache
    /// containing a running executable. A failed or full census refuses removal.
    static func hasActiveProcess(in directory: URL) -> Bool {
        var pids = [pid_t](repeating: 0, count: Limits.processes)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
        guard bytes > 0, bytes < capacity else { return true }
        let prefix = normalized(directory).path + "/"
        var name = [CChar](repeating: 0, count: Limits.processNameBytes)
        var path = [CChar](repeating: 0, count: Limits.processPathBytes)
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0,
               builders.contains(String(cString: name)) { return true }
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                if String(cString: path).hasPrefix(prefix) { return true }
            } else if kill(pid, 0) == 0 {
                return true
            }
        }
        return false
    }
}
