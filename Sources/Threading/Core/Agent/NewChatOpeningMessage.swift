import Foundation

/// Joins a chat's own task with reusable text from Settings, on either side of it.
/// The caller keeps the task alone for the sidebar title.
enum NewChatOpeningMessage {
    static func compose(prompt: String?, prefix: String, suffix: String) -> String? {
        let parts = [prefix, prompt, suffix]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
