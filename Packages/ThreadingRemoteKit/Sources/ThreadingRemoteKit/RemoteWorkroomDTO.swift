import Foundation

// Linked Workrooms over the remote door: a person outside this Mac answers the questions agents
// put to them, in the iPhone app instead of the web portal. The Mac owns every record and every
// check; these are the bounded projections a client renders and the requests it may send.
//
// Two viewers reach these routes. A **participant** holds a guest membership whose scope is one
// workroom person; they see exactly what that person sees in the portal and act as them. The
// **owner** holds a paired owner device; they read any question in an open room and may comment
// on it, but never answer or decline on a person's behalf.

/// The subtree under `RemoteRoute.workroom`. Paths are built from these and an escaped id, never
/// typed out, so the host and the client cannot disagree about a spelling.
public enum RemoteWorkroomPath {
    /// `GET /api/workroom/inbox?new=&open=&recent=` → `RemoteWorkroomInboxDTO`.
    public static let inbox = "inbox"
    /// `GET /api/workroom/state` → `RemoteWorkroomStateDTO`. Cheap; polled while a screen shows.
    public static let state = "state"
    /// `GET /api/workroom/question/<id>` → `RemoteWorkroomQuestionDTO`, and the actions below
    /// it, each answering with the updated question.
    public static let question = "question"

    public enum Action: String, CaseIterable, Sendable {
        /// Body `RemoteWorkroomAnswerRequestDTO`. Participant only.
        case answer
        /// Body `RemoteWorkroomMessageRequestDTO`. A participant writes to the agent; the owner
        /// comments, which the person and the agent both see.
        case message
        /// Body `RemoteWorkroomMessageRequestDTO` with the reason. Participant only.
        case decline
    }

    /// Query keys of the inbox, one cursor per section.
    public enum Cursor: String, CaseIterable, Sendable {
        case replies = "new"
        case open
        case recent
    }
}

public enum RemoteWorkroomViewer: RemoteLosslessStringToken {
    case participant
    case owner
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "participant": self = .participant
        case "owner": self = .owner
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .participant: return "participant"
        case .owner: return "owner"
        case let .unknown(value): return value
        }
    }
}

/// `open → answered`, or closed as `declined` by the person or `withdrawn` by the agent.
public enum RemoteWorkroomQuestionState: RemoteLosslessStringToken {
    case open
    case answered
    case declined
    case withdrawn
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "answered": self = .answered
        case "declined": self = .declined
        case "withdrawn": self = .withdrawn
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .open: return "open"
        case .answered: return "answered"
        case .declined: return "declined"
        case .withdrawn: return "withdrawn"
        case let .unknown(value): return value
        }
    }
}

/// Which inbox section a page belongs to. Each question is in exactly one for a participant: an
/// unseen message puts it in `replies` whatever its state, otherwise open is `open` and the rest
/// `recent`. The owner sees one `latest` section, newest question first.
public enum RemoteWorkroomSectionKind: RemoteLosslessStringToken {
    case replies
    case open
    case recent
    case latest
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "replies": self = .replies
        case "open": self = .open
        case "recent": self = .recent
        case "latest": self = .latest
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .replies: return "replies"
        case .open: return "open"
        case .recent: return "recent"
        case .latest: return "latest"
        case let .unknown(value): return value
        }
    }
}

/// The controller's form field kinds, spelled as it stores them.
public enum RemoteWorkroomFieldKind: RemoteLosslessStringToken {
    case singleChoice
    case multiChoice
    case yesNo
    case number
    case shortText
    case longText
    case confirm
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "singleChoice": self = .singleChoice
        case "multiChoice": self = .multiChoice
        case "yesNo": self = .yesNo
        case "number": self = .number
        case "shortText": self = .shortText
        case "longText": self = .longText
        case "confirm": self = .confirm
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .singleChoice: return "singleChoice"
        case .multiChoice: return "multiChoice"
        case .yesNo: return "yesNo"
        case .number: return "number"
        case .shortText: return "shortText"
        case .longText: return "longText"
        case .confirm: return "confirm"
        case let .unknown(value): return value
        }
    }
}

/// The value a `yesNo` field sends, in display order. The Mac's form spells them the same way;
/// a test on the Mac side pins the two vocabularies together.
public enum RemoteWorkroomYesNo: String, CaseIterable, Sendable {
    case yes
    case no
}

/// The value a `confirm` field sends, in display order.
public enum RemoteWorkroomConfirmation: String, CaseIterable, Sendable {
    case agree
    case disagree
    case unsure
}

