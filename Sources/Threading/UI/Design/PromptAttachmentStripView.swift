import AppKit

/// Scrollable image rail shared by both composers. Callers supply their attachment tiles and
/// own decoding and submission; this view owns the strip's hierarchy and sizing.
@MainActor
class PromptAttachmentStripView: ThemedScrollView {
    let content = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // The scroll view sizes its document; Auto Layout still sizes each tile inside it.
        content.translatesAutoresizingMaskIntoConstraints = true
        documentView = content
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .none
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var hasTiles: Bool { !content.arrangedSubviews.isEmpty }
    var attachmentHeight: CGFloat {
        hasTiles ? Design.Size.promptAttachmentThumbnail + Design.Spacing.medium : 0
    }

    func appendTile(_ tile: NSView) {
        content.addArrangedSubview(tile)
        layoutTiles()
    }

    func removeTile(_ tile: NSView) {
        content.removeArrangedSubview(tile)
        tile.removeFromSuperview()
        layoutTiles()
    }

    func clearTiles() {
        for tile in content.arrangedSubviews {
            content.removeArrangedSubview(tile)
            tile.removeFromSuperview()
        }
        layoutTiles()
        contentView.scroll(to: .zero)
    }

    func layoutTiles() {
        let count = content.arrangedSubviews.count
        guard count > 0 else {
            content.frame = .zero
            isHidden = true
            return
        }
        let side = Design.Size.promptAttachmentThumbnail
        let gap = Design.Spacing.small
        let width = CGFloat(count) * side + CGFloat(count - 1) * gap
        content.frame = NSRect(x: 0, y: 0, width: max(width, contentView.bounds.width),
                             height: side)
        content.layoutSubtreeIfNeeded()
        content.needsDisplay = true
        isHidden = false
    }
}
