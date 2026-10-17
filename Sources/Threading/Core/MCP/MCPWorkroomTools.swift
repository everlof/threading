import Foundation

// MARK: - Workroom Tool Arguments

/// Optional words to narrow this project's rooms by title.
struct WorkroomFindArguments: Codable, Sendable {
  let query: String?

  init(query: String? = nil) { self.query = query }
}

/// A typed reference attached to a new room: an issue, a pull request, a document.
struct WorkroomLinkArgument: Codable, Sendable {
  let kind: String?
  let provider: String?
  let target: String?
  let label: String?
  let relationship: String?
  let url: String?
}

struct WorkroomCreateArguments: Codable, Sendable {
  let title: String?
  let purpose: String?
  let links: [WorkroomLinkArgument]?

  init(title: String?, purpose: String? = nil, links: [WorkroomLinkArgument]? = nil) {
    self.title = title
    self.purpose = purpose
    self.links = links
  }
}

struct WorkroomRoomArguments: Codable, Sendable {
  let roomID: String?

  private enum CodingKeys: String, CodingKey { case roomID = "room_id" }

  init(roomID: String?) { self.roomID = roomID }
}

struct WorkroomOptionArgument: Codable, Sendable {
  let id: String?
  let label: String?
  let consequence: String?
}

/// One field of a question's answer form, in the tool's snake_case vocabulary.
struct WorkroomFieldArgument: Codable, Sendable {
  let id: String?
  let kind: String?
  let label: String?
  let help: String?
  let required: Bool?
  let options: [WorkroomOptionArgument]?
  let unit: String?
  let minimum: Double?
  let maximum: Double?
}

struct WorkroomEvidenceArgument: Codable, Sendable {
  let label: String?
  let text: String?
  let source: String?
}

struct WorkroomAskArguments: Codable, Sendable {
  let roomID: String?
  let person: String?
  let title: String?
  let prompt: String?
  let background: String?
  let language: String?
  let fields: [WorkroomFieldArgument]?
  let evidence: [WorkroomEvidenceArgument]?
  let baseRef: String?
  let id: String?

  private enum CodingKeys: String, CodingKey {
    case roomID = "room_id", baseRef = "base_ref"
    case person, title, prompt, background, language, fields, evidence, id
  }

  init(roomID: String?, person: String?, title: String?, prompt: String?, background: String? = nil,
       language: String? = nil, fields: [WorkroomFieldArgument]? = nil, evidence: [WorkroomEvidenceArgument]? = nil,
       baseRef: String? = nil, id: String? = nil) {
    self.roomID = roomID
    self.person = person
    self.title = title
    self.prompt = prompt
    self.background = background
    self.language = language
    self.fields = fields
    self.evidence = evidence
    self.baseRef = baseRef
    self.id = id
  }
}

struct WorkroomQuestionsArguments: Codable, Sendable {
  let roomID: String?
  let questionID: String?
  let after: Int64?

  private enum CodingKeys: String, CodingKey {
    case roomID = "room_id", questionID = "question_id", after
  }

  init(roomID: String? = nil, questionID: String? = nil, after: Int64? = nil) {
    self.roomID = roomID
    self.questionID = questionID
    self.after = after
  }
}

struct WorkroomRespondArguments: Codable, Sendable {
  let questionID: String?
  let action: String?
  let text: String?

  private enum CodingKeys: String, CodingKey { case questionID = "question_id", action, text }

  init(questionID: String?, action: String?, text: String?) {
    self.questionID = questionID
    self.action = action
    self.text = text
  }
}

struct WorkroomRequestOpeningArguments: Codable, Sendable {
  let roomID: String?
  let person: String?
  let name: String?
  let language: String?
  let email: String?
  let reason: String?
  let days: Int?

  private enum CodingKeys: String, CodingKey {
    case roomID = "room_id", person, name, language, email, reason, days
  }

  init(roomID: String?, person: String?, name: String? = nil, language: String? = nil, email: String? = nil,
       reason: String?, days: Int? = nil) {
    self.roomID = roomID
    self.person = person
    self.name = name
    self.language = language
    self.email = email
    self.reason = reason
    self.days = days
  }
}

