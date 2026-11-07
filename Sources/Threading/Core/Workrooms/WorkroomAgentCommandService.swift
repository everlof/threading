import Foundation
import ThreadingController

// MARK: - Workroom Agent Command Service

/// The Workrooms tools on this Mac's server. `AgentToolCoordinator` only forwards here.
///
/// **Scope is the session's project.** A room belongs to the project of the session that created
/// it (`scope` = `project:<id>`), and a session sees, asks in and opens only its own project's
/// rooms; another project's room answers exactly like one that does not exist.
///
/// **The asker is the session's own mailbox**, registered on this Mac's store, so an answer is
/// mail to it and every existing delivery path applies. The git context is read by the host from
/// the session's working directory, never taken from the model.
///
/// **Opening is the user's.** `workroom_request_opening` asks through `approveOpening`, which the
/// window layer answers with a native sheet; the web portal has no owner capability an agent
/// could drive.
@MainActor
final class WorkroomAgentCommandService {

    /// The user's answer to an opening, or nil when there is no window to ask in.
    typealias OpeningApprover = @MainActor (WorkroomOpeningFacts) async -> Bool?

    private let projects: ProjectStore
    private let mailbox: MacMailbox
    private let approveOpening: OpeningApprover
    private let revealSettings: @MainActor () -> Void

    init(projects: ProjectStore, mailbox: MacMailbox, approveOpening: @escaping OpeningApprover,
         revealSettings: @escaping @MainActor () -> Void) {
        self.projects = projects
        self.mailbox = mailbox
        self.approveOpening = approveOpening
        self.revealSettings = revealSettings
    }

    // MARK: - Tools

    func find(_ arguments: WorkroomFindArguments, for sessionID: SessionID,
              completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        run(sessionID, completion) { caller, store in
            let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            var rooms: [RoomRow] = []
            var cursor: Int64 = 0
            // Bounded: a project's rooms, a page at a time, at most `maximumRoomScan` examined.
            for _ in 0..<WorkroomToolDefaults.maximumRoomPages {
                let page = try await store.workrooms(scope: caller.scope, after: cursor, limit: 50)
                for room in page.items where query.isEmpty || room.title.lowercased().contains(query) {
                    rooms.append(try await Self.row(room, store: store))
                }
                guard page.items.count == 50 else { break }
                cursor = page.next
            }
            var people: [PersonRow] = []
            var after: Int64 = 0
            repeat {
                let page = try await store.workroomPeople(after: after, limit: 100)
                people += page.items.map(PersonRow.init)
                guard page.items.count == 100 else { break }
                after = page.next
            } while people.count < WorkroomToolDefaults.maximumPeople
            return .success(await Self.json(FindResult(rooms: rooms, people: people)))
        }
    }

    func create(_ arguments: WorkroomCreateArguments, for sessionID: SessionID,
                completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        guard let title = Self.nonEmpty(arguments.title) else { return completion(.failure("title is required.")) }
        let links: [ParsedLink]
        do { links = try (arguments.links ?? []).prefix(WorkroomToolDefaults.maximumLinks).map(Self.parse) } catch {
            return completion(.failure(Self.words(for: error)))
        }
        guard (arguments.links ?? []).count <= WorkroomToolDefaults.maximumLinks else {
            return completion(.failure("At most \(WorkroomToolDefaults.maximumLinks) links."))
        }
        run(sessionID, completion) { caller, store in
            let room = try await store.createWorkroom(id: WorkroomID(), scope: caller.scope, title: title,
                                                      purpose: arguments.purpose ?? "", createdBy: caller.address)
            for link in links {
                _ = try await store.addWorkroomLink(id: WorkroomLinkID(), roomID: room.id, kind: link.kind,
                                                    provider: link.provider, target: link.target, label: link.label,
                                                    relationship: link.relationship, url: link.url)
            }
            NotificationCenter.default.post(WorkroomStatusDidChange())
            return .success("""
                Created private workroom \(room.id) “\(title)”. Nobody outside this Mac can see it. Ask in it with \
                workroom_ask; when the user wants the person to answer, call workroom_request_opening.
                """)
        }
    }

