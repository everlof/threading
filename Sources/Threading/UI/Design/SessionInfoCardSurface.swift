import AppKit

#if os(Linux)
/// Linux's SDL overlay chassis for the shared session hover-card body. The fixed-theme host
/// already renders this Design panel above the navigator; the card itself remains one source.
@MainActor
enum SessionInfoCardSurface {
    static func panel(info: SessionInfoCardView.Info, appearance: NSAppearance) -> ThemedMenuPanelView {
        let card = SessionInfoCardView(info: info, isEmbedded: true)
        card.appearance = appearance
        let cardHeight = ceil(card.fittingSize.height)
        let padding = Design.Spacing.inset
        let panel = ThemedMenuPanelView(frame: NSRect(x: 0, y: 0,
            width: SessionPopoverDefaults.width,
            height: cardHeight + padding * 2))
        panel.setRows([card], heights: [cardHeight], padding: padding)
        panel.appearance = appearance
        return panel
    }
}
#endif
