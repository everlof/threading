import Foundation

/// The preview's compact two-line row. This is host layout, not Mac sidebar geometry: the Mac
/// owns inline account badges, extension slots and hover controls which the preview lacks.
struct SavedAgentRowLayout {
    let title: CGRect
    let identityDetail: CGRect
    let status: CGRect

    init(row: CGRect, showsStatus: Bool, titleLeadingInset: CGFloat) {
        let leading = min(titleLeadingInset, max(0, row.width))
        let trailing = min(12, max(0, row.width - leading))
        let available = max(0, row.width - leading - trailing)
        let headingHeight = min(24, max(0, row.height))
        let statusWidth = showsStatus ? min(76, available) : 0
        let gap = statusWidth > 0 ? min(8, max(0, available - statusWidth)) : 0
        title = CGRect(x: row.minX + leading, y: row.minY,
                       width: max(0, available - statusWidth - gap), height: headingHeight)
        identityDetail = CGRect(x: row.minX + leading, y: row.minY + headingHeight,
                                width: available, height: max(0, row.height - headingHeight))
        status = CGRect(x: row.maxX - trailing - statusWidth, y: row.minY,
                        width: statusWidth, height: headingHeight)
    }
}
