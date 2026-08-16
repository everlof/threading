import Foundation

// MARK: - Artifact Kind

/// A build output a project can regenerate, recognised either by its directory name together
/// with proof that the ecosystem which produces it is actually present, or by a manifest the
/// tool that wrote it left behind.
///
/// The marker is not decoration. `build`, `dist` and `target` are ordinary English words, and
/// a directory called `target` beside no `Cargo.toml` is somebody's data, not Cargo's cache.
enum ArtifactKind: String, CaseIterable, Codable, Sendable {
    case rust
    case node
    case swiftPackage
    case cocoaPods
    case next
    case turbo
    case pythonVenv
    case pythonCache
    case gradle
    case coverage

    /// Xcode's DerivedData, identified by the manifest Xcode writes at the top of it rather
    /// than by a name: the trees measured under `/tmp` on 2026-08-13 were called `dd`, `dd2`,
    /// `verify-dd`, `dd-snap`, `threading-theme-polish-dd` and `derived-data`, so there is no
    /// name to match on. See `DerivedDataManifest`.
    case xcodeDerivedData

    /// The directory this kind occupies, or nil for a kind with no fixed name at all.
    var directoryName: String? {
        switch self {
        case .rust: return "target"
        case .node: return "node_modules"
        case .swiftPackage: return ".build"
        case .cocoaPods: return "Pods"
        case .next: return ".next"
        case .turbo: return ".turbo"
        case .pythonVenv: return ".venv"
        case .pythonCache: return "__pycache__"
        case .gradle: return "build"
        case .coverage: return "coverage"
        case .xcodeDerivedData: return nil
        }
    }

    /// Files that must sit beside the directory for it to be that kind's output. Any one is
    /// enough; an empty list means the name alone is unambiguous, or that this kind is not
    /// recognised by name in the first place.
    var markerFiles: [String] {
        switch self {
        case .rust: return ["Cargo.toml"]
        case .node, .next, .turbo, .coverage: return ["package.json"]
        case .swiftPackage: return ["Package.swift"]
        case .cocoaPods: return ["Podfile"]
        case .pythonVenv: return ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg"]
        case .gradle: return ["build.gradle", "build.gradle.kts", "pom.xml", "settings.gradle"]
        case .pythonCache, .xcodeDerivedData: return []
        }
    }

    /// Whether the kind is proved by a manifest its own tool wrote rather than by a name and a
    /// marker beside it.
    ///
    /// This is what decides which safety gate applies. A name-gated kind is only ever offered
    /// inside a repository that calls it disposable; a manifest-gated kind carries its own
    /// proof and is the only thing offered outside one.
    var isManifestGated: Bool {
        switch self {
        case .xcodeDerivedData: return true
        case .rust, .node, .swiftPackage, .cocoaPods, .next, .turbo, .pythonVenv, .pythonCache,
             .gradle, .coverage: return false
        }
    }

    /// Every kind recognised by name, which is every kind `kind(for:)` can answer.
    static var nameGated: [ArtifactKind] { allCases.filter { !$0.isManifestGated } }

    /// The names those kinds occupy, as one set: the scratch walk prunes on this rather than
    /// asking each kind in turn, once per directory it visits.
    static let nameGatedDirectoryNames: Set<String> = Set(nameGated.compactMap(\.directoryName))

    /// What the row calls it.
    var displayName: String {
        switch self {
        case .rust: return L10n.string("Rust build output")
        case .node: return L10n.string("Node packages")
        case .swiftPackage: return L10n.string("Swift build output")
        case .cocoaPods: return "CocoaPods"
        case .next: return L10n.string("Next.js build")
        case .turbo: return L10n.string("Turbo cache")
        case .pythonVenv: return L10n.string("Python environment")
        case .pythonCache: return L10n.string("Python bytecode")
        case .gradle: return L10n.string("Gradle build output")
        case .coverage: return L10n.string("Coverage output")
        case .xcodeDerivedData: return L10n.string("Xcode derived data")
        }
    }

    /// How it comes back, shown so a row says what removing it costs.
    var rebuildHint: String {
        switch self {
        case .rust: return "cargo build"
        case .node: return "npm install"
        case .swiftPackage: return "swift build"
        case .cocoaPods: return "pod install"
        case .next: return "next build"
        case .turbo: return L10n.string("rebuilt on next run")
        case .pythonVenv: return L10n.string("recreate the environment")
        case .pythonCache: return L10n.string("regenerated on next run")
        case .gradle: return "gradle build"
        case .coverage: return L10n.string("re-run the tests")
        case .xcodeDerivedData: return "xcodebuild"
        }
    }

