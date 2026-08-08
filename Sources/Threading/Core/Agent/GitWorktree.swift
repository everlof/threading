import Foundation

/// Creates git worktrees, so a session can run on its own branch without disturbing the
/// checkout you are working in.
///
/// This is the one place the app mutates a repository, so it shells out to `git` rather than
/// writing git's internal files itself: worktree registration touches several files that must
/// stay consistent, and `git` is the only thing that gets that right.
enum GitWorktree {

    // MARK: - Types

    enum Failure: LocalizedError {
        case notARepository
        case destinationExists(String)
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                return L10n.string("This project is not inside a git repository.")
            case .destinationExists(let path):
                return L10n.format("%@ already exists.", path)
            case .gitFailed(let message):
                return message
            }
        }
    }

    // MARK: - Public Methods

    /// Suggests where a worktree for `branch` should live: beside the repository, named after
    /// it, so sibling worktrees of one repo group together on disk.
    static func suggestedLocation(forBranch branch: String, in project: Project) -> URL? {
        guard let root = GitInfo.repositoryRoot(for: project.folderPath) else { return nil }

        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        return root
            .deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(safeBranch)")
    }

    /// Creates a worktree at `destination` on a new `branch`.
    ///
    /// Returns the created directory, which is a checkout of the same repository and so will
    /// group with its siblings in the sidebar.
    @discardableResult
    static func create(branch: String, at destination: URL, from project: Project) throws -> URL {
        ThreadingLogger.git.info(
            "Worktree creation started project=\(project.id.uuidString, privacy: .public) branch=\(branch, privacy: .private(mask: .hash)) destination=\(destination.path, privacy: .private(mask: .hash))"
        )
        guard let root = GitInfo.repositoryRoot(for: project.folderPath) else {
            ThreadingLogger.git.notice(
                "Worktree creation refused project=\(project.id.uuidString, privacy: .public) reason=not_repository"
            )
            throw Failure.notARepository
        }

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            ThreadingLogger.git.notice(
                "Worktree creation refused project=\(project.id.uuidString, privacy: .public) reason=destination_exists destination=\(destination.path, privacy: .private(mask: .hash))"
            )
            throw Failure.destinationExists(destination.path)
        }

        // -b creates the branch; without it an existing branch already checked out elsewhere
        // would be refused, which is the common case when reusing a name.
        do {
            try run(
                ["worktree", "add", "-b", branch, destination.path],
                in: root
            )
        } catch {
            ThreadingLogger.git.error(
                "Worktree creation failed project=\(project.id.uuidString, privacy: .public) branch=\(branch, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }

        ThreadingLogger.git.info(
            "Worktree creation completed project=\(project.id.uuidString, privacy: .public) branch=\(branch, privacy: .private(mask: .hash)) destination=\(destination.path, privacy: .private(mask: .hash))"
        )
        return destination
    }

    /// Branch names already present in the repository, for offering existing branches.
    static func branches(in project: Project) -> [String] {
        guard let root = GitInfo.repositoryRoot(for: project.folderPath) else { return [] }
        let output: String
        do {
            output = try run(
                ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
                in: root
            )
        } catch {
            ThreadingLogger.git.warning(
                "Worktree branch listing failed project=\(project.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return []
        }

        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private Methods

    @discardableResult
    fileprivate static func run(_ arguments: [String], in directory: URL) throws -> String {
        do {
            let output = try GitProcess.run(arguments, in: directory)
            return String(decoding: output, as: UTF8.self)
        } catch {
            throw Failure.gitFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

// MARK: - Session-owned Worktrees

/// The complete local-delivery state transition, including the refusal state the coordinator
/// persists. Keeping the error-to-state mapping here lets process-level tests exercise the same
/// boundary as the UI instead of recreating `needsAttention` in a fixture.
enum ManagedWorkspaceLocalFinishOutcome: Equatable {
    case completed(ManagedWorkspace)
    case needsAttention(ManagedWorkspace)
}

/// Creates and finishes the detached worktree behind the composer's explicit opt-in.
///
/// There is intentionally no generated branch in the local-delivery path. The session works on
/// detached commits, Threading fast-forwards the checkout the user selected, and removing the
/// worktree leaves no branch name to remember or garbage-collect.
enum ManagedGitWorkspace {

    enum Failure: LocalizedError {
        case notARepository
        case checkoutIsDetached
        case checkoutIsDirty
        case destinationExists(String)
        case workspaceMissing(String)
        case workspaceIsDirty
        case historyWasRewritten
        case noCommittedChanges
        case publicationNotConfigured
        case publicationNotReady
        case unsupportedChangeRequestRemote
        case publishedRevisionChanged
        case targetBranchChanged(expected: String, actual: String?)
        case targetMoved
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                return L10n.string("This project is not inside a git repository.")
            case .checkoutIsDetached:
                return L10n.string("The selected checkout is detached. Switch it to a branch first.")
            case .checkoutIsDirty:
                return L10n.string("The selected checkout has uncommitted changes. Commit or stash them first.")
            case .destinationExists(let path):
                return L10n.format("The managed workspace already exists: %@", path)
            case .workspaceMissing(let path):
                return L10n.format("The managed workspace is missing: %@", path)
            case .workspaceIsDirty:
                return L10n.string("The agent left uncommitted changes in its managed workspace.")
            case .historyWasRewritten:
                return L10n.string("The managed workspace no longer descends from the commit it started on.")
            case .noCommittedChanges:
                return L10n.string("The managed workspace has no committed changes to publish.")
            case .publicationNotConfigured:
                return L10n.string("This managed workspace was not configured to publish for review.")
            case .publicationNotReady:
                return L10n.string("The managed workspace has no recorded change request to finish.")
            case .unsupportedChangeRequestRemote:
                return L10n.string("Automatic review publishing requires a supported GitHub.com or GitLab.com origin remote.")
            case .publishedRevisionChanged:
                return L10n.string("The managed workspace changed after its review was published.")
            case .targetBranchChanged(let expected, let actual):
                return L10n.format(
                    "The source checkout moved from %@ to %@.",
                    expected,
                    actual ?? L10n.string("a detached commit")
                )
            case .targetMoved:
                return L10n.string("The target branch moved while the session was working. The workspace was kept for review.")
            case .gitFailed(let message):
                return message
            }
        }
    }

    static func canProvision(from project: Project) -> Bool {
        GitInfo.repositoryRoot(for: project.folderPath) != nil
    }

    /// Applies the selected local delivery and turns every validation refusal into the durable
    /// state the session coordinator presents. Publication has its own asynchronous path; this
    /// method owns only the two local outcomes selected in the composer.
    static func finishLocalDelivery(
        _ workspace: ManagedWorkspace
    ) -> ManagedWorkspaceLocalFinishOutcome {
        ThreadingLogger.git.info(
            "Managed workspace local delivery started mode=\(workspace.delivery.rawValue, privacy: .public) workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash))"
        )
        do {
            let completed: ManagedWorkspace
            switch workspace.delivery {
            case .mergeAndCleanUp:
                completed = try integrateAndClean(workspace)
            case .keepForReview:
                completed = keepForReview(workspace)
            }
            ThreadingLogger.git.info(
                "Managed workspace local delivery completed mode=\(workspace.delivery.rawValue, privacy: .public) state=\(completed.state.rawValue, privacy: .public) workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash))"
            )
            return .completed(completed)
        } catch {
            ThreadingLogger.git.error(
                "Managed workspace local delivery failed mode=\(workspace.delivery.rawValue, privacy: .public) workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            var failed = workspace
            failed.state = .needsAttention
            failed.lastError = error.localizedDescription
            return .needsAttention(failed)
        }
    }

    /// Makes the directory before the session is persisted, so a failed setup cannot leave a
    /// sidebar row that points at nowhere.
    static func provision(
        sessionID: SessionID,
        from project: Project,
        plan: ManagedWorkspacePlan,
        rootDirectory: URL? = nil
    ) throws -> ManagedWorkspace {
        ThreadingLogger.git.info(
            "Managed workspace provisioning started session=\(sessionID.uuidString, privacy: .public) mode=\(plan.delivery.rawValue, privacy: .public) publication=\(plan.publication != nil, privacy: .public)"
        )
        guard let sourceRoot = GitInfo.repositoryRoot(for: project.folderPath)?.standardizedFileURL
        else { throw Failure.notARepository }

        guard try isClean(sourceRoot) else { throw Failure.checkoutIsDirty }
        let branch = try symbolicBranch(in: sourceRoot)
        let baseCommit = try run(["rev-parse", "HEAD"], in: sourceRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plan.publication != nil {
            guard let remote = GitInfo.remoteOriginURL(for: sourceRoot.path),
                  ChangeRequestRepository.supported(remote: remote) != nil else {
                throw Failure.unsupportedChangeRequestRemote
            }
        }

        let parent = rootDirectory
            ?? AppDataLocations.supportDirectory.appendingPathComponent(
                "ManagedWorkspaces",
                isDirectory: true
            )
        let worktreeRoot = parent.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: worktreeRoot.path) else {
            throw Failure.destinationExists(worktreeRoot.path)
        }

        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        do {
            try run(["worktree", "add", "--detach", worktreeRoot.path, baseCommit], in: sourceRoot)
            try copyIncludedIgnoredFiles(from: sourceRoot, to: worktreeRoot)
            try run([
                "worktree", "lock", "--reason",
                "Threading managed session \(sessionID.uuidString.lowercased())",
                worktreeRoot.path
            ], in: sourceRoot)
        } catch {
            // This directory did not exist before this call and no agent has run in it. A
            // best-effort ordinary removal is therefore safe; failure leaves Git's own record
            // intact rather than reaching for --force.
            do {
                try run(["worktree", "remove", worktreeRoot.path], in: sourceRoot)
            } catch let cleanupError {
                ThreadingLogger.git.warning(
                    "Managed workspace provisioning cleanup failed session=\(sessionID.uuidString, privacy: .public): \(cleanupError.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            ThreadingLogger.git.error(
                "Managed workspace provisioning failed session=\(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }

        let projectURL = URL(fileURLWithPath: project.folderPath).standardizedFileURL
        let relativeComponents = Array(
            projectURL.pathComponents.dropFirst(sourceRoot.pathComponents.count)
        )
        let execution = relativeComponents.reduce(worktreeRoot) {
            $0.appendingPathComponent($1, isDirectory: true)
        }

        let workspace = ManagedWorkspace(
            repositoryRoot: sourceRoot.path,
            sourceCheckoutPath: sourceRoot.path,
            worktreeRoot: worktreeRoot.path,
            executionPath: execution.path,
            targetBranch: branch,
            baseCommit: baseCommit,
            delivery: plan.delivery,
            publication: plan.publication,
            remoteBranch: plan.publication.map { _ in publicationBranch(for: sessionID) },
            finalCommit: nil,
            changeRequest: nil,
            remoteBranchState: nil,
            state: .active,
            lastError: nil
        )
        ThreadingLogger.git.info(
            "Managed workspace provisioning completed session=\(sessionID.uuidString, privacy: .public) mode=\(plan.delivery.rawValue, privacy: .public) publication=\(plan.publication != nil, privacy: .public)"
        )
        return workspace
    }

    /// Validates the agent's handoff, fast-forwards the original checkout, and removes exactly
    /// the detached worktree Threading owns. Every refusal occurs before removal.
    static func integrateAndClean(_ workspace: ManagedWorkspace) throws -> ManagedWorkspace {
        let source = URL(fileURLWithPath: workspace.sourceCheckoutPath, isDirectory: true)
        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            if workspace.state == .integrated { return workspace }
            throw Failure.workspaceMissing(worktree.path)
        }
        guard try isClean(worktree) else { throw Failure.workspaceIsDirty }
        guard try isClean(source) else { throw Failure.checkoutIsDirty }

        let actualBranch = try? symbolicBranch(in: source)
        guard actualBranch == workspace.targetBranch else {
            throw Failure.targetBranchChanged(
                expected: workspace.targetBranch,
                actual: actualBranch
            )
        }

        let finalCommit = try run(["rev-parse", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard succeeds(
            ["merge-base", "--is-ancestor", workspace.baseCommit, finalCommit],
            in: source
        ) else { throw Failure.historyWasRewritten }

        let sourceCommit = try run(["rev-parse", "HEAD"], in: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceCommit == workspace.baseCommit {
            if finalCommit != workspace.baseCommit {
                try run(["merge", "--ff-only", finalCommit], in: source)
            }
        } else if !succeeds(["merge-base", "--is-ancestor", finalCommit, sourceCommit], in: source) {
            throw Failure.targetMoved
        }

        // Unlock is tolerant for a retry after a previous cleanup failure: the merge is
        // idempotent, and an already-unlocked worktree is still exactly this recorded path.
        _ = try? run(["worktree", "unlock", worktree.path], in: source)
        try run(["worktree", "remove", worktree.path], in: source)

        var completed = workspace
        completed.baseCommit = finalCommit
        completed.finalCommit = finalCommit
        completed.state = .integrated
        completed.lastError = nil
        return completed
    }

    /// The immutable local facts needed by the network publication step. Unlike local delivery,
    /// this does not inspect or constrain the source checkout: publishing must not mutate it,
    /// and a person continuing work there is independent of the isolated review branch.
    static func publicationSnapshot(
        for workspace: ManagedWorkspace
    ) throws -> ManagedWorkspacePublicationSnapshot {
        guard workspace.publication != nil, let branch = workspace.remoteBranch else {
            throw Failure.publicationNotConfigured
        }
        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            throw Failure.workspaceMissing(worktree.path)
        }
        guard try isClean(worktree) else { throw Failure.workspaceIsDirty }

        let finalCommit = try run(["rev-parse", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalCommit != workspace.baseCommit else { throw Failure.noCommittedChanges }
        guard succeeds(
            ["merge-base", "--is-ancestor", workspace.baseCommit, finalCommit],
            in: worktree
        ) else { throw Failure.historyWasRewritten }
        guard let remote = GitInfo.remoteOriginURL(for: workspace.repositoryRoot),
              let repository = ChangeRequestRepository.supported(remote: remote) else {
            throw Failure.unsupportedChangeRequestRemote
        }

        return ManagedWorkspacePublicationSnapshot(
            root: worktree,
            repository: repository,
            finalCommit: finalCommit,
            remote: "origin",
            branch: branch
        )
    }

    /// Removes a worktree only after its change-request receipt and exact published revision
    /// have been persisted. The operation is retry-safe across the narrow remove/persist crash
    /// window: a missing checkout with both receipts already recorded is considered disposed.
    static func cleanPublished(_ workspace: ManagedWorkspace) throws -> ManagedWorkspace {
        guard let finalCommit = workspace.finalCommit,
              workspace.changeRequest != nil else { throw Failure.publicationNotReady }

        let source = URL(fileURLWithPath: workspace.repositoryRoot, isDirectory: true)
        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            var completed = workspace
            completed.state = .published
            completed.lastError = nil
            return completed
        }
        guard try isClean(worktree) else { throw Failure.workspaceIsDirty }
        let currentCommit = try run(["rev-parse", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentCommit == finalCommit else { throw Failure.publishedRevisionChanged }
        guard succeeds(
            ["merge-base", "--is-ancestor", workspace.baseCommit, finalCommit],
            in: worktree
        ) else { throw Failure.historyWasRewritten }

        _ = try? run(["worktree", "unlock", worktree.path], in: source)
        try run(["worktree", "remove", worktree.path], in: source)

        var completed = workspace
        completed.state = .published
        completed.lastError = nil
        return completed
    }

    /// Removes a checkout after provisioning succeeded but the session record could not be
    /// created. No agent has received this path, so only the exact untouched base commit is
    /// disposable; unlike delivery, a simultaneous branch switch or dirty source checkout is
    /// irrelevant and must not strand an otherwise empty registration.
    static func discardUnstarted(_ workspace: ManagedWorkspace) throws {
        let source = URL(fileURLWithPath: workspace.repositoryRoot, isDirectory: true)
        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: worktree.path) else { return }
        guard try isClean(worktree) else { throw Failure.workspaceIsDirty }

        let finalCommit = try run(["rev-parse", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalCommit == workspace.baseCommit else { throw Failure.historyWasRewritten }

        _ = try? run(["worktree", "unlock", worktree.path], in: source)
        try run(["worktree", "remove", worktree.path], in: source)
    }

    static func keepForReview(_ workspace: ManagedWorkspace) -> ManagedWorkspace {
        var kept = workspace
        kept.state = .kept
        kept.lastError = nil
        return kept
    }

    /// Recreates the stable cwd behind Archive's Undo after a successfully integrated workspace
    /// was removed. Provider transcript lookup hashes this path, so a different temporary path
    /// would make the same conversation look unrelated.
    static func restore(_ workspace: ManagedWorkspace) throws -> ManagedWorkspace {
        ThreadingLogger.git.info(
            "Managed workspace restore started state=\(workspace.state.rawValue, privacy: .public) workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash))"
        )
        let source = URL(fileURLWithPath: workspace.sourceCheckoutPath, isDirectory: true)
        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        if FileManager.default.fileExists(atPath: worktree.path) {
            var active = workspace
            active.state = .active
            active.lastError = nil
            return active
        }

        let targetCommit: String
        if workspace.state == .published, let publishedCommit = workspace.finalCommit {
            targetCommit = publishedCommit
        } else {
            targetCommit = try run(["rev-parse", workspace.targetBranch], in: source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try run(["worktree", "add", "--detach", worktree.path, targetCommit], in: source)
            try run([
                "worktree", "lock", "--reason", "Threading restored managed session",
                worktree.path
            ], in: source)
        } catch {
            // Restore has not relaunched the agent yet, so this newly created checkout still has
            // no user work to protect. Leave no half-restored registration when locking fails.
            do {
                try run(["worktree", "remove", worktree.path], in: source)
            } catch let cleanupError {
                ThreadingLogger.git.warning(
                    "Managed workspace restore cleanup failed workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash)): \(cleanupError.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            ThreadingLogger.git.error(
                "Managed workspace restore failed workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }

        var active = workspace
        if workspace.state != .published {
            active.baseCommit = targetCommit
        }
        active.state = .active
        active.lastError = nil
        ThreadingLogger.git.info(
            "Managed workspace restore completed previous_state=\(workspace.state.rawValue, privacy: .public) workspace=\(workspace.worktreeRoot, privacy: .private(mask: .hash))"
        )
        return active
    }

    private static func symbolicBranch(in directory: URL) throws -> String {
        let branch = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw Failure.checkoutIsDetached }
        return branch
    }

    static func publicationBranch(for sessionID: SessionID) -> String {
        "threading/\(sessionID.uuidString.lowercased())"
    }

    private static func isClean(_ directory: URL) throws -> Bool {
        try run(["status", "--porcelain=v1", "--untracked-files=all"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// `.worktreeinclude` is the opt-in setup contract shared with other worktree tools: it can
    /// name ignored local configuration that should be copied into a fresh checkout. Tracked
    /// files and symlinks are refused, and existing destinations are never overwritten.
    private static func copyIncludedIgnoredFiles(from source: URL, to destination: URL) throws {
        let include = source.appendingPathComponent(".worktreeinclude")
        guard FileManager.default.fileExists(atPath: include.path) else { return }

        let resolvedSource = source.resolvingSymlinksInPath()
        let resolvedDestination = destination.resolvingSymlinksInPath()

        let output = try run([
            "ls-files", "--others", "--ignored", "--exclude-from=.worktreeinclude", "-z"
        ], in: source)
        for relative in output.split(separator: "\0").map(String.init) where !relative.isEmpty {
            guard succeeds(["check-ignore", "--quiet", "--", relative], in: source) else { continue }
            let sourceFile = source
                .appendingPathComponent(relative)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let destinationFile = destination.appendingPathComponent(relative).standardizedFileURL
            let destinationParent = destinationFile
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
            guard sourceFile.path.hasPrefix(resolvedSource.path + "/"),
                  destinationFile.path.hasPrefix(destination.path + "/"),
                  destinationParent.path == resolvedDestination.path
                    || destinationParent.path.hasPrefix(resolvedDestination.path + "/"),
                  !FileManager.default.fileExists(atPath: destinationFile.path)
            else { continue }

            let values = try sourceFile.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
        }
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) throws -> String {
        do {
            return try GitWorktree.run(arguments, in: directory)
        } catch {
            throw Failure.gitFailed(error.localizedDescription)
        }
    }

    private static func succeeds(_ arguments: [String], in directory: URL) -> Bool {
        (try? GitWorktree.run(arguments, in: directory)) != nil
    }
}

/// A managed checkout can finish itself only when the selected runtime surface receives
/// Threading's private MCP bridge and the lifecycle tools are enabled. Keeping this beside the
/// repository lifecycle makes the composer, immediate starts and unattended starts ask the same
/// question instead of treating a visible checkbox as sufficient authorization.
@MainActor
enum ManagedWorkspaceEligibility {
    static func supportsFinishHandshake(kind: AgentKind, usesNativeUI: Bool) -> Bool {
        let supportsBridge = usesNativeUI
            ? kind.supports(.threadingBridge)
            : kind.supports(.terminalThreadingBridge)
        return supportsBridge && MCPToolCatalog.isEnabled(MCPToolCatalog.session)
    }

    static func supportsPublication(from project: Project) -> Bool {
        guard let remote = GitInfo.remoteOriginURL(for: project.folderPath) else { return false }
        return ChangeRequestRepository.supported(remote: remote) != nil
    }
}

/// The contract appended to the opening brief only for opted-in sessions. The agent owns the
/// implementation work; Threading owns repository integration and disposal after the final turn.
enum ManagedWorkspaceInstructions {
    static func append(to opening: String?, plan: ManagedWorkspacePlan) -> String? {
        guard let opening, !opening.isEmpty else { return opening }
        let finish: String
        if let publication = plan.publication {
            let readiness = publication == .draft ? "draft" : "ready-for-review"
            finish = "Threading will publish an opaque generated remote branch, open a \(readiness) change request against the branch this session started from, and remove this local worktree."
        } else {
            switch plan.delivery {
            case .mergeAndCleanUp:
                finish = "Threading will fast-forward the selected checkout and remove this worktree."
            case .keepForReview:
                finish = "Threading will keep this worktree for review instead of merging it."
            }
        }
        return opening + "\n\n" + """
            This session is running in a Threading-managed isolated worktree. Work only in this \
            checkout. Commit every intended non-ignored change and run the relevant checks. Do \
            not merge, push, create a branch, or remove the worktree yourself. When the task is \
            genuinely complete, call archive_session during your final reply; \(finish) If the \
            task is incomplete or blocked, do not call it.
            """
    }
}

// MARK: - Managed remote publication

struct ManagedWorkspacePublicationSnapshot: Sendable {
    let root: URL
    let repository: ChangeRequestRepository
    let finalCommit: String
    let remote: String
    let branch: String
}

struct ManagedWorkspacePublicationResult: Sendable {
    let finalCommit: String
    let changeRequest: ManagedWorkspaceChangeRequest
    let wasCreated: Bool
    let credentialSource: ChangeRequestCredentialSource?
}

/// Turns an explicitly opted-in managed commit into a review without ever creating a local
/// branch. Forge API work is routed through the provider boundary while local refs remain here.
struct ManagedWorkspacePublisher: Sendable {
    enum Failure: LocalizedError {
        case automaticCredentialRequired(String)
        case discoveryFailed(String)
        case interactiveFallback(String)
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .automaticCredentialRequired(let message):
                return message
            case .discoveryFailed(let message),
                 .interactiveFallback(let message),
                 .creationFailed(let message):
                return message
            }
        }
    }

    private let providers: ChangeRequestProviderRegistry

    init(providers: ChangeRequestProviderRegistry) {
        self.providers = providers
    }

    @MainActor
    static func live() -> ManagedWorkspacePublisher {
        ManagedWorkspacePublisher(providers: .live())
    }

    func publish(_ workspace: ManagedWorkspace) async throws -> ManagedWorkspacePublicationResult {
        let snapshot = try ManagedGitWorkspace.publicationSnapshot(for: workspace)
        switch await providers.automaticCreationReadiness(repository: snapshot.repository) {
        case .ready:
            break
        case .unavailable(let message):
            throw Failure.automaticCredentialRequired(message)
        }
        let seed = try await ChangeRequestGit.proposalSeed(
            in: snapshot.root,
            baseRevision: workspace.baseCommit,
            provider: snapshot.repository.provider
        )

        try await ChangeRequestGit.pushDetached(
            commit: snapshot.finalCommit,
            to: snapshot.branch,
            remote: snapshot.remote,
            in: snapshot.root
        )

        let discovered = await providers.discover(
            repository: snapshot.repository,
            branch: snapshot.branch,
            headRevision: snapshot.finalCommit
        )
        let summary: ChangeRequestSummary
        let wasCreated: Bool
        let credentialSource: ChangeRequestCredentialSource?
        switch discovered {
        case .failed(let message):
            throw Failure.discoveryFailed(message)

        case .loaded(let status):
            if let existing = status.changeRequest {
                summary = existing
                wasCreated = false
                credentialSource = nil
            } else {
                guard let publication = workspace.publication else {
                    throw ManagedGitWorkspace.Failure.publicationNotConfigured
                }
                let outcome = await providers.create(
                    repository: snapshot.repository,
                    proposal: ChangeRequestProposal(
                        title: seed.title,
                        body: seed.body,
                        baseBranch: workspace.targetBranch,
                        headBranch: snapshot.branch,
                        isDraft: publication == .draft
                    )
                )
                switch outcome {
                case .created(let created, let credential):
                    summary = created
                    wasCreated = true
                    credentialSource = credential
                case .webForm(_, let message):
                    // A final-turn automation has nobody present to complete a browser form.
                    // Preserve the pushed branch and local worktree for an explicit retry.
                    throw Failure.interactiveFallback(message)
                case .failed(let message):
                    throw Failure.creationFailed(message)
                }
            }
        }

        return ManagedWorkspacePublicationResult(
            finalCommit: snapshot.finalCommit,
            changeRequest: ManagedWorkspaceChangeRequest(
                provider: snapshot.repository.provider.rawValue,
                repository: snapshot.repository.slug,
                remote: snapshot.remote,
                branch: snapshot.branch,
                number: summary.number,
                url: summary.url,
                isDraft: summary.isDraft
            ),
            wasCreated: wasCreated,
            credentialSource: credentialSource
        )
    }
}
