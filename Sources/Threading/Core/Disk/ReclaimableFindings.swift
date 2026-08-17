import Foundation

// MARK: - Reclaimable Findings

/// How reclaimable build output is grouped for a person to read: by the checkout it belongs to,
/// and — for a finding that belongs to no checkout — by what its own tool says it was built for.
///
/// Extracted from the Storage page the day the agent proposal sheet had to draw the same content.
/// Two surfaces grouping one set of findings by two rules are two surfaces that disagree about
/// what a directory belongs to, and the three-tier scratch attribution below is exactly the part
/// nobody should write twice: it normalises symlinks, lets the most specific project win, and is
/// free of git by contract.
enum ReclaimableFindings {

    // MARK: - Types

    /// What one group's findings belong to, and therefore what a surface may do with them.
    ///
    /// A checkout is a project's own scan: forgotten per project and re-measured after a
    /// removal. The three scratch cases are the read-time attribution of findings that belong to
    /// no checkout at all.
    ///
    /// Four cases rather than one optional project, because "no project" is two different facts.
    /// A workspace that is gone is the safest thing this app will ever offer — nothing can
    /// rebuild into that tree and nothing will read it again. A workspace that is alive and
    /// simply not ours is usually another agent session's copy of a tree, and filing it under
    /// the orphan heading would tell the user a directory somebody may be building in right now
    /// was left over from a deletion.
    enum Attribution {

        /// One checkout of a project: its own folder, or one of its worktrees.
        case checkout(Project)

        /// Scratch findings built for a workspace inside this project's folder.
        case scratchProject(Project)

        /// Scratch findings whose workspace no longer exists.
        case scratchOrphan

        /// Scratch findings whose workspace exists and belongs to no project Threading knows.
        case scratchOther

        /// The project whose running sessions a confirmation warns about, when there is one.
        var project: Project? {
            switch self {
            case .checkout(let project), .scratchProject(let project): return project
            case .scratchOrphan, .scratchOther: return nil
            }
        }

        /// Whether a removal here corrects the scratch reading rather than a project's.
        var isScratch: Bool {
            switch self {
            case .checkout: return false
            case .scratchProject, .scratchOrphan, .scratchOther: return true
            }
        }

        /// Whether the group trails the page instead of sorting into it by size. A heading that
        /// names no project reads as a mistake in the middle of a list of projects.
        var trailsThePage: Bool {
            switch self {
            case .checkout, .scratchProject: return false
            case .scratchOrphan, .scratchOther: return true
            }
        }

        /// Whether the workspace these findings name is gone, which changes what a row's caption
        /// says about it.
        var namesADeletedWorkspace: Bool {
            switch self {
            case .scratchOrphan: return true
            case .checkout, .scratchProject, .scratchOther: return false
            }
        }
    }

    /// One group's findings — a checkout's, or one tier of the scratch scope's.
    ///
    /// The **checkout** is the grouping rather than the project, because a project's build
    /// output is spread across every worktree it has and the path alone does not say which:
    /// six of these checkouts hold a `web/node_modules`, and a row reading `web/node_modules`
    /// under a heading reading `sonda` names none of them.
    struct Group {
        let attribution: Attribution

        /// The first line: the project and its checkout, or the scratch tier's heading.
        let title: String

        /// The line beneath it, which is always where on disk. A worktree name does not say
        /// where it lives, and neither does a tier's name — and that is what somebody about to
        /// delete gigabytes wants to confirm.
        let subtitle: String

        /// What a fold state is keyed by. A checkout's path for a checkout; a stated key for a
        /// scratch tier, which spans roots and so has no one path to be named after.
        let identity: String

        let artifacts: [ReclaimableArtifact]

        var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    }

    // MARK: - Grouping

