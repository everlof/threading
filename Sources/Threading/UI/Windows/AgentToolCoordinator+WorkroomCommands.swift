/// Workrooms tools forward to `WorkroomAgentCommandService`; the hub adds only the approval window.
@MainActor
extension AgentToolCoordinator {
    typealias WorkroomCompletion = @MainActor @Sendable (MCPToolResult) -> Void
    private var workroomCommands: WorkroomAgentCommandService {
        let window = presentationWindow
        return WorkroomAgentCommandService(
            projects: dependencies.projects, mailbox: dependencies.mail,
            approveOpening: { facts in if let window { await WorkroomOpeningSheet.ask(in: window, facts: facts) } else { nil } },
            revealSettings: { WorkroomOpeningSheet.revealSettings() })
    }

    func workroomFind(_ a: WorkroomFindArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.find(a, for: s, completion: c) }
    func workroomCreate(_ a: WorkroomCreateArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.create(a, for: s, completion: c) }
    func workroomContext(_ a: WorkroomRoomArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.context(a, for: s, completion: c) }
    func workroomAsk(_ a: WorkroomAskArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.ask(a, for: s, completion: c) }
    func workroomQuestions(_ a: WorkroomQuestionsArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.questions(a, for: s, completion: c) }
    func workroomRespond(_ a: WorkroomRespondArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.respond(a, for: s, completion: c) }
    func workroomRequestOpening(_ a: WorkroomRequestOpeningArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.requestOpening(a, for: s, completion: c) }
    func workroomSetLanguage(_ a: WorkroomSetLanguageArguments, for s: SessionID, completion c: @escaping WorkroomCompletion) { workroomCommands.setLanguage(a, for: s, completion: c) }
}