    func context(_ arguments: WorkroomRoomArguments, for sessionID: SessionID,
                 completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        run(sessionID, completion) { caller, store in
            let room = try await Self.room(arguments.roomID, caller: caller, store: store)
            let summary = try await store.workroomSummary(room.id)
            let links = try await store.workroomLinks(roomID: room.id).items.map(LinkRow.init)
            var counts: [String: Int] = [:]
            var after: Int64 = 0
            var historyComplete = false
            for _ in 0..<WorkroomToolDefaults.maximumQuestionPages {
                let page = try await store.workroomAsks(roomID: room.id, after: after, limit: 50)
                for question in page.items { counts[question.state.rawValue, default: 0] += 1 }
                if page.items.isEmpty { historyComplete = true; break }
                after = page.next
            }
            if !historyComplete {
                historyComplete = try await store.workroomAsks(roomID: room.id, after: after, limit: 1).items.isEmpty
            }
            counts[WorkroomQuestionState.open.rawValue] = summary.openQuestions
            return .success(await Self.json(ContextResult(
                id: room.id.description, title: room.title, purpose: room.purpose,
                createdByThisSession: room.createdBy == caller.address.description,
                state: Self.state(summary.publication), openUntil: summary.publication.expiresAt,
                people: summary.people.map(PersonRow.init), links: links, questions: counts,
                questionHistoryComplete: historyComplete
            )))
        }
    }

    func ask(_ arguments: WorkroomAskArguments, for sessionID: SessionID,
             completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        guard let roomText = arguments.roomID, let personHandle = Self.nonEmpty(arguments.person),
              let title = Self.nonEmpty(arguments.title), let prompt = Self.nonEmpty(arguments.prompt) else {
            return completion(.failure("room_id, person, title and prompt are required."))
        }
        let id: QuestionID
        if let raw = Self.nonEmpty(arguments.id) {
            guard let parsed = try? QuestionID(raw) else { return completion(.failure("id must be a UUID you chose, or omitted.")) }
            id = parsed
        } else {
            id = QuestionID()
        }
        let form: WorkroomForm
        let evidence: [WorkroomEvidence]
        do {
            form = WorkroomForm(fields: try (arguments.fields ?? []).map(Self.field))
            evidence = (arguments.evidence ?? []).map {
                WorkroomEvidence(label: $0.label ?? "", text: $0.text ?? "", source: Self.nonEmpty($0.source))
            }
        } catch {
            return completion(.failure(Self.words(for: error)))
        }
        if let base = arguments.baseRef, !WorkroomGitContextReader.isSafeRef(base) {
            return completion(.failure("base_ref must be a branch or commit name."))
        }
        run(sessionID, completion) { caller, store in
            let room = try await Self.room(roomText, caller: caller, store: store)
            guard let person = try await store.workroomPerson(handle: personHandle) else {
                return .failure("""
                    No person “\(personHandle)”. Use a handle from workroom_find, or propose them with \
                    workroom_request_opening when the user wants to.
                    """)
            }
            let language = Self.nonEmpty(arguments.language) ?? person.language
            var gitContext: WorkroomGitContext?
            var gitNote = "No git checkout was found, so no git context was recorded."
            if let directory = caller.directory {
                switch await WorkroomGitContextReader.capture(directory: directory, base: arguments.baseRef) {
                case .success(let context):
                    gitContext = context
                    gitNote = "Recorded \(context.headRef ?? String(context.headCommit.prefix(12))) against "
                        + "\(context.baseRef): \(context.commits.count) commits, \(context.changedPathCount) changed paths."
                case .failure(.unknownBase(let base)):
                    return .failure("base_ref “\(base)” does not name a commit in this checkout.")
                case .failure(.notARepository):
                    break
                }
            }
            let draft = WorkroomQuestionDraft(title: title, prompt: prompt, background: arguments.background ?? "",
                                              language: language, form: form, evidence: evidence)
            let question = try await store.askWorkroom(id: id, roomID: room.id, scope: caller.scope, asker: caller.address,
                                                       personHandle: person.handle, draft: draft, gitContext: gitContext)
            NotificationCenter.default.post(WorkroomStatusDidChange())
            let publication = try await store.workroomPublication(room.id)
            let access = try await store.workroomAccess(room.id)
            let visible = publication.isOpen() && access.contains { $0.person == person.id && $0.state == .granted }
            if visible { await WorkroomAppNotifier.notify(.asked, about: question) }
            let waiting = visible
                ? "\(person.name) can see it now."
                : "It waits, invisible, until the user opens this room to \(person.name) (workroom_request_opening)."
            return .success("""
                Asked question \(question.id) “\(title)” of \(person.name) (\(language)). \(waiting) \(gitNote) \
                Keep working: the answer arrives as mail, and workroom_questions with this question_id reads it.
                """)
        }
    }

