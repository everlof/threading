import Foundation

/// Positive row extents with O(log rows) point updates and viewport lookup. Full reloads
/// build once in O(rows); a disclosed document row must not rebuild every following offset.
struct RowHeightIndex {
    private var tree: [CGFloat] = [0]
    private var count: Int { tree.count - 1 }

    mutating func reset(_ extents: [CGFloat]) {
        tree = [0] + extents
        for index in 1..<tree.count {
            let parent = index + (index & -index)
            if parent < tree.count { tree[parent] += tree[index] }
        }
    }

    mutating func add(_ delta: CGFloat, at row: Int) {
        var index = row + 1
        while index < tree.count {
            tree[index] += delta
            index += index & -index
        }
    }

    mutating func append(_ extent: CGFloat) {
        let index = count + 1
        let first = index - (index & -index)
        let preceding = offset(count) - offset(first)
        tree.append(preceding + extent)
    }

    mutating func removeLast(_ rows: Int) {
        tree.removeLast(rows)
    }

    func offset(_ rows: Int) -> CGFloat {
        var index = rows
        var sum: CGFloat = 0
        while index > 0 {
            sum += tree[index]
            index -= index & -index
        }
        return sum
    }

    func firstOffset(_ value: CGFloat, strictlyAfter: Bool) -> Int {
        if strictlyAfter ? value < 0 : value <= 0 { return 0 }
        var index = 0, bit = 1
        while bit <= count / 2 { bit *= 2 }
        var sum: CGFloat = 0
        while bit > 0 {
            let next = index + bit
            if next <= count {
                let candidate = sum + tree[next]
                if strictlyAfter ? candidate <= value : candidate < value {
                    index = next
                    sum = candidate
                }
            }
            bit /= 2
        }
        return index + 1
    }
}
