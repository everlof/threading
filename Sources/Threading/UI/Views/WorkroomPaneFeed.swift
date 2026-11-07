import AppKit
import ThreadingController
import ThreadingRemoteKit

// MARK: - Workroom Pane Feed

/// Reads one chat's Linked Workrooms for its `WorkroomPaneViewController`, and does what the
/// owner asks there.
///
/// The pane's action handler is the only owner of the feed, and the feed holds the pane weakly,
/// so the tab that holds the pane decides how long both live.
///
/// **Bounded before anything is drawn.** The rooms are the chat's ties (the store's first 100)
/// and its repository's newest rooms, shown up to `WorkroomPaneFeedDefaults.rooms`; the questions
/// are read in at most `questionPages` pages and the newest `questions` shown; one question's
/// conversation is the detail the store already bounds. Every read is the store actor's; the
/// main actor only turns finished records into words.
@MainActor
final class WorkroomPaneFeed {

    // MARK: - Properties

    let sessionID: SessionID
    private weak var pane: WorkroomPaneViewController?
    private let projects: ProjectStore
    private let appEvents = AppEventObservations()
    private var reading: Task<Void, Never>?
    private var openQuestion: QuestionID?
    /// A comment that could not be stored, said under the composer until the next one is sent or
    /// the question is left.
    private var commentFailure: String?

    // MARK: - Initialization

    /// The pane, with the feed behind it.
    static func makePane(for sessionID: SessionID, projects: ProjectStore = .shared) -> WorkroomPaneViewController {
        let pane = WorkroomPaneViewController()
        let feed = WorkroomPaneFeed(sessionID: sessionID, pane: pane, projects: projects)
        pane.onAction = { feed.perform($0) }
        pane.onRefresh = { [weak feed] in feed?.refresh() }
        return pane
    }

