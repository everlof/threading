import AppKit

typealias TriggerToolCompletion = @MainActor @Sendable (MCPToolResult) -> Void

@MainActor extension AgentToolCoordinator {
    func listTriggerSources(completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.listTriggerSources(completion: completion)
    }
    func listTriggers(completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.listTriggers(completion: completion)
    }
    func listTriggerRuns(_ arguments: TriggerReferenceArguments, completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.listTriggerRuns(arguments, completion: completion)
    }
    func createTriggerDraft(_ arguments: CreateTriggerDraftArguments, for sessionID: SessionID, completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.createTriggerDraft(arguments, for: sessionID, projects: dependencies.projects, completion: completion)
    }
    func proposeTriggerActivation(_ arguments: TriggerReferenceArguments, completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.proposeTriggerActivation(arguments, window: presentationWindow, completion: completion)
    }
    func reportTriggerAssessment(_ arguments: ReportTriggerAssessmentArguments, for sessionID: SessionID, completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.reportTriggerAssessment(arguments, for: sessionID, completion: completion)
    }
    func reportTriggerResult(_ arguments: ReportTriggerResultArguments, for sessionID: SessionID, completion: @escaping TriggerToolCompletion) {
        TriggerToolActions.reportTriggerResult(arguments, for: sessionID, completion: completion)
    }
}
