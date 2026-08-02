import Foundation

// MARK: - Conversation Context

/// A reference or instruction attached to a user turn without becoming editable prompt prose.
///
/// Providers receive the same serialized envelope, while the timeline keeps this typed value so
/// the composer, local transcript, replay, and remote clients can all present one vocabulary.
struct ConversationContextAttachment: Codable, Equatable, Identifiable, Sendable {

    enum Kind: String, Codable, CaseIterable, Sendable {
        case reference
        case comment
    }

    enum Source: String, Codable, CaseIterable, Sendable {
        case message
        case code
        case attachment
    }

    let id: UUID
    let kind: Kind
    let source: Source

    /// A short, safe label such as `Agent response`, `PromptView.swift:42`, or `chart.png`.
    let title: String

    /// The quoted message, code line, or attachment description. It is bounded before transport.
    let excerpt: String?

    /// Human feedback. Present for `.comment`, absent for a context-only reference.
    let comment: String?

    /// A durable provider-neutral anchor. Paths are project-relative whenever the caller can
    /// resolve them; message anchors use their stable timeline row; attachment anchors use the
    /// store-relative path rather than a machine-private absolute path.
    let locator: String?

    let lineStart: Int?
    let lineEnd: Int?

    init(
        id: UUID = UUID(),
        kind: Kind,
        source: Source,
        title: String,
        excerpt: String? = nil,
        comment: String? = nil,
        locator: String? = nil,
        lineStart: Int? = nil,
        lineEnd: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.excerpt = excerpt
        self.comment = comment
        self.locator = locator
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }

    var presentationDetail: String {
        if let comment, !comment.isEmpty { return comment }
        if let excerpt, !excerpt.isEmpty { return excerpt }
        return locator ?? title
    }

    func commenting(_ body: String) -> ConversationContextAttachment {
        ConversationContextAttachment(
            kind: .comment,
            source: source,
            title: title,
            excerpt: excerpt,
            comment: body,
            locator: locator,
            lineStart: lineStart,
            lineEnd: lineEnd
        )
    }
}

/// One locally visible user turn. Context is retained beside the prose rather than pasted into
/// it, which keeps copy, selection, folding, and transcript exports readable.
struct ConversationUserMessage: Equatable, Sendable {
    let text: String
    let context: [ConversationContextAttachment]

    init(text: String, context: [ConversationContextAttachment] = []) {
        self.text = text
        self.context = ConversationContextPolicy.normalized(context)
    }
}

/// The value handed to every native provider transport.
struct ConversationPrompt: Equatable, Sendable {
    let text: String
    let context: [ConversationContextAttachment]

    init(text: String, context: [ConversationContextAttachment] = []) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = ConversationContextPolicy.normalized(context)
    }

    var visibleText: String {
        guard text.isEmpty else { return text }
        let comments = context.filter { $0.kind == .comment }.count
        if comments == 1 { return "Please address the comment above." }
        if comments > 1 { return "Please address the comments above." }
        return "Please use the attached context."
    }

    var userMessage: ConversationUserMessage {
        ConversationUserMessage(text: visibleText, context: context)
    }

    /// Appends a typed JSON envelope after the human prose. The envelope is deliberately one
    /// provider-neutral text shape: Claude, Codex, and ACP all accept text turns, and their own
    /// transcripts then preserve enough information for Threading to reconstruct the receipts.
    var transportText: String {
        guard !context.isEmpty,
              let data = try? ConversationContextPolicy.encoder.encode(context),
              data.count <= ConversationContextPolicy.maximumEnvelopeUTF8Bytes,
              let payload = String(data: data, encoding: .utf8) else {
            return visibleText
        }
        return "\(visibleText)\n\n\(ConversationContextPolicy.openingMarker)\n\(payload)\n\(ConversationContextPolicy.closingMarker)"
    }

    /// Recovers a prompt from a provider-owned transcript. A malformed or hand-written marker is
    /// ordinary user text: replay never hides bytes unless a complete, bounded envelope decodes.
    static func replaying(_ value: String) -> ConversationUserMessage {
        guard let opening = value.range(
            of: ConversationContextPolicy.openingMarker,
            options: .backwards
        ), let closing = value.range(
            of: ConversationContextPolicy.closingMarker,
            range: opening.upperBound..<value.endIndex
        ) else {
            return ConversationUserMessage(text: value)
        }

        let json = value[opening.upperBound..<closing.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.utf8.count <= ConversationContextPolicy.maximumEnvelopeUTF8Bytes,
              let data = json.data(using: .utf8),
              let decoded = try? ConversationContextPolicy.decoder.decode(
                  [ConversationContextAttachment].self,
                  from: data
              ) else {
            return ConversationUserMessage(text: value)
        }

        let normalized = ConversationContextPolicy.normalized(decoded)
        guard !normalized.isEmpty else { return ConversationUserMessage(text: value) }
        let prose = value[..<opening.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationUserMessage(
            text: prose.isEmpty ? ConversationPrompt(text: "", context: normalized).visibleText : prose,
            context: normalized
        )
    }
}

/// Bounds context before it enters a prompt, persisted transcript, or remote snapshot.
enum ConversationContextPolicy {
    static let maximumAttachments = 32
    static let maximumTitleCharacters = 200
    static let maximumDetailCharacters = 4_000
    static let maximumLocatorCharacters = 1_000
    static let maximumEnvelopeUTF8Bytes = 96 * 1_024
    static let openingMarker = "<threading_context_attachments version=\"1\">"
    static let closingMarker = "</threading_context_attachments>"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func normalized(
        _ attachments: [ConversationContextAttachment]
    ) -> [ConversationContextAttachment] {
        var seen: Set<UUID> = []
        var result: [ConversationContextAttachment] = []
        for attachment in attachments.prefix(maximumAttachments) {
            guard seen.insert(attachment.id).inserted else { continue }
            let title = bounded(attachment.title, maximum: maximumTitleCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let comment = boundedOptional(attachment.comment, maximum: maximumDetailCharacters)
            if attachment.kind == .comment, comment == nil { continue }

            let candidate = ConversationContextAttachment(
                id: attachment.id,
                kind: attachment.kind,
                source: attachment.source,
                title: title,
                excerpt: boundedOptional(
                    attachment.excerpt,
                    maximum: maximumDetailCharacters
                ),
                comment: comment,
                locator: boundedOptional(
                    attachment.locator,
                    maximum: maximumLocatorCharacters
                ),
                lineStart: attachment.lineStart.flatMap { $0 > 0 ? $0 : nil },
                lineEnd: attachment.lineEnd.flatMap { $0 > 0 ? $0 : nil }
            )

            let proposed = result + [candidate]
            guard let encoded = try? encoder.encode(proposed),
                  encoded.count <= maximumEnvelopeUTF8Bytes else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private static func boundedOptional(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let result = bounded(value, maximum: maximum)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum - 1)) + "…"
    }
}