public enum RemoteWorkroomEntryKind: RemoteLosslessStringToken {
    /// An answer revision; `answers` holds what was chosen.
    case answer
    /// A message in the conversation, from either side or a comment from the owner.
    case message
    /// The person declined; `text` is their reason. Closing.
    case decline
    /// The agent withdrew the question; `text` is its reason. Closing.
    case withdrawal
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "answer": self = .answer
        case "message": self = .message
        case "decline": self = .decline
        case "withdrawal": self = .withdrawal
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .answer: return "answer"
        case .message: return "message"
        case .decline: return "decline"
        case .withdrawal: return "withdrawal"
        case let .unknown(value): return value
        }
    }
}

/// Who wrote an entry. `person` is the person the question is addressed to, `agent` the session
/// that asked, `owner` the person who owns the Mac.
public enum RemoteWorkroomAuthor: RemoteLosslessStringToken {
    case person
    case agent
    case owner
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "person": self = .person
        case "agent": self = .agent
        case "owner": self = .owner
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .person: return "person"
        case .agent: return "agent"
        case .owner: return "owner"
        case let .unknown(value): return value
        }
    }
}

// MARK: - Inbox

public struct RemoteWorkroomQuestionSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let roomTitle: String
    /// The asking session's name, as the person sees it ("Ticket sweep").
    public let askerName: String
    /// Who the question is for; the owner's list shows it, a participant's always says them.
    public let personName: String
    public let state: RemoteWorkroomQuestionState
    /// The start of the newest message the participant has not opened, else nil.
    public let unreadPreview: String?
    public let askedAt: Double
    public let updatedAt: Double

    public init(id: String, title: String, roomTitle: String, askerName: String, personName: String,
                state: RemoteWorkroomQuestionState, unreadPreview: String?, askedAt: Double, updatedAt: Double) {
        self.id = id
        self.title = title
        self.roomTitle = roomTitle
        self.askerName = askerName
        self.personName = personName
        self.state = state
        self.unreadPreview = unreadPreview
        self.askedAt = askedAt
        self.updatedAt = updatedAt
    }
}

public struct RemoteWorkroomSectionDTO: Codable, Equatable, Sendable {
    public let kind: RemoteWorkroomSectionKind
    public let items: [RemoteWorkroomQuestionSummaryDTO]
    /// Where this section resumes; pass it back under the section's `Cursor` key.
    public let next: Int64
    /// The section stopped at its bound rather than at its end.
    public let more: Bool

    public init(kind: RemoteWorkroomSectionKind, items: [RemoteWorkroomQuestionSummaryDTO], next: Int64, more: Bool) {
        self.kind = kind
        self.items = items
        self.next = next
        self.more = more
    }
}

public struct RemoteWorkroomInboxDTO: Codable, Equatable, Sendable {
    public let viewer: RemoteWorkroomViewer
    /// The participant's own name, or nil for the owner.
    public let personName: String?
    /// The participant's language (BCP-47), so the app can say its own words in it.
    public let language: String?
    public let sections: [RemoteWorkroomSectionDTO]
    public let state: RemoteWorkroomStateDTO

    public init(viewer: RemoteWorkroomViewer, personName: String?, language: String?,
                sections: [RemoteWorkroomSectionDTO], state: RemoteWorkroomStateDTO) {
        self.viewer = viewer
        self.personName = personName
        self.language = language
        self.sections = sections
        self.state = state
    }
}

/// What a screen polls and a badge shows. `version` changes whenever the inbox would; `waiting`
/// is the participant's open questions plus unread messages, bounded, and zero for the owner.
public struct RemoteWorkroomStateDTO: Codable, Equatable, Sendable {
    public let version: String
    public let waiting: Int

    public init(version: String, waiting: Int) {
        self.version = version
        self.waiting = waiting
    }
}

// MARK: - Question

public struct RemoteWorkroomOptionDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let consequence: String?

    public init(id: String, label: String, consequence: String?) {
        self.id = id
        self.label = label
        self.consequence = consequence
    }
}

public struct RemoteWorkroomFieldDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: RemoteWorkroomFieldKind
    public let label: String
    public let help: String?
    public let required: Bool
    public let options: [RemoteWorkroomOptionDTO]
    public let unit: String?
    public let minimum: Double?
    public let maximum: Double?

    public init(id: String, kind: RemoteWorkroomFieldKind, label: String, help: String?, required: Bool,
                options: [RemoteWorkroomOptionDTO], unit: String?, minimum: Double?, maximum: Double?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.help = help
        self.required = required
        self.options = options
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct RemoteWorkroomEvidenceDTO: Codable, Equatable, Sendable {
    public let label: String
    public let text: String
    public let source: String?

    public init(label: String, text: String, source: String?) {
        self.label = label
        self.text = text
        self.source = source
    }
}

/// One field of an answer: the raw values the form takes back, and the words the person chose.
public struct RemoteWorkroomFieldAnswerDTO: Codable, Equatable, Sendable {
    public let field: String
    public let values: [String]

    public init(field: String, values: [String]) {
        self.field = field
        self.values = values
    }
}

public struct RemoteWorkroomShownAnswerDTO: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One step of the conversation, in the order the Mac stored it.
public struct RemoteWorkroomEntryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: RemoteWorkroomEntryKind
    public let author: RemoteWorkroomAuthor
    public let authorName: String
    public let at: Double
    /// A message, a reason, or an answer's comment.
    public let text: String
    /// For an answer: what was chosen, field by field, as the person reads it.
    public let shown: [RemoteWorkroomShownAnswerDTO]
    /// For an answer: its revision, from 1.
    public let revision: Int?

    public init(id: String, kind: RemoteWorkroomEntryKind, author: RemoteWorkroomAuthor, authorName: String,
                at: Double, text: String, shown: [RemoteWorkroomShownAnswerDTO], revision: Int?) {
        self.id = id
        self.kind = kind
        self.author = author
        self.authorName = authorName
        self.at = at
        self.text = text
        self.shown = shown
        self.revision = revision
    }
}

public struct RemoteWorkroomQuestionDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let viewer: RemoteWorkroomViewer
    public let roomTitle: String
    public let askerName: String
    public let personName: String
    /// BCP-47 tag the agent wrote the question in.
    public let language: String
    public let title: String
    public let prompt: String
    public let background: String
    public let evidence: [RemoteWorkroomEvidenceDTO]
    /// Empty: the answer is the comment alone, which is then required.
    public let fields: [RemoteWorkroomFieldDTO]
    public let state: RemoteWorkroomQuestionState
    public let entries: [RemoteWorkroomEntryDTO]
    /// The latest answer's raw values, to fill the form when the person changes it.
    public let latestAnswer: [RemoteWorkroomFieldAnswerDTO]
    public let latestComment: String
    /// What this viewer may do now. The Mac checks each again when it is asked.
    public let canAnswer: Bool
    public let canMessage: Bool
    public let canDecline: Bool
    /// The participant's next open question, for "Next question"; nil at the last.
    public let nextQuestionID: String?
    /// Changes whenever this page would. Poll `state` for the inbox, this for one question.
    public let version: String

    public init(id: String, viewer: RemoteWorkroomViewer, roomTitle: String, askerName: String, personName: String,
                language: String, title: String, prompt: String, background: String,
                evidence: [RemoteWorkroomEvidenceDTO], fields: [RemoteWorkroomFieldDTO],
                state: RemoteWorkroomQuestionState, entries: [RemoteWorkroomEntryDTO],
                latestAnswer: [RemoteWorkroomFieldAnswerDTO], latestComment: String,
                canAnswer: Bool, canMessage: Bool, canDecline: Bool, nextQuestionID: String?, version: String) {
        self.id = id
        self.viewer = viewer
        self.roomTitle = roomTitle
        self.askerName = askerName
        self.personName = personName
        self.language = language
        self.title = title
        self.prompt = prompt
        self.background = background
        self.evidence = evidence
        self.fields = fields
        self.state = state
        self.entries = entries
        self.latestAnswer = latestAnswer
        self.latestComment = latestComment
        self.canAnswer = canAnswer
        self.canMessage = canMessage
        self.canDecline = canDecline
        self.nextQuestionID = nextQuestionID
        self.version = version
    }
}

// MARK: - Requests

public struct RemoteWorkroomAnswerRequestDTO: Codable, Equatable, Sendable {
    public let answers: [RemoteWorkroomFieldAnswerDTO]
    public let comment: String

    public init(answers: [RemoteWorkroomFieldAnswerDTO], comment: String) {
        self.answers = answers
        self.comment = comment
    }
}

public struct RemoteWorkroomMessageRequestDTO: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) { self.text = text }
}

/// Bounds a client can check before sending; the Mac enforces the same.
public enum RemoteWorkroomLimits {
    public static let messageBytes = 4_096
    public static let commentBytes = 8_192
    public static let shortTextBytes = 200
    public static let longTextBytes = 4_000
    /// A request body larger than this is refused before it is decoded.
    public static let maximumRequestBytes = 65_536
    /// How often an open screen asks for `state` while it is in front.
    public static let pollInterval: TimeInterval = 4
}