    /// Splits a project's findings by the checkout each belongs to, and names each one.
    ///
    /// The name is the worktree's, else the branch the checkout stands on — a worktree is
    /// recognisable by its name, while the project's own folder is best identified by what it
    /// has checked out. Reads git, once per distinct checkout rather than once per finding.
    static func checkoutGroups(
        _ artifacts: [ReclaimableArtifact],
        of project: Project
    ) -> [Group] {
        Dictionary(grouping: artifacts, by: \.checkoutPath)
            .map { path, artifacts in
                let label = GitInfo.worktreeName(for: path)
                    ?? GitInfo.currentBranch(for: path)
                    ?? URL(fileURLWithPath: path).lastPathComponent
                return Group(
                    attribution: .checkout(project),
                    title: "\(project.name) · \(label)",
                    subtitle: abbreviate(path),
                    identity: path,
                    artifacts: artifacts.sorted { $0.byteCount > $1.byteCount }
                )
            }
            .sorted { $0.byteCount > $1.byteCount }
    }

    /// Splits the scratch scope's findings three ways by the workspace each was built for.
    ///
    /// **Pure, and free of git by contract.** The per-checkout grouping above shells out once per
    /// checkout to name it; this path must not, because the trees it groups have no repository to
    /// ask — that absence is the whole reason the manifest gate exists — and because there can be
    /// one group here per project and two more besides.
    ///
    /// - A workspace that still exists inside a known project's folder groups under that
    ///   project, exactly as a nested worktree does.
    /// - A workspace that no longer exists is an orphan. Nothing can rebuild into that tree and
    ///   nothing will read it again, which makes it the safest thing this app offers.
    /// - Anything else is a workspace that is alive and is not ours, most often another agent
    ///   session's copy of a tree. It is offered, but under its own heading: it is not an
    ///   orphan, and saying so would be a claim about somebody else's live directory.
    ///
    /// Paths are compared with symlinks resolved, because `/tmp` is a symlink to `/private/tmp`
    /// and two spellings of one directory must not read as two places. The most specific project
    /// wins, so a project checked out inside another takes its own build caches with it.
    ///
    /// `workspaceExists` is stated for tests, which have no deleted workspace to point at.
    static func scratchGroups(
        _ artifacts: [ReclaimableArtifact],
        among projects: [Project],
        workspaceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Group] {
        let folders = projects
            .map { (project: $0, folder: normalized($0.folderPath)) }
            .sorted { $0.folder.count > $1.folder.count }

        var attributed: [ProjectID: [ReclaimableArtifact]] = [:]
        var byID: [ProjectID: Project] = [:]
        var orphaned: [ReclaimableArtifact] = []
        var other: [ReclaimableArtifact] = []

        for artifact in artifacts {
            guard let workspace = artifact.workspacePath else {
                // Every scratch finding the scanner produces names a workspace. One that does
                // not is still not an orphan: nothing said a workspace was deleted.
                other.append(artifact)
                continue
            }

            guard workspaceExists(workspace) else {
                orphaned.append(artifact)
                continue
            }

            let path = normalized(workspace)
            let owner = folders.first { path == $0.folder || path.hasPrefix($0.folder + "/") }
            guard let owner else {
                other.append(artifact)
                continue
            }

            attributed[owner.project.id, default: []].append(artifact)
            byID[owner.project.id] = owner.project
        }

        var groups: [Group] = attributed.compactMap { id, artifacts in
            guard let project = byID[id] else { return nil }
            return Group(
                attribution: .scratchProject(project),
                title: "\(project.name) · \(Strings.buildCacheInTemporary)",
                subtitle: rootsLabel(of: artifacts),
                identity: ScratchGroupKey.project(id),
                artifacts: artifacts.sorted { $0.byteCount > $1.byteCount }
            )
        }
        .sorted { $0.byteCount > $1.byteCount }

        if !orphaned.isEmpty {
            groups.append(Group(
                attribution: .scratchOrphan,
                title: Strings.deletedWorkspaces,
                subtitle: rootsLabel(of: orphaned),
                identity: ScratchGroupKey.orphaned,
                artifacts: orphaned.sorted { $0.byteCount > $1.byteCount }
            ))
        }

        if !other.isEmpty {
            groups.append(Group(
                attribution: .scratchOther,
                title: Strings.otherTemporaryCaches,
                subtitle: rootsLabel(of: other),
                identity: ScratchGroupKey.other,
                artifacts: other.sorted { $0.byteCount > $1.byteCount }
            ))
        }

        return groups
    }