    /// The kind occupying `url`, or nil when the name matches nothing or its marker is absent.
    ///
    /// **This answer is name-first, and stays that way.** A manifest-gated kind is deliberately
    /// invisible here — DerivedData has no fixed name to match, and a `dd` in a project folder
    /// is not something the project scan should start offering. Its recognizer is
    /// `DerivedDataManifest.read(inDirectory:)`, reachable only from the scratch walk.
    static func kind(for url: URL) -> ArtifactKind? {
        let name = url.lastPathComponent
        guard let kind = nameGated.first(where: { $0.directoryName == name }) else { return nil }

        guard !kind.markerFiles.isEmpty else { return kind }

        let parent = url.deletingLastPathComponent()
        let hasMarker = kind.markerFiles.contains {
            FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
        return hasMarker ? kind : nil
    }
}

// MARK: - Derived Data Manifest

/// What Xcode writes at the top of a DerivedData tree, and the reason such a tree can be
/// offered outside any repository at all.
///
/// The project scan's necessary gate is git: without a repository nothing asserts a directory
/// is regenerable rather than someone's only copy. Scratch directories have no git to ask —
/// the verification copies agents build in are `rsync`'d *without* `.git` on purpose, so a
/// build in them cannot touch the developer's index — so the gate is **replaced rather than
/// relaxed**. A directory holding `info.plist` with a `WorkspacePath`, plus `Build/` and
/// `ModuleCache.noindex/`, was written by Xcode and by nothing else. All 24 trees measured
/// under `/tmp` and `$TMPDIR` on 2026-08-13 had that shape; `target` beside a `Cargo.toml` is a
/// guess by comparison.
struct DerivedDataManifest: Equatable {

    // MARK: - Properties

    /// The workspace Xcode built from. It is also the attribution: a tree whose workspace no
    /// longer exists is an orphan that nothing can rebuild into and nothing will read again.
    let workspacePath: String

    /// The build system's own record of when it last used the tree — a better staleness reading
    /// than the newest write inside, and absent from trees old enough not to carry it.
    let lastAccessedDate: Date?

    // MARK: - Reading

    /// The manifest at the top of `url`, or nil when the directory is not a DerivedData tree.
    ///
    /// The two required subdirectories are checked first because they are two stats that almost
    /// every directory in `/tmp` fails, which keeps the plist read off the walk's common path.
    static func read(
        inDirectory url: URL,
        fileManager: FileManager = .default
    ) -> DerivedDataManifest? {
        for name in ScratchDefaults.derivedDataRequiredDirectories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: url.appendingPathComponent(name).path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { return nil }
        }

        let manifest = url.appendingPathComponent(ScratchDefaults.derivedDataManifestName)
        // A ceiling rather than a trust: the file Xcode writes is a few hundred bytes, and a
        // walk of somebody's scratch directory should not be able to read an arbitrary blob
        // into memory because it was named `info.plist`.
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ScratchDefaults.maximumManifestBytes,
              let data = try? Data(contentsOf: manifest),
              let contents = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let plist = contents as? [String: Any],
              let workspacePath = plist[Key.workspacePath] as? String,
              !workspacePath.isEmpty else { return nil }

        // Read leniently: a tree without a usable date is still a DerivedData tree, and the
        // measured mtime stands in for it.
        return DerivedDataManifest(
            workspacePath: workspacePath,
            lastAccessedDate: plist[Key.lastAccessedDate] as? Date
        )
    }

    // MARK: - Keys

    /// The two keys read out of `info.plist`. Everything else Xcode writes there is ignored.
    private enum Key {
        static let workspacePath = "WorkspacePath"
        static let lastAccessedDate = "LastAccessedDate"
    }
}

// MARK: - Reclaimable Artifact

/// One directory that can be deleted and rebuilt.
///
/// `Codable` so a scan survives to the next launch: finding these means walking every other
/// directory in a project first, which is far too slow to repeat whenever a page opens. The
/// record is a claim about the disk at a moment, not the disk itself, so everything that reads
/// one back re-checks what matters (see `ArtifactScanner.isSafeToRemove`).
struct ReclaimableArtifact: Identifiable, Equatable, Codable, Sendable {
    let url: URL
    let kind: ArtifactKind