    private init(sessionID: SessionID, pane: WorkroomPaneViewController, projects: ProjectStore) {
        self.sessionID = sessionID
        self.pane = pane
        self.projects = projects
        appEvents.observe(WorkroomStatusDidChange.self) { [weak self] _ in self?.refresh() }
        // An invitation accepted on a phone, or a person signed out.
        appEvents.observe(SessionSharingDidChange.self) { [weak self] _ in self?.refresh() }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard change.affects(AppSettingIdentity.workroomsEnabled.rawValue,
                                 AppSettingIdentity.workroomOwnerHandle.rawValue) else { return }
            self?.refresh()
        }
    }

    // MARK: - Reading

    /// Reads the chat's workrooms again; a read still running is abandoned for this one.
    func refresh() {
        reading?.cancel()
        let chatTitle = projects.session(withID: sessionID)?.displayTitle ?? ""
        guard AppSettings.shared.workroomsEnabled else {
            pane?.apply(WorkroomPanePresentation(chatTitle: chatTitle, notice: .off))
            return
        }
        guard !projects.sessionRunsOnRemoteHost(sessionID), let project = projects.project(forSessionID: sessionID) else {
            pane?.apply(WorkroomPanePresentation(chatTitle: chatTitle, notice: .elsewhere))
            return
        }
        let request = Request(sessionID: sessionID, scope: WorkroomAgentCommandService.scope(for: project),
                              chatTitle: chatTitle, openQuestion: openQuestion, commentFailure: commentFailure,
                              ownerHandle: AppSettings.shared.workroomOwnerHandle)
        reading = Task { [weak self] in
            let presentation = await Self.read(request)
            guard !Task.isCancelled, let self else { return }
            self.pane?.apply(presentation)
        }
    }

    private struct Request {
        let sessionID: SessionID
        let scope: String
        let chatTitle: String
        let openQuestion: QuestionID?
        let commentFailure: String?
        let ownerHandle: String?
    }

    private static func read(_ request: Request) async -> WorkroomPanePresentation {
        var result = WorkroomPanePresentation(chatTitle: request.chatTitle)
        do {
            let store = try await MacMailbox.shared.controllerStore()
            let address = try await MacMailbox.shared.address(for: request.sessionID)
            var names: [WorkroomPersonID: String] = [:]

            // This chat's own rooms first, then its repository's newest that it has not tied.
            var rooms = try await store.workroomTies(address)
            var repository: [LinkedWorkroom] = []
            var after: Int64 = 0
            for _ in 0..<WorkroomPaneFeedDefaults.roomPages {
                let page = try await store.workrooms(scope: request.scope, after: after,
                                                     limit: WorkroomPaneFeedDefaults.pageSize)
                repository += page.items
                guard page.items.count == WorkroomPaneFeedDefaults.pageSize else { break }
                after = page.next
            }
            let tied = Set(rooms.map(\.id))
            rooms += repository.reversed().filter { !tied.contains($0.id) }
            for room in rooms {
                guard result.rooms.count < WorkroomPaneFeedDefaults.rooms else { break }
                let summary = try await store.workroomSummary(room.id)
                // A closed room the chat never worked in is history, not something to act on.
                guard summary.publication.state != .closed || tied.contains(room.id) else { continue }
                var people: [WorkroomPanePresentation.Person] = []
                for person in summary.people {
                    names[person.id] = person.name
                    let isOwner = person.handle == request.ownerHandle
                    people.append(WorkroomPanePresentation.Person(
                        id: person.id.description, name: person.name,
                        status: personStatus(app: RemoteAccessCoordinator.shared.access(forWorkroomPerson: person.id),
                                             browsers: try await store.workroomDevices(person: person.id),
                                             isOwner: isOwner),
                        canInvite: !isOwner
                    ))
                }
                result.rooms.append(WorkroomPanePresentation.Room(
                    id: room.id.description, title: room.title, status: roomStatus(summary),
                    canClose: summary.publication.state == .open, people: people
                ))
            }

            // The chat's questions, newest first.
            var asked: [WorkroomQuestion] = []
            after = 0
            for _ in 0..<WorkroomPaneFeedDefaults.questionPages {
                let page = try await store.workroomAsks(asker: address, after: after,
                                                        limit: WorkroomPaneFeedDefaults.pageSize)
                asked += page.items
                guard page.items.count == WorkroomPaneFeedDefaults.pageSize else { break }
                after = page.next
            }
            result.moreQuestions = asked.count > WorkroomPaneFeedDefaults.questions
            for question in asked.suffix(WorkroomPaneFeedDefaults.questions).reversed() {
                if names[question.person] == nil {
                    names[question.person] = (try? await store.workroomPerson(question.person))?.name
                }
                result.questions.append(WorkroomPanePresentation.Question(
                    id: question.id.description, title: question.draft.title,
                    status: [names[question.person] ?? "", questionState(question)].filter { !$0.isEmpty }
                        .joined(separator: WorkroomPaneFeedDefaults.separator)
                ))
            }

            if let open = request.openQuestion {
                var shown = Self.detail(try await store.workroomQuestionDetail(open))
                shown.failure = request.commentFailure
                result.detail = shown
            }
        } catch {
            result.notice = .failure(MacMailbox.describe(error))
        }
        return result
    }

    // MARK: - Words

    /// Whether the room is reachable, until when, and how much in it waits.
    static func roomStatus(_ summary: WorkroomSummary, now: Date = Date()) -> String {
        let publication = summary.publication
        var parts: [String] = []
        switch publication.state {
        case .private:
            parts.append(L10n.string("Not opened to anyone yet"))
        case .closed:
            parts.append(L10n.string("Closed"))
        case .open:
            if !publication.isOpen(at: now) {
                parts.append(L10n.string("Expired"))
            } else if let until = publication.expiresAt.flatMap(date) {
                parts.append(L10n.format("Open until %@", until.formatted(date: .abbreviated, time: .shortened)))
            } else {
                parts.append(L10n.string("Open with no end date"))
            }
        }
        if summary.openQuestions > 0 {
            parts.append(L10n.format("Open questions: %d", summary.openQuestions))
        }
        return parts.joined(separator: WorkroomPaneFeedDefaults.separator)
    }

    /// Where the person can see their questions: the app first, since that is where they are
    /// told about them, then an invitation still waiting, then a browser.
    static func personStatus(app: RemoteAccessCoordinator.SessionAccess, browsers: [WorkroomDevice],
                             isOwner: Bool) -> String {
        if isOwner { return L10n.string("You · your paired iPhone shows every question") }
        if let seen = app.members.map({ $0.lastSeenAt ?? $0.joinedAt }).max() {
            return L10n.format("In the app · last seen %@", seen.formatted(date: .abbreviated, time: .shortened))
        }
        if let link = app.links.max(by: { $0.expiresAt < $1.expiresAt }) {
            return L10n.format("app invitation unused until %@", link.expiresAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let browser = browsers.compactMap({ date($0.lastSeenAt) }).max() {
            return L10n.format("%d browsers, last %@", browsers.count, browser.formatted(date: .abbreviated, time: .shortened))
        }
        return L10n.string("Not in the app yet")
    }

    static func questionState(_ question: WorkroomQuestion) -> String {
        switch question.state {
        case .open: return L10n.string("Waiting for an answer")
        case .answered:
            return question.answerRevision > 1
                ? L10n.format("Answered · revision %d", question.answerRevision) : L10n.string("Answered")
        case .declined: return L10n.string("Declined")
        case .withdrawn: return L10n.string("Withdrawn")
        }
    }

    /// One question as the owner reads it — the same projection the owner's phone gets, so the
    /// two cannot disagree about who said what.
    static func detail(_ record: WorkroomQuestionDetail) -> WorkroomPanePresentation.Detail {
        let question = WorkroomRemoteBridge.project(record, viewer: .owner(canComment: true), next: nil)
        let entries = question.entries.map { entry in
            let heading: String
            switch entry.kind {
            case .answer:
                heading = (entry.revision ?? 1) > 1
                    ? L10n.format("%@ changed the answer", entry.authorName) : L10n.format("%@ answered", entry.authorName)
            case .decline: heading = L10n.format("%@ declined", entry.authorName)
            case .withdrawal: heading = L10n.format("%@ withdrew the question", entry.authorName)
            default: heading = entry.authorName
            }
            let when = Date(timeIntervalSince1970: entry.at).formatted(date: .abbreviated, time: .shortened)
            return WorkroomPanePresentation.Entry(
                id: entry.id, heading: [heading, when].joined(separator: WorkroomPaneFeedDefaults.separator),
                lines: entry.shown.map { shownLine(label: $0.label, value: $0.value) },
                text: entry.text
            )
        }
        return WorkroomPanePresentation.Detail(
            id: question.id, title: question.title,
            status: [question.roomTitle, question.personName, questionState(record.question)]
                .joined(separator: WorkroomPaneFeedDefaults.separator),
            prompt: question.prompt, entries: entries,
            commentReaders: question.canMessage
                ? L10n.format("%@ sees your comment, and this chat gets it as mail.", question.personName) : nil,
            failure: nil
        )
    }

    /// A field and what was chosen in it, as one line: "Belopp: 120 kr", but "Stämmer det? Ja" —
    /// a label that already ends on its own punctuation takes no colon after it.
    static func shownLine(label: String, value: String) -> String {
        let separator = label.last.map(WorkroomPaneFeedDefaults.closingPunctuation.contains) == true
            ? WorkroomPaneFeedDefaults.spaceSeparator : WorkroomPaneFeedDefaults.labelSeparator
        return label + separator + value
    }

    private static func date(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    // MARK: - Actions

    private func perform(_ action: WorkroomPaneAction) {
        switch action {
        case .openQuestion(let id):
            openQuestion = try? QuestionID(id)
            commentFailure = nil
            refresh()
        case .showQuestions:
            openQuestion = nil
            commentFailure = nil
            refresh()
        case .openSettings:
            WorkroomOpeningSheet.revealSettings()
        case .inviteToApp(let id):
            guard let person = try? WorkroomPersonID(id) else { return }
            let name = pane?.presentation.rooms.lazy.flatMap(\.people).first { $0.id == id }?.name ?? ""
            let window = pane?.view.window
            Task { [weak self] in
                await WorkroomAppInvitationAlert.invite(person, name: name, in: window)
                self?.refresh()
            }
        case .closeRoom(let id):
            // As Settings ▸ Workrooms closes a room: at once. Its questions and answers stay, and
            // an agent can ask to open it again.
            guard let room = try? WorkroomID(id) else { return }
            Task { [weak self] in
                _ = try? await MacMailbox.shared.controllerStore().closeWorkroom(room)
                WorkroomHost.shared.refresh()
                NotificationCenter.default.post(WorkroomStatusDidChange())
                self?.refresh()
            }
        case let .comment(id, text):
            guard let question = try? QuestionID(id) else { return }
            Task { [weak self] in
                do {
                    let store = try await MacMailbox.shared.controllerStore()
                    try await WorkroomRemoteBridge.ownerComment(on: question, text: text, store: store)
                    self?.commentFailure = nil
                    self?.pane?.commentDidSend()
                } catch {
                    self?.commentFailure = L10n.format("The comment was not saved: %@", MacMailbox.describe(error))
                    self?.pane?.commentDidFail()
                }
                self?.refresh()
            }
        }
    }
}

// MARK: - Defaults

enum WorkroomPaneFeedDefaults {
    static let rooms = 6
    static let roomPages = 2
    static let questions = 20
    static let questionPages = 4
    static let pageSize = 50
    static let separator = " · " // localization-ignore: punctuation between facts, not copy
    static let labelSeparator = ": " // localization-ignore: punctuation between a field and its value
    static let spaceSeparator = " " // localization-ignore: between a question-shaped field and its value
    /// Marks a field label already closes with, in the languages questions are written in.
    static let closingPunctuation: Set<Character> = ["?", ":", "!", ".", "？", "："]
}
