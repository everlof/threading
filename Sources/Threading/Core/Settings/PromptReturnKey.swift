import Foundation

/// What the Return key does in a prompt composer. The default follows each composer's
/// send placement; the other choices give the user one answer in every composer.
/// ⌘Return always sends, while Shift- and Option-Return always start a new line.
/// Raw values are persisted, so case names are part of the settings contract.
public enum PromptReturnKey: String, CaseIterable {
    case matchesComposer
    case sends
    case startsNewLine

    var settingsTitle: String {
        switch self {
        case .matchesComposer: L10n.string("Do What the Composer Expects")
        case .sends: L10n.string("Send")
        case .startsNewLine: L10n.string("Start a New Line")
        }
    }

    var settingsDetail: String {
        switch self {
        case .matchesComposer:
            L10n.string("A box with a send control in it sends; a note attached to a report takes a line break.")
        case .sends:
            L10n.string("Shift-Return starts a new line.")
        case .startsNewLine:
            L10n.string("Command-Return sends.")
        }
    }
}
