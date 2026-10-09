import ThreadingRemoteKit

struct RemoteConversationResultLink: Equatable, Sendable {
    let title: String
    let detail: String
    let symbol: String
    let route: SessionWorkspaceRoute

    /// Three navigation cards at most. An image is linked only when this answer names an
    /// attachment the host actually admitted. Review and Browser explicitly describe current
    /// workspace state; they never claim a historical diff or a successful test result.
    static func links(
        answer: String, attachments: [RemoteAttachmentDTO], workspace: RemoteWorkspaceDTO?
    ) -> [Self] {
        var result = [Self(
            title: MobileL10n.string("Review changes"), detail: MobileL10n.string("Current working tree"),
            symbol: "plus.forwardslash.minus", route: .review
        )]
        if let attachment = attachments.first(where: {
            $0.kind == .image && !$0.path.isEmpty && answer.contains($0.path)
        }) {
            result.append(Self(title: MobileL10n.string("Open image"), detail: attachment.name,
                               symbol: "photo", route: .attachment(id: attachment.id)))
        } else if !attachments.isEmpty {
            result.append(Self(title: MobileL10n.string("Attachments"), detail: MobileL10n.string("Files shared in this chat"),
                               symbol: "paperclip", route: .attachments))
        }
        if let tab = workspace?.browserTabs.first(where: { $0.isActive && !$0.isPrivate }) {
            result.append(Self(title: MobileL10n.string("Open browser"), detail: tab.title,
                               symbol: "globe", route: .browser(tabID: tab.id)))
        }
        return result
    }
}
