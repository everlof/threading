import AppKit

/// The leading icon and text slots shared by native navigator rows. A host supplies its
/// resolved spacing and retains row selection, actions, accessibility and trailing content.
/// The geometry is a value so a bitmap backend can place ink without building offscreen views.
struct NavigatorRowGeometry: Equatable, Sendable {
    let leadingInset: CGFloat
    let iconSlotWidth: CGFloat
    let contentGap: CGFloat

    init(leadingInset: CGFloat, iconSlotWidth: CGFloat, contentGap: CGFloat) {
        self.leadingInset = leadingInset
        self.iconSlotWidth = iconSlotWidth
        self.contentGap = contentGap
    }

    /// A row's title starts after the same slot whether its icon is an image, a fallback
    /// mark, or absent. That keeps every title in the list on one line.
    var titleLeadingOffset: CGFloat { leadingInset + iconSlotWidth + contentGap }

    /// Centres the visible mark in the fixed slot, independently of the mark's own size.
    func iconRect(in row: NSRect, side: CGFloat) -> NSRect {
        let fittedSide = max(0, min(side, iconSlotWidth, row.height))
        return NSRect(
            x: row.minX + leadingInset + (iconSlotWidth - fittedSide) / 2,
            y: row.midY - fittedSide / 2,
            width: fittedSide,
            height: fittedSide
        )
    }

    /// The bounded text region before host-owned trailing status or actions. A narrow row
    /// gives text zero width rather than a negative rectangle that escapes its own cell.
    func titleRect(in row: NSRect, trailingInset: CGFloat) -> NSRect {
        let start = min(row.maxX, row.minX + titleLeadingOffset)
        return NSRect(
            x: start,
            y: row.minY,
            width: max(0, row.maxX - max(0, trailingInset) - start),
            height: row.height
        )
    }
}