    /// Bytes actually occupied on disk, summed from the files inside.
    let byteCount: Int64

    /// When anything inside it was last written — the age that tells a live build output from
    /// one belonging to a checkout nobody has touched in months.
    let modifiedAt: Date?

    /// The checkout it belongs to, which is not always the project's own folder: a repository's
    /// worktrees frequently live *inside* it, each carrying build output of its own. For a
    /// finding in a scratch location, which belongs to no checkout, this is the scratch root it
    /// was found under.
    let checkoutPath: String

    /// What a manifest-gated finding's own tool declared it was built for — Xcode's
    /// `WorkspacePath`. Nil for everything found by name inside a project.
    ///
    /// Optional so an older cache decodes unchanged, and read rather than resolved: whether the
    /// workspace still exists, and whether it belongs to a project Threading knows, are both
    /// answered when listing rather than when scanning, because both change in between.
    let workspacePath: String?

    var id: String { url.path }

    // MARK: - Initialization

    /// Spelled out rather than left to the memberwise initializer so `workspacePath` can default
    /// to nil, which is what every finding inside a project folder is.
    init(
        url: URL,
        kind: ArtifactKind,
        byteCount: Int64,
        modifiedAt: Date?,
        checkoutPath: String,
        workspacePath: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.checkoutPath = checkoutPath
        self.workspacePath = workspacePath
    }

    // MARK: - Reading

    /// Whether this sits in a checkout other than the project's own folder.
    func isNestedCheckout(of projectFolder: String) -> Bool {
        checkoutPath != projectFolder
    }

    /// Whether something wrote here moments ago, which usually means a build is running.
    ///
    /// Worth its own state because the first real scan found it: the largest directory on the
    /// page had been written to two minutes earlier, in a worktree with no Threading session to
    /// warn about. Age is the only evidence available that a directory is in use, and deleting
    /// a `target/` mid-build is the one way this goes wrong for someone who understood exactly
    /// what they asked for.
    func isInUse(at now: Date = Date()) -> Bool {
        guard let modifiedAt else { return false }
        return now.timeIntervalSince(modifiedAt) < ArtifactDefaults.inUseWindow
    }
}

// MARK: - Artifact Scanner

/// Finds build output that can be deleted and rebuilt, and deletes it.
///
/// **Two gates, and neither alone is enough.** A path is only ever offered when git ignores it
/// *and* its name and marker identify it as a known build output.
///
/// Ignore status alone is tempting — the project itself declared the path disposable — and it
/// is wrong. Measured on this machine, `git check-ignore` also says yes to `.env.local`,
/// `.env.jira` and `ansible/runner-controller-secrets.yml`. A tool that deleted everything git
/// ignores would delete your secrets. So the ignore is *necessary* (it proves the project does
/// not track this) and the allowlist is *sufficient* (it proves a tool can recreate it).
///
/// **Outside a project the necessary gate is replaced, never dropped.** `scanScratch(roots:)`
/// walks the locations agents build in, where the trees worth finding have no repository to ask
/// — and there the proof is a manifest the producing tool wrote (`DerivedDataManifest`) plus
/// containment in a scratch root. Nothing recognised by name is offered there at all.
///
/// Every path blocks on the filesystem, so callers hop to a queue of their own first.
enum ArtifactScanner {

    // MARK: - Scanning

    /// Every reclaimable directory inside a checkout, including any worktrees nested within it.
    ///
    /// Found directories are **not descended into**: a `node_modules` holding a thousand nested
    /// `node_modules` is one answer, not a thousand, and the walk stops at the top of it.
    static func scan(projectFolder: String) -> [ReclaimableArtifact] {
        let root = URL(fileURLWithPath: projectFolder)
        var found: [ReclaimableArtifact] = []

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        // Hidden files are deliberately *not* skipped — `.build`, `.venv` and `.next` are all
        // hidden, and they are three of the largest things worth finding.
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            ThreadingLogger.storage.warning(
                "Artifact scan could not enumerate project root=\(root.path, privacy: .private(mask: .hash))"
            )
            return []
        }

        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            if url.lastPathComponent == ArtifactDefaults.gitDirectoryName {
                walker.skipDescendants()
                continue
            }

            if walker.level > ArtifactDefaults.maximumDepth {
                walker.skipDescendants()
                continue
            }

            guard let kind = ArtifactKind.kind(for: url) else { continue }

            // Nothing below a build output is a separate answer.
            walker.skipDescendants()

