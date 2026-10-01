import Foundation

/// Agent requests contain content, never worker identity, recipients or destination authority.
public enum ControllerAgentRequest: Codable, Sendable {
    case context
    case questions(after: Int64)
    case messages(after: Int64)
    case messageConsumed(id: UUID)
    case history(after: Int64)
    case checkpoint(text: String)
    case ask(id: QuestionID, text: String, checkpoint: String)
    case finish(payload: String)
    case memoryGet(key: String)
    case memoryPut(key: String, expectedRevision: Int, content: String)
    case knowledgeGet(spaceID: KnowledgeSpaceID, key: String)
    case knowledgePut(spaceID: KnowledgeSpaceID, key: String, expectedRevision: Int, content: String)
}

public struct ControllerAgentResponse: Codable, Sendable {
    public var work: WorkItem?
    public var messages: ControllerPage<WorkMessage>?
    public var message: WorkMessage?
    public var history: ControllerPage<WorkActivity>?
    public var questions: ControllerPage<WorkQuestion>?
    public var question: WorkQuestion?
    public var delivery: WorkDelivery?
    public var memory: WorkerMemory?
    public var knowledge: KnowledgeEntry?
}

extension ControllerStore {
    public func agentRequest(executionID: ExecutionID, credential: String,
                             request: ControllerAgentRequest) throws -> ControllerAgentResponse {
        try db.transaction {
            let launch = try launch(executionID)
            let expected: String = try required("executionCredential", executionID.description)
            guard credential == expected, launch.state == .dispatching || launch.state == .running else {
                throw ControllerError.forbidden
            }
            var response = ControllerAgentResponse()
            // Terminal writes may retry their identical receipt until the process is confirmed
            // stopped. Existing core operations fence changed/stale writes. Other tools require
            // the current running execution, including worker memory writes.
            switch request {
            case .ask(let id, let text, let checkpoint):
                response.question = try ask(executionID: executionID, id: id, recipients: launch.spec.recipients,
                                            text: text, checkpoint: checkpoint)
            case .finish(let payload):
                response.delivery = try finish(executionID: executionID, destination: launch.spec.destination, payload: payload)
            default:
                let (work, _) = try running(executionID)
                switch request {
                case .context: response.work = work
                case .messages(let after): response.messages = try messages(workID: work.id, after: after)
                case .messageConsumed(let id): response.message = try consumeMessage(executionID: executionID, id: id)
                case .history(let after): response.history = try activities(workID: work.id, after: after)
                case .questions(let after): response.questions = try questions(workID: work.id, after: after)
                case .checkpoint(let text): response.work = try checkpoint(executionID: executionID, text: text)
                case .memoryGet(let key): response.memory = try memory(workerID: work.workerID, key: key)
                case .memoryPut(let key, let revision, let content):
                    response.memory = try putMemory(workerID: work.workerID, key: key, expectedRevision: revision, content: content)
                case .knowledgeGet(let space, let key):
                    try requireKnowledgeAccess(spaceID: space, workerID: work.workerID, writing: false)
                    response.knowledge = try knowledge(spaceID: space, key: key)
                case .knowledgePut(let space, let key, let revision, let content):
                    try requireKnowledgeAccess(spaceID: space, workerID: work.workerID, writing: true)
                    response.knowledge = try saveKnowledge(spaceID: space, key: key, expectedRevision: revision, content: content, executionID: executionID)
                case .ask, .finish: throw ControllerError.conflict
                }
            }
            return response
        }
    }
}
