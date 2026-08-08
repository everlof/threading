import Foundation
import ThreadingRemoteKit

/// Projects the Mac's existing git reader onto a bounded, platform-neutral mobile payload.
///
/// Git and the checkout stay entirely on the host. This bridge deliberately reuses
/// `GitReviewReader`, so the desktop pane and the phone agree about untracked files, branch
/// bases, unborn repositories, and Last Turn snapshots.
@MainActor
enum RemoteGitReviewBridge {

    enum Failure: LocalizedError {
        case sessionUnavailable
        case notRepository

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable: return L10n.string("Session unavailable.")
            case .notRepository: return L10n.string("Not a git repository.")
            }
        }
    }

    static func review(
        sessionID: SessionID,
        mode: RemoteGitReviewMode,
        completion: @escaping (RemoteGitReviewSnapshotDTO) -> Void
    ) {
        let ordinaryRoot = repositoryRoot(for: sessionID)
        guard ordinaryRoot != nil || mode == .lastTurn else {
            completion(snapshot(
                mode: mode,
                message: Failure.notRepository.localizedDescription,
                localizationKey: "Not a git repository."
            ))
            return
        }

        let request: GitReviewReader.DiffRequest
        switch mode {
        case .uncommitted:
            request = .uncommitted
        case .unstaged:
            request = .unstaged
        case .staged:
            request = .staged
        case .branch:
            request = .branch
        case .lastTurn:
            guard let checkpoint = GitTurnBaselineStore.shared
                .latestCheckpoint(forSessionID: sessionID) else {
                let message: String
                let localizationKey: String
                if GitTurnBaselineStore.shared.captureFailure(forSessionID: sessionID) != nil {
                    message = L10n.string("Couldn’t capture this turn’s starting state.")
                    localizationKey = "Couldn’t capture this turn’s starting state."
                } else {
                    message = L10n.string(
                        "No turn recorded yet. A baseline is captured before the agent starts working."
                    )
                    localizationKey =
                        "No turn recorded yet. A baseline is captured before the agent starts working."
                }
                completion(snapshot(
                    mode: mode,
                    message: message,
                    localizationKey: localizationKey
                ))
                return
            }
            guard checkpoint.canPresentDiff else {
                completion(snapshot(
                    mode: mode,
                    message: checkpoint.failureDescription
                        ?? L10n.string("This turn did not reach a complete checkpoint."),
                    localizationKey: "This turn did not reach a complete checkpoint."
                ))
                return
            }
            request = .turnCheckpoint(checkpoint)
        }

        let root: URL?
        if case .turnCheckpoint(let checkpoint) = request {
            root = GitTurnBaselineStore.shared.repositoryRoot(
                for: checkpoint,
                preferredPath: ordinaryRoot?.path
            )
        } else {
            root = ordinaryRoot
        }
        guard let root else {
            completion(snapshot(
                mode: mode,
                message: Failure.notRepository.localizedDescription,
                localizationKey: "Not a git repository."
            ))
            return
        }

        GitReviewReader.diff(request, in: root) { result in
            switch result {
            case .success(let files):
                completion(RemoteGitReviewSnapshotDTO(
                    mode: mode,
                    files: files.map(project),
                    message: files.isEmpty ? "No changes." : nil,
                    messageLocalization: files.isEmpty
                        ? .init(key: "No changes.")
                        : nil
                ))
            case .failure(let failure):
                completion(snapshot(
                    mode: mode,
                    message: failure.errorDescription ?? "git failed.",
                    localizationKey: "Couldn’t read changes."
                ))
            }
        }
    }

    static func repositoryFiles(
        sessionID: SessionID,
        completion: @escaping (Result<RemoteRepositoryFilesDTO, Failure>) -> Void
    ) {
        guard let root = repositoryRoot(for: sessionID) else {
            completion(.failure(.notRepository))
            return
        }

        GitReviewReader.repositoryFiles(in: root) { result in
            switch result {
            case .success(let paths):
                let cap = GitReviewDefaults.remoteRepositoryFileLimit
                completion(.success(RemoteRepositoryFilesDTO(
                    paths: Array(paths.prefix(cap)),
                    isTruncated: paths.count > cap
                )))
            case .failure:
                completion(.failure(.notRepository))
            }
        }
    }

    static func repositoryFile(
        sessionID: SessionID,
        path: String,
        completion: @escaping (Result<RemoteRepositoryFileDTO, Failure>) -> Void
    ) {
        guard let root = repositoryRoot(for: sessionID) else {
            completion(.failure(.notRepository))
            return
        }

        GitReviewReader.repositoryFile(path: path, in: root) { result in
            switch result {
            case .success(let file):
                completion(.success(RemoteRepositoryFileDTO(
                    path: file.path,
                    content: file.content,
                    isBinary: file.isBinary,
                    isTruncated: file.isTruncated
                )))
            case .failure:
                completion(.failure(.sessionUnavailable))
            }
        }
    }

    private static func repositoryRoot(for sessionID: SessionID) -> URL? {
        guard RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else {
            return nil
        }
        return GitInfo.repositoryRoot(for: project.folderPath)
    }

    private static func snapshot(
        mode: RemoteGitReviewMode,
        message: String,
        localizationKey: String
    ) -> RemoteGitReviewSnapshotDTO {
        RemoteGitReviewSnapshotDTO(
            mode: mode,
            files: [],
            message: message,
            messageLocalization: .init(key: localizationKey)
        )
    }

    private static func project(_ file: GitFileDiff) -> RemoteGitFileDiffDTO {
        let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count }
        var remaining = GitReviewDefaults.fileDisplayCap
        var hunks: [RemoteGitHunkDTO] = []

        for hunk in file.hunks where remaining > 0 {
            let kept = hunk.lines.prefix(remaining)
            remaining -= kept.count
            hunks.append(RemoteGitHunkDTO(
                header: hunk.header,
                lines: kept.map(project)
            ))
        }

        let change: String
        let renamedFrom: String?
        switch file.change {
        case .modified:
            change = "modified"
            renamedFrom = nil
        case .added:
            change = "added"
            renamedFrom = nil
        case .deleted:
            change = "deleted"
            renamedFrom = nil
        case .untracked:
            change = "untracked"
            renamedFrom = nil
        case .renamed(let source):
            change = "renamed"
            renamedFrom = source
        case .binary:
            change = "binary"
            renamedFrom = nil
        }

        return RemoteGitFileDiffDTO(
            path: file.path,
            change: change,
            renamedFrom: renamedFrom,
            hunks: hunks,
            added: file.added,
            removed: file.removed,
            isTruncated: lineCount > GitReviewDefaults.fileDisplayCap
        )
    }

    private static func project(_ line: GitDiffLine) -> RemoteGitDiffLineDTO {
        let kind: String
        switch line.kind {
        case .context: kind = "context"
        case .added: kind = "addition"
        case .removed: kind = "removal"
        }

        let cap = GitReviewDefaults.lineCharacterCap
        let text = line.text.count > cap
            ? String(line.text.prefix(cap)) + "…"
            : line.text
        return RemoteGitDiffLineDTO(
            kind: kind,
            text: text,
            oldNumber: line.oldNumber,
            newNumber: line.newNumber
        )
    }
}