            guard isDisposable(url) else { continue }

            let measured = measure(url)
            found.append(ReclaimableArtifact(
                url: url,
                kind: kind,
                byteCount: measured.bytes,
                modifiedAt: measured.modifiedAt,
                checkoutPath: GitInfo.repositoryRoot(
                    for: url.deletingLastPathComponent().path
                )?.path ?? projectFolder
            ))
        }

        return found.sorted { $0.byteCount > $1.byteCount }
    }

    /// Every reclaimable directory in the scratch locations agents build in — outside any
    /// project, and usually outside any repository.
    ///
    /// **Only manifest-gated findings are ever returned.** A `node_modules` beside a real
    /// `package.json` in `/tmp` passes the project scan's *sufficient* gate and fails its
    /// *necessary* one, and relaxing that is how this feature would become an
    /// arbitrary-delete primitive pointed at a directory full of other people's data. So a
    /// name-gated kind found here is not offered — it is **pruned**, whole, without being
    /// measured or asked about. That prune is load-bearing rather than tidy: one `rsync`'d
    /// scratch tree measured here holds 87,998 files, and there were 170 session directories
    /// beside it.
    ///
    /// No git subprocess runs on this path. The trees worth finding have no repository to ask,
    /// which is the entire reason the manifest gate exists.
    static func scanScratch(roots: [URL] = ScratchDefaults.roots) -> [ReclaimableArtifact] {
        var found: [ReclaimableArtifact] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        for root in roots {
            // Hidden files are deliberately *not* skipped here either: scratch directories are
            // routinely named with a leading dot, and `.build` is one of the names pruned.
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                ThreadingLogger.storage.warning(
                    "Scratch scan could not enumerate root=\(root.path, privacy: .private(mask: .hash))"
                )
                continue
            }

            while let url = walker.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

                if url.lastPathComponent == ArtifactDefaults.gitDirectoryName {
                    walker.skipDescendants()
                    continue
                }

                if walker.level > ScratchDefaults.maximumDepth {
                    walker.skipDescendants()
                    continue
                }

                // Asked before the name prune, so a DerivedData tree that happens to be called
                // `build` or `target` is still recognised for what its own manifest says it is.
                if let manifest = DerivedDataManifest.read(inDirectory: url) {
                    // Nothing below a build output is a separate answer.
                    walker.skipDescendants()

                    let measured = measure(url)
                    found.append(ReclaimableArtifact(
                        url: url,
                        kind: .xcodeDerivedData,
                        byteCount: measured.bytes,
                        // The manifest's own reading wins when it is the newer one: it is the
                        // build system saying when it last used the tree, rather than the walk
                        // guessing from whichever file was written last.
                        modifiedAt: [measured.modifiedAt, manifest.lastAccessedDate]
                            .compactMap { $0 }
                            .max(),
                        checkoutPath: root.path,
                        workspacePath: manifest.workspacePath
                    ))
                    continue
                }

                if ArtifactKind.nameGatedDirectoryNames.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
            }
        }

        return found.sorted { $0.byteCount > $1.byteCount }
    }

    // MARK: - Safety

    /// Whether git considers the path disposable — the *necessary* gate, proving the project
    /// does not keep what is about to be deleted.
    ///
    /// Two questions, and the second is not redundant. **`check-ignore` answers about patterns,
    /// not about tracking**: a path matched by `.gitignore` reports as ignored even when it is
    /// committed, since git's rule is that tracked files are unaffected by the ignore list. A
    /// directory that is both matched and tracked would pass the first question while holding
    /// content that exists nowhere else. So `ls-files` is asked as well, and anything tracked
    /// inside refuses the whole directory.
    ///
    /// A path git knows nothing about (outside any repository) is refused too: without a
    /// repository nothing asserts the directory is regenerable rather than someone's only copy.
    static func isDisposable(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        guard let root = GitInfo.repositoryRoot(for: parent.path) else { return false }

        // `check-ignore` exits 0 when the path is ignored, 1 when it is not — so a thrown
        // error is the ordinary "not ignored" answer here, not a failure.
        do {
            _ = try GitProcess.run(
                ["check-ignore", "--quiet", url.path],
                in: root,
                maximumOutput: ArtifactDefaults.maximumCheckOutput,
                reportsRejectedExit: false
            )
        } catch {
            return false
        }

        return !tracksAnything(in: url, root: root)
    }

    /// Whether git tracks any file inside the directory. Empty output means nothing there is
    /// committed, which is what makes the directory the tool's to remove.
    private static func tracksAnything(in url: URL, root: URL) -> Bool {
        do {
            let output = try GitProcess.run(
                ["ls-files", "--cached", "-z", "--", url.path],
                in: root,
                maximumOutput: ArtifactDefaults.maximumTrackedOutput
            )
            return !output.isEmpty
        } catch {
            // An unreadable answer is not permission to delete.
            return true
        }
    }

    /// Whether a manifest-gated path is disposable — the replacement for the git gate, and the
    /// only gate that can answer yes outside a repository.
    ///
    /// Two questions, and the second is not redundant either. The manifest is re-read rather
    /// than remembered, because a tree stops being Xcode's the moment its `info.plist` goes.
    /// And the path must still sit inside a scratch root: the manifest alone would make this a
    /// rule about any directory anywhere that happens to hold three names, while the whole
    /// claim being made is about the locations agents build in. Both sides are compared with
    /// symlinks resolved, since `/tmp` is a symlink to `/private/tmp` and two spellings of one
    /// directory must not read as two places.
    static func isDisposableScratch(
        _ url: URL,
        kind: ArtifactKind,
        roots: [URL] = ScratchDefaults.roots
    ) -> Bool {
        guard kind == .xcodeDerivedData else { return false }
        guard DerivedDataManifest.read(inDirectory: url) != nil else { return false }
        return isContained(url, in: roots)
    }

    /// Whether `url` sits inside one of `roots`, both normalised the same way so that `/tmp`
    /// and `/private/tmp` cannot disagree about being the same directory.
    private static func isContained(_ url: URL, in roots: [URL]) -> Bool {
        let path = normalized(url)
        return roots.contains { root in
            let rootPath = normalized(root)
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Both gates again, immediately before a delete.
    ///
    /// Re-checked rather than trusted from the scan: a listing the user is reading is a listing
    /// going stale, and the cost of being wrong here is somebody's directory. Which pair of
    /// gates applies is decided by the kind, so a name-gated finding can never be waved through
    /// on a manifest and a manifest-gated one is never asked a question git cannot answer.
    static func isSafeToRemove(_ artifact: ReclaimableArtifact) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifact.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        guard !artifact.kind.isManifestGated else {
            return isDisposableScratch(artifact.url, kind: artifact.kind)
        }

        guard ArtifactKind.kind(for: artifact.url) == artifact.kind,
              isDisposable(artifact.url) else { return false }

        return true
    }

    // MARK: - Removal

    /// Deletes an artifact, refusing anything that no longer passes both gates.
    ///
    /// Removed outright rather than moved to the Trash, which for once is the safer-feeling
    /// option that helps nobody: the point of the operation is the space, and 30 GB sitting in
    /// the Trash has not been reclaimed. What makes that acceptable is the gates — nothing is
    /// offered that a documented command cannot rebuild.
    @discardableResult
    static func remove(_ artifact: ReclaimableArtifact) -> Bool {
        removeWithOutcome(artifact) == .removed
    }

    /// The typed result used by the cleanup coordinator. A refusal means the safety gates no
    /// longer pass; a failure means the same vetted directory was still eligible but could not
    /// be removed. Keeping those apart makes the final progress receipt honest.
    static func removeWithOutcome(_ artifact: ReclaimableArtifact) -> ArtifactRemovalOutcome {
        guard isSafeToRemove(artifact) else {
            ThreadingLogger.storage.error(
                "Refused to remove \(artifact.url.path, privacy: .private(mask: .hash)): no longer disposable"
            )
            return .refused
        }

        do {
            try FileManager.default.removeItem(at: artifact.url)
            ThreadingLogger.storage.notice(
                "Reclaimable artifact removed kind=\(artifact.kind.rawValue, privacy: .public) path=\(artifact.url.path, privacy: .private(mask: .hash)) bytes=\(artifact.byteCount, privacy: .public)"
            )
            return .removed
        } catch {
            ThreadingLogger.storage.error(
                "Could not remove \(artifact.url.path, privacy: .private(mask: .hash)) — \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .failed
        }
    }

    // MARK: - Measuring

    /// Bytes on disk and the newest write inside, walked once.
    ///
    /// **Each inode is counted once**, the way `du` counts it, because a build directory is
    /// full of hard links and summing per-file sizes reports space that deleting would not
    /// return. Measured on one Cargo `target/`: 37,810 files but 25,021 distinct inodes, and
    /// the naive sum claimed 42.79 GB where the directory occupies 33.18 GB — a 29% overstatement
    /// of the one number this whole feature promises.
    ///
    /// The identifier is only fetched for files that *are* linked more than once, so the
    /// ordinary file costs nothing extra.
    private static func measure(_ url: URL) -> (bytes: Int64, modifiedAt: Date?) {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .linkCountKey,
            .fileResourceIdentifierKey
        ]
        // Packages are descended into: `du` counts what is inside an `.app`, and a DerivedData's
        // `Build/Products` is nothing but bundles — skipping them understates the one number
        // this measurement exists to report.
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys
        ) else { return (0, nil) }

        var bytes: Int64 = 0
        var newest: Date?
        var countedLinks: Set<NSObject> = []

        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }

            if (values.linkCount ?? 1) > 1 {
                guard let identifier = values.fileResourceIdentifier as? NSObject,
                      countedLinks.insert(identifier).inserted else { continue }
            }

            bytes += Int64(values.totalFileAllocatedSize ?? 0)
            if let modified = values.contentModificationDate, modified > (newest ?? .distantPast) {
                newest = modified
            }
        }

        return (bytes, newest)
    }
}

