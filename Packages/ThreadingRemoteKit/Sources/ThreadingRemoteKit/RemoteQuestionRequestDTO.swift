import Foundation

/// An exact, bounded question, separate from tool approval and from usage recovery.
/// The host keeps request identity and validates an answer again before forwarding it.
public struct RemoteQuestionRequestDTO: Codable, Equatable, Identifiable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let detail: String
        public init(label: String, detail: String) { self.label = label; self.detail = detail }
    }
    public struct Question: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let header: String
        public let prompt: String
        public let options: [Option]
        public let allowsOther: Bool
        public init(id: String, header: String, prompt: String, options: [Option], allowsOther: Bool) {
            self.id = id; self.header = header; self.prompt = prompt
            self.options = options; self.allowsOther = allowsOther
        }
    }
    public let id: String
    public let questions: [Question]
    public let blocksTurn: Bool
    public let canAnswer: Bool
    public init(id: String, questions: [Question], blocksTurn: Bool, canAnswer: Bool = true) {
        self.id = id; self.questions = questions; self.blocksTurn = blocksTurn; self.canAnswer = canAnswer
    }
    public func allowingAnswers(_ allowed: Bool) -> Self {
        Self(id: id, questions: questions, blocksTurn: blocksTurn, canAnswer: canAnswer && allowed)
    }
    /// Fail whole: truncating a choice would change what the person agreed to send.
    public var isValid: Bool {
        guard UUID(uuidString: id) != nil, (1...3).contains(questions.count) else { return false }
        var ids = Set<String>()
        return questions.allSatisfy { question in
            guard Self.fits(question.id, 200), Self.fits(question.header, 200),
                  Self.fits(question.prompt, 2000), ids.insert(question.id).inserted,
                  question.options.count <= 6, question.allowsOther || !question.options.isEmpty else { return false }
            var labels = Set<String>()
            return question.options.allSatisfy {
                Self.fits($0.label, 200) && Self.fits($0.detail, 2000, empty: true)
                    && labels.insert($0.label).inserted
            }
        }
    }
    public func accepts(_ answers: [String: String]) -> Bool {
        guard isValid, answers.count == questions.count else { return false }
        return questions.allSatisfy { question in
            guard let answer = answers[question.id], Self.fits(answer, 8000) else { return false }
            return question.allowsOther || question.options.contains { $0.label == answer }
        }
    }
    private static func fits(_ value: String, _ bytes: Int, empty: Bool = false) -> Bool {
        value.utf8.prefix(bytes + 1).count <= bytes
            && (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
