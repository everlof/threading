import Foundation

struct WorkspaceFileReference: Equatable, Hashable, Sendable {
    /// Always relative to the selected session's execution checkout.
    let path: String
}

struct WorkspaceFileMentionQuery: Equatable, Sendable {
    let term: String
    let replacementRange: NSRange

    /// A mention starts only at a token boundary. `mail@example.com` and prose containing an @
    /// remain ordinary text; a leading or whitespace-delimited `@path` opens file completion.
    static func parse(text: String, caretUTF16Offset: Int) -> WorkspaceFileMentionQuery? {
        let utf16 = Array(text.utf16)
        guard caretUTF16Offset >= 0, caretUTF16Offset <= utf16.count else { return nil }
        var start = caretUTF16Offset
        while start > 0 {
            let scalar = utf16[start - 1]
            guard scalar != 0x20, scalar != 0x09, scalar != 0x0A, scalar != 0x0D else { break }
            start -= 1
        }
        guard start < caretUTF16Offset, utf16[start] == 0x40 else { return nil }
        if start > 0 {
            let previous = utf16[start - 1]
            guard previous == 0x20 || previous == 0x09 || previous == 0x0A || previous == 0x0D else {
                return nil
            }
        }
        let range = NSRange(location: start + 1, length: caretUTF16Offset - start - 1)
        guard let swiftRange = Range(range, in: text) else { return nil }
        return WorkspaceFileMentionQuery(
            term: String(text[swiftRange]),
            replacementRange: NSRange(location: start, length: caretUTF16Offset - start)
        )
    }
}

enum WorkspaceFileSearchFailure: Error, Equatable, Sendable {
    case sessionUnavailable
    case checkoutUnavailable
    case repositoryUnavailable
    case indexTooLarge(limit: Int)
    case fileUnavailable(path: String)
}
