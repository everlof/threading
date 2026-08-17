import AppKit

// MARK: - Storage Cleanup Proposal Sheet

/// The sheet an agent's cleanup proposal is put to the user in: what is going, why, who asked,
/// and — the whole point of the accessory — where.
///
/// Its own type rather than another method on the tool coordinator. Composing this sheet is
/// presentation policy: which grouping the outline uses, how tall it may be before it scrolls,
/// what the title says when the asking session has a name. The coordinator's job is to resolve
/// the proposal against the gate and hand the answer back to the agent, and it is already the
/// largest application service in the app.
///
/// **The paths are the accessory, not the message.** The message used to carry one bullet per
/// absolute path, which is the shape that made a proposal unreadable: six lines sharing their
/// first thirty-four characters, with the part that says which directory is going somewhere in
/// the middle of each. `StorageCleanupOutline` folds them into the headings the Storage page
/// already uses and the path segments they share; this presents that.
@MainActor
enum StorageCleanupProposalSheet {

    /// Puts one batch to the user and reports what happened through `respond`.
    ///
    /// `owners` is the checkout each finding belonged to when it was proposed, captured by the
    /// caller: a batch can be presented after the sheet in front of it deleted something, and
    /// re-reading the caches here would group this proposal by what is left instead.
    static func present(
        _ batch: StorageCleanupLedger.Batch,
        in window: NSWindow,
        owners: [String: Project],
        among projects: [Project],
        respond: @escaping @MainActor (StorageCleanupLedger.SheetResult) -> Void
    ) {
        let artifacts = batch.artifacts
        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }
        let title = StorageToolStrings.proposalTitle(
            asker: batch.asker,
            count: artifacts.count,
            size: StorageCleanupOutline.size(bytes)
        )

        // The reason, then the warning, then what removal means.
        var body: [String] = []
        if let reason = batch.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            body.append(reason)
        }
        if artifacts.contains(where: { $0.isInUse() }) {
            body.append(StorageToolStrings.proposalInUse)
        }
        body.append(StorageToolStrings.proposalFooter)

        let request = ConfirmationRequest(
            prompt: .approveAgentStorageCleanup,
            title: title,
            message: body.joined(separator: "\n\n"),
            confirmTitle: StorageToolStrings.approve,
            cancelTitle: StorageToolStrings.decline,
            accessory: accessory(
                for: outline(of: artifacts, owners: owners, among: projects),
                accessibilityLabel: title
            )
        )

        ConfirmationAlert.ask(request, in: window) { approved in
            guard approved else {
                ThreadingLogger.agent.info(
                    "Agent cleanup declined: \(artifacts.count, privacy: .public) directories"
                )
                respond(.declined)
                return
            }

            remove(artifacts, respond: respond)
        }
    }

    // MARK: - Removing

    /// Hands the approved directories to the one removal lane, and reports what actually went.
    private static func remove(
        _ artifacts: [ReclaimableArtifact],
        respond: @escaping @MainActor (StorageCleanupLedger.SheetResult) -> Void
    ) {
        let started = ArtifactCleanupCoordinator.shared.remove(artifacts) { outcome in
            let removed = outcome.removed
            for project in ProjectStore.shared.projects {
                ArtifactScanService.shared.forget(removed, in: project.id)
            }
            // The scratch reading keeps its own cache, and re-walking `/private/tmp` to learn
            // what this delete just did to it would be the most expensive way to find out.
            ArtifactScanService.shared.forgetScratch(removed)

            ThreadingLogger.agent.info(
                "Agent cleanup approved: removed \(removed.count, privacy: .public) directories"
            )

            respond(.approved(removed.map {
                StorageCleanupLedger.Removal(path: $0.url.path, byteCount: $0.byteCount)
            }))
        }

        // The removal lane is one lane. Nothing is recorded when it is busy: the user's approval
        // was for directories that are all still there, so this proposal is told why rather than
        // answered with a decision nobody took.
        guard started else {
            respond(.unavailable(StorageToolStrings.cleanupAlreadyRunning))
            return
        }
    }

    // MARK: - Content

    /// The proposal, grouped the way the Storage page groups the same findings.
    private static func outline(
        of artifacts: [ReclaimableArtifact],
        owners: [String: Project],
        among projects: [Project]
    ) -> StorageCleanupOutline {
        var grouped: [ProjectID: [ReclaimableArtifact]] = [:]
        var byID: [ProjectID: Project] = [:]
        var scratch: [ReclaimableArtifact] = []

        for artifact in artifacts {
            guard let project = owners[artifact.url.path] else {
                scratch.append(artifact)
                continue
            }
            grouped[project.id, default: []].append(artifact)
            byID[project.id] = project
        }

        return StorageCleanupOutline.make(from: ReclaimableFindings.groups(
            checkoutArtifacts: grouped.compactMap { id, artifacts in
                byID[id].map { (project: $0, artifacts: artifacts) }
            },
            scratchArtifacts: scratch,
            among: projects
        ))
    }

    /// A scrollable, size-bounded outline for the sheet's accessory slot.
    ///
    /// The alert sizes an accessory to its frame, so a proposal naming two directories is two
    /// lines tall and one naming forty scrolls. Nothing is dropped from what the user is
    /// approving — a sheet that summarises away part of a delete is worse than the wall of paths
    /// it replaced — and the buttons stay on the screen either way.
    static func accessory(
        for outline: StorageCleanupOutline,
        accessibilityLabel: String
    ) -> NSView {
        let view = StorageProposalOutlineView(
            outline: outline,
            accessibilityLabel: accessibilityLabel
        )
        let height = min(StorageProposalDefaults.maximumHeight, view.fittingHeight())

        let scroll = ThemedScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: StorageProposalDefaults.width,
            height: height
        ))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = view

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            view.topAnchor.constraint(equalTo: clip.topAnchor),
            view.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])

        return scroll
    }
}

// MARK: - Storage Proposal Defaults

/// The proposal sheet's outline, sized the way the permission sheet's diff is: wide enough for a
/// path and its size, and bounded in height so a proposal naming forty directories scrolls rather
/// than pushing the buttons off the screen.
enum StorageProposalDefaults {
    static let width: CGFloat = 460
    static let maximumHeight: CGFloat = 260
}
