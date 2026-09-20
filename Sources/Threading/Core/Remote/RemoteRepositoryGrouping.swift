import CryptoKit
import Foundation
import ThreadingRemoteKit

// MARK: - Constants

private enum RemoteRepositoryGroupingDefaults {
    /// Half a SHA-256, hex. Long enough that two repositories on one Mac will not collide,
    /// short enough to stay a cheap dictionary key on the phone.
    static let identityLength = 32
}

/// Which added checkouts belong to one repository, as a paired client has to see it.
///
/// The Mac's sidebar puts every checkout of a repository under that repository's own row, so a
/// worktree is always beside the checkout it grew from however the project list is arranged.
/// A client has no such answer available: it never learns a checkout path, so its project list
/// is names, and names sort a worktree called `AnotherTerminal-experiment-jev` nowhere near the
/// project the user renamed `Threading`. This sends the grouping the Mac already computes.
///
/// The rules are the sidebar's, deliberately: the repository is `git rev-parse --git-common-dir`,
/// the checkout that answers for it is the main working tree (`GitInfo.isMainWorkingTree`), and
/// the repository's name is that checkout's project name — so renaming it renames the group on
/// both surfaces. The scratchpad answers "no repository" even though it is one, which keeps it
/// out of a group and, more importantly, keeps it from dragging a project the user added inside
/// it into one.
enum RemoteRepositoryGrouping {

    // MARK: - Public Methods

    /// One entry per project that is in a repository, keyed by project id.
    ///
    /// O(projects), with one memoized `worktreeLocation` read each — the same read the caller's
    /// own `currentBranch` already warmed for that path.
    static func describe(_ projects: [Project]) -> [ProjectID: RemoteRepositoryDTO] {
        var identities: [ProjectID: String] = [:]
        var namesByIdentity: [String: String] = [:]
        var mainCheckouts: Set<ProjectID> = []

        for project in projects where !project.isTheScratchpad {
            guard let identity = GitInfo.repositoryIdentity(for: project.folderPath) else {
                continue
            }
            identities[project.id] = identity

            // Asked for by what the checkout *is* rather than by position: the checkouts are in
            // the user's own arrangement, and a monorepo package has no worktree name either, so
            // "the first one" would let `packages/api` name the whole repository.
            guard GitInfo.isMainWorkingTree(project.folderPath) else { continue }
            mainCheckouts.insert(project.id)
            namesByIdentity[identity] = project.name
        }

        return identities.reduce(into: [:]) { descriptions, entry in
            let (projectID, identity) = entry
            descriptions[projectID] = RemoteRepositoryDTO(
                id: publishedIdentity(of: identity),
                // A repository whose main working tree has not been added is still a repository,
                // and its worktrees still belong together. It is named after the directory the
                // shared git dir sits in, which is what the sidebar falls back to as well.
                name: namesByIdentity[identity] ?? GitInfo.repositoryName(forIdentity: identity),
                isMainCheckout: mainCheckouts.contains(projectID)
            )
        }
    }

    // MARK: - Private Methods

    /// The repository's identity as a client may hold it.
    ///
    /// A digest rather than the `git-common-dir` path, because the owner catalogue publishes a
    /// project's name and never its location, and grouping needs equality rather than a path.
    private static func publishedIdentity(of identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return String(
            digest.map { String(format: "%02x", $0) }
                .joined()
                .prefix(RemoteRepositoryGroupingDefaults.identityLength)
        )
    }
}
