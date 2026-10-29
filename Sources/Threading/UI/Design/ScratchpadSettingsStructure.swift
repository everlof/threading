import AppKit

/// One Scratchpad Settings row on both desktop hosts; hosts own choosing and moving the folder.
@MainActor
enum ScratchpadSettingsStructure {
    static let help = "Chats that are about no project live here. The folder is made the first time "
        + "you start a scratchpad, and it is an ordinary git repository, so Git Review works "
        + "on it and nothing you write is lost. It sits outside Threading's own storage on "
        + "purpose — Reset Everything does not touch it."

    static var helpTopic: HelpTopic {
        HelpTopic(title: L10n.string("Scratchpad folder"),
                  paragraphs: [L10n.string(help)])
    }

    static func row(path: String, choose: ThemedButton, useDefault: ThemedButton,
                    helpButton: NSView? = nil) -> (view: NSView, pathLabel: NSTextField) {
        choose.title = L10n.string("Choose…")
        useDefault.title = L10n.string("Use Default")

        let title = NSTextField(labelWithString: L10n.string("Scratchpad folder"))
        title.applyFont(.body)
        title.textColor = Design.Text.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleView = helpButton.map { SettingsRowStructure.titleLine(title, helpButton: $0) }
            ?? title

        let pathLabel = SettingsRowStructure.wrappingSubtitle(path)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let controls = NSStackView(views: [choose, useDefault])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = Design.Spacing.small
        choose.setContentHuggingPriority(.required, for: .horizontal)
        useDefault.setContentHuggingPriority(.required, for: .horizontal)
        let view = SettingsRowStructure.assemble([titleView, pathLabel], control: controls)
        return (view, pathLabel)
    }
}