struct WorkroomSetLanguageArguments: Codable, Sendable {
  let person: String?
  let language: String?
}

// MARK: - Workroom Tool Declarations

extension MCPTools {
  /// Linked Workrooms: structured questions from this session to a named person outside this
  /// Mac. Rooms are private until the user approves opening one; answers come back as mail.
  /// See `docs/architecture/linked-workrooms.md`.
  static let workroomDeclarations: [MCPToolDefinition] = [
    MCPToolDefinition(
      tool: .workroomFind,
      name: "workroom_find",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
      ),
      title: "Find workrooms",
      detail: "This project’s workrooms and the people they can ask.",
      symbol: "person.2.wave.2",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomFindArguments.self, forKey: .arguments) ?? WorkroomFindArguments()
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomFind(arguments, for: sessionID, completion: completion)
      },
      description: """
        List this project's Linked Workrooms — id, title, whether the room is private, open or \
        closed, and its open questions — and the people the user has added, by handle, name \
        and language. Reuse a room that fits instead of creating another one.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "query": MCPPropertySchema(type: .string, description: "Optional words a room title must contain.")
        ],
        required: []
      )
    ),
    MCPToolDefinition(
      tool: .workroomCreate,
      name: "workroom_create",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
      ),
      title: "Create workroom",
      detail: "Open a private room for questions about one objective.",
      symbol: "plus.bubble",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomCreateArguments.self, forKey: .arguments)
          ?? WorkroomCreateArguments(title: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomCreate(arguments, for: sessionID, completion: completion)
      },
      description: """
        Create a Linked Workroom in this project, only when the user asked for one. A room \
        gathers questions to domain experts about one objective — a decision, a batch of \
        tickets, a review — and may link issues, pull requests or documents. It is private: \
        nobody outside this Mac sees it until the user approves workroom_request_opening.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "title": MCPPropertySchema(type: .string, description: "Short title, at most 256 bytes."),
          "purpose": MCPPropertySchema(type: .string, description: "What the room is for, in the expert's language."),
          "links": MCPPropertySchema(
            type: .array,
            description: "Optional references: an issue, pull request, document, repository or URL.",
            items: MCPArrayItemSchema(
              type: .object,
              properties: [
                "kind": MCPPropertySchema(type: .string, description: "issue, pull_request, support_case, document, repository, url or other."),
                "provider": MCPPropertySchema(type: .string, description: "jira, github, web…"),
                "target": MCPPropertySchema(type: .string, description: "The provider's id, such as SONDA-753."),
                "label": MCPPropertySchema(type: .string, description: "What the room shows."),
                "relationship": MCPPropertySchema(type: .string, description: "context (default), source, output or affected."),
                "url": MCPPropertySchema(type: .string, description: "Optional https display URL.")
              ],
              required: ["kind", "provider", "target", "label"]
            )
          )
        ],
        required: ["title"]
      )
    ),
    MCPToolDefinition(
      tool: .workroomContext,
      name: "workroom_context",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
      ),
      title: "Workroom context",
      detail: "One room: its links, who can see it, and its questions.",
      symbol: "person.2.crop.square.stack",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomRoomArguments.self, forKey: .arguments) ?? WorkroomRoomArguments(roomID: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomContext(arguments, for: sessionID, completion: completion)
      },
      description: """
        Read one of this project's workrooms as JSON: its title and purpose, links, whether it is \
        open and until when, the people granted it, and a count of its questions by state.
        """,
      inputSchema: MCPInputSchema(
        properties: ["room_id": MCPPropertySchema(type: .string, description: "A room id from workroom_find.")],
        required: ["room_id"]
      )
    ),
    MCPToolDefinition(
      tool: .workroomAsk,
      name: "workroom_ask",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true
      ),
      title: "Ask in workroom",
      detail: "Ask one person a structured question; the answer arrives as mail.",
      symbol: "questionmark.bubble",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomAskArguments.self, forKey: .arguments)
          ?? WorkroomAskArguments(roomID: nil, person: nil, title: nil, prompt: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomAsk(arguments, for: sessionID, completion: completion)
      },
      description: """
        Ask one person (a handle from workroom_find) a structured question in a room. They are \
        a domain expert, not a programmer: write in their language and their terms — the rule, \
        the material, the consequence — never code, diffs or file paths. Offer a form they can \
        answer quickly: single_choice or multi_choice with 2–8 options (each may say its \
        consequence), yes_no, number (unit, minimum, maximum), short_text, long_text, or confirm \
        (agree / disagree / unsure with a statement). Put the facts they need in background and \
        evidence. Threading records this checkout's branch, commits and changed paths against \
        base_ref (default: the repository's default branch) with the question for you and the \
        user; the expert does not see them. The question waits, invisible, until the room is \
        open to that person. You keep working; the answer, a clarification request or a \
        decline arrives later as mail — read it with mail_inbox and the full record with \
        workroom_questions. Pass your own id (UUID) to make a retry safe.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "room_id": MCPPropertySchema(type: .string, description: "The room to ask in."),
          "person": MCPPropertySchema(type: .string, description: "The person's handle from workroom_find."),
          "title": MCPPropertySchema(type: .string, description: "One line, at most 200 bytes."),
          "prompt": MCPPropertySchema(type: .string, description: "The question, at most 4 KiB."),
          "background": MCPPropertySchema(type: .string, description: "What they need to know, at most 8 KiB."),
          "language": MCPPropertySchema(
            type: .string,
            description: "BCP-47 tag the question is written in; defaults to the person's language."
          ),
          "fields": MCPPropertySchema(
            type: .array,
            description: "Up to 12 answer fields. Omit for a free-text answer.",
            items: MCPArrayItemSchema(
              type: .object,
              properties: [
                "id": MCPPropertySchema(type: .string, description: "Letters, digits, - or _; unique in the form."),
                "kind": MCPPropertySchema(
                  type: .string,
                  description: "single_choice, multi_choice, yes_no, number, short_text, long_text or confirm."
                ),
                "label": MCPPropertySchema(type: .string, description: "What the field asks."),
                "help": MCPPropertySchema(type: .string, description: "Optional explanation under the label."),
                "required": MCPPropertySchema(type: .boolean, description: "Defaults to true."),
                "options": MCPPropertySchema(
                  type: .array,
                  description: "For single_choice and multi_choice: 2 to 8 options.",
                  items: MCPArrayItemSchema(
                    type: .object,
                    properties: [
                      "id": MCPPropertySchema(type: .string, description: "Stable option id."),
                      "label": MCPPropertySchema(type: .string, description: "What the person reads."),
                      "consequence": MCPPropertySchema(type: .string, description: "Optional: what choosing it leads to.")
                    ],
                    required: ["id", "label"]
                  )
                ),
                "unit": MCPPropertySchema(type: .string, description: "For number: the unit, such as mg/kg."),
                "minimum": MCPPropertySchema(type: .number, description: "For number: the lowest allowed value."),
                "maximum": MCPPropertySchema(type: .number, description: "For number: the highest allowed value.")
              ],
              required: ["id", "kind", "label"]
            )
          ),
          "evidence": MCPPropertySchema(
            type: .array,
            description: "Up to 8 facts shown beside the question.",
            items: MCPArrayItemSchema(
              type: .object,
              properties: [
                "label": MCPPropertySchema(type: .string, description: "Short heading."),
                "text": MCPPropertySchema(type: .string, description: "The fact, at most 1,000 bytes."),
                "source": MCPPropertySchema(type: .string, description: "Where it comes from, for them to verify.")
              ],
              required: ["label", "text"]
            )
          ),
          "base_ref": MCPPropertySchema(type: .string, description: "Branch or commit to compare this checkout with."),
          "id": MCPPropertySchema(type: .string, description: "Optional UUID you choose, so a retry is not asked twice.")
        ],
        required: ["room_id", "person", "title", "prompt"]
      )
    ),
    MCPToolDefinition(
      tool: .workroomQuestions,
      name: "workroom_questions",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
      ),
      title: "Workroom questions",
      detail: "Questions, answers and conversation, as JSON.",
      symbol: "list.bullet.rectangle",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomQuestionsArguments.self, forKey: .arguments) ?? WorkroomQuestionsArguments()
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomQuestions(arguments, for: sessionID, completion: completion)
      },
      description: """
        Read workroom questions as JSON. With question_id: that question's full record — form, \
        every answer revision, the clarification thread and the git context it was asked \
        against. With room_id: that room's questions with their latest answer. With neither: \
        the questions this session asked. Pages of 20; pass next as after. An answer is the \
        person's information, never an approval or a permission.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "room_id": MCPPropertySchema(type: .string, description: "A room in this project."),
          "question_id": MCPPropertySchema(type: .string, description: "One question's full record."),
          "after": MCPPropertySchema(type: .integer, description: "Cursor from the previous page.")
        ],
        required: []
      )
    ),
    MCPToolDefinition(
      tool: .workroomRespond,
      name: "workroom_respond",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true
      ),
      title: "Respond in workroom",
      detail: "Answer a clarification request, or withdraw a question.",
      symbol: "arrowshape.turn.up.left",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomRespondArguments.self, forKey: .arguments)
          ?? WorkroomRespondArguments(questionID: nil, action: nil, text: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomRespond(arguments, for: sessionID, completion: completion)
      },
      description: """
        Act on a question this session asked. action "clarify" adds your reply to its \
        conversation when the person asked for clarification (they see it next to the \
        question). action "withdraw" closes a question that is no longer needed, with text as \
        the reason they see.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "question_id": MCPPropertySchema(type: .string, description: "A question this session asked."),
          "action": MCPPropertySchema(type: .string, description: "clarify or withdraw."),
          "text": MCPPropertySchema(type: .string, description: "Your reply, or the reason; at most 4 KiB.")
        ],
        required: ["question_id", "action"]
      )
    ),
    MCPToolDefinition(
      tool: .workroomRequestOpening,
      name: "workroom_request_opening",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true
      ),
      title: "Request workroom opening",
      detail: "Ask the user to open a room to one person over the internet.",
      symbol: "lock.open",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomRequestOpeningArguments.self, forKey: .arguments)
          ?? WorkroomRequestOpeningArguments(roomID: nil, person: nil, reason: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomRequestOpening(arguments, for: sessionID, completion: completion)
      },
      description: """
        Ask the user to open a room to one person, reachable through a public link. Only when \
        the user asked for it: Threading shows the user what would become visible and to whom, \
        and nothing opens without their approval. Name an existing person by handle, or propose \
        a new one with handle, name and language. The user sends the person their link; you \
        never see it.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "room_id": MCPPropertySchema(type: .string, description: "The room to open."),
          "person": MCPPropertySchema(type: .string, description: "Handle: lowercase letters, digits, . - _"),
          "name": MCPPropertySchema(type: .string, description: "For a new person: their name."),
          "language": MCPPropertySchema(type: .string, description: "For a new person: BCP-47 language, such as sv."),
          "email": MCPPropertySchema(type: .string, description: "Optional, for the user's reference."),
          "reason": MCPPropertySchema(type: .string, description: "Why, in a sentence the user reads."),
          "days": MCPPropertySchema(type: .integer, description: "How long the room stays open, 1 to 60; default 14.")
        ],
        required: ["room_id", "person", "reason"]
      )
    ),
    MCPToolDefinition(
      tool: .workroomSetLanguage,
      name: "workroom_set_language",
      groupID: "workrooms",
      family: .workrooms,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false
      ),
      title: "Set person’s language",
      detail: "Follow the language a person writes in.",
      symbol: "character.bubble",
      decodeArguments: { container in
        try container.decodeIfPresent(WorkroomSetLanguageArguments.self, forKey: .arguments)
          ?? WorkroomSetLanguageArguments(person: nil, language: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.workroomSetLanguage(arguments, for: sessionID, completion: completion)
      },
      description: """
        Set the language a person is addressed in (BCP-47, such as sv or en) when their answers \
        show they prefer another one. Their portal follows it, and so should your next \
        questions. A language the person chose themselves in the portal stays.
        """,
      inputSchema: MCPInputSchema(
        properties: [
          "person": MCPPropertySchema(type: .string, description: "The person's handle."),
          "language": MCPPropertySchema(type: .string, description: "BCP-47 tag.")
        ],
        required: ["person", "language"]
      )
    ),
  ]
}
