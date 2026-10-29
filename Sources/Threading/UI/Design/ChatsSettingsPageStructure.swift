import AppKit

/// The Chats Settings section hierarchy shared by the macOS host and Linux AppKit shim.
/// Hosts supply the controls and services; this view owns their order, captions and help.
@MainActor
enum ChatsSettingsPageStructure {
    struct Content {
        let newChats: SettingsCard
        let openingMessage: SettingsCard
        let attachments: SettingsCard?
        let scratchpad: SettingsCard
    }

    static var attachmentsHelpTopic: HelpTopic {
        HelpTopic(title: L10n.string("Attachments"), paragraphs: [L10n.string(
            "Threading reads each agent's output for image, PDF, document, archive "
                + "and diagram paths and lists them in the chat's panel. Turn an agent "
                + "off here if an update changes how it prints paths."
        )])
    }

    static func sections(
        _ content: Content,
        openingHelpButton: NSView? = nil,
        attachmentsHelpButton: NSView? = nil
    ) -> [NSView] {
        let openingHelp = openingHelpButton
            ?? HelpPopoverButton(topic: OpeningMessageSettingsStructure.sectionHelpTopic)
        var result = [
            section("New Chats", content: content.newChats),
            section("Opening Message", content: content.openingMessage, helpButton: openingHelp)
        ]
        if let attachments = content.attachments {
            let help = attachmentsHelpButton
                ?? HelpPopoverButton(topic: attachmentsHelpTopic)
            result.append(section("Attachments", content: attachments, helpButton: help))
        }
        result.append(section("Scratchpad", content: content.scratchpad))
        return result
    }

    private static func section(_ title: String, content: NSView,
                                helpButton: NSView? = nil) -> NSView {
        let caption = SettingsPageStructure.caption(L10n.string(title))
        let titleView = helpButton.map {
            SettingsRowStructure.titleLine(caption, helpButton: $0)
        } ?? caption
        return SettingsPageStructure.section(caption: titleView, content: content)
    }
}
