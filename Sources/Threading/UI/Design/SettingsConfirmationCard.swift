import AppKit

/// The confirmation rows shown in General Settings on either desktop host. Hosts provide
/// preference state and actions; this component owns the row and card hierarchy.
@MainActor
enum SettingsConfirmationCard {
    struct Choice {
        let title: String
        let subtitle: String
        let control: NSView
    }

    static func make(choices: [Choice], trailingRows: [NSView] = [])
        -> (card: SettingsCard, choiceRows: [NSView]) {
        let choiceRows = choices.map { choice in
            SettingsRowStructure.make(title: choice.title,
                                      subtitle: choice.subtitle,
                                      control: choice.control)
        }
        return (SettingsCard(rows: choiceRows + trailingRows), choiceRows)
    }
}
