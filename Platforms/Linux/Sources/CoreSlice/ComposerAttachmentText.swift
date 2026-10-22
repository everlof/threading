import Foundation

/// The path spelling both local and scheduled composer sends hand to an agent.
enum ComposerAttachmentText {
    static func appending(paths: [String], to text: String) -> String {
        guard !paths.isEmpty else { return text }

        let addition = paths.map(quotedPath).joined(separator: " ")
        guard !text.isEmpty else { return addition }
        guard !text.hasSuffix(" "), !text.hasSuffix("\n") else {
            return text + addition
        }
        return text + " " + addition
    }

    static func quotedPath(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
