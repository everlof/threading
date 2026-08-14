import AppKit

// MARK: - Storage Tools

/// The storage tools an agent can reach: read what can be reclaimed, and *propose* removing
/// some of it.
///
/// The split is the whole design. An agent that notices the disk is nearly full is well placed
/// to say which 30 GB is worth losing and what rebuilding it costs — and badly placed to be
/// trusted with `rm -rf` on the strength of that judgement. So it reads and proposes; the user
/// decides; Threading deletes.
///
/// **A proposal can only name paths the scanner already found.** Anything else is refused
/// outright, which is what stops the tool from being an arbitrary-delete primitive dressed as a
/// cleanup. Everything in that listing has passed the gates `ArtifactScanner` applies to where
/// it was found — inside a project, git ignores it and a known command rebuilds it; outside one,
/// the tool that wrote it says so in its own manifest — and the gates are checked again at the
/// moment of deletion.
///
/// **The listing has two scopes and one shape.** The scratch scope — the temporary locations
/// agents build in — produces lines beside the projects' rather than a second tool, because the
/// ENOSPC path already points here: an agent that has just failed a write should get one answer
/// covering both, with the same proposal sheet and the same user decision behind it.
extension AgentToolCoordinator {

    // MARK: - Listing

    /// What can be reclaimed, from the cache the scan service keeps.
    ///
    /// Deliberately does not scan: a walk takes a minute, and an agent asking about disk space
    /// wants an answer now. A reading with nothing in it says so rather than pretending the
    /// disk is clean.
    func listReclaimableStorage() -> MCPToolResult {
        let projects = ProjectStore.shared.projects
        let service = ArtifactScanService.shared

        let byProject = projects.map { ($0, service.artifacts(for: $0.id)) }
        let scratch = service.scratchArtifacts()

        let lines = byProject.flatMap { project, artifacts in
            artifacts.map { describe($0, in: project) }
        } + scratch.map { Self.describeScratch($0) }

        guard !lines.isEmpty else {
            // Sweeps the scratch scope too, so the nudge covers everything the answer did.
            ArtifactScanService.shared.refreshStaleProjects()
            return .success(
                service.isScanning
                    ? StorageToolStrings.scanning
                    : StorageToolStrings.nothingFound
            )
        }

        let total = (byProject.flatMap { $0.1 } + scratch)
            .reduce(0) { $0 + $1.byteCount }

        // The oldest reading on show, across both scopes: a header claiming the freshness of the
        // project scan would be claiming it for scratch lines that can be an hour staler.
        let measured = [service.oldestScan(among: projects.map(\.id)), service.scratchScannedAt()]
            .compactMap { $0 }
            .min()
            .map { StorageToolStrings.measured(Self.storageRelativeDate.localizedString(for: $0, relativeTo: Date())) }
            ?? ""

        return .success(
            StorageToolStrings.header(
                total: Self.storageSize.string(fromByteCount: total),
                count: lines.count,
                measured: measured
            )
            + "\n" + lines.joined(separator: "\n")
            + "\n\n" + StorageToolStrings.listingFooter
        )
    }

    /// One line per directory, carrying everything a proposal needs to be a good one: the exact
    /// path to quote back, its size, which checkout it belongs to, what rebuilds it, and how
    /// long since anything wrote there.
    private func describe(_ artifact: ReclaimableArtifact, in project: Project) -> String {
        var parts = [
            artifact.url.path,
            Self.storageSize.string(fromByteCount: artifact.byteCount),
            "\(project.name)/\(GitInfo.worktreeName(for: artifact.checkoutPath) ?? StorageToolStrings.mainCheckout)",
            artifact.kind.displayName,
            StorageToolStrings.rebuild(artifact.kind.rebuildHint)
        ]

        parts.append(contentsOf: Self.age(of: artifact, at: Date()))

        return parts.joined(separator: " · ")
    }

