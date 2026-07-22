import Foundation

/// Which added projects are checkouts of the same repository.
///
/// A separate file because this is a *git* question asked of the project list, rather than
/// part of owning and persisting it — and because both the composer's branch menu and the
/// window's session routing need the same answer, which they were deriving separately.
extension ProjectStore {

    /// The *other* added checkouts of one project's repository, each with the branch it is on.
    ///
    /// A branch is only somewhere a session can run if a checkout is standing on it, and only
    /// an added project is somewhere Skalman can put a session. Everything else is just a
    /// branch name — which is why this is what the branch menu offers rather than the output
    /// of `git branch`.
    func siblingCheckouts(of projectID: ProjectID) -> [(projectID: ProjectID, branch: String)] {
        guard let origin = project(withID: projectID),
              let identity = GitInfo.repositoryIdentity(for: origin.folderPath) else { return [] }

        return projects.compactMap { candidate in
            guard candidate.id != projectID,
                  GitInfo.repositoryIdentity(for: candidate.folderPath) == identity,
                  let branch = GitInfo.currentBranch(for: candidate.folderPath) else { return nil }

            return (projectID: candidate.id, branch: branch)
        }
    }

    /// The project whose checkout is on `branch`, within one project's repository.
    ///
    /// Nil when no added checkout is on it, which the caller must treat as "nowhere to run"
    /// rather than silently falling back to the origin: a session that lands in the wrong
    /// checkout still records the branch that was asked for, and the two then disagree.
    func checkout(onBranch branch: String, inRepositoryOf projectID: ProjectID) -> ProjectID? {
        if GitInfo.currentBranch(for: project(withID: projectID)?.folderPath ?? "") == branch {
            return projectID
        }

        return siblingCheckouts(of: projectID).first { $0.branch == branch }?.projectID
    }
}
