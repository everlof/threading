#if os(Linux)
import Foundation
import ThreadingPTYHostKit
@testable import CoreSlice

/// Saved-terminal commands issued by the Linux sidebar. Every mutation reopens the current
/// owner and terminal under the host lock; a recycled row or stale menu cannot edit another one.
enum TerminalRowAction {
    struct RenameReceipt: Sendable {
        let changed: Bool
        let title: String
        let customTitle: String?
    }

    static func rename(store: String, terminalID: TerminalID, projectID: ProjectID,
                       title: String, displayedCurrentTitle: String?) throws -> RenameReceipt {
        guard title.utf8.count <= 4_096 else { throw WindowFailure("terminal name is too long") }
        let customTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTitle = customTitle.isEmpty ? nil : customTitle
        return try LinuxStoreMutation.withDatabase(at: store) { database in
            guard let result = try database.updateTerminal(id: terminalID, in: projectID,
                edit: { terminal in
                    // The bounded navigator may show only a prefix of a saved long name.
                    // Accepting the unchanged prompt must preserve the complete stored value.
                    if title == displayedCurrentTitle,
                       terminal.customTitle != displayedCurrentTitle { return false }
                    guard terminal.customTitle != storedTitle else { return false }
                    terminal.customTitle = storedTitle
                    return true
                }) else {
                throw WindowFailure("terminal is no longer in this project")
            }
            return RenameReceipt(changed: result.changed,
                                 title: result.terminal.displayTitle,
                                 customTitle: result.terminal.customTitle)
        }
    }

    /// Resolve the owning path when Copy is chosen. A project move while the menu was open
    /// cannot make its cached label copy the former checkout.
    static func worktreePath(store: String, terminalID: TerminalID,
                             projectID: ProjectID) throws -> String {
        try LinuxStoreMutation.withDatabase(at: store) { database in
            guard let project = try database.projectRecord(id: projectID),
                  project.terminals.contains(where: { $0.id == terminalID }) else {
                throw WindowFailure("terminal is no longer in this project")
            }
            return project.folderPath
        }
    }

    /// Remove the durable row before stopping its child, matching the macOS ownership order.
    /// A daemon failure is reported separately because the row has already been committed away.
    static func close(store: String, socket: String, terminalID: TerminalID,
                      projectID: ProjectID) throws -> Bool {
        try LinuxStoreMutation.withDatabase(at: store) { database in
            guard try database.removeTerminal(id: terminalID, from: projectID) else {
                throw WindowFailure("terminal is no longer in this project")
            }
        }
        let identity = PTYHostSessionIdentity(.projectTerminal(terminalID))
        if PTYHostSessionStop.run(identity, socketPath: socket,
                                  build: "linux-native-window") {
            return true
        }
        // A child that already exited needs no stop acknowledgement. Survey only after the
        // direct stop failed; a failed survey must not be mistaken for proof of exit.
        switch GraphicalTerminal.terminalPresence(socket: socket, id: terminalID) {
        case .absent, .exited:
            return true
        case .running, .unavailable:
            return false
        }
    }
}
#endif
