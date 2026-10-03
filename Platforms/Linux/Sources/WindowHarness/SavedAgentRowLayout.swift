import Foundation

/// Reserve the host-owned attention/retained mark beside the production one-line session
/// content. Full provider, account and durable identity remain in the accessible row label.
struct SavedAgentRowLayout {
    let title: CGRect
    let status: CGRect

    init(row: CGRect, showsStatus: Bool, titleLeadingInset: CGFloat) {
        let leading = min(titleLeadingInset, max(0, row.width))
        let trailing = min(12, max(0, row.width - leading))
        let available = max(0, row.width - leading - trailing)
        let statusWidth = showsStatus ? min(76, available) : 0
        let gap = statusWidth > 0 ? min(8, max(0, available - statusWidth)) : 0
        title = CGRect(x: row.minX + leading, y: row.minY,
                       width: max(0, available - statusWidth - gap), height: row.height)
        status = CGRect(x: row.maxX - trailing - statusWidth, y: row.minY,
                        width: statusWidth, height: row.height)
    }
}
