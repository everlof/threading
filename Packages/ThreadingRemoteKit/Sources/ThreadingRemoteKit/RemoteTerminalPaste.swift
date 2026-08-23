import Foundation

/// Text on its way into a live terminal as a *paste* rather than as typing.
///
/// The distinction is the whole point. A remote client that types text into a PTY sends the
/// bytes as they stand, and a program reading them takes every line break for Return: a
/// three-line snippet submits its first line and leaves the other two arriving into whatever
/// the agent asked next. Bracketed paste is how a terminal says "this block came from
/// somewhere else" — Claude Code shows such a block as one `[Pasted text]` token — and a
/// program that asked for the mode is the only one that may be told.
///
/// The mode is not ours to guess. `RemoteTerminalModeSeed` states it to a joining client from
/// the Mac's live emulator, and every caller here passes that answer through; with the mode
/// off the text goes in exactly as typing it would, because that is all the program can read.
public enum RemoteTerminalPaste {

    // MARK: - Constants

    public static let start = "\u{1b}[200~"
    public static let end = "\u{1b}[201~"

    /// As many bytes as one terminal write may carry, matching what the host will accept.
    ///
    /// A clipboard is not a text field: it can be holding a whole file. The host refuses an
    /// oversized write outright, and a raw keystroke frame carries no acknowledgement, so a
    /// client that does not ask this question first pastes into silence.
    public static let maximumBytes = 64 * 1024

    // MARK: - Public Methods

    /// `text` delimited as one paste when the program has bracketed paste on.
    public static func delimited(_ text: String, bracketedPaste: Bool) -> String {
        guard bracketedPaste, !text.isEmpty else { return text }
        return start + text + end
    }

    /// Whether a line break makes this text a paste rather than typing.
    ///
    /// Typing cannot produce one — Return submits — so a draft that carries a line break was
    /// pasted into the composer, and sending it undelimited reproduces the bug bracketed paste
    /// exists to prevent one layer further out.
    public static func carriesLineBreaks(_ text: String) -> Bool {
        text.contains { $0.isNewline }
    }

    /// Whether a write of this text is within what the host will accept.
    public static func fits(_ text: String) -> Bool {
        text.utf8.count <= maximumBytes
    }
}
