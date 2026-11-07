import Foundation
import ThreadingController
import ThreadingRemoteKit
import ThreadingWorkroomPortal

/// Who is asking through the remote door, as far as Linked Workrooms is concerned.
///
/// A workroom membership answers as its one person and reaches nothing else. A paired owner
/// device reads every question and may comment; it never answers or declines for a person. Any
/// other authorization — a shared chat, a shared terminal — is not a workroom viewer at all.
enum WorkroomRemoteViewer: Equatable, Sendable {
    case participant(WorkroomPersonID)
    case owner(canComment: Bool)

    @MainActor
    init?(_ authorization: RemoteAuthorization, workroomsEnabled: Bool = AppSettings.shared.workroomsEnabled) {
        guard workroomsEnabled else { return nil }
        if let person = authorization.scope.workroomPerson {
            self = .participant(person)
        } else if authorization.principal == .ownerDevice, authorization.scope == .allSessions {
            self = .owner(canComment: authorization.canManageHost)
        } else {
            return nil
        }
    }

    var wire: RemoteWorkroomViewer {
        switch self {
        case .participant: return .participant
        case .owner: return .owner
        }
    }
}

/// Why an authenticated workroom request is turned away before it is read.
enum RemoteWorkroomRefusal: Error {
    /// The capability was revoked while the request waited for the main actor.
    case revoked
}

/// One `workroom/…` request, parsed — its body decoded too — on the server's queue before
/// anything is read or the main actor is asked. Anything else is a 404.
enum WorkroomRemoteRoute: Equatable, Sendable {
    case inbox(replies: Int64, open: Int64, recent: Int64)
    case state
    case question(QuestionID)
    case answer(QuestionID, RemoteWorkroomAnswerRequestDTO)
    case message(QuestionID, String)
    case decline(QuestionID, String)

    /// `subpath` is what follows `/api/workroom/`; `query` reads one query value. A write whose
    /// body does not decode is no request at all.
    init?(method: String, subpath: String, query: (String) -> String?, body: Data = Data()) {
        let parts = subpath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch (method, parts.count) {
        case ("GET", 1) where parts[0] == RemoteWorkroomPath.inbox:
            func cursor(_ key: RemoteWorkroomPath.Cursor) -> Int64? {
                guard let raw = query(key.rawValue), !raw.isEmpty else { return 0 }
                guard let value = Int64(raw), value >= 0 else { return nil }
                return value
            }
            guard let replies = cursor(.replies), let open = cursor(.open), let recent = cursor(.recent) else { return nil }
            self = .inbox(replies: replies, open: open, recent: recent)
        case ("GET", 1) where parts[0] == RemoteWorkroomPath.state:
            self = .state
        case ("GET", 2) where parts[0] == RemoteWorkroomPath.question:
            guard let id = try? QuestionID(parts[1]) else { return nil }
            self = .question(id)
        case ("POST", 3) where parts[0] == RemoteWorkroomPath.question:
            guard let id = try? QuestionID(parts[1]), let action = RemoteWorkroomPath.Action(rawValue: parts[2]) else {
                return nil
            }
            let decoder = JSONDecoder()
            switch action {
            case .answer:
                guard let request = try? decoder.decode(RemoteWorkroomAnswerRequestDTO.self, from: body) else { return nil }
                self = .answer(id, request)
            case .message:
                guard let request = try? decoder.decode(RemoteWorkroomMessageRequestDTO.self, from: body) else { return nil }
                self = .message(id, request.text)
            case .decline:
                guard let request = try? decoder.decode(RemoteWorkroomMessageRequestDTO.self, from: body) else { return nil }
                self = .decline(id, request.text)
            }
        default:
            return nil
        }
    }

    var isMutation: Bool {
        switch self {
        case .answer, .message, .decline: return true
        case .inbox, .state, .question: return false
        }
    }
}

