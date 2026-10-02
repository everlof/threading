import Foundation
@testable import CoreSlice

/// The preview exposes its existing operations through the production command admission plane.
/// These fixed values are independent of catalogue size; they contain no views or IO work.
enum NavigatorActions {
    enum Command: String, CaseIterable {
        case addProject = "project.add"
        case newProject = "project.new"
        case newScratchpad = "project.scratchpad"
        case newChat = "linux.project.new-chat"
        case newManager = "linux.project.new-manager"
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
            case .newProject: return "Start New Project…"
            case .newScratchpad: return "New Scratchpad"
            case .newChat: return "New Chat…"
            case .newManager: return "New Manager…"
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
            case .newProject: return 31
            case .newScratchpad: return 32
            case .newChat: return 34
            case .newManager: return 35
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
        enum Kind { case projectActions, addProject, projectCreate, chatProviders }
        let kind: Kind
        let projectID: ProjectID?
        let returnToSidebar: Bool
        var selected = 0
        var first = 0
        var commands: [HostCommandDescriptor]
    }

    static func commands(_ state: State) -> [HostCommandDescriptor] {
        Command.allCases.map { command in
            let reason: String?
            if command == .addProject || command == .newProject || command == .newScratchpad { reason = nil }
            else if state.projectID == nil { reason = "Select a project first." }
            else {
                switch command {
                case .addProject, .newProject, .newScratchpad: reason = nil
                case .newChat:
                    reason = !state.hasCodex && !state.hasClaude
                        ? "Configure a chat provider first."
                        : state.canCreateAgent ? nil : "limit of 8 open terminals"
                case .newManager: reason = "Managers are not available in the Linux preview."
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
                scope: [.addProject, .newProject, .newScratchpad].contains(command) ? .application : .project,
                risk: .ordinary,
                availability: reason.map { .unavailable(reason: $0) } ?? .available)
        }
    }

    static func projectCommands(_ state: State) -> [HostCommandDescriptor] {
        commands(state).filter { $0.id != Command.newProject.rawValue &&
            $0.id != Command.newScratchpad.rawValue &&
            $0.id != Command.newChat.rawValue &&
            $0.id != Command.newManager.rawValue }
    }

    static func projectCreateCommands(_ state: State) -> [HostCommandDescriptor] {
        let catalog = commands(state)
        return [Command.newChat, .newManager, .newShell].compactMap { command in
            guard let descriptor = catalog.first(where: { $0.id == command.rawValue }) else { return nil }
            if command == .newShell {
                return HostCommandDescriptor(id: descriptor.id, title: "New Terminal",
                    detail: descriptor.detail, group: descriptor.group, shortcut: descriptor.shortcut,
                    origin: descriptor.origin, scope: descriptor.scope, risk: descriptor.risk,
                    availability: descriptor.availability)
            }
            return descriptor
        }
    }

    static func chatProviderCommands(_ state: State) -> [HostCommandDescriptor] {
        commands(state).filter { $0.id == Command.newCodex.rawValue ||
            $0.id == Command.newClaude.rawValue }
    }

    static func addProjectMenuCommands() -> [HostCommandDescriptor] {
        [
            HostCommandDescriptor(id: Command.newProject.rawValue, title: "Start New Project…",
                detail: nil, group: "Project", shortcut: nil, origin: .builtIn,
                scope: .application, risk: .ordinary, availability: .available),
            HostCommandDescriptor(id: Command.addProject.rawValue, title: "Use an Existing Folder…",
                detail: nil, group: "Project", shortcut: nil, origin: .builtIn,
                scope: .application, risk: .ordinary, availability: .available),
            HostCommandDescriptor(id: Command.newScratchpad.rawValue, title: "New Scratchpad",
                detail: nil, group: "Project", shortcut: nil, origin: .builtIn,
                scope: .application, risk: .ordinary, availability: .available)
        ]
    }

    /// A stale displayed row is never authority: re-read availability and the exact project
    /// immediately before returning to the same operation used by keyboard shortcuts.
    @MainActor static func invoke(_ command: Command, projectID: ProjectID?,
                                 state: @escaping @MainActor () -> State) -> HostCommandInvocationOutcome {
        let plane = HostCommandPlane(catalog: { commands(state()) }, invoke: { id in
            guard [.addProject, .newProject, .newScratchpad].contains(command) ||
                state().projectID == projectID else {
                return .refused(commandID: id, reason: "The selected project has changed.")
            }
            return .invoked(commandID: id)
        })
        return plane.invoke(commandID: command.rawValue)
    }
}
