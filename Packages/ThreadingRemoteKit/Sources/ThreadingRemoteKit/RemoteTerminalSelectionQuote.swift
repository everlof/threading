import Foundation

/// Terminal lines a person selected on a remote client and chose to send to the agent running
/// in that terminal.
///
/// The quote is a snapshot: the buffer it was cut from keeps moving, so the chip that stands
/// for it in the composer holds the text itself rather than a range. It is trimmed the way a
/// terminal row deserves — trailing cell padding dropped from every line, blank lines dropped
/// from both ends — and refuses to exist for a selection that held nothing but whitespace.
public struct RemoteTerminalSelectionQuote: Equatable, Hashable, Identifiable, Sendable {
    /// As many quotes as one message carries; the same bound attachments use.
    public static let maximumPerMessage = 8
    /// The longest preview a chip shows before an ellipsis.
    public static let previewLength = 60
    static let quoteSeparator = "\n\n"
    static let draftSeparator = " "

    public let id: UUID
    public let lines: [String]

    public init?(id: UUID = UUID(), selectedText: String) {
        var lines = selectedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.trimmingTrailingWhitespace(String($0)) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        self.id = id
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }

    public var lineCount: Int { lines.count }

    /// The first line that says something, with runs of whitespace collapsed and a cap on
    /// length, for the chip's one line of context.
    public var preview: String {
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let collapsed = first
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > Self.previewLength else { return collapsed }
        return String(collapsed.prefix(Self.previewLength)) + "…"
    }

    /// `quotes` with `quote` added, unless the message is already carrying its full
    /// complement, in which case the list is returned unchanged.
    public static func appending(
        _ quote: RemoteTerminalSelectionQuote,
        to quotes: [RemoteTerminalSelectionQuote]
    ) -> [RemoteTerminalSelectionQuote] {
        guard quotes.count < maximumPerMessage else { return quotes }
        return quotes + [quote]
    }

    /// The bytes that put `quotes` into a live prompt, as text typed at the cursor.
    ///
    /// When the program has bracketed paste on, the quotes travel as one paste, which is what
    /// keeps an agent's prompt from treating every line break as Return; Claude Code shows such
    /// a block as one "[Pasted text]" token. Without bracketed paste the lines go in as typed,
    /// exactly as pasting them would.
    public static func insertionText(
        for quotes: [RemoteTerminalSelectionQuote],
        bracketedPaste: Bool
    ) -> String {
        guard !quotes.isEmpty else { return "" }
        let body = quotes.map(\.text).joined(separator: quoteSeparator)
        return RemoteTerminalPaste.delimited(body, bracketedPaste: bracketedPaste)
    }

    /// One composed line for the atomic terminal submission: the quotes first, then whatever
    /// the person typed after them. The host appends Return.
    public static func submissionText(
        for quotes: [RemoteTerminalSelectionQuote],
        draft: String,
        bracketedPaste: Bool
    ) -> String {
        let quoted = insertionText(for: quotes, bracketedPaste: bracketedPaste)
        guard !quoted.isEmpty else { return typedText(draft, bracketedPaste: bracketedPaste) }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return quoted }
        return quoted + draftSeparator + typedText(typed, bracketedPaste: bracketedPaste)
    }

    /// What the person typed, delimited as a paste when it carries line breaks.
    ///
    /// The host writes a submitted line into the PTY as it stands and appends Return, so a
    /// draft holding a line break arrives as several Returns: the first line submits and the
    /// rest land in whatever the agent asked next. Pasting is the only way a line break gets
    /// into that box — Return sends — so this is the composer's half of the same rule the
    /// quotes already follow. A single-line draft is typing, and is left exactly as typed.
    private static func typedText(_ draft: String, bracketedPaste: Bool) -> String {
        guard bracketedPaste, RemoteTerminalPaste.carriesLineBreaks(draft) else { return draft }
        // The host trims the ends of an undelimited line before writing it. Delimiters would
        // hide that trim from it, so the blank edges a pasted block usually carries are dropped
        // here instead of arriving as leading and trailing Returns inside the paste.
        return RemoteTerminalPaste.delimited(
            draft.trimmingCharacters(in: .newlines),
            bracketedPaste: true
        )
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var scalars = Substring(line)
        while let last = scalars.last, last.isWhitespace || last == "\0" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
