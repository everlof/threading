#if os(Linux)
import AppKit

/// The visible rows of the navigator's open menu, kept across frames while its entries stay the
/// same. AppKit keeps a menu row's view for as long as the menu is open, so a press and its
/// release reach one view. Rebuilding on every frame let a press that moved the highlight hand
/// its release to a fresh row that never saw the press, and the choice was lost. A changed menu
/// or entry list builds fresh rows; only the visible page is retained.
@MainActor
final class RetainedMenuRows {
    private var signature: [String] = []
    private var rows: [Int: ThemedMenuRowView] = [:]

    /// Keeps rows for `visible` when `menu` and `entries` match the previous frame.
    func prepare(menu: String, entries: [ThemedMenuEntry], visible: Range<Int>) {
        let next = [menu] + entries.map(Self.signature)
        if next != signature {
            signature = next
            rows.removeAll()
        } else {
            rows = rows.filter { visible.contains($0.key) }
        }
    }

    func row(at index: Int, plan: ThemedMenuRowPlan) -> ThemedMenuRowView? {
        if let row = rows[index] { return row }
        guard let row = plan.row(at: index) else { return nil }
        rows[index] = row
        return row
    }

    func reset() {
        signature = []
        rows.removeAll()
    }

    private static func signature(_ entry: ThemedMenuEntry) -> String {
        guard case .item(let item) = entry else { return "\u{1E}" }
        return [item.title, item.help ?? "", item.isEnabled ? "1" : "0", item.isSelected ? "1" : "0"]
            .joined(separator: "\u{1F}")
    }
}
#endif
