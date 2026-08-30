import Foundation

/// Whether a project's execution folder can host an agent process.
///
/// A project record can outlive a checkout removed outside Threading. The login shell would
/// otherwise fail its leading `cd` before the provider starts, leaving a dead session row and no
/// provider transcript. This check belongs ahead of both session creation and process launch so
/// the composer can keep the submitted brief and an existing row can show a durable refusal.
enum ProjectLaunchPreflight {

    enum Failure: Equatable {
        case missing(path: String)
        case notDirectory(path: String)

        var path: String {
            switch self {
            case .missing(let path), .notDirectory(let path): path
            }
        }

        var knownCause: String {
            switch self {
            case .missing: "project-folder-missing"
            case .notDirectory: "project-path-not-directory"
            }
        }

        var summary: String {
            switch self {
            case .missing(let path):
                L10n.format("Its folder is missing: %@", path)
            case .notDirectory(let path):
                L10n.format("Something that is not a folder is already at %@.", path)
            }
        }
    }

    static func failure(
        forFolderPath path: String,
        fileManager: FileManager = .default
    ) -> Failure? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing(path: path)
        }
        guard isDirectory.boolValue else {
            return .notDirectory(path: path)
        }
        return nil
    }

    static func launchFailure(
        for project: Project,
        fileManager: FileManager = .default
    ) -> SessionLaunchFailure? {
        guard let failure = failure(
            forFolderPath: project.folderPath,
            fileManager: fileManager
        ) else { return nil }

        return SessionLaunchFailure(
            origin: .preflight,
            summary: failure.summary,
            knownCause: failure.knownCause
        )
    }
}
