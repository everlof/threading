import Foundation

/// Owned text inputs, with no references to mutable terminal cells or arena tables.
/// Capture under TerminalLock; trimming, Unicode conversion and joining happen after release.
struct RecentBufferTextSnapshot: Sendable {
    // Bound examined storage as well as returned text, including an all-blank history.
    static let maximumRows = 4_096
    static let maximumCells = 256 * 1_024

    struct Row: Sendable {
        let cells: [PackedCell]
        let isWrapped: Bool

        private func code(_ cell: PackedCell, graphemes: [[UInt32]?]) -> UInt32 {
            switch cell.contentTag {
            case .codepoint: return cell.content
            case .grapheme: return graphemes[Int(cell.content)]?.first ?? 0
            case .backgroundPalette, .backgroundRGB: return 0
            }
        }

        func text(maximumUTF8Bytes: Int, graphemes: [[UInt32]?]) -> String? {
            var end = cells.count
            while end > 0 && code(cells[end - 1], graphemes: graphemes) == 0 { end -= 1 }
            if end > 0 {
                switch cells[end - 1].widthState {
                case .narrow: break
                case .wide: end = min(cells.count, end + 1)
                case .spacerHead, .spacerTail: end -= 1
                }
            }
            var result = ""
            var bytes = 0
            for cell in cells.prefix(end) {
                switch cell.contentTag {
                case .codepoint:
                    let scalar = Unicode.Scalar(cell.content) ?? " "
                    bytes += scalar.utf8.count
                    guard bytes <= maximumUTF8Bytes else { return nil }
                    result.unicodeScalars.append(scalar)
                case .grapheme:
                    let values = graphemes[Int(cell.content)] ?? [32]
                    // Even one cell can carry an externally sized combining sequence.
                    guard values.count <= maximumUTF8Bytes - bytes else { return nil }
                    for value in values {
                        let scalar = Unicode.Scalar(value) ?? " "
                        bytes += scalar.utf8.count
                        guard bytes <= maximumUTF8Bytes else { return nil }
                        result.unicodeScalars.append(scalar)
                    }
                case .backgroundPalette, .backgroundRGB:
                    bytes += 1
                    guard bytes <= maximumUTF8Bytes else { return nil }
                    result.unicodeScalars.append("\0")
                }
            }
            return result
        }
    }

    let rowsNewestFirst: [Row]
    let graphemes: [[UInt32]?]
    let nextAbsoluteRow: Int

    func text(maximumUTF8Bytes: Int) -> Terminal.RecentBufferText {
        var logicalLinesNewestFirst: [[String]] = []
        var currentRowsNewestFirst: [String] = []
        var currentBytes = 0
        var acceptedBytes = 0
        for row in rowsNewestFirst {
            let separatorBytes = logicalLinesNewestFirst.isEmpty ? 0 : 1
            let remaining = maximumUTF8Bytes - acceptedBytes - separatorBytes - currentBytes
            guard remaining >= 0,
                  let text = row.text(maximumUTF8Bytes: remaining, graphemes: graphemes) else { break }
            currentRowsNewestFirst.append(text)
            currentBytes += text.utf8.count
            guard !row.isWrapped else { continue }
            logicalLinesNewestFirst.append(currentRowsNewestFirst)
            acceptedBytes += separatorBytes + currentBytes
            currentRowsNewestFirst.removeAll(keepingCapacity: true)
            currentBytes = 0
        }
        return Terminal.RecentBufferText(
            text: logicalLinesNewestFirst.reversed().map { $0.reversed().joined() }
                .joined(separator: "\n"),
            nextAbsoluteRow: nextAbsoluteRow)
    }
}
