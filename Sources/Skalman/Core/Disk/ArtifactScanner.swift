import Foundation

// MARK: - Artifact Kind

/// A build output a project can regenerate, recognised by its directory name together with
/// proof that the ecosystem which produces it is actually present.
///
/// The marker is not decoration. `build`, `dist` and `target` are ordinary English words, and
/// a directory called `target` beside no `Cargo.toml` is somebody's data, not Cargo's cache.
enum ArtifactKind: String, CaseIterable, Codable {
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

    /// The directory this kind occupies.
    var directoryName: String {
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
        }
    }

    /// Files that must sit beside the directory for it to be that kind's output. Any one is
    /// enough; an empty list means the name alone is unambiguous.
    var markerFiles: [String] {
        switch self {
        case .rust: return ["Cargo.toml"]
        case .node, .next, .turbo, .coverage: return ["package.json"]
        case .swiftPackage: return ["Package.swift"]
        case .cocoaPods: return ["Podfile"]
        case .pythonVenv: return ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg"]
        case .gradle: return ["build.gradle", "build.gradle.kts", "pom.xml", "settings.gradle"]
        case .pythonCache: return []
        }
    }

    /// What the row calls it.
    var displayName: String {
        switch self {
        case .rust: return "Rust build output"
        case .node: return "Node packages"
        case .swiftPackage: return "Swift build output"
        case .cocoaPods: return "CocoaPods"
        case .next: return "Next.js build"
        case .turbo: return "Turbo cache"
        case .pythonVenv: return "Python environment"
        case .pythonCache: return "Python bytecode"
        case .gradle: return "Gradle build output"
        case .coverage: return "Coverage output"
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
        case .turbo: return "rebuilt on next run"
        case .pythonVenv: return "recreate the environment"
        case .pythonCache: return "regenerated on next run"
        case .gradle: return "gradle build"
        case .coverage: return "re-run the tests"
        }
    }

    /// The kind occupying `url`, or nil when the name matches nothing or its marker is absent.
    static func kind(for url: URL) -> ArtifactKind? {
        let name = url.lastPathComponent
        guard let kind = allCases.first(where: { $0.directoryName == name }) else { return nil }

        guard !kind.markerFiles.isEmpty else { return kind }

        let parent = url.deletingLastPathComponent()
        let hasMarker = kind.markerFiles.contains {
            FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
        return hasMarker ? kind : nil
    }
}

// MARK: - Reclaimable Artifact

/// One directory that can be deleted and rebuilt.
///
/// `Codable` so a scan survives to the next launch: finding these means walking every other
/// directory in a project first, which is far too slow to repeat whenever a page opens. The
/// record is a claim about the disk at a moment, not the disk itself, so everything that reads
/// one back re-checks what matters (see `ArtifactScanner.isSafeToRemove`).
struct ReclaimableArtifact: Identifiable, Equatable, Codable {
    let url: URL
    let kind: ArtifactKind

    /// Bytes actually occupied on disk, summed from the files inside.
    let byteCount: Int64

    /// When anything inside it was last written — the age that tells a live build output from
    /// one belonging to a checkout nobody has touched in months.
    let modifiedAt: Date?

    /// The checkout it belongs to, which is not always the project's own folder: a repository's
    /// worktrees frequently live *inside* it, each carrying build output of its own.
    let checkoutPath: String

    var id: String { url.path }

    /// Whether this sits in a checkout other than the project's own folder.
    func isNestedCheckout(of projectFolder: String) -> Bool {
        checkoutPath != projectFolder
    }

    /// Whether something wrote here moments ago, which usually means a build is running.
    ///
    /// Worth its own state because the first real scan found it: the largest directory on the
    /// page had been written to two minutes earlier, in a worktree with no Skalman session to
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
        ) else { return [] }

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
                maximumOutput: ArtifactDefaults.maximumCheckOutput
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

    /// Both gates again, immediately before a delete.
    ///
    /// Re-checked rather than trusted from the scan: a listing the user is reading is a listing
    /// going stale, and the cost of being wrong here is somebody's directory.
    static func isSafeToRemove(_ artifact: ReclaimableArtifact) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifact.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              ArtifactKind.kind(for: artifact.url) == artifact.kind,
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
        guard isSafeToRemove(artifact) else {
            SkalmanLogger.agent.error(
                "Refused to remove \(artifact.url.path, privacy: .public): no longer disposable"
            )
            return false
        }

        do {
            try FileManager.default.removeItem(at: artifact.url)
            return true
        } catch {
            SkalmanLogger.agent.error(
                "Could not remove \(artifact.url.path, privacy: .public) — \(error.localizedDescription, privacy: .public)"
            )
            return false
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
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
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
