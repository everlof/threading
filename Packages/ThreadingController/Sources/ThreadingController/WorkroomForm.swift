import Foundation

// The typed parts of a Linked Workrooms question: what a person is asked to fill in, the evidence
// shown beside it, and the git state it was asked against. Every bound lives here so the MCP
// adapter, the portal and the store refuse the same things.

public enum WorkroomFieldKind: String, Codable, Sendable, CaseIterable {
    case singleChoice, multiChoice, yesNo, number, shortText, longText, confirm
}

/// One option of a choice field. `consequence` says what choosing it would lead to, in the
/// question's language, so a domain expert answers the decision rather than the wording.
public struct WorkroomOption: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let consequence: String?

    public init(id: String, label: String, consequence: String? = nil) {
        self.id = id
        self.label = label
        self.consequence = consequence
    }
}

public struct WorkroomField: Codable, Equatable, Sendable {
    public let id: String
    public let kind: WorkroomFieldKind
    public let label: String
    public let help: String?
    public let required: Bool
    public let options: [WorkroomOption]?
    public let unit: String?
    public let minimum: Double?
    public let maximum: Double?

    public init(id: String, kind: WorkroomFieldKind, label: String, help: String? = nil, required: Bool = true,
                options: [WorkroomOption]? = nil, unit: String? = nil, minimum: Double? = nil, maximum: Double? = nil) {
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

/// The answer to one field. Values are option ids for choices, `yes`/`no`, a decimal number,
/// text, or `agree`/`disagree`/`unsure` for a confirmation — one encoding every adapter can read.
public struct WorkroomFieldAnswer: Codable, Equatable, Sendable {
    public let field: String
    public let values: [String]

    public init(field: String, values: [String]) {
        self.field = field
        self.values = values
    }
}

public enum WorkroomConfirmation: String, Sendable, CaseIterable { case agree, disagree, unsure }
public enum WorkroomYesNo: String, Sendable, CaseIterable { case yes, no }

public struct WorkroomForm: Codable, Equatable, Sendable {
    public let fields: [WorkroomField]

    public init(fields: [WorkroomField] = []) { self.fields = fields }

    func validate() throws {
        guard fields.count <= WorkroomLimits.fields else { throw ControllerError.invalidInput("form_fields") }
        var seen = Set<String>()
        for field in fields {
            try WorkroomLimits.identifier(field.id, field: "field_id")
            guard seen.insert(field.id).inserted else { throw ControllerError.invalidInput("field_id") }
            try Limits.text(field.label, field: "field_label", maximum: WorkroomLimits.labelBytes)
            if let help = field.help { try Limits.text(help, field: "field_help", maximum: WorkroomLimits.helpBytes) }
            switch field.kind {
            case .singleChoice, .multiChoice:
                guard let options = field.options,
                      (2...WorkroomLimits.options).contains(options.count) else { throw ControllerError.invalidInput("field_options") }
                var ids = Set<String>()
                for option in options {
                    try WorkroomLimits.identifier(option.id, field: "option_id")
                    guard ids.insert(option.id).inserted else { throw ControllerError.invalidInput("option_id") }
                    try Limits.text(option.label, field: "option_label", maximum: WorkroomLimits.optionBytes)
                    if let consequence = option.consequence {
                        try Limits.text(consequence, field: "option_consequence", maximum: WorkroomLimits.consequenceBytes)
                    }
                }
            default:
                guard field.options == nil else { throw ControllerError.invalidInput("field_options") }
            }
            if field.kind == .number {
                if let unit = field.unit { try Limits.text(unit, field: "field_unit", maximum: WorkroomLimits.unitBytes) }
                for bound in [field.minimum, field.maximum].compactMap({ $0 }) where !bound.isFinite {
                    throw ControllerError.invalidInput("field_bounds")
                }
                if let minimum = field.minimum, let maximum = field.maximum, minimum > maximum {
                    throw ControllerError.invalidInput("field_bounds")
                }
            } else {
                guard field.unit == nil, field.minimum == nil, field.maximum == nil else {
                    throw ControllerError.invalidInput("field_bounds")
                }
            }
        }
    }

    /// The person's answer, checked against this form: every value well-formed for its field,
    /// every required field present, nothing for a field the form does not have.
    public func validate(answers: [WorkroomFieldAnswer]) throws {
        var byField: [String: WorkroomFieldAnswer] = [:]
        for answer in answers {
            guard byField[answer.field] == nil else { throw ControllerError.invalidInput("answer_field") }
            byField[answer.field] = answer
        }
        guard Set(byField.keys).isSubset(of: Set(fields.map(\.id))) else { throw ControllerError.invalidInput("answer_field") }
        for field in fields {
            let values = byField[field.id]?.values ?? []
            if values.isEmpty {
                guard !field.required else { throw ControllerError.invalidInput("answer_required") }
                continue
            }
            let options = Set(field.options?.map(\.id) ?? [])
            switch field.kind {
            case .singleChoice:
                guard values.count == 1, options.contains(values[0]) else { throw ControllerError.invalidInput("answer_choice") }
            case .multiChoice:
                guard Set(values).count == values.count, Set(values).isSubset(of: options) else {
                    throw ControllerError.invalidInput("answer_choice")
                }
            case .yesNo:
                guard values.count == 1, WorkroomYesNo(rawValue: values[0]) != nil else { throw ControllerError.invalidInput("answer_yes_no") }
            case .confirm:
                guard values.count == 1, WorkroomConfirmation(rawValue: values[0]) != nil else {
                    throw ControllerError.invalidInput("answer_confirm")
                }
            case .number:
                guard values.count == 1, let number = WorkroomLimits.number(values[0]) else { throw ControllerError.invalidInput("answer_number") }
                if let minimum = field.minimum, number < minimum { throw ControllerError.invalidInput("answer_number") }
                if let maximum = field.maximum, number > maximum { throw ControllerError.invalidInput("answer_number") }
            case .shortText:
                guard values.count == 1 else { throw ControllerError.invalidInput("answer_text") }
                try Limits.text(values[0], field: "answer_text", maximum: WorkroomLimits.shortTextBytes)
                guard !values[0].contains(where: \.isNewline) else { throw ControllerError.invalidInput("answer_text") }
            case .longText:
                guard values.count == 1 else { throw ControllerError.invalidInput("answer_text") }
                try Limits.text(values[0], field: "answer_text", maximum: WorkroomLimits.longTextBytes)
            }
        }
    }
}

/// Something the agent cites beside its question. Shown as text; a source is a note to verify,
/// never a link the portal follows.
public struct WorkroomEvidence: Codable, Equatable, Sendable {
    public let label: String
    public let text: String
    public let source: String?

    public init(label: String, text: String, source: String? = nil) {
        self.label = label
        self.text = text
        self.source = source
    }

    func validate() throws {
        try Limits.text(label, field: "evidence_label", maximum: WorkroomLimits.evidenceLabelBytes)
        try Limits.text(text, field: "evidence_text", maximum: WorkroomLimits.evidenceTextBytes)
        if let source { try Limits.text(source, field: "evidence_source", maximum: WorkroomLimits.evidenceSourceBytes) }
    }
}

public struct WorkroomCommit: Codable, Equatable, Sendable {
    public let hash: String
    public let subject: String

    public init(hash: String, subject: String) {
        self.hash = hash
        self.subject = subject
    }
}

/// The checkout a question was asked against, captured by the host from the asking session's
/// working directory — never typed by the model. Agents and the owner read it; the domain
/// expert's page does not show it.
public struct WorkroomGitContext: Codable, Equatable, Sendable {
    public let repository: String?
    public let baseRef: String
    public let baseCommit: String
    public let headRef: String?
    public let headCommit: String
    public let mergeBase: String?
    public let changedPaths: [String]
    public let changedPathCount: Int
    public let commits: [WorkroomCommit]
    public let dirty: Bool
    public let capturedAt: String

    public init(repository: String?, baseRef: String, baseCommit: String, headRef: String?, headCommit: String,
                mergeBase: String?, changedPaths: [String], changedPathCount: Int, commits: [WorkroomCommit],
                dirty: Bool, capturedAt: String) {
        self.repository = repository
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.headRef = headRef
        self.headCommit = headCommit
        self.mergeBase = mergeBase
        self.changedPaths = changedPaths
        self.changedPathCount = changedPathCount
        self.commits = commits
        self.dirty = dirty
        self.capturedAt = capturedAt
    }

    func validate() throws {
        if let repository { try Limits.text(repository, field: "git_repository", maximum: WorkroomLimits.refBytes) }
        try Limits.text(baseRef, field: "git_base_ref", maximum: WorkroomLimits.refBytes)
        if let headRef { try Limits.text(headRef, field: "git_head_ref", maximum: WorkroomLimits.refBytes) }
        for hash in [baseCommit, headCommit] + (mergeBase.map { [$0] } ?? []) {
            guard (7...64).contains(hash.count), hash.allSatisfy(\.isHexDigit) else { throw ControllerError.invalidInput("git_commit") }
        }
        guard changedPaths.count <= WorkroomLimits.changedPaths, changedPathCount >= changedPaths.count,
              commits.count <= WorkroomLimits.commits else { throw ControllerError.invalidInput("git_context") }
        for path in changedPaths { try Limits.text(path, field: "git_path", maximum: WorkroomLimits.pathBytes) }
        for commit in commits {
            guard (7...64).contains(commit.hash.count), commit.hash.allSatisfy(\.isHexDigit) else {
                throw ControllerError.invalidInput("git_commit")
            }
            try Limits.text(commit.subject, field: "git_subject", maximum: WorkroomLimits.subjectBytes, empty: true)
        }
        try Limits.text(capturedAt, field: "git_captured_at", maximum: 64)
    }
}

public enum WorkroomLimits {
    public static let titleBytes = 200
    public static let promptBytes = 4_096
    public static let backgroundBytes = 8_192
    public static let fields = 12
    public static let options = 8
    public static let labelBytes = 300
    public static let helpBytes = 1_000
    public static let optionBytes = 200
    public static let consequenceBytes = 500
    public static let unitBytes = 16
    public static let shortTextBytes = 200
    public static let longTextBytes = 4_000
    public static let commentBytes = 8_192
    public static let noteBytes = 4_096
    public static let evidence = 8
    public static let evidenceLabelBytes = 200
    public static let evidenceTextBytes = 1_000
    public static let evidenceSourceBytes = 300
    public static let changedPaths = 50
    public static let commits = 20
    public static let refBytes = 256
    public static let pathBytes = 512
    public static let subjectBytes = 300
    public static let answerRevisions = 20
    public static let notes = 20
    public static let openQuestionsPerRoom = 50
    public static let asksPerHour = 10
    public static let devicesPerPerson = 20
    public static let languageBytes = 35
    /// Index rows one inbox request may examine, whatever it returns. A cap on output is not a
    /// cap on work: a person with many questions in closed rooms would otherwise make one page
    /// scan all of them.
    public static let inboxScan = 500
    public static let invitationLifetime: TimeInterval = 7 * 86_400
    public static let deviceLifetime: TimeInterval = 30 * 86_400
    /// A device's last-seen time is written at most this often, so reading pages is not a write.
    public static let deviceTouchInterval: TimeInterval = 600

    static func identifier(_ value: String, field: String) throws {
        guard (1...32).contains(value.utf8.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw ControllerError.invalidInput(field)
        }
    }

    /// BCP-47 shape: a 2–3 letter language and up to three subtags (`sv`, `en-GB`, `zh-Hant-TW`).
    public static func language(_ value: String) throws {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.utf8.count <= languageBytes, let first = parts.first,
              (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }), parts.count <= 4,
              parts.dropFirst().allSatisfy({ (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { throw ControllerError.invalidInput("language") }
    }

    /// A finite decimal, with `.` or `,` as the separator: a Swedish expert writes `0,5`.
    public static func number(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard normalized.utf8.count <= 32, let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
