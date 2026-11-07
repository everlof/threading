import Foundation
import ThreadingRemoteKit

/// What the person has chosen and written so far, field by field, before it is sent.
///
/// Values are the wire values the Mac validates against the form: option ids, the
/// `RemoteWorkroomYesNo` and `RemoteWorkroomConfirmation` raw values, a decimal number as typed,
/// or text. The phone checks the same rules first so a person learns what is missing before a
/// round trip, and the Mac checks them again whatever the phone said.
struct WorkroomAnswerDraft: Equatable {
    var values: [String: [String]] = [:]
    var comment = ""

    init() {}

    /// The form as the latest answer left it, so changing an answer starts from it.
    init(question: RemoteWorkroomQuestionDTO) {
        values = Dictionary(
            question.latestAnswer.map { ($0.field, $0.values) },
            uniquingKeysWith: { first, _ in first }
        )
        comment = question.latestComment
    }

    func single(_ field: String) -> String? { values[field]?.first }

    func contains(_ value: String, in field: String) -> Bool {
        values[field]?.contains(value) == true
    }

    mutating func choose(_ value: String, in field: String) {
        values[field] = [value]
    }

    mutating func toggle(_ value: String, in field: String) {
        var chosen = values[field] ?? []
        if let index = chosen.firstIndex(of: value) { chosen.remove(at: index) } else { chosen.append(value) }
        values[field] = chosen
    }

    mutating func setText(_ text: String, in field: String) {
        values[field] = [text]
    }

    // MARK: Checking

    enum Problem: Equatable {
        /// A required field is empty, or a comment-only answer has no comment.
        case missing
        /// A number field is not a number, or outside its range. Carries the field's label.
        case number(String)
        case tooLong
        /// An answer with no fields needs its comment.
        case emptyAnswer
    }

    /// The first thing that would make the Mac refuse this answer, or nil.
    func problem(for fields: [RemoteWorkroomFieldDTO]) -> Problem? {
        if fields.isEmpty, comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyAnswer
        }
        guard comment.utf8.count <= RemoteWorkroomLimits.commentBytes else { return .tooLong }
        for field in fields {
            let entered = entries(field)
            if entered.isEmpty {
                if field.required { return .missing }
                continue
            }
            switch field.kind {
            case .number:
                guard let value = Self.number(entered[0]),
                      field.minimum.map({ value >= $0 }) ?? true,
                      field.maximum.map({ value <= $0 }) ?? true else { return .number(field.label) }
            case .shortText:
                guard entered[0].utf8.count <= RemoteWorkroomLimits.shortTextBytes else { return .tooLong }
            case .longText:
                guard entered[0].utf8.count <= RemoteWorkroomLimits.longTextBytes else { return .tooLong }
            case .singleChoice, .multiChoice, .yesNo, .confirm, .unknown:
                break
            }
        }
        return nil
    }

    /// The request this draft sends: every field with something in it, trimmed the way the
    /// portal trims, and the comment as written.
    func request(for fields: [RemoteWorkroomFieldDTO]) -> RemoteWorkroomAnswerRequestDTO {
        RemoteWorkroomAnswerRequestDTO(
            answers: fields.compactMap { field in
                let entered = entries(field)
                return entered.isEmpty ? nil : RemoteWorkroomFieldAnswerDTO(field: field.id, values: entered)
            },
            comment: comment
        )
    }

    /// A field's non-empty values. Long text keeps its own whitespace; every other kind is
    /// trimmed, because a stray space after a number or a choice is not part of the answer.
    private func entries(_ field: RemoteWorkroomFieldDTO) -> [String] {
        (values[field.id] ?? [])
            .map { field.kind == .longText ? $0 : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A finite decimal with `.` or `,` as its separator: a Swedish expert types `0,5`. The same
    /// rule the Mac applies, so a value the phone accepts is one the Mac accepts.
    static func number(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.utf8.count <= 32, let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}

/// The Mac's reasons for refusing a workroom write, as `RemoteErrorDTO.detail` names them.
/// Named once here so the phone never spells a wire token inline.
enum WorkroomRefusal: String {
    case answerRequired = "answer_required"
    case answerChoice = "answer_choice"
    case answerYesNo = "answer_yes_no"
    case answerConfirm = "answer_confirm"
    case answerNumber = "answer_number"
    case answerText = "answer_text"
    case answerRevisions = "answer_revisions"
    case comment
    case note
    case notes

    /// What the person reads for an error a workroom route answered with.
    static func message(for error: Error) -> String {
        guard let error = error as? RemoteClientError, case let .server(status, _, detail) = error else {
            return error.localizedDescription
        }
        switch status {
        case 400:
            switch detail.flatMap(WorkroomRefusal.init(rawValue:)) {
            case .answerRequired: return MobileL10n.string("Fill in every field that is not marked optional.")
            case .answerChoice, .answerYesNo, .answerConfirm: return MobileL10n.string("Choose one of the options.")
            case .answerNumber: return MobileL10n.string("Enter a number within the stated range.")
            case .answerText, .comment, .note: return MobileL10n.string("That text is too long.")
            case .answerRevisions: return MobileL10n.string("This answer can’t be changed again.")
            case .notes: return MobileL10n.string("This conversation is full.")
            case nil: return MobileL10n.string("Check your answer and try again.")
            }
        case 403: return MobileL10n.string("You can’t do that on this question.")
        case 404: return MobileL10n.string("This question isn’t available any more.")
        case 409: return MobileL10n.string("This question is closed.")
        default: return error.localizedDescription
        }
    }
}