    func questions(_ arguments: WorkroomQuestionsArguments, for sessionID: SessionID,
                   completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        run(sessionID, completion) { caller, store in
            if let raw = Self.nonEmpty(arguments.questionID) {
                guard let id = try? QuestionID(raw) else { return .failure("question_id must be a question id.") }
                let detail = try await store.workroomQuestionDetail(id)
                let room = try await store.workroom(detail.question.roomID)
                guard room.scope == caller.scope else { throw ControllerError.notFound }
                return .success(await Self.json(detail))
            }
            let page: ControllerPage<WorkroomQuestion>
            if let roomText = arguments.roomID {
                let room = try await Self.room(roomText, caller: caller, store: store)
                page = try await store.workroomAsks(roomID: room.id, after: max(arguments.after ?? 0, 0), limit: 20)
            } else {
                page = try await store.workroomAsks(asker: caller.address, after: max(arguments.after ?? 0, 0), limit: 20)
            }
            var items: [QuestionRow] = []
            for question in page.items {
                let latest = question.answerRevision > 0
                    ? try await store.workroomQuestionDetail(question.id).answers.last : nil
                items.append(QuestionRow(question, personName: try await store.workroomPerson(question.person).name,
                                         latest: latest))
            }
            return .success(await Self.json(QuestionsResult(items: items, next: page.items.count == 20 ? page.next : nil)))
        }
    }

    func respond(_ arguments: WorkroomRespondArguments, for sessionID: SessionID,
                 completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        guard let raw = arguments.questionID, let id = try? QuestionID(raw) else {
            return completion(.failure("question_id is required."))
        }
        run(sessionID, completion) { caller, store in
            switch arguments.action {
            // `clarify` is the earlier name, kept so a session that learned it still works.
            case "message", "clarify":
                guard let text = Self.nonEmpty(arguments.text) else { return .failure("text is required for a message.") }
                _ = try await store.respondToWorkroomQuestion(id, asker: caller.address, text: text)
                NotificationCenter.default.post(WorkroomStatusDidChange())
                await WorkroomAppNotifier.notify(.agentMessage(text: text),
                                                 about: try await store.workroomQuestionDetail(id).question)
                return .success("""
                    Sent. It is in the question's conversation, and the person's inbox shows it as a new \
                    message; an open page shows it within seconds. Their reply arrives as mail.
                    """)
            case "withdraw":
                _ = try await store.withdrawWorkroomQuestion(id, asker: caller.address, reason: arguments.text ?? "")
                NotificationCenter.default.post(WorkroomStatusDidChange())
                return .success("Withdrew question \(id). The person sees it as withdrawn.")
            default:
                return .failure("action must be message or withdraw.")
            }
        }
    }

