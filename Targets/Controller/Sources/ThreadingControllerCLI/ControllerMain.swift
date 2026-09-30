import Foundation
import ThreadingController
import ControllerRuntime
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local-owner adapter. Invocations can be carried over SSH; this is not an authenticated
/// multi-user service and must never be exposed directly as an agent's unrestricted tool.
@main
struct ControllerMain {
    static let help = """
    threading-controller --database PATH COMMAND ARGS...
    JSON on stdout; failures on stderr with nonzero exit. Text arguments use bounded UTF-8 files.
    This CLI has the authority of the local OS account. Answer identity is owner-attested.

    workers [CURSOR]
    worker-add WORKER_UUID NAME
    enqueue WORKER_UUID SOURCE_KEY INSTRUCTION_FILE
    claim WORKER_UUID
    work WORK_UUID
    works WORKER_UUID [CURSOR]
    checkpoint EXECUTION_UUID TEXT_FILE
    ask EXECUTION_UUID QUESTION_UUID RECIPIENTS_CSV QUESTION_FILE CHECKPOINT_FILE
    questions WORK_UUID [CURSOR]
    question QUESTION_UUID
    open-questions WORKER_UUID [CURSOR]
    answer QUESTION_UUID PERSON GROUPS_CSV_OR_DASH ANSWER_FILE
    finish EXECUTION_UUID DESTINATION PAYLOAD_FILE
    interrupt EXECUTION_UUID
    retry WORK_UUID
    deliveries [CURSOR]
    pending-deliveries [CURSOR]
    work-deliveries WORK_UUID [CURSOR]
    delivery DELIVERY_UUID
    delivery-begin DELIVERY_UUID
    delivery-ack DELIVERY_UUID ATTEMPT_UUID RECEIPT_FILE
    delivery-uncertain DELIVERY_UUID ATTEMPT_UUID
    delivery-confirm-absent DELIVERY_UUID ATTEMPT_UUID
    memory-get WORKER_UUID KEY
    memory-put WORKER_UUID KEY EXPECTED_REVISION TEXT_FILE
    memory-history WORKER_UUID KEY [CURSOR]
    knowledge-grant SPACE_UUID WORKER_UUID EXPECTED_REVISION none|read|write
    knowledge-get SPACE_UUID KEY
    knowledge-put SPACE_UUID KEY EXPECTED_REVISION TEXT_FILE
    knowledge-history SPACE_UUID KEY [CURSOR]
    events [CURSOR]
    launch WORKER_UUID RECIPE_JSON_FILE
    launch-prepare WORKER_UUID RECIPE_JSON_FILE
    launch-dispatch EXECUTION_UUID
    launch-status EXECUTION_UUID
    launch-record EXECUTION_UUID
    launch-stop EXECUTION_UUID
    launches WORK_UUID [CURSOR]
    launch-confirm-stopped EXECUTION_UUID
    worker-policy WORKER_UUID
    active-launches [CURSOR]
    worker-configure WORKER_UUID EXPECTED_REVISION MAX_CONCURRENT RECIPE_JSON_FILE
    worker-enable WORKER_UUID EXPECTED_REVISION
    worker-pause WORKER_UUID EXPECTED_REVISION
    supervise [POLL_MILLISECONDS]
    supervisor-tick
    automations [CURSOR]
    automation AUTOMATION_UUID
    automation-configure AUTOMATION_UUID EXPECTED_REVISION SPEC_JSON_FILE
    automation-enable AUTOMATION_UUID EXPECTED_REVISION
    automation-pause AUTOMATION_UUID EXPECTED_REVISION
    automation-delete AUTOMATION_UUID EXPECTED_REVISION
    automation-run AUTOMATION_UUID EXPECTED_REVISION REQUEST_KEY
    automation-runs AUTOMATION_UUID [CURSOR]
    owner-rpc  (one bounded JSON request on stdin; trusted SSH/OS owner only)

    threading-controller agent REQUEST_JSON_FILE
    threading-controller agent-mcp
    Scoped agent tools use the execution credential/environment supplied by launch.
    Requests: {"context":{}}, {"questions":{"after":0}}, {"checkpoint":{"text":"..."}},
    {"ask":{"id":"QUESTION_UUID","text":"...","checkpoint":"..."}},
    {"finish":{"payload":"..."}}, {"memoryGet":{"key":"..."}},
    {"memoryPut":{"key":"...","expectedRevision":0,"content":"..."}}.
    After ask/finish, exit. The question/result is durable; no human waits on this process.

    Recipients: person:identifier,group:identifier. One authorized answer resolves a question.
    interrupt records a confirmed stopped execution; it does not kill its process.
    delivery-confirm-absent requires destination evidence; a timeout does not establish absence.
    launch-confirm-stopped requires independent proof the process stopped; missing inventory is insufficient.
    """
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] { print(help); return }
            let environment = ProcessInfo.processInfo.environment
            let agentMode = arguments.first == "agent" || arguments.first == "agent-mcp"
            let path: String
            let command: String
            if agentMode {
                guard arguments.count == (arguments.first == "agent-mcp" ? 1 : 2),
                      let database = environment["THREADING_CONTROLLER_DATABASE"] else {
                    throw ControllerError.invalidInput("agent_environment")
                }
                path = database; command = arguments.removeFirst()
            } else {
                guard arguments.count >= 3, arguments.removeFirst() == "--database" else {
                    throw ControllerError.invalidInput("usage; use --help")
                }
                path = arguments.removeFirst()
                command = arguments.removeFirst()
            }
            // A private existing directory is required; never chmod an arbitrary user directory.
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let attributes = try FileManager.default.attributesOfItem(atPath: parent)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ControllerError.invalidInput("database_directory_requires_owner_only_access")
            }
            umask(0o077)
            let store = try ControllerStore(path: path)
            if agentMode {
                guard let execution = environment["THREADING_EXECUTION_ID"],
                      let credential = environment["THREADING_EXECUTION_CREDENTIAL"] else { throw ControllerError.forbidden }
                if command == "agent-mcp" {
                    try await ControllerMCPServer.run(store: store, executionID: ExecutionID(execution), credential: credential)
                } else {
                    let request = try JSONDecoder().decode(ControllerAgentRequest.self, from: Data(file(arguments[0]).utf8))
                    try output(await store.agentRequest(executionID: ExecutionID(execution), credential: credential, request: request))
                }
            } else {
                try await execute(command, arguments, store, database: URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        } catch {
            let message = (error as? ControllerError)?.description ?? "controller_io_or_decode_error"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
    static func execute(_ command: String, _ args: [String], _ store: ControllerStore, database: String) async throws {
        func count(_ n: Int) throws { guard args.count == n else { throw ControllerError.invalidInput("arguments") } }
        func cursor(_ n: Int) throws -> Int64 {
            guard args.count == n || args.count == n + 1 else { throw ControllerError.invalidInput("arguments") }
            if args.count == n { return 0 }
            guard let value = Int64(args[n]), value >= 0 else { throw ControllerError.invalidInput("cursor") }
            return value
        }
        switch command {
        case "automations":
            let after = try cursor(0); try output(await store.automations(after: after))
        case "automation":
            try count(1); try output(await store.automation(AutomationID(args[0])))
        case "automation-configure":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            let spec = try JSONDecoder().decode(ControllerAutomationSpec.self, from: Data(file(args[2], maximum: automationSpecFileBytes).utf8))
            try output(await store.configureAutomation(AutomationID(args[0]), expectedRevision: revision, spec: spec))
        case "automation-enable", "automation-pause", "automation-delete":
            try count(2)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            if command == "automation-delete" {
                try output(await store.deleteAutomation(AutomationID(args[0]), expectedRevision: revision))
            } else {
                try output(await store.setAutomationEnabled(AutomationID(args[0]), expectedRevision: revision, enabled: command == "automation-enable"))
            }
        case "automation-run":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.runAutomation(AutomationID(args[0]), expectedRevision: revision, key: args[2]))
        case "automation-runs":
            let after = try cursor(1); try output(await store.automationRuns(AutomationID(args[0]), after: after))
        case "owner-rpc":
            try count(0); try await ControllerOwnerRPC.run(store: store, database: database)
        case "knowledge-grant":
            try count(4)
            guard let revision = Int(args[2]), let access = KnowledgeAccess(rawValue: args[3]) else { throw ControllerError.invalidInput("knowledge_grant") }
            try output(await store.grantKnowledge(spaceID: KnowledgeSpaceID(args[0]), workerID: WorkerID(args[1]), expectedRevision: revision, access: access))
        case "knowledge-get":
            try count(2); try output(await store.knowledge(spaceID: KnowledgeSpaceID(args[0]), key: args[1]))
        case "knowledge-put":
            try count(4)
            guard let revision = Int(args[2]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.putKnowledge(spaceID: KnowledgeSpaceID(args[0]), key: args[1], expectedRevision: revision, content: file(args[3])))
        case "knowledge-history":
            let after = try cursor(2); try output(await store.knowledgeHistory(spaceID: KnowledgeSpaceID(args[0]), key: args[1], after: after))
        case "active-launches":
            let after = try cursor(0); try output(await store.activeLaunchStatuses(after: after))
        case "worker-policy":
            try count(1); try output(await store.workerPolicy(WorkerID(args[0])))
        case "worker-configure":
            try count(4)
            guard let revision = Int(args[1]), let concurrent = Int(args[2]) else { throw ControllerError.invalidInput("worker_policy") }
            let spec = try JSONDecoder().decode(ControllerLaunchSpec.self, from: Data(file(args[3]).utf8))
            try output(await store.configureWorker(WorkerID(args[0]), expectedRevision: revision, maximumConcurrent: concurrent, spec: spec))
        case "worker-enable", "worker-pause":
            try count(2)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.setWorkerEnabled(WorkerID(args[0]), expectedRevision: revision, enabled: command == "worker-enable"))
        case "supervise", "supervisor-tick":
            guard args.count <= (command == "supervise" ? 1 : 0),
                  let interval = args.isEmpty ? 2_000 : Int(args[0]) else { throw ControllerError.invalidInput("supervisor_arguments") }
            try await ControllerSupervisorCommand.run(store: store, database: database, intervalMilliseconds: interval, once: command == "supervisor-tick")
        case "workers":
            let after = try cursor(0); try output(await store.workers(after: after))
        case "worker-add":
            try count(2); try output(await store.addWorker(id: WorkerID(args[0]), name: args[1]))
        case "enqueue":
            try count(3); try output(await store.enqueue(workerID: WorkerID(args[0]), key: args[1], instruction: file(args[2])))
        case "claim":
            try count(1); try output(await store.claim(workerID: WorkerID(args[0])))
        case "work":
            try count(1); try output(await store.work(WorkID(args[0])))
        case "works":
            let after = try cursor(1); try output(await store.works(workerID: WorkerID(args[0]), after: after))
        case "checkpoint":
            try count(2); try output(await store.checkpoint(executionID: ExecutionID(args[0]), text: file(args[1])))
        case "ask":
            try count(5); try output(await store.ask(executionID: ExecutionID(args[0]), id: QuestionID(args[1]),
                recipients: csv(args[2]), text: file(args[3]), checkpoint: file(args[4])))
        case "questions":
            let after = try cursor(1); try output(await store.questions(workID: WorkID(args[0]), after: after))
        case "question":
            try count(1); try output(await store.question(QuestionID(args[0])))
        case "open-questions":
            let after = try cursor(1); try output(await store.openQuestions(workerID: WorkerID(args[0]), after: after))
        case "pending-deliveries":
            let after = try cursor(0); try output(await store.pendingDeliveries(after: after))
        case "work-deliveries":
            let after = try cursor(1); try output(await store.workDeliveries(workID: WorkID(args[0]), after: after))
        case "answer":
            try count(4)
            let principal = try AnswerPrincipal(person: args[1], groups: Set(args[2] == "-" ? [] : csv(args[2])))
            try output(await store.answer(questionID: QuestionID(args[0]), principal: principal, text: file(args[3])))
        case "finish":
            try count(3); try output(await store.finish(executionID: ExecutionID(args[0]), destination: args[1], payload: file(args[2])))
        case "interrupt":
            try count(1); try output(await store.interrupt(executionID: ExecutionID(args[0])))
        case "retry":
            try count(1); try output(await store.retry(workID: WorkID(args[0])))
        case "deliveries":
            let after = try cursor(0); try output(await store.deliveries(after: after))
        case "delivery":
            try count(1); try output(await store.delivery(DeliveryID(args[0])))
        case "delivery-begin":
            try count(1); try output(await store.beginDelivery(DeliveryID(args[0])))
        case "delivery-ack":
            try count(3); try output(await store.acknowledgeDelivery(DeliveryID(args[0]), attemptID: DeliveryAttemptID(args[1]), receipt: file(args[2])))
        case "delivery-uncertain":
            try count(2); try output(await store.markDeliveryUncertain(DeliveryID(args[0]), attemptID: DeliveryAttemptID(args[1])))
        case "delivery-confirm-absent":
            try count(2); try output(await store.confirmDeliveryAbsent(DeliveryID(args[0]), attemptID: DeliveryAttemptID(args[1])))
        case "memory-get":
            try count(2); try output(await store.memory(workerID: WorkerID(args[0]), key: args[1]))
        case "memory-put":
            try count(4)
            guard let revision = Int(args[2]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.putMemory(workerID: WorkerID(args[0]), key: args[1], expectedRevision: revision, content: file(args[3])))
        case "memory-history":
            let after = try cursor(2); try output(await store.memoryHistory(workerID: WorkerID(args[0]), key: args[1], after: after))
        case "events":
            let after = try cursor(0); try output(await store.events(after: after))
        case "launch", "launch-prepare":
            try count(2)
            let spec = try JSONDecoder().decode(ControllerLaunchSpec.self, from: Data(file(args[1]).utf8))
            let launch = try await store.prepareLaunch(workerID: WorkerID(args[0]), spec: spec)
            if command == "launch", let launch {
                try output(ControllerLaunchStatus(await dispatch(store, launch.executionID, database)))
            } else { try output(launch.map(ControllerLaunchStatus.init)) }
        case "launch-dispatch":
            try count(1); try output(ControllerLaunchStatus(await dispatch(store, ExecutionID(args[0]), database)))
        case "launch-status":
            try count(1); try output(await ControllerPTYRuntime.observe(store: store, executionID: ExecutionID(args[0])))
        case "launch-record":
            try count(1); try output(ControllerLaunchStatus(await store.launch(ExecutionID(args[0]))))
        case "launch-stop":
            try count(1); try output(ControllerLaunchStatus(await ControllerPTYRuntime.stop(store: store, executionID: ExecutionID(args[0]))))
        case "launches":
            let after = try cursor(1); try output(await store.launchStatuses(workID: WorkID(args[0]), after: after))
        case "launch-confirm-stopped":
            try count(1); try output(ControllerLaunchStatus(await store.confirmLaunchStopped(ExecutionID(args[0]), exitStatus: nil)))
        default: throw ControllerError.invalidInput("unknown_command")
        }
    }
    static func dispatch(_ store: ControllerStore, _ id: ExecutionID, _ database: String) async throws -> ControllerLaunch {
        guard let binary = Bundle.main.executableURL?.path else { throw ControllerError.invalidInput("controller_executable") }
        return try await ControllerPTYRuntime.dispatch(store: store, executionID: id, database: database, controllerBinary: binary)
    }
    /// A spec file wraps a whole bounded instruction in JSON, whose escaping can grow it several
    /// times over; the instruction itself is still held to its own limit when the spec validates.
    static let automationSpecFileBytes = 204_800

    static func file(_ path: String, maximum: Int = 32_768) throws -> String {
        // Open nonblocking BEFORE fstat: opening a FIFO through Foundation could wait forever.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ControllerError.invalidInput("text_file") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ControllerError.invalidInput("regular_text_file_required")
        }
        var data = Data()
        while data.count <= maximum {
            guard let chunk = try handle.read(upToCount: maximum + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximum, let text = String(data: data, encoding: .utf8) else {
            throw ControllerError.invalidInput("text_file")
        }
        return text
    }
    static func csv(_ value: String) -> [String] { value.components(separatedBy: ",") }
    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
