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
    enqueue-request WORKER_UUID SOURCE_KEY INSTRUCTION_FILE REQUEST_FILE
    work-message WORK_UUID MESSAGE_UUID PERSON TEXT_FILE
    work-messages WORK_UUID [CURSOR]
    work-history WORK_UUID [CURSOR]
    work-cancel WORK_UUID
    worker-archive WORKER_UUID
    worker-reconcile WORKER_UUID EXPECTED_REVISION RECIPE_JSON_FILE
    worker-sources WORKER_UUID
    worker-set-sources WORKER_UUID EXPECTED_REVISION request,schedule,event
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
    memory-list WORKER_UUID [CURSOR]
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

    host
    host-set-name NAME
    mail-address WORKER_UUID
    mail-peer-set HOST_UUID EXPECTED_REVISION NAME PEER_JSON_FILE   ({"transport":[argv]|null,"push":bool,"pull":bool})
    mail-peers [CURSOR]
    mail-grant-set RECIPIENT_ADDRESS SENDER_PATTERN EXPECTED_REVISION none|notify|wake|ask normal|interrupt [CHAIN_TOKEN_BUDGET]
    mail-grants RECIPIENT_ADDRESS [CURSOR]
    mail-register SESSION_ADDRESS NAME
    mail-credential SESSION_ADDRESS   (the session's private mail-tool credential, for its launch environment)
    mail-credential-rotate SESSION_ADDRESS   (replaces it; the old credential stops working at once)
    mail-contact-set ADDRESS NAME|-
    mail-contacts [CURSOR]
    mailbox ADDRESS [CURSOR]
    mail-history ADDRESS [CURSOR]
    mail-sent ADDRESS
    mail-forward OLD | mail-forward-revision OLD
    mail-forward-set OLD NEW REVISION | mail-forward-clear OLD REVISION
    mail-move OLD NEW   (moves OLD's unacknowledged mail to NEW, keeping message ids)
    mail-get MESSAGE_UUID
    mail-send FROM_ADDRESS TO_ADDRESS MESSAGE_UUID TEXT_FILE [normal|interrupt [owner-admitted]]
    mail-ack ADDRESS MESSAGE_UUID
    mail-context-reset SESSION_ADDRESS   (a person started a new turn: the session's next mail starts a new chain)
    mail-notice ADDRESS post-tool-use|stop|session-start
    mail-outbound HOST_UUID
    mail-outbound-cancel MESSAGE_UUID   (stops delivering queued mail; it bounces to its sender as cancelled.
        Queued mail older than seven days bounces as expired on its own)
    mail-sync   (one exchange pass with configured peers)
    mail-rpc --peer HOST_UUID   (a peer's forced SSH command: one bounded JSON request on stdin)

    source-configure SOURCE_UUID EXPECTED_REVISION SPEC_JSON_FILE   (always paused, approval cleared)
    source-approve SOURCE_UUID EXPECTED_REVISION SHA256
    source-enable|source-pause|source-delete SOURCE_UUID EXPECTED_REVISION
    sources [CURSOR]
    source SOURCE_UUID
    source-events SOURCE_UUID [CURSOR]
    source-poll SOURCE_UUID   (one poll now; needs approval, not enabling)
    trigger-configure TRIGGER_UUID EXPECTED_REVISION SPEC_JSON_FILE   (always paused)
    trigger-enable|trigger-pause|trigger-delete TRIGGER_UUID EXPECTED_REVISION
    triggers SOURCE_UUID [CURSOR]
    trigger TRIGGER_UUID
    secret-set NAME TEXT_FILE   (owner-only file a source names; never read back)

    usage-collect EXECUTION_UUID   (write a stopped execution's receipt now)
    usage-receipt EXECUTION_UUID
    usage-receipts WORKER_UUID [CURSOR]
    usage-summary FROM_DAY THROUGH_DAY [CURSOR]   (UTC days, YYYY-MM-DD; daily cells per worker, account, model)
    worker-capacity WORKER_UUID
    worker-budget WORKER_UUID
    worker-budget-set WORKER_UUID EXPECTED_REVISION TOKENS_PER_DAY|none
    A recipe names its transcript with "usage": {"runtime":"claude|codex","home":"/abs","account":"name"}.
    Budget tokens are uncached input + cache writes + output; cached reads are excluded.
    A source is any executable on the probe contract (docs/feature-drafts/portable-trigger-sources.md).
    It runs with this account's authority, unsandboxed; approval pins its content hash.
    Addresses are HOST_UUID/worker/UUID or HOST_UUID/session/UUID. Sender patterns: an address,
    HOST_UUID/* or *. Grants live on the recipient's host; mail carries information, never authority.

    threading-controller agent REQUEST_JSON_FILE
    threading-controller agent-mcp
    threading-controller agent-notice post-tool-use|stop|session-start
    A session (not an execution) uses THREADING_MAILBOX_ADDRESS and THREADING_MAILBOX_CREDENTIAL
    instead, and agent-mcp then serves only the mail tools.
    The last is a hook command: it prints a host-authored mail notice as hook JSON, or nothing,
    and always exits 0 so a hook can never break the agent's turn.
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
            if arguments == ["--version"] {
                try output(["protocol": "1", "schema": "10", "capabilities": "work,mail,triggers,memory,usage,capacity,transcript-binding"])
                return
            }
            if arguments == ["--help"] { print(help); return }
            if arguments.first == "agent-notice" { await ControllerAgentNotice.run(arguments); return }
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
                if command == "agent-mcp", environment["THREADING_EXECUTION_ID"] == nil,
                   let address = environment["THREADING_MAILBOX_ADDRESS"],
                   let credential = environment["THREADING_MAILBOX_CREDENTIAL"] {
                    // A session's own mail tools, on the host that runs it.
                    try await ControllerMCPServer.run(store: store, caller: .mailbox(MailAddress(address), credential: credential))
                    return
                }
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
        case "host":
            try count(0); try output(await store.host())
        case "host-set-name":
            try count(1); try output(await store.setHostName(args[0]))
        case "mail-address":
            try count(1); try output(await store.mailAddress(worker: WorkerID(args[0])))
        case "mail-peer-set":
            try count(4)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            let settings = try JSONDecoder().decode(MailPeerSettings.self, from: Data(file(args[3]).utf8))
            try output(await store.setMailPeer(host: HostID(args[0]), expectedRevision: revision, name: args[2],
                                               transport: settings.transport, push: settings.push, pull: settings.pull))
        case "mail-peers":
            let after = try cursor(0); try output(await store.mailPeers(after: after))
        case "mail-grant-set":
            guard args.count == 5 || args.count == 6 else { throw ControllerError.invalidInput("arguments") }
            guard let revision = Int(args[2]), let priority = MailPriority(rawValue: args[4]) else { throw ControllerError.invalidInput("mail_grant") }
            let budget: Int64? = args.count == 6 ? Int64(args[5]) : nil
            if args.count == 6, budget == nil { throw ControllerError.invalidInput("chain_budget") }
            let mode: MailMode?
            if args[3] == "none" { mode = nil } else {
                guard let value = MailMode(rawValue: args[3]) else { throw ControllerError.invalidInput("mail_mode") }
                mode = value
            }
            try output(await store.setMailGrant(recipient: MailAddress(args[0]), sender: args[1], expectedRevision: revision,
                                                mode: mode, allowsInterrupt: priority == .interrupt, chainTokenBudget: budget))
        case "mail-grants":
            let after = try cursor(1); try output(await store.mailGrants(recipient: MailAddress(args[0]), after: after))
        case "mail-register":
            try count(2); try output(await store.registerMailbox(MailAddress(args[0]), name: args[1]))
        case "mail-credential":
            try count(1); try output(await store.mailboxCredential(MailAddress(args[0])))
        case "mail-credential-rotate":
            try count(1); try output(await store.rotateMailboxCredential(MailAddress(args[0])))
        case "mail-contact-set":
            try count(2); try output(await store.setMailContact(MailAddress(args[0]), name: args[1] == "-" ? nil : args[1]))
        case "mail-contacts":
            let after = try cursor(0); try output(await store.mailContacts(after: after))
        case "mailbox":
            let after = try cursor(1); try output(await store.inbox(MailAddress(args[0]), after: after))
        case "mail-forward":
            try count(1); try output(await store.mailForward(MailAddress(args[0])))
        case "mail-forward-set":
            try count(3)
            guard let revision = Int(args[2]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.setMailForward(from: MailAddress(args[0]), to: MailAddress(args[1]), expectedRevision: revision))
        case "mail-forward-clear":
            try count(2)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            try await store.clearMailForward(MailAddress(args[0]), expectedRevision: revision)
            try output(await store.mailForwardRevision(MailAddress(args[0])))
        case "mail-forward-revision":
            try count(1); try output(await store.mailForwardRevision(MailAddress(args[0])))
        case "mail-move":
            try count(2); try output(await store.moveMail(from: MailAddress(args[0]), to: MailAddress(args[1])))
        case "mail-sent":
            try count(1); try output(await store.recentSentMail(MailAddress(args[0])))
        case "mail-history":
            let after = try cursor(1); try output(await store.mailHistory(MailAddress(args[0]), after: after))
        case "mail-get":
            try count(1)
            guard let id = UUID(uuidString: args[0]) else { throw ControllerError.invalidInput("message_id") }
            try output(await store.mail(id))
        case "mail-send":
            guard (4...6).contains(args.count), let id = UUID(uuidString: args[2]) else { throw ControllerError.invalidInput("arguments") }
            guard let priority = MailPriority(rawValue: args.count >= 5 ? args[4] : "normal") else { throw ControllerError.invalidInput("priority") }
            // `owner-admitted`: the owner decided admission itself (the Mac's same-project rule)
            // for a recipient on this host; it never reaches another host's grants.
            guard args.count < 6 || args[5] == MailOwnerRPCWords.ownerAdmitted else { throw ControllerError.invalidInput("arguments") }
            try output(await store.sendMail(from: MailAddress(args[0]), to: MailAddress(args[1]), id: id, text: file(args[3]),
                                            replyTo: nil, priority: priority, ownerAdmitted: args.count == 6))
        case "mail-context-reset":
            try count(1); try await store.resetMailContext(MailAddress(args[0])); try output(["reset": args[0]])
        case "mail-ack":
            try count(2)
            guard let id = UUID(uuidString: args[1]) else { throw ControllerError.invalidInput("message_id") }
            try output(await store.acknowledgeMail(mailbox: MailAddress(args[0]), ids: [id]))
        case "mail-notice":
            try count(2)
            guard let event = MailNoticeEvent(rawValue: args[1]) else { throw ControllerError.invalidInput("event") }
            try output(await store.mailNotice(MailAddress(args[0]), event: event))
        case "mail-outbound":
            try count(1)
            try output(await store.outboundBatch(for: HostID(args[0])).envelopes)
        case "mail-outbound-cancel":
            try count(1)
            guard let id = UUID(uuidString: args[0]) else { throw ControllerError.invalidInput("message_id") }
            try output(await store.cancelOutboundMail(id))
        case "mail-sync":
            try count(0)
            try output(await ControllerMailSync.sync(store: store).0)
        case "source-configure", "trigger-configure":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            if command == "source-configure" {
                let spec = try JSONDecoder().decode(ControllerSourceSpec.self, from: Data(file(args[2]).utf8))
                try output(await store.configureSource(SourceID(args[0]), expectedRevision: revision, spec: spec))
            } else {
                let spec = try JSONDecoder().decode(ControllerTriggerSpec.self, from: Data(file(args[2]).utf8))
                try output(await store.configureTrigger(TriggerRuleID(args[0]), expectedRevision: revision, spec: spec))
            }
        case "source-approve":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            try output(await store.approveSource(SourceID(args[0]), expectedRevision: revision, hash: args[2]))
        case "source-enable", "source-pause", "source-delete":
            try count(2)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            if command == "source-delete" { try output(await store.deleteSource(SourceID(args[0]), expectedRevision: revision)) }
            else { try output(await store.setSourceEnabled(SourceID(args[0]), expectedRevision: revision, enabled: command == "source-enable")) }
        case "trigger-enable", "trigger-pause", "trigger-delete":
            try count(2)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            if command == "trigger-delete" { try output(await store.deleteTrigger(TriggerRuleID(args[0]), expectedRevision: revision)) }
            else { try output(await store.setTriggerEnabled(TriggerRuleID(args[0]), expectedRevision: revision, enabled: command == "trigger-enable")) }
        case "sources":
            let after = try cursor(0); try output(await store.sources(after: after))
        case "source":
            try count(1); try output(await store.source(SourceID(args[0])))
        case "source-events":
            let after = try cursor(1); try output(await store.sourceEvents(SourceID(args[0]), after: after))
        case "source-poll":
            try count(1); try output(await ControllerSourcePoller.poll(store: store, id: SourceID(args[0]), database: database, manual: true))
        case "triggers":
            let after = try cursor(1); try output(await store.triggers(source: SourceID(args[0]), after: after))
        case "trigger":
            try count(1); try output(await store.trigger(TriggerRuleID(args[0])))
        case "secret-set":
            try count(2)
            try ControllerSourcePoller.storeSecret(args[0], value: file(args[1], maximum: 16_384), database: database)
            try output(["stored": args[0]])
        case "usage-collect":
            try count(1); try output(await ControllerUsageCollector.collect(store: store, executionID: ExecutionID(args[0])))
        case "usage-receipt":
            try count(1); try output(await store.usageReceipt(ExecutionID(args[0])))
        case "usage-receipts":
            let after = try cursor(1); try output(await store.usageReceipts(worker: WorkerID(args[0]), after: after))
        case "usage-summary":
            let after = try cursor(2); try output(await store.usageSummary(from: args[0], through: args[1], after: after))
        case "worker-capacity":
            try count(1); try output(await store.workerCapacity(WorkerID(args[0])))
        case "worker-budget":
            try count(1); try output(await store.workerBudget(WorkerID(args[0])))
        case "worker-budget-set":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            let tokens: Int64? = args[2] == "none" ? nil : Int64(args[2])
            if args[2] != "none", tokens == nil { throw ControllerError.invalidInput("budget") }
            try output(await store.setWorkerBudget(WorkerID(args[0]), expectedRevision: revision, tokensPerDay: tokens))
        case "mail-rpc":
            try count(2)
            guard args[0] == "--peer" else { throw ControllerError.invalidInput("arguments") }
            let peer = try HostID(args[1])
            guard let input = try FileHandle.standardInput.read(upToCount: MailTransportLimits.requestBytes + 1),
                  input.count <= MailTransportLimits.requestBytes else { throw ControllerError.invalidInput("mail_rpc_size") }
            let request = try JSONDecoder().decode(MailRPCRequest.self, from: input)
            try output(await store.handleMailRPC(request, peer: peer))
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
        case "enqueue-request":
            try count(4); try output(await store.enqueue(workerID: WorkerID(args[0]), key: args[1], instruction: file(args[2]), request: file(args[3])))
        case "work-message":
            try count(4)
            guard let id = UUID(uuidString: args[1]) else { throw ControllerError.invalidInput("message_id") }
            try output(await store.message(workID: WorkID(args[0]), id: id, author: args[2], text: file(args[3])))
        case "work-messages":
            let after = try cursor(1); try output(await store.messages(workID: WorkID(args[0]), after: after))
        case "work-history":
            let after = try cursor(1); try output(await store.activities(workID: WorkID(args[0]), after: after))
        case "work-cancel":
            try count(1); try output(await store.cancel(workID: WorkID(args[0])))
        case "worker-archive":
            try count(1); try output(await store.archiveWorker(WorkerID(args[0])))
        case "worker-sources":
            try count(1); try output(await store.workerSources(WorkerID(args[0])))
        case "worker-set-sources":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            let sources = try csv(args[2]).map { text -> WorkSource in
                guard let source = WorkSource(rawValue: text) else { throw ControllerError.invalidInput("source") }; return source
            }
            try output(await store.setWorkerSources(WorkerID(args[0]), expectedRevision: revision, sources: sources))
        case "worker-reconcile":
            try count(3)
            guard let revision = Int(args[1]) else { throw ControllerError.invalidInput("revision") }
            let spec = try JSONDecoder().decode(ControllerLaunchSpec.self, from: Data(file(args[2]).utf8))
            try output(await store.reconcileWorker(WorkerID(args[0]), expectedRevision: revision, spec: spec))
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
        case "memory-list":
            let after = try cursor(1); try output(await store.memoryKeys(workerID: WorkerID(args[0]), after: after))
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
    struct MailPeerSettings: Decodable { let transport: [String]?; let push: Bool; let pull: Bool }
    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