    /// Every group a set of findings falls into, in the order a page or a sheet reads them:
    /// checkouts and a project's own scratch caches by size, then the two tiers that name no
    /// project — orphans first, since they are the only findings nothing can ever want back.
    ///
    /// The one place both surfaces get their whole answer from, rather than each assembling the
    /// halves in an order of its own.
    static func groups(
        checkoutArtifacts: [(project: Project, artifacts: [ReclaimableArtifact])],
        scratchArtifacts: [ReclaimableArtifact],
        among projects: [Project],
        workspaceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Group] {
        var sortable = checkoutArtifacts.flatMap { checkoutGroups($0.artifacts, of: $0.project) }

        let scratch = scratchGroups(
            scratchArtifacts,
            among: projects,
            workspaceExists: workspaceExists
        )
        sortable += scratch.filter { !$0.attribution.trailsThePage }

        return sortable.sorted { $0.byteCount > $1.byteCount }
            + scratch.filter(\.attribution.trailsThePage)
    }

    // MARK: - Reading a path

    /// Replaces the home directory with `~`, so a path is read for its shape rather than its
    /// first forty identical characters.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A finding's path, read for its shape: relative to the checkout or scratch root it was
    /// found under, which every row under one heading shares.
    static func rowTitle(for artifact: ReclaimableArtifact) -> String {
        let root = artifact.checkoutPath + "/"
        let path = artifact.url.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : abbreviate(path)
    }

    // MARK: - Private

    /// Where a scratch group's findings sit, which is what a checkout card says with its path.
    /// A tier's heading names what the findings are, not where they are, and the second question
    /// is the one asked before deleting gigabytes.
    private static func rootsLabel(of artifacts: [ReclaimableArtifact]) -> String {
        Set(artifacts.map(\.checkoutPath))
            .sorted()
            .map(abbreviate)
            .joined(separator: " · ")
    }

    /// One spelling for one directory, so `/tmp` and `/private/tmp` cannot disagree about being
    /// the same place. Resolution happens on both sides of every comparison.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Strings

    enum Strings {

        /// What a project's findings outside its own folder are called, after its name: the same
        /// `<project> · <where>` shape a checkout heading has.
        static var buildCacheInTemporary: String { L10n.string("build cache in /tmp") }

        /// The orphan tier's heading, which names what the findings are rather than where they
        /// live — there is no project left to name, and that absence is the point.
        static var deletedWorkspaces: String {
            L10n.string("Left over from deleted workspaces")
        }

        /// The tier for a workspace that is alive and is not ours. Deliberately not the orphan
        /// heading: somebody may be building in it right now.
        static var otherTemporaryCaches: String {
            L10n.string("Other build caches in temporary locations")
        }

        /// The tree a cache was built for, which is the only thing that says which checkout fed
        /// it.
        static func builtFor(_ workspace: String) -> String {
            L10n.format("built for %@", workspace)
        }

        /// The same, when that tree is gone. On the orphan tier this is the whole reason the row
        /// is safe to remove.
        static func builtForMissing(_ workspace: String) -> String {
            L10n.format("built for %@, which no longer exists", workspace)
        }

        static func lastWritten(_ relative: String) -> String {
            L10n.format("last written %@", relative)
        }

        /// Written moments ago, which almost always means a build is running in it.
        static func inUse(_ relative: String) -> String {
            L10n.format("in use — written %@", relative)
        }
    }
}

// MARK: - Scratch Group Key

/// What a scratch group's fold state is keyed by.
///
/// A checkout is named by its path; a scratch tier spans every root the walk covers and has no
/// one path to be named after, so it states a key instead. The same set holds both, and these
/// cannot collide with a checkout: a checkout identity is an absolute path and begins with `/`.
enum ScratchGroupKey {
    static let prefix = "scratch"

    static func project(_ id: ProjectID) -> String { "\(prefix).project.\(id.uuidString)" }
    static let orphaned = "\(prefix).orphaned"
    static let other = "\(prefix).other"
}