enum ArtifactRemovalOutcome: Equatable, Sendable {
    case removed
    case refused
    case failed
}

// MARK: - Artifact Defaults

enum ArtifactDefaults {
    static let gitDirectoryName = ".git"

    /// Deep enough for a monorepo's `packages/<name>/node_modules` and for worktrees kept
    /// inside a checkout, shallow enough that the walk is not a crawl of the whole disk.
    static let maximumDepth = 8

    /// `check-ignore --quiet` prints nothing; the ceiling exists only so a surprise cannot
    /// grow the buffer.
    static let maximumCheckOutput = 4096

    /// `ls-files` is asked only whether *anything* is tracked, so one path is already the
    /// whole answer and the rest of a large listing is waste.
    static let maximumTrackedOutput = 64 * 1024

    /// How recently a write means "something is building here". Generous, because the cost of
    /// calling a live build stale is an interrupted build, while the cost of calling a stale
    /// one live is a sentence of caution on a row.
    static let inUseWindow: TimeInterval = 15 * 60
}

// MARK: - Scratch Defaults

/// The scratch scope: where agents build when they are not building in a project.
enum ScratchDefaults {

    /// The shared temporary directory, spelled the way the filesystem does. `/tmp` is a symlink
    /// to this, so naming both would walk 76 GB twice for one answer.
    static let sharedTemporaryPath = "/private/tmp"

