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

    // MARK: - Suggesting

    /// Checks paths an agent nominated, and files the ones that pass into the listing.
    ///
    /// **This is how something becomes proposable, not a way around the gate that guards
    /// deletion.** `StorageCleanupGate` still refuses any path outside the findings; what this
    /// changes is that a directory can enter the findings on demand instead of only when the
    /// passive walk happens to reach it. The scan runs on a timer over roots it already knows,
    /// which is the right economy for a chore nobody is waiting on and the wrong one for an agent
    /// that has just failed a write.
    ///
    /// Every path goes through `ArtifactScanner.vet`, which runs the same three gates a walk
    /// runs. Nothing is taken on the agent's word — the `reason` is recorded for the user to
    /// read, never treated as evidence — and a refusal names the gate that said no, because an
    /// agent told *which* proof was missing can often supply it.
    func suggestReclaimableLocation(
        _ arguments: SuggestReclaimableLocationArguments
    ) -> MCPToolResult {
        let paths = (arguments.paths ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else { return .failure(StorageToolStrings.noPaths) }

        // One census for the whole call, on the main actor, the way the scan and the cleanup
        // take theirs — so a session that ends mid-call cannot make two paths disagree.
        let dormantSessionIDs = DormantSessionCensus.dormant()

        var accepted = 0
        var refused = 0
        var lines: [String] = []

        for path in Set(paths).sorted() {
            switch ArtifactScanner.vet(
                URL(fileURLWithPath: path),
                dormantSessionIDs: dormantSessionIDs
            ) {
            case .vetted(let artifact):
                guard ArtifactScanService.shared.adopt(artifact) else {
                    refused += 1
                    lines.append(StorageToolStrings.vetOutOfScope(path))
                    continue
                }
                accepted += 1
                lines.append(StorageToolStrings.vetAccepted(
                    path,
                    kind: artifact.kind.displayName,
                    size: Self.storageSize.string(fromByteCount: artifact.byteCount)
                ))

            case .refused(let refusal):
                refused += 1
                lines.append(Self.describe(refusal, at: path))
            }
        }

        return .success(
            StorageToolStrings.vetSummary(accepted: accepted, refused: refused)
            + "\n" + lines.joined(separator: "\n")
            + "\n\n" + StorageToolStrings.vetFooter
        )
    }

    private static func describe(
        _ refusal: ArtifactScanner.VetRefusal,
        at path: String
    ) -> String {
        switch refusal {
        case .missing:
            return StorageToolStrings.vetMissing(path)
        case .sessionNotDormant:
            return StorageToolStrings.vetSessionNotDormant(path)
        case .notIgnoredByGit(let kind):
            return StorageToolStrings.vetNotIgnoredByGit(path, kind: kind.displayName)
        case .unrecognised:
            return StorageToolStrings.vetUnrecognised(path)
        }
    }

    // MARK: - Proposing

    /// Puts an agent's proposal to the user, and removes what they approve.
    ///
    /// Answers only once the user has decided, so the agent's next turn knows the outcome
    /// rather than guessing at it. The sheet is presented on the window rather than run modally,
    /// so the app stays usable — including the session that asked.
    ///
    /// **It does not necessarily ask.** Everything between the gate and the sheet goes through
    /// `StorageCleanupLedger`, because the disk is one disk: when it fills, every session hits
    /// ENOSPC in the same minute and reads the same listing, and the user was being asked the
    /// same question once per agent. A path already on screen, already removed on their word, or
    /// already declined is answered from what they decided rather than put to them again.
    func proposeStorageCleanup(
        _ arguments: StorageCleanupArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        // Both scopes, one vetted list. The gate's rule does not change with the scope — a
        // proposal may only name a path already in the findings — so widening what the listing
        // covers widens what can be proposed, and nothing else.
        let projects = ProjectStore.shared.projects
        let byProject = projects.map {
            (project: $0, artifacts: ArtifactScanService.shared.artifacts(for: $0.id))
        }
        let scratch = ArtifactScanService.shared.scratchArtifacts()

        let resolution = StorageCleanupGate.resolve(
            arguments.paths,
            against: byProject.flatMap(\.artifacts) + scratch
        )

        guard !resolution.isEmptyRequest else {
            completion(.failure(StorageToolStrings.noPaths))
            return
        }

        // Which checkout each finding belongs to, captured now. A batch can be presented after
        // the sheet in front of it deleted something, and asking the caches again at that point
        // would group this proposal by what is left rather than by what was proposed.
        var owners: [String: Project] = [:]
        for entry in byProject {
            for artifact in entry.artifacts { owners[artifact.url.path] = entry.project }
        }

        StorageCleanupLedger.shared.submit(
            resolution,
            reason: arguments.reason,
            asker: ProjectStore.shared.session(withID: sessionID)?.displayTitle,
            present: { [weak self] batch, respond in
                guard let window = self?.presentationWindow else {
                    respond(.unavailable(StorageToolStrings.noWindow))
                    return
                }
                StorageCleanupProposalSheet.present(
                    batch,
                    in: window,
                    owners: owners,
                    among: projects,
                    respond: respond
                )
            },
            completion: { answer in
                completion(StorageToolStrings.result(of: answer))
            }
        )
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