    func setLanguage(_ arguments: WorkroomSetLanguageArguments, for sessionID: SessionID,
                     completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        guard let handle = Self.nonEmpty(arguments.person), let language = Self.nonEmpty(arguments.language) else {
            return completion(.failure("person and language are required."))
        }
        run(sessionID, completion) { _, store in
            guard let person = try await store.workroomPerson(handle: handle) else { return .failure("No person “\(handle)”.") }
            do {
                let updated = try await store.setWorkroomPersonLanguage(person.id, language: language, source: .agent)
                return .success("\(updated.name) is now addressed in \(updated.language). Write your next questions in it.")
            } catch ControllerError.conflict {
                return .failure("\(person.name) chose \(person.language) themselves in the portal; keep writing in it.")
            }
        }
    }

    func requestOpening(_ arguments: WorkroomRequestOpeningArguments, for sessionID: SessionID,
                        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        guard let roomText = arguments.roomID, let handle = Self.nonEmpty(arguments.person),
              let reason = Self.nonEmpty(arguments.reason) else {
            return completion(.failure("room_id, person and reason are required."))
        }
        let days = arguments.days ?? WorkroomToolDefaults.defaultOpenDays
        guard (1...WorkroomToolDefaults.maximumOpenDays).contains(days) else {
            return completion(.failure("days must be 1 to \(WorkroomToolDefaults.maximumOpenDays)."))
        }
        run(sessionID, completion) { caller, store in
            let room = try await Self.room(roomText, caller: caller, store: store)
            let existing = try await store.workroomPerson(handle: handle)
            var proposed: (name: String, language: String, email: String?)?
            if existing == nil {
                guard let name = Self.nonEmpty(arguments.name), let language = Self.nonEmpty(arguments.language) else {
                    return .failure("No person “\(handle)”. To propose a new one, give name and language too.")
                }
                try ControllerStore.validatePerson(handle: handle, name: name, language: language,
                                                   email: Self.nonEmpty(arguments.email))
                proposed = (name, language, Self.nonEmpty(arguments.email))
            }
            let key = "\(room.id)|\(handle)"
            if let refusal = WorkroomOpeningLedger.shared.admit(key) { return .failure(refusal) }
            let openQuestions = try await Self.openQuestionCount(room: room.id, person: existing?.id, store: store)
            let name = existing?.name ?? proposed?.name ?? handle
            // The owner is granted beside anyone a room is opened to, so a tied session's
            // questions for the owner can be answered from the same portal.
            var owner: WorkroomPerson?
            if let ownerHandle = AppSettings.shared.workroomOwnerHandle, ownerHandle != handle {
                owner = try await store.workroomPerson(handle: ownerHandle)
            }
            let answer = await self.approveOpening(WorkroomOpeningFacts(
                roomTitle: room.title, projectName: caller.projectName, personName: name, handle: handle,
                language: existing?.language ?? proposed?.language ?? "", proposedByAgent: existing == nil,
                openQuestions: openQuestions, provider: AppSettings.shared.workroomTunnelProvider,
                domain: AppSettings.shared.workroomNgrokDomain, days: days, reason: reason, ownerName: owner?.name
            ))
            guard let approved = answer else {
                WorkroomOpeningLedger.shared.finish(key, approved: false)
                return .failure("No Threading window is available to ask the user.")
            }
            WorkroomOpeningLedger.shared.finish(key, approved: approved)
            guard approved else { return .failure("The user did not open the room. Do not ask again unless they ask you to.") }
            let person: WorkroomPerson
            if let existing { person = existing } else if let proposed {
                person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: handle, name: proposed.name,
                                                           language: proposed.language, email: proposed.email)
            } else { throw ControllerError.notFound }
            _ = try await store.openWorkroom(room.id, people: [person.id] + (owner.map { [$0.id] } ?? []),
                                             expiresAt: Date().addingTimeInterval(TimeInterval(days) * 86_400))
            await WorkroomAppNotifier.roomOpened(room.id, to: person.id)
            WorkroomHost.shared.refresh()
            NotificationCenter.default.post(WorkroomStatusDidChange())
            self.revealSettings()
            return .success("""
                The user opened “\(room.title)” to \(person.name) for \(days) days. The user sends them their link \
                from Settings ▸ Workrooms; you never see it. Their answers arrive as mail.
                """)
        }
    }

    // MARK: - Running

    struct Caller {
        let scope: String
        let projectName: String
        let address: MailAddress
        let directory: URL?
    }

    private func run(_ sessionID: SessionID, _ completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void,
                     _ body: @escaping @MainActor (Caller, ControllerStore) async throws -> MCPToolResult) {
        guard !projects.sessionRunsOnRemoteHost(sessionID), let project = projects.project(forSessionID: sessionID) else {
            return completion(.failure("Workrooms are available to sessions that run on this Mac."))
        }
        let name = MailAgentCommandService.mailTitle(of: sessionID, projects: projects)
        let directory = projects.workingDirectory(forSessionID: sessionID).map { URL(fileURLWithPath: $0) }
        let mailbox = self.mailbox
        Task { @MainActor in
            do {
                let address = try await mailbox.register(sessionID, name: name)
                let store = try await mailbox.controllerStore()
                let caller = Caller(scope: Self.scope(for: project), projectName: project.name,
                                    address: address, directory: directory)
                completion(try await body(caller, store))
            } catch {
                completion(.failure(Self.words(for: error)))
            }
        }
    }

    // MARK: - Helpers

    /// Which rooms a session reaches: its repository's, so every checkout and worktree of one
    /// repository shares them and a chat that moves to another checkout keeps its rooms. A
    /// folder Git has never verified as a repository keeps rooms of its own.
    static func scope(for project: Project) -> String {
        if let repository = project.lastKnownRepositoryIdentity {
            return WorkroomScope.repositoryPrefix + repository
        }
        return legacyScope(for: project.id)
    }

    /// The scope rooms were created in before they belonged to a repository.
    static func legacyScope(for project: ProjectID) -> String { WorkroomScope.projectPrefix + "\(project)" }

    private static func room(_ text: String?, caller: Caller, store: ControllerStore) async throws -> LinkedWorkroom {
        guard let text, let id = try? WorkroomID(text) else { throw ControllerError.invalidInput("room_id") }
        let room = try await store.workroom(id)
        guard room.scope == caller.scope else { throw ControllerError.notFound }
        return room
    }

    private static func row(_ room: LinkedWorkroom, store: ControllerStore) async throws -> RoomRow {
        let summary = try await store.workroomSummary(room.id)
        return RoomRow(id: room.id.description, title: room.title, state: state(summary.publication),
                       openUntil: summary.publication.expiresAt, openQuestions: summary.openQuestions,
                       people: summary.people.map(\.handle))
    }

    private static func openQuestionCount(room: WorkroomID, person: WorkroomPersonID?, store: ControllerStore) async throws -> Int {
        guard let person else { return 0 }
        return try await store.openWorkroomQuestionCount(room, person: person)
    }

    static func state(_ publication: WorkroomPublication) -> String {
        switch publication.state {
        case .private: return "private"
        case .closed: return "closed"
        case .open: return publication.isOpen() ? "open" : "expired"
        }
    }

    struct ParsedLink {
        let kind: WorkroomLinkKind
        let provider: String
        let target: String
        let label: String
        let relationship: WorkroomLinkRelationship
        let url: String?
    }

    static func parse(_ link: WorkroomLinkArgument) throws -> ParsedLink {
        let kinds: [String: WorkroomLinkKind] = [
            "issue": .issue, "pull_request": .pullRequest, "pullrequest": .pullRequest, "support_case": .supportCase,
            "document": .document, "repository": .repository, "url": .url, "other": .other
        ]
        guard let kind = kinds[(link.kind ?? "").lowercased()],
              let provider = nonEmpty(link.provider), let target = nonEmpty(link.target), let label = nonEmpty(link.label),
              let relationship = WorkroomLinkRelationship(rawValue: (nonEmpty(link.relationship) ?? "context").lowercased())
        else { throw ControllerError.invalidInput("links") }
        return ParsedLink(kind: kind, provider: provider, target: target, label: label, relationship: relationship,
                          url: nonEmpty(link.url))
    }

    static func field(_ argument: WorkroomFieldArgument) throws -> WorkroomField {
        let kinds: [String: WorkroomFieldKind] = [
            "single_choice": .singleChoice, "multi_choice": .multiChoice, "yes_no": .yesNo, "number": .number,
            "short_text": .shortText, "long_text": .longText, "confirm": .confirm
        ]
        let spelled = (argument.kind ?? "").lowercased()
        guard let kind = kinds[spelled] ?? WorkroomFieldKind(rawValue: argument.kind ?? "") else {
            throw ControllerError.invalidInput("field_kind")
        }
        return WorkroomField(
            id: argument.id ?? "", kind: kind, label: argument.label ?? "", help: nonEmpty(argument.help),
            required: argument.required ?? true,
            options: argument.options?.map { WorkroomOption(id: $0.id ?? "", label: $0.label ?? "", consequence: nonEmpty($0.consequence)) },
            unit: nonEmpty(argument.unit), minimum: argument.minimum, maximum: argument.maximum
        )
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What an agent is told, in words it can act on.
    static func words(for error: any Error) -> String {
        if let failure = error as? MacMailbox.Failure {
            switch failure {
            case .unavailable(let reason): return "Workrooms are unavailable on this Mac right now (\(reason))."
            case .refused(let error): return words(for: error)
            }
        }
        guard let error = error as? ControllerError else { return error.localizedDescription }
        switch error {
        case .notFound: return "No such room or question in this project."
        case .conflict: return "That id was already used with different content, or the question is closed."
        case .forbidden: return "Not allowed."
        case .invalidInput(let field):
            switch field {
            case "room_full": return "This room already has \(WorkroomLimits.openQuestionsPerRoom) open questions. Answer, decline or withdraw an open question to make room; waiting does not free capacity."
            case "language": return "language must be a BCP-47 tag such as sv or en-GB."
            case "handle": return "person must be lowercase letters, digits, . - or _."
            case "field_kind": return "Each field's kind must be single_choice, multi_choice, yes_no, number, short_text, long_text or confirm."
            case "field_options": return "single_choice and multi_choice need 2 to 8 options; other kinds take none."
            case "form_fields": return "At most \(WorkroomLimits.fields) fields."
            case "evidence": return "At most \(WorkroomLimits.evidence) evidence items."
            default: return "\(field) is not valid; check its length and shape."
            }
        default: return error.description
        }
    }

    /// Encoded on a worker: a question's record is bounded but not frame-cheap.
    static func json<T: Encodable & Sendable>(_ value: T) async -> String {
        await Task.detached(priority: .userInitiated) { encoded(value) }.value
    }

    nonisolated private static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Projections

    struct RoomRow: Encodable, Sendable {
        let id: String
        let title: String
        let state: String
        let openUntil: String?
        let openQuestions: Int
        let people: [String]
    }

    struct PersonRow: Encodable, Sendable {
        let handle: String
        let name: String
        let language: String

        init(_ person: WorkroomPerson) {
            handle = person.handle
            name = person.name
            language = person.language
        }
    }

    struct LinkRow: Encodable, Sendable {
        let kind: String
        let provider: String
        let target: String
        let label: String
        let relationship: String
        let url: String?

        init(_ link: WorkroomLink) {
            kind = link.kind.rawValue
            provider = link.provider
            target = link.target
            label = link.label
            relationship = link.relationship.rawValue
            url = link.url
        }
    }

    struct FindResult: Encodable, Sendable {
        let rooms: [RoomRow]
        let people: [PersonRow]
    }

    struct ContextResult: Encodable, Sendable {
        let id: String
        let title: String
        let purpose: String
        let createdByThisSession: Bool
        let state: String
        let openUntil: String?
        let people: [PersonRow]
        let links: [LinkRow]
        let questions: [String: Int]
        let questionHistoryComplete: Bool
    }

    struct QuestionRow: Encodable, Sendable {
        let id: String
        let roomId: String
        let title: String
        let person: String
        let state: String
        let askedAt: String
        let answerRevisions: Int
        let latestAnswer: WorkroomAnswer?
        let notes: Int

        init(_ question: WorkroomQuestion, personName: String, latest: WorkroomAnswer?) {
            id = question.id.description
            roomId = question.roomID.description
            title = question.draft.title
            person = personName
            state = question.state.rawValue
            askedAt = question.askedAt
            answerRevisions = question.answerRevision
            latestAnswer = latest
            notes = question.noteCount
        }
    }

    struct QuestionsResult: Encodable, Sendable {
        let items: [QuestionRow]
        let next: Int64?
    }
}