/// The Linked Workroom routes of the remote door: the iPhone app's view of the same records the
/// portal serves, through the same participant operations, so an answer from either is the same
/// answer and reaches the asking session the same way.
///
/// Not main-actor: the store is its own actor, and projecting and encoding a question is work for
/// the caller's executor. Only delivery and settings hop to the main actor, briefly.
enum WorkroomRemoteBridge {
    static func respond(to route: WorkroomRemoteRoute, viewer: WorkroomRemoteViewer) async -> HTTPResponse {
        do {
            let store = try await MacMailbox.shared.controllerStore()
            switch (route, viewer) {
            case let (.inbox(replies, open, recent), .participant(person)):
                return RemoteRouter.json(try await participantInbox(store, person: person,
                                                                    cursors: (replies, open, recent)))
            case let (.inbox(_, _, recent), .owner):
                return RemoteRouter.json(try await ownerInbox(store, before: recent))
            case let (.state, .participant(person)):
                return RemoteRouter.json(try await participantState(store, person: person))
            case (.state, .owner):
                return RemoteRouter.json(try await ownerInbox(store, before: 0).state)
            case let (.question(id), _):
                return RemoteRouter.json(try await question(store, id: id, viewer: viewer))
            case (.answer, _), (.message, _), (.decline, _):
                return try await perform(route, viewer: viewer, store: store)
            }
        } catch ControllerError.notFound {
            return RemoteRouter.error(404, "Not Found")
        } catch ControllerError.conflict {
            return RemoteRouter.error(409, "Conflict")
        } catch let ControllerError.invalidInput(field) {
            return RemoteRouter.error(400, "Bad Request", detail: field)
        } catch {
            ThreadingLogger.remote.error(
                "Remote workroom request failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return RemoteRouter.error(503, "Service Unavailable")
        }
    }

    // MARK: - Writes

    private static func perform(_ route: WorkroomRemoteRoute, viewer: WorkroomRemoteViewer,
                                store: ControllerStore) async throws -> HTTPResponse {
        let participant = WorkroomPortalBackend()
        let id: QuestionID
        switch (route, viewer) {
        case let (.answer(question, request), .participant(person)):
            id = question
            let detail = try await participant.question(person: person, id: id)
            // The form decides which values count, exactly as the portal's post does: unknown
            // fields are dropped and blank values removed before the store validates the rest.
            let answers = detail.question.draft.form.fields.compactMap { field -> WorkroomFieldAnswer? in
                let values = (request.answers.first { $0.field == field.id }?.values ?? [])
                    .map { field.kind == .longText ? $0 : $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return values.isEmpty ? nil : WorkroomFieldAnswer(field: field.id, values: values)
            }
            _ = try await participant.answer(person: person, id: id, answers: answers, comment: request.comment)
        case let (.message(question, text), .participant(person)):
            id = question
            _ = try await participant.clarify(person: person, id: id, text: text)
        case let (.decline(question, reason), .participant(person)):
            id = question
            _ = try await participant.decline(person: person, id: id, reason: reason)
        case let (.message(question, text), .owner(canComment: true)):
            id = question
            let name = try await ownerName(store)
            _ = try await store.ownerCommentOnWorkroomQuestion(id, ownerName: name, text: text)
            let commented = try await store.workroomQuestionDetail(id).question
            await MainActor.run {
                if commented.asker.kind == .session {
                    MacMailDelivery.shared.arrived(for: SessionID(commented.asker.id), priority: .normal)
                }
                NotificationCenter.default.post(WorkroomStatusDidChange())
            }
            await WorkroomAppNotifier.notify(.ownerComment(name: name, text: text), about: commented)
        default:
            // The owner never answers or declines for a person, and a view-only owner device
            // does not comment.
            return RemoteRouter.error(403, "Forbidden")
        }
        return RemoteRouter.json(try await question(store, id: id, viewer: viewer))
    }

    /// The owner's name on a comment: the person chosen for the owner's own questions, else the
    /// macOS account's full name.
    private static func ownerName(_ store: ControllerStore) async throws -> String {
        if let handle = await MainActor.run(body: { AppSettings.shared.workroomOwnerHandle }),
           let person = try await store.workroomPerson(handle: handle) {
            return person.name
        }
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return await MainActor.run { L10n.string("Owner") } }
        return String(name.prefix(128))
    }

    // MARK: - Reads

    private static func participantInbox(_ store: ControllerStore, person: WorkroomPersonID,
                                         cursors: (Int64, Int64, Int64)) async throws -> RemoteWorkroomInboxDTO {
        let record = try await store.workroomPerson(person)
        let pages: [(RemoteWorkroomSectionKind, WorkroomInboxFilter, Int64)] = [
            (.replies, .replies, cursors.0), (.open, .open, cursors.1), (.recent, .recent, cursors.2)
        ]
        var sections: [RemoteWorkroomSectionDTO] = []
        for (kind, filter, cursor) in pages {
            let page = try await store.participantInbox(person: person, filter: filter, cursor: cursor)
            sections.append(RemoteWorkroomSectionDTO(
                kind: kind, items: page.items.map { summary($0.question, roomTitle: $0.roomTitle,
                                                            personName: record.name, unread: $0.reply) },
                next: page.next, more: page.more
            ))
        }
        return RemoteWorkroomInboxDTO(viewer: .participant, personName: record.name, language: record.language,
                                      sections: sections, state: try await participantState(store, person: person))
    }

    private static func participantState(_ store: ControllerStore, person: WorkroomPersonID) async throws
        -> RemoteWorkroomStateDTO {
        RemoteWorkroomStateDTO(version: try await store.participantInboxVersion(person: person),
                               waiting: try await store.participantWaitingCount(person: person))
    }

    private static func ownerInbox(_ store: ControllerStore, before cursor: Int64) async throws -> RemoteWorkroomInboxDTO {
        let page = try await store.ownerWorkroomQuestions(before: cursor)
        let items = page.items.map {
            summary($0.question, roomTitle: $0.roomTitle, personName: $0.personName, unread: nil)
        }
        // The newest page's identities and page versions: it changes when a question arrives or
        // anything on the first page moves. Older pages are read on demand.
        let first = cursor == 0 ? page.items : try await store.ownerWorkroomQuestions().items
        let version = WorkroomRemoteBridge.fingerprint(first.map { "\($0.question.id):\($0.question.pageVersion)" })
        return RemoteWorkroomInboxDTO(
            viewer: .owner, personName: nil, language: nil,
            sections: [RemoteWorkroomSectionDTO(kind: .latest, items: items, next: page.next, more: page.more)],
            state: RemoteWorkroomStateDTO(version: version, waiting: 0)
        )
    }

    private static func question(_ store: ControllerStore, id: QuestionID, viewer: WorkroomRemoteViewer) async throws
        -> RemoteWorkroomQuestionDTO {
        let detail: WorkroomQuestionDetail
        let next: QuestionID?
        switch viewer {
        case let .participant(person):
            // Reading it is opening it: the participant's unread mark goes, as in the portal.
            detail = try await WorkroomPortalBackend().question(person: person, id: id)
            next = try await store.participantNextQuestion(person: person, after: id)
        case .owner:
            detail = try await store.workroomQuestionDetail(id)
            next = nil
        }
        return project(detail, viewer: viewer, next: next)
    }

    // MARK: - Projection

    static func project(_ detail: WorkroomQuestionDetail, viewer: WorkroomRemoteViewer,
                        next: QuestionID?) -> RemoteWorkroomQuestionDTO {
        let question = detail.question
        let draft = question.draft
        let writable = question.state == .open || question.state == .answered
        let isParticipant: Bool
        let canComment: Bool
        switch viewer {
        case .participant: isParticipant = true; canComment = false
        case let .owner(comment): isParticipant = false; canComment = comment
        }
        let latest = detail.answers.last
        return RemoteWorkroomQuestionDTO(
            id: question.id.description,
            viewer: viewer.wire,
            roomTitle: detail.room.title,
            askerName: question.askerName,
            personName: detail.personName,
            language: draft.language,
            title: draft.title,
            prompt: draft.prompt,
            background: draft.background,
            evidence: draft.evidence.map { RemoteWorkroomEvidenceDTO(label: $0.label, text: $0.text, source: $0.source) },
            fields: draft.form.fields.map(field),
            state: RemoteWorkroomQuestionState(rawValue: question.state.rawValue),
            entries: entries(detail),
            latestAnswer: (latest?.answers ?? []).map { RemoteWorkroomFieldAnswerDTO(field: $0.field, values: $0.values) },
            latestComment: latest?.comment ?? "",
            canAnswer: isParticipant && writable,
            canMessage: writable && (isParticipant || canComment),
            canDecline: isParticipant && question.state == .open,
            nextQuestionID: next?.description,
            version: question.pageVersion
        )
    }

    private static func field(_ field: WorkroomField) -> RemoteWorkroomFieldDTO {
        RemoteWorkroomFieldDTO(
            id: field.id, kind: RemoteWorkroomFieldKind(rawValue: field.kind.rawValue), label: field.label,
            help: field.help, required: field.required,
            options: (field.options ?? []).map { RemoteWorkroomOptionDTO(id: $0.id, label: $0.label, consequence: $0.consequence) },
            unit: field.unit, minimum: field.minimum, maximum: field.maximum
        )
    }

    private static func entries(_ detail: WorkroomQuestionDetail) -> [RemoteWorkroomEntryDTO] {
        let question = detail.question
        return detail.timeline.compactMap { step in
            switch step {
            case let .answer(index):
                guard detail.answers.indices.contains(index) else { return nil }
                let answer = detail.answers[index]
                let shown = question.draft.form.fields.compactMap { field -> RemoteWorkroomShownAnswerDTO? in
                    guard let values = answer.answers.first(where: { $0.field == field.id })?.values,
                          !values.isEmpty else { return nil }
                    return RemoteWorkroomShownAnswerDTO(
                        label: field.label,
                        value: WorkroomAnswerDisplay.value(field, values: values, language: question.draft.language)
                    )
                }
                return RemoteWorkroomEntryDTO(
                    id: "\(question.id)/\(answer.revision)", kind: .answer, author: .person,
                    authorName: detail.personName, at: seconds(answer.at), text: answer.comment,
                    shown: shown, revision: answer.revision
                )
            case let .note(index):
                guard detail.notes.indices.contains(index) else { return nil }
                let note = detail.notes[index]
                let kind: RemoteWorkroomEntryKind
                switch note.kind {
                case .clarification, .response, .comment: kind = .message
                case .decline: kind = .decline
                case .withdrawal: kind = .withdrawal
                }
                let author: RemoteWorkroomAuthor
                let name: String
                switch note.author {
                case .person: author = .person; name = detail.personName
                case .agent: author = .agent; name = question.askerName
                case .owner: author = .owner; name = note.name ?? WorkroomRemoteDefaults.ownerFallbackName
                }
                return RemoteWorkroomEntryDTO(
                    id: note.id.uuidString.lowercased(), kind: kind, author: author, authorName: name,
                    at: seconds(note.at), text: note.text, shown: [], revision: nil
                )
            }
        }
    }

    private static func summary(_ question: WorkroomQuestion, roomTitle: String, personName: String,
                                unread: String?) -> RemoteWorkroomQuestionSummaryDTO {
        RemoteWorkroomQuestionSummaryDTO(
            id: question.id.description, title: question.draft.title, roomTitle: roomTitle,
            askerName: question.askerName, personName: personName,
            state: RemoteWorkroomQuestionState(rawValue: question.state.rawValue),
            unreadPreview: unread, askedAt: seconds(question.askedAt), updatedAt: seconds(question.updatedAt)
        )
    }

    private static func seconds(_ iso: String) -> Double {
        ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0
    }

    /// FNV-1a over the parts: stable across launches, which `Hasher` is not.
    static func fingerprint(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

enum WorkroomRemoteDefaults {
    /// A comment stored without its writer's name, which only an older build could have written.
    static let ownerFallbackName = "Owner" // localization-ignore: a stored record's fallback, not copy
}
