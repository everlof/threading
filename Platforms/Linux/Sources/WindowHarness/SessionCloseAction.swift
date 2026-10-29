#if os(Linux)
import Foundation
import ThreadingPTYHostKit
@testable import CoreSlice

/// Revalidates the exact saved row before stopping its daemon child. Closing keeps the record
/// and provider transcript intact; the window releases its cached presentation on success.
enum SessionCloseAction {
    static func run(store: String, socket: String, sessionID: SessionID,
                    projectID: ProjectID, stopHostedChild: Bool) throws {
        try LinuxStoreMutation.withDatabase(at: store) { database in
            guard let record = try database.sessionRecord(id: sessionID),
                  record.project.id == projectID, !record.session.isArchived else {
                throw WindowFailure("session is no longer in this project")
            }
            guard stopHostedChild else { return }

            switch GraphicalTerminal.agentPresence(socket: socket, id: sessionID) {
            case .absent, .exited:
                return
            case .running:
                guard PTYHostSessionStop.run(.agentSession(sessionID), socketPath: socket,
                                             build: "linux-native-window") else {
                    throw WindowFailure("the hosted agent did not confirm its exit")
                }
            case .unavailable:
                throw WindowFailure("the session host could not confirm whether the agent is running")
            }
        }
    }
}
#endif