/// What the user is shown before a room opens to someone outside this Mac.
struct WorkroomOpeningFacts: Sendable {
    let roomTitle: String
    let projectName: String
    let personName: String
    let handle: String
    let language: String
    let proposedByAgent: Bool
    let openQuestions: Int
    let provider: WorkroomTunnelProvider
    let domain: String?
    let days: Int
    let reason: String
    /// The owner's own person, granted beside them, or nil when none is set or it is them.
    var ownerName: String? = nil
}

/// One proposal in front of the user per room and person, and no re-asking straight after a no.
@MainActor
final class WorkroomOpeningLedger {
    static let shared = WorkroomOpeningLedger()

    private var pending: Set<String> = []
    private var declined: [String: Date] = [:]

    /// Nil to proceed; otherwise the refusal the agent is given.
    func admit(_ key: String, now: Date = Date()) -> String? {
        if pending.contains(key) { return "The user is already being asked to open this room to that person." }
        if let at = declined[key], now.timeIntervalSince(at) < WorkroomToolDefaults.declineCooldown {
            return "The user just declined to open this room to that person. Do not ask again unless they ask you to."
        }
        pending.insert(key)
        return nil
    }

    func finish(_ key: String, approved: Bool, now: Date = Date()) {
        pending.remove(key)
        if approved { declined[key] = nil } else { declined[key] = now }
    }
}

