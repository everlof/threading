#if os(Linux)
import Foundation
@testable import CoreSlice

/// Admits a fresh native chat on a worker before the UI mounts its conversation pane.
/// The record, selected identity and project count commit together under the store lock.
enum ComposerNativeCreation {
    struct Request: Sendable {
        let store: String
        let directory: String
        let kind: AgentKind
        let accountHandle: AccountHandle
        let permissionMode: AgentPermissionMode?
        let title: String?
        let model: String?
        let reasoningEffort: String?
        let fastMode: Bool?
        let expectedCheckout: LinuxGitCheckout?
        let id: SessionID
    }

    struct Receipt: Sendable {
        let projectID: ProjectID
        let row: AgentSessionRowPresentation
        let branch: String?
        let sessionCount: Int
    }

    static func create(_ request: Request) throws -> Receipt {
        guard request.kind.supportsNativeUI && request.kind.supports(.terminalUI),
              let directory = ProjectDirectory.existing(at: request.directory) else {
            throw WindowFailure("Native conversation or project directory is unavailable.")
        }
        let checkout = LinuxGitCheckout.read(at: directory.path)
        if let expectedCheckout = request.expectedCheckout,
           (checkout?.identity != expectedCheckout.identity
                || checkout?.branch != expectedCheckout.branch) {
            throw WindowFailure("Selected checkout changed before the conversation started.")
        }
        let accountPath = try GraphicalTerminal.accountPath(
            for: request.kind, handle: request.accountHandle)
        return try NativeWorkspaceSession.withDatabase(store: request.store) { database in
            let snapshot = try database.navigationSnapshot(recentSessionLimit: 0,
                                                           recentTerminalLimit: 0)
            guard let project = snapshot.projects.first(where: { $0.folderPath == directory.path }),
                  try database.sessionRecord(id: request.id) == nil else {
                throw WindowFailure("Project or fresh conversation identity is unavailable.")
            }
            let catalogue = request.model != nil || request.reasoningEffort != nil || request.fastMode != nil
                ? ComposerModelCatalog.read(provider: request.kind,
                    directory: URL(fileURLWithPath: accountPath, isDirectory: true),
                    projectDirectory: directory.path) : .empty
            if request.model != nil || request.reasoningEffort != nil {
                guard catalogue.admits(model: request.model, effort: request.reasoningEffort) else {
                    throw WindowFailure("Selected model or effort is no longer available for this account.")
                }
            }
            guard ComposerSpeedLaunch.admits(request.fastMode, kind: request.kind,
                model: request.model, catalogue: catalogue) else {
                throw WindowFailure("Selected speed is no longer available for this model.")
            }
            guard var session = AgentSessionCreation.makeRecord(
                kind: request.kind, accountHandle: request.accountHandle,
                model: request.model, reasoningEffort: request.reasoningEffort,
                fastMode: request.fastMode,
                usesNativeUI: true, permissionMode: request.permissionMode,
                title: request.title, id: request.id)
            else { throw WindowFailure("Unsupported native conversation configuration.") }
            session.branch = checkout?.branch
            try database.addSession(session, to: project.id, position: project.sessionCount,
                                    selectNewSession: true)
            let row = AgentSessionRowPresentation(session: session, usesAgentTitle: true,
                untitledTitle: AgentDefaults.untitledSessionName)
            return Receipt(projectID: project.id, row: row, branch: session.branch,
                           sessionCount: project.sessionCount + 1)
        }
    }
}
#endif