    /// Where the scratch scan looks.
    ///
    /// The per-user temporary directory is the `/var/folders/…/T/` that `_CS_DARWIN_USER_TEMP_DIR`
    /// names — 8.1 GB of it on the machine this was measured on. macOS cleans it on a schedule of
    /// its own, which nothing does for `/private/tmp`; it is included because the space is real,
    /// not because a reading there keeps as well.
    ///
    /// Standardised at the source so every containment check compares like with like.
    static let roots: [URL] = [
        URL(fileURLWithPath: sharedTemporaryPath, isDirectory: true),
        FileManager.default.temporaryDirectory
    ].map { $0.standardizedFileURL }

    /// Deliberately shallower than the project scan's `maximumDepth`, and a separate constant
    /// rather than a shared one because the two walks answer to different shapes. A project is
    /// walked for a monorepo's `packages/<name>/node_modules` and for worktrees kept inside a
    /// checkout; a scratch root is walked across 170 session directories, one of which alone
    /// holds 87,998 files. Every DerivedData tree measured on 2026-08-13 sat within 6 levels of
    /// `/private/tmp` and most within 3, so 7 buys a level of headroom over what exists while
    /// keeping the walk off the far side of an rsync'd repository copy.
    static let maximumDepth = 7

    /// The manifest Xcode writes at the top of a DerivedData tree.
    static let derivedDataManifestName = "info.plist"

    /// The directories that must sit beside that manifest. Xcode also writes
    /// `SDKStatCaches.noindex/` and `SourcePackages/`, which are not required: these two are
    /// present in every tree measured, and asking for more names would refuse a real tree over
    /// a version difference.
    static let derivedDataRequiredDirectories = ["Build", "ModuleCache.noindex"]

    /// A ceiling on the manifest read. Xcode's own is a few hundred bytes.
    static let maximumManifestBytes = 64 * 1024
}