enum WorkroomToolDefaults {
    static let maximumRoomPages = 4
    static let maximumQuestionPages = 4
    static let maximumPeople = 200
    static let maximumLinks = 20
    static let defaultOpenDays = 14
    static let maximumOpenDays = 60
    static let declineCooldown: TimeInterval = 15 * 60
}

enum WorkroomScope {
    static let repositoryPrefix = "repository:"
    static let projectPrefix = "project:"
}

/// Rooms created in one checkout before rooms belonged to a repository move to their
/// repository's scope, once each, as soon as the checkout's repository is known. Bounded by the
/// same room scan Settings uses; a room whose project is gone or not a repository stays put.
@MainActor
enum WorkroomScopeMigration {
    static func run(projects: ProjectStore = .shared) async {
        guard let store = try? await MacMailbox.shared.controllerStore() else { return }
        var after: Int64 = 0
        for _ in 0..<WorkroomsPageDefaults.roomPages {
            guard let page = try? await store.allWorkrooms(after: after, limit: 50) else { return }
            for room in page.items where room.scope.hasPrefix(WorkroomScope.projectPrefix) {
                guard let id = UUID(uuidString: String(room.scope.dropFirst(WorkroomScope.projectPrefix.count))),
                      let project = projects.project(withID: ProjectID(id)),
                      project.lastKnownRepositoryIdentity != nil else { continue }
                let target = WorkroomAgentCommandService.scope(for: project)
                if (try? await store.rescopeWorkroom(room.id, from: room.scope, to: target)) == true {
                    ThreadingLogger.app.info("Workroom moved to its repository's scope")
                }
            }
            guard page.items.count == 50 else { return }
            after = page.next
        }
    }
}
