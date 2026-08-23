import Foundation

// MARK: - Claude Task Notification

/// One legacy background-task notification injected into a Claude conversation.
///
/// Claude has emitted these as XML-shaped text both inside a message and as the payload of a
/// `queue-operation`. The envelope is provider control data, not agent prose: the subagent
/// projection uses it to finish a child row, while usage-limit observation uses a failed
/// notification only as *provisional* evidence that the parent conversation may now be blocked.
/// Keeping the parse here prevents those two consumers from quietly accepting different shapes.
struct ClaudeTaskNotification: Equatable, Sendable {

    // MARK: - Properties

    let taskID: String?
    let toolUseID: String?
    let status: String?
    let summary: String?

    /// The provider identity that remains stable when the same notification is read again.
    var identity: String? { toolUseID ?? taskID }

    var isFailed: Bool {
        status?.caseInsensitiveCompare("failed") == .orderedSame
    }

    // MARK: - Public Methods

    static func parse(_ text: String) -> ClaudeTaskNotification? {
        guard let envelope = envelope(in: text) else { return nil }

        return ClaudeTaskNotification(
            taskID: tagValue("task-id", in: envelope),
            toolUseID: tagValue("tool-use-id", in: envelope),
            status: tagValue("status", in: envelope),
            summary: tagValue("summary", in: envelope)
        )
    }

    // MARK: - Private Methods

    /// Isolates one complete envelope. An opening tag alone is not control data while Claude is
    /// still appending the record.
    private static func envelope(in text: String) -> Substring? {
        let opening = "<task-notification>"
        let closing = "</task-notification>"
        guard let openingRange = text.range(of: opening),
              let closingRange = text.range(
                of: closing,
                range: openingRange.upperBound..<text.endIndex
              )
        else { return nil }

        return text[openingRange.lowerBound..<closingRange.upperBound]
    }

    private static func tagValue(_ tag: String, in text: Substring) -> String? {
        let opening = "<\(tag)>"
        let closing = "</\(tag)>"
        guard let openingRange = text.range(of: opening),
              let closingRange = text.range(
                of: closing,
                range: openingRange.upperBound..<text.endIndex
              )
        else { return nil }

        let value = text[openingRange.upperBound..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
