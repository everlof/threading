import AppKit

/// The two standing instructions flank the task in the same order on both desktop hosts.
@MainActor
enum OpeningMessageSettingsStructure {
    struct Row {
        let title: String
        let subtitle: String
    }

    static let prefixPlaceholder =
        "For example: Think it through before you start changing files."
    static let suffixPlaceholder =
        "For example: Rename this chat to a ONE-WORD, ALL-CAPS name that represents it."
    static let sectionHelp =
        "Both are sent once, inside the first turn of a new chat — side chats and "
        + "cross-provider continuations included. Neither is sent again when a "
        + "chat resumes, and an imported conversation receives nothing. The name "
        + "in the sidebar still comes from the task you wrote."

    static var sectionHelpTopic: HelpTopic {
        HelpTopic(title: L10n.string("Opening Message"),
                  paragraphs: [L10n.string(sectionHelp)])
    }

    static func rows(prefixField: NSView, suffixField: NSView,
                     makeLabelRow: (Row) -> NSView,
                     makeFullRow: (NSView) -> NSView) -> [NSView] {
        let before = Row(title: "Before the task you write",
            subtitle: "Sent once ahead of the task, framing how this chat should be worked on.")
        let after = Row(title: "After the task you write",
            subtitle: "Sent once after the task, for a standing instruction about the answer.")
        if prefixField.accessibilityLabel()?.isEmpty != false {
            prefixField.setAccessibilityLabel(before.title)
        }
        if suffixField.accessibilityLabel()?.isEmpty != false {
            suffixField.setAccessibilityLabel(after.title)
        }
        return [
            makeLabelRow(before),
            makeFullRow(prefixField),
            makeLabelRow(after),
            makeFullRow(suffixField)
        ]
    }
}
