import Foundation
@testable import CoreSlice

/// The preview exposes its existing operations through the production command admission plane.
/// These nine values are independent of catalogue size; they contain no views or IO work.
enum NavigatorActions {
    enum Command: String, CaseIterable {
        case addProject = "project.add"
        case openShell = "linux.project.open-shell"
        case newShell = "linux.project.new-shell"
        case newCodex = "linux.session.new-codex"
        case codexAccount = "linux.account.choose-codex"
        case newClaude = "linux.session.new-claude"
        case claudeAccount = "linux.account.choose-claude"
        case savedAgents = "linux.project.saved-agents"
        case savedTerminals = "linux.project.saved-terminals"

        var title: String {
            switch self {
            case .addProject: return "Add project folder…"
            case .openShell: return "Open shell"
            case .newShell: return "New shell"
            case .newCodex: return "New Codex session"
            case .codexAccount: return "Choose Codex account…"
            case .newClaude: return "New Claude session"
            case .claudeAccount: return "Choose Claude account…"
            case .savedAgents: return "Saved agents"
            case .savedTerminals: return "Saved terminals"
            }
        }

        var eventKind: Int32 {
            switch self {
            case .addProject: return 23
            case .openShell: return 8
            case .newShell: return 9
            case .newCodex: return 13
            case .codexAccount: return 20
            case .newClaude: return 21
            case .claudeAccount: return 22
            case .savedAgents: return 11
            case .savedTerminals: return 10
            }
        }
    }

    struct State {
        let projectID: ProjectID?
        let canOpenShell: Bool
        let canCreateShell: Bool
        let shellMayBeRunning: Bool
        let canCreateAgent: Bool
        let hasCodex: Bool
        let hasClaude: Bool
        let hasAgents: Bool
        let hasTerminals: Bool
    }

    struct Presentation {
        let projectID: ProjectID?
        let returnToSidebar: Bool
        var selected = 0
        var first = 0
        var commands: [HostCommandDescriptor]
    }

    static func commands(_ state: State) -> [HostCommandDescriptor] {
        Command.allCases.map { command in
            let reason: String?
            if command == .addProject { reason = nil }
            else if state.projectID == nil { reason = "Select a project first." }
            else {
                switch command {
                case .addProject: reason = nil
                case .openShell: reason = state.canOpenShell ? nil : "limit of 8 open terminals"
                case .newShell: reason = state.canCreateShell ? nil : state.shellMayBeRunning
                    ? "terminal may still be running" : "limit of 8 open terminals"
                case .newCodex, .newClaude:
                    let configured = command == .newCodex ? state.hasCodex : state.hasClaude
                    reason = !configured ? "This provider is not configured."
                        : state.canCreateAgent ? nil : "limit of 8 open terminals"
                case .codexAccount: reason = state.hasCodex ? nil : "Codex is not configured."
                case .claudeAccount: reason = state.hasClaude ? nil : "Claude is not configured."
                case .savedAgents: reason = state.hasAgents ? nil : "no saved agents"
                case .savedTerminals: reason = state.hasTerminals ? nil : "no saved terminals"
                }
            }
            return HostCommandDescriptor(id: command.rawValue, title: command.title, detail: reason,
                group: "Project", shortcut: nil, origin: .builtIn,
                scope: command == .addProject ? .application : .project, risk: .ordinary,
                availability: reason.map { .unavailable(reason: $0) } ?? .available)
        }
    }

    /// A stale displayed row is never authority: re-read availability and the exact project
    /// immediately before returning to the same operation used by keyboard shortcuts.
    @MainActor static func invoke(_ command: Command, projectID: ProjectID?,
                                 state: @escaping @MainActor () -> State) -> HostCommandInvocationOutcome {
        let plane = HostCommandPlane(catalog: { commands(state()) }, invoke: { id in
            guard command == .addProject || state().projectID == projectID else {
                return .refused(commandID: id, reason: "The selected project has changed.")
            }
            return .invoked(commandID: id)
        })
        return plane.invoke(commandID: command.rawValue)
    }
}
