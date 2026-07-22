import AppKit

// MARK: - Storage Tools

/// The storage tools an agent can reach: read what can be reclaimed, and *propose* removing
/// some of it.
///
/// The split is the whole design. An agent that notices the disk is nearly full is well placed
/// to say which 30 GB is worth losing and what rebuilding it costs — and badly placed to be
/// trusted with `rm -rf` on the strength of that judgement. So it reads and proposes; the user
/// decides; Skalman deletes.
///
/// **A proposal can only name paths the scanner already found.** Anything else is refused
/// outright, which is what stops the tool from being an arbitrary-delete primitive dressed as a
/// cleanup. Everything in that listing has passed both of `ArtifactScanner`'s gates — git
/// ignores it, and a known command rebuilds it — and the gates are checked again at the moment
/// of deletion.
extension MainWindowController {

    // MARK: - Listing

    /// What can be reclaimed, from the cache the scan service keeps.
    ///
    /// Deliberately does not scan: a walk takes a minute, and an agent asking about disk space
    /// wants an answer now. A reading with nothing in it says so rather than pretending the
    /// disk is clean.
    func listReclaimableStorage() -> MCPToolResult {
        let projects = ProjectStore.shared.projects
        let service = ArtifactScanService.shared

        let lines = projects.flatMap { project in
            service.artifacts(for: project.id).map { artifact in
                describe(artifact, in: project)
            }
        }

        guard !lines.isEmpty else {
            ArtifactScanService.shared.refreshStaleProjects()
            return .success(
                service.isScanning
                    ? StorageToolStrings.scanning
                    : StorageToolStrings.nothingFound
            )
        }

        let total = projects
            .flatMap { service.artifacts(for: $0.id) }
            .reduce(0) { $0 + $1.byteCount }

        let measured = service.oldestScan(among: projects.map(\.id))
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
            "rebuild: \(artifact.kind.rebuildHint)"
        ]

        if let modifiedAt = artifact.modifiedAt {
            let age = Self.storageRelativeDate.localizedString(for: modifiedAt, relativeTo: Date())
            parts.append(artifact.isInUse() ? StorageToolStrings.inUse(age) : "last written \(age)")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Pressure

    /// Told to the agent at `initialize`, and **only when the disk is actually short**.
    ///
    /// Advertising a cleanup tool is not the same as making it useful. An agent has no way to
    /// notice a full disk until something fails on it, so a capability it might want is close
    /// to useless — what it lacks is the fact. This supplies exactly that fact, at the one
    /// moment it changes what a reasonable agent would do, and says nothing at all otherwise:
    /// the same "quiet until relevant" rule the rest of the app's surfaces follow.
    ///
    /// Silent too when the tools are switched off, since describing a capability a session
    /// cannot reach only invites it to try.
    func storagePressure() -> String {
        guard MCPToolCatalog.isEnabled(MCPToolCatalog.storage),
              let reading = DiskSpace.homeReading(),
              reading.isUnderPressure else { return "" }

        let reclaimable = ProjectStore.shared.projects
            .flatMap { ArtifactScanService.shared.artifacts(for: $0.id) }
            .reduce(0) { $0 + $1.byteCount }

        let free = Self.storageSize.string(fromByteCount: reading.available)
        let capacity = Self.storageSize.string(fromByteCount: reading.capacity)

        guard reclaimable > 0 else {
            return StorageToolStrings.pressureOnly(free: free, capacity: capacity)
        }

        return StorageToolStrings.pressureWithReclaimable(
            free: free,
            capacity: capacity,
            reclaimable: Self.storageSize.string(fromByteCount: reclaimable)
        )
    }

    // MARK: - Proposing

    /// Puts an agent's proposal to the user, and removes what they approve.
    ///
    /// Answers only once the user has decided, so the agent's next turn knows the outcome
    /// rather than guessing at it. The sheet is presented on the window rather than run modally,
    /// so the app stays usable — including the session that asked.
    func proposeStorageCleanup(
        _ arguments: StorageCleanupArguments,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        let requested = (arguments.paths ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !requested.isEmpty else {
            completion(.failure(StorageToolStrings.noPaths))
            return
        }

        // The gate that keeps this from being an arbitrary delete: a path is only actionable if
        // the scanner already vetted it. An unknown path is refused by name, so the agent can
        // tell a typo from a rejection.
        let known = Dictionary(
            uniqueKeysWithValues: ProjectStore.shared.projects
                .flatMap { project in
                    ArtifactScanService.shared.artifacts(for: project.id).map {
                        ($0.url.path, (artifact: $0, project: project))
                    }
                }
        )

        let matched = requested.compactMap { known[$0] }
        let unknown = requested.filter { known[$0] == nil }

        guard !matched.isEmpty else {
            completion(.failure(StorageToolStrings.unknownPaths(unknown)))
            return
        }

        presentCleanupProposal(
            matched.map(\.artifact),
            reason: arguments.reason,
            unknown: unknown,
            completion: completion
        )
    }

    private func presentCleanupProposal(
        _ artifacts: [ReclaimableArtifact],
        reason: String?,
        unknown: [String],
        completion: @escaping (MCPToolResult) -> Void
    ) {
        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }

        let alert = NSAlert()
        alert.messageText = StorageToolStrings.proposalTitle(
            count: artifacts.count,
            size: Self.storageSize.string(fromByteCount: bytes)
        )

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

        alert.informativeText = body.joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: StorageToolStrings.approve)
        alert.addButton(withTitle: StorageToolStrings.decline)

        guard let window else {
            completion(.failure(StorageToolStrings.noWindow))
            return
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(.success(StorageToolStrings.declined))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let removed = artifacts.filter { ArtifactScanner.remove($0) }
                let reclaimed = removed.reduce(0) { $0 + $1.byteCount }

                DispatchQueue.main.async {
                    for project in ProjectStore.shared.projects {
                        ArtifactScanService.shared.forget(removed, in: project.id)
                    }

                    SkalmanLogger.agent.info(
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
    static let scanning = "Skalman is still measuring the projects' build output. Ask again shortly."
    static let nothingFound = "No reclaimable build output was found in the user's projects."

    static let listingFooter = """
        Everything above is ignored by git and rebuildable by the command shown. To act on any \
        of it, call propose_storage_cleanup with the exact paths — that asks the user, who \
        decides. Nothing is removed without their approval.
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

    /// Stated only while the disk is short. Leads with the number, since that is the part the
    /// agent could not have known, and names the tool second.
    static func pressureWithReclaimable(free: String, capacity: String, reclaimable: String) -> String {
        """


        Disk space is low: \(free) free of \(capacity). Skalman has already identified \
        \(reclaimable) of build output that can be deleted and rebuilt. If a task is short of \
        room, or the user hits a disk-full error, call list_reclaimable_storage and suggest \
        what is worth removing — then propose_storage_cleanup to ask them.
        """
    }

    static func pressureOnly(free: String, capacity: String) -> String {
        """


        Disk space is low: \(free) free of \(capacity). list_reclaimable_storage reports build \
        output across the user's projects that can be deleted and rebuilt, if room is needed.
        """
    }

    static func inUse(_ relative: String) -> String {
        "IN USE — written \(relative)"
    }

    static func header(total: String, count: Int, measured: String) -> String {
        "\(total) reclaimable across \(count) directories\(measured):"
    }

    static func unknownPaths(_ paths: [String]) -> String {
        """
        None of these paths are in the current listing, so none can be proposed: \
        \(paths.joined(separator: ", ")). Call list_reclaimable_storage and quote its paths \
        exactly. Only build output Skalman has already vetted can be proposed.
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