    /// One line for a finding in a scratch location, which belongs to no checkout.
    ///
    /// Deliberately **not** `describe(_:in:)`. That one names the checkout through
    /// `GitInfo.worktreeName`, which starts a git process; a scratch tree has no repository to
    /// ask, and that absence is the whole reason the manifest gate exists. So this does pure
    /// path and stat work, and the listing does not pay a subprocess per scratch finding to
    /// learn nothing.
    ///
    /// **Whether the workspace still exists is answered here, not at scan time**, because it
    /// changes in between: a `/tmp` workspace is deleted by the session that made it, and a
    /// restored one stops being an orphan. An orphaned cache is marked in the line rather than
    /// merely described, because it is the safest thing this listing ever offers — nothing can
    /// rebuild into it and nothing will read it again — and an agent putting a proposal together
    /// should be able to lead with those.
    static func describeScratch(
        _ artifact: ReclaimableArtifact,
        at now: Date = Date(),
        workspaceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var parts = [
            artifact.url.path,
            storageSize.string(fromByteCount: artifact.byteCount)
        ]

        if let workspace = artifact.workspacePath {
            parts.append(
                workspaceExists(workspace)
                    ? StorageToolStrings.builtFor(workspace)
                    : StorageToolStrings.orphaned(workspace)
            )
        }

        parts.append(artifact.kind.displayName)
        parts.append(StorageToolStrings.rebuild(artifact.kind.rebuildHint))
        parts.append(contentsOf: age(of: artifact, at: now))

        return parts.joined(separator: " · ")
    }

    /// The tail both line shapes end with: how long since anything wrote there, and whether that
    /// is recent enough to mean a build is running in it right now. Empty when the scan recorded
    /// no modification date, since a missing age is not an age of zero.
    private static func age(of artifact: ReclaimableArtifact, at now: Date) -> [String] {
        guard let modifiedAt = artifact.modifiedAt else { return [] }

        let age = storageRelativeDate.localizedString(for: modifiedAt, relativeTo: now)
        return [artifact.isInUse(at: now) ? StorageToolStrings.inUse(age) : StorageToolStrings.lastWritten(age)]
    }

    // MARK: - Proposing

    /// Puts an agent's proposal to the user, and removes what they approve.
    ///
    /// Answers only once the user has decided, so the agent's next turn knows the outcome
    /// rather than guessing at it. The sheet is presented on the window rather than run modally,
    /// so the app stays usable — including the session that asked.
    func proposeStorageCleanup(
        _ arguments: StorageCleanupArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        // Both scopes, one vetted list. The gate's rule does not change with the scope — a
        // proposal may only name a path already in the findings — so widening what the listing
        // covers widens what can be proposed, and nothing else.
        let vetted = ProjectStore.shared.projects.flatMap {
            ArtifactScanService.shared.artifacts(for: $0.id)
        } + ArtifactScanService.shared.scratchArtifacts()

        let resolution = StorageCleanupGate.resolve(arguments.paths, against: vetted)

        guard !resolution.isEmptyRequest else {
            completion(.failure(StorageToolStrings.noPaths))
            return
        }

        guard !resolution.matched.isEmpty else {
            completion(.failure(StorageToolStrings.unknownPaths(resolution.unknown)))
            return
        }

        presentCleanupProposal(
            resolution.matched,
            reason: arguments.reason,
            unknown: resolution.unknown,
            completion: completion
        )
    }

    private func presentCleanupProposal(
        _ artifacts: [ReclaimableArtifact],
        reason: String?,
        unknown: [String],
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }

        var body: [String] = []
        if let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            body.append(reason)
        }
        body.append(artifacts.map { "• \($0.url.path)  —  \(Self.storageSize.string(fromByteCount: $0.byteCount))" }
            .joined(separator: "\n"))
        if artifacts.contains(where: { $0.isInUse() }) {
            body.append(StorageToolStrings.proposalInUse)
        }
        body.append(StorageToolStrings.proposalFooter)

        let request = ConfirmationRequest(
            prompt: .approveAgentStorageCleanup,
            title: StorageToolStrings.proposalTitle(
                count: artifacts.count,
                size: Self.storageSize.string(fromByteCount: bytes)
            ),
            message: body.joined(separator: "\n\n"),
            confirmTitle: StorageToolStrings.approve,
            cancelTitle: StorageToolStrings.decline
        )

        guard let window = presentationWindow else {
            completion(.failure(StorageToolStrings.noWindow))
            return
        }

        ConfirmationAlert.ask(request, in: window) { approved in
            guard approved else {
                completion(.success(StorageToolStrings.declined))
                return
            }

            Task { @MainActor in
                let removed = await Task.detached(priority: .userInitiated) {
                    artifacts.filter { ArtifactScanner.remove($0) }
                }.value
                let reclaimed = removed.reduce(0) { $0 + $1.byteCount }

                for project in ProjectStore.shared.projects {
                    ArtifactScanService.shared.forget(removed, in: project.id)
                }
                // The scratch reading keeps its own cache, and re-walking `/private/tmp` to learn
                // what this delete just did to it would be the most expensive way to find out.
                ArtifactScanService.shared.forgetScratch(removed)

                ThreadingLogger.agent.info(
                    "Agent cleanup approved: removed \(removed.count, privacy: .public) directories"
                )

                completion(.success(StorageToolStrings.approved(
                    count: removed.count,
                    size: Self.storageSize.string(fromByteCount: reclaimed),
                    refused: artifacts.count - removed.count,
                    unknown: unknown
                )))
            }
        }
    }

    // MARK: - Formatters

    private static let storageSize: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let storageRelativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Storage Tool Strings

