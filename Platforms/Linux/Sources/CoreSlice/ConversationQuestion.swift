import Foundation
import ThreadingRemoteKit

/// Bounded, provider-neutral input. Questions are decisions supplied by the user, never inferred
/// from assistant prose or answered by a timer. Stable question IDs are echoed without rewriting.
struct ConversationQuestionRequest: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        let detail: String
    }
    struct Question: Equatable, Sendable {
        let id: String
        let header: String
        let prompt: String
        let options: [Option]
        let allowsOther: Bool
    }

    enum Limits {
        static let questions = 3
        static let options = 6
        static let shortTextBytes = 200
        static let textBytes = 2_000
        static let answerBytes = 8_000
        static let pendingRequests = 3
    }

    let id: UUID
    let questions: [Question]
    let blocksTurn: Bool

    /// The installed app-server schema, generated with `codex app-server generate-ts`.
    /// Reject the whole request if it cannot be displayed faithfully; truncating a choice could
    /// change what the user thinks they answered. Secret input needs its own secure boundary.
    static func codex(_ parameters: [String: Any], id: UUID = UUID()) -> Self? {
        guard let raw = parameters["questions"] as? [Any],
              (1...Limits.questions).contains(raw.count) else { return nil }
        var questions: [Question] = []
        var ids: Set<String> = []
        func bounded(_ value: Any?, bytes: Int, empty: Bool = false) -> String? {
            guard let text = value as? String,
                  text.utf8.prefix(bytes + 1).count <= bytes,
                  (empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return nil }
            return text
        }
        for value in raw {
            guard let item = value as? [String: Any], item["isSecret"] as? Bool != true,
                  let key = bounded(item["id"], bytes: Limits.shortTextBytes),
                  ids.insert(key).inserted,
                  let header = bounded(item["header"], bytes: Limits.shortTextBytes),
                  let prompt = bounded(item["question"], bytes: Limits.textBytes)
            else { return nil }
            var options: [Option] = []
            if let value = item["options"], !(value is NSNull) {
                guard let rawOptions = value as? [Any],
                      rawOptions.count <= Limits.options else { return nil }
                var labels: Set<String> = []
                for rawOption in rawOptions {
                    guard let option = rawOption as? [String: Any],
                          let label = bounded(option["label"], bytes: Limits.shortTextBytes),
                          labels.insert(label).inserted,
                          let detail = bounded(option["description"], bytes: Limits.textBytes, empty: true)
                    else { return nil }
                    options.append(Option(label: label, detail: detail))
                }
            }
            questions.append(Question(
                id: key, header: header, prompt: prompt, options: options,
                allowsOther: options.isEmpty || item["isOther"] as? Bool == true
            ))
        }
        return Self(id: id, questions: questions, blocksTurn: parameters["isBlocking"] as? Bool ?? true)
    }

    var remoteRequest: RemoteQuestionRequestDTO {
        RemoteQuestionRequestDTO(id: id.uuidString, questions: questions.map { question in
            .init(id: question.id, header: question.header, prompt: question.prompt,
                  options: question.options.map { .init(label: $0.label, detail: $0.detail) },
                  allowsOther: question.allowsOther)
        }, blocksTurn: blocksTurn)
    }

    func accepts(_ answers: [String: String]) -> Bool { remoteRequest.accepts(answers) }

}

@MainActor
protocol QuestionAskingConversation: AnyObject {
    var onQuestion: ((ConversationQuestionRequest, @escaping ([String: String]?) -> Void) -> Void)? { get set }
    var onQuestionResolved: ((UUID) -> Void)? { get set }
}