enum StorageToolStrings {
    static let mainCheckout = "main checkout"

    static let scanning = """
        Threading is still measuring build output, in the user's projects and in the temporary \
        locations agents build in. Ask again shortly.
        """

    /// Names both scopes, because the answer covers both: "nothing in your projects" would be a
    /// narrower claim than the one that was actually checked.
    static let nothingFound = """
        No reclaimable build output was found, either in the user's projects or in the temporary \
        locations agents build in.
        """

    /// The two gates, stated as the alternatives they are. A finding inside a project is offered
    /// because git ignores it; one in a temporary location has no repository to ask, and is
    /// offered because Xcode's own manifest says what wrote it. Claiming git for both would be
    /// false about every scratch line.
    static let listingFooter = """
        Everything above is either ignored by git or identified as a build cache by Xcode's own \
        manifest, and is rebuildable by the command shown. To act on any of it, call \
        propose_storage_cleanup with the exact paths — that asks the user, who decides. Nothing \
        is removed without their approval.
        """

    static let noPaths = "No paths were given. Pass one absolute path per line in `paths`."
    static let noWindow = "There is no window to ask the user in."
    static let declined = "The user declined. Nothing was removed."

    static let approve = "Remove"
    static let decline = "Keep"

    static let proposalInUse = """
        One of these was written in the last few minutes, so a build may be running in it right \
        now.
        """

    static let proposalFooter = """
        Each is rebuilt by its own tool the next time it is needed. They are deleted \
        immediately rather than moved to the Trash.
        """

    static func measured(_ relative: String) -> String {
        " · measured \(relative)"
    }

    static func inUse(_ relative: String) -> String {
        "IN USE — written \(relative)"
    }

    static func lastWritten(_ relative: String) -> String {
        "last written \(relative)"
    }

    static func rebuild(_ hint: String) -> String {
        "rebuild: \(hint)"
    }

    /// The tree a scratch finding's own tool declared it was built for. Its path says nothing
    /// about which checkout fed it; two caches in one temporary directory can belong to two
    /// checkouts of the same project.
    static func builtFor(_ workspace: String) -> String {
        "built for \(workspace)"
    }

    /// The same when that tree is gone, marked in the shape `inUse(_:)` uses so the two states
    /// that change what a line is worth read alike. This is the tier to propose first: nothing
    /// can rebuild into it and nothing will ever read it again.
    static func orphaned(_ workspace: String) -> String {
        "ORPHANED — built for \(workspace), which no longer exists"
    }

    static func header(total: String, count: Int, measured: String) -> String {
        "\(total) reclaimable across \(count) directories\(measured):"
    }

    static func unknownPaths(_ paths: [String]) -> String {
        """
        None of these paths are in the current listing, so none can be proposed: \
        \(paths.joined(separator: ", ")). Call list_reclaimable_storage and quote its paths \
        exactly. Only build output Threading has already vetted can be proposed.
        """
    }

    static func proposalTitle(count: Int, size: String) -> String {
        count == 1
            ? "An agent suggests removing a build directory to reclaim \(size)."
            : "An agent suggests removing \(count) build directories to reclaim \(size)."
    }

    static func approved(count: Int, size: String, refused: Int, unknown: [String]) -> String {
        var text = "The user approved. Removed \(count) directories, reclaiming \(size)."
        if refused > 0 {
            text += " \(refused) were left alone: they no longer looked safe to remove when checked again."
        }
        if !unknown.isEmpty {
            text += " Not in the listing and therefore ignored: \(unknown.joined(separator: ", "))."
        }
        return text
    }
}
