import Foundation

// MARK: - Code Context Preview

/// A bounded, presentation-only slice of code around one or more target lines.
///
/// The source renderer supplies lines by index so a large diff is never copied just to open a
/// comment sheet. A normal target keeps two neighbours on either side. A target too large for
/// the sheet keeps its beginning and end with an explicit omission row, which makes the preview
/// O(visible) even when somebody selected a whole generated file.
struct CodeContextPreview: Equatable, Sendable {

    enum Change: Equatable, Sendable {
        case context
        case added
        case removed
    }

    struct SourceLine: Equatable, Sendable {
        let number: Int?
        let change: Change
        let text: String

        init(number: Int?, change: Change, text: String) {
            self.number = number
            self.change = change
            self.text = Self.bounded(text)
        }

        private static func bounded(_ text: String) -> String {
            guard text.count > CodeContextPreview.maximumLineCharacters else { return text }
            return String(text.prefix(CodeContextPreview.maximumLineCharacters - 1)) + "…"
        }
    }

    enum Row: Equatable, Sendable {
        case line(SourceLine, isTarget: Bool)
        case omission(Int)
    }

    let rows: [Row]

    /// Builds only the rows the preview can draw. `lineAt` is called at most ten times.
    static func make(
        totalLineCount: Int,
        target: ClosedRange<Int>,
        lineAt: (Int) -> SourceLine
    ) -> CodeContextPreview? {
        guard totalLineCount > 0,
              target.lowerBound >= 0,
              target.upperBound < totalLineCount else { return nil }

        let lower = max(0, target.lowerBound - contextRadius)
        let upper = min(totalLineCount - 1, target.upperBound + contextRadius)
        let candidateCount = upper - lower + 1

        let indices: [Int?]
        if candidateCount <= maximumVisibleLineRows {
            indices = Array(lower...upper).map(Optional.some)
        } else if target.count <= maximumVisibleLineRows {
            // The selection is what the sheet is about; only the neighbours are optional. Cutting
            // from the middle of the candidate range hid the selected lines themselves ("1 more
            // lines are not shown" inside a four-line comment), so context is shed first, from
            // whichever side has more of it.
            let spare = maximumVisibleLineRows - target.count
            let leading = min(target.lowerBound - lower, (spare + 1) / 2)
            let trailing = min(upper - target.upperBound, spare - leading)
            indices = Array((target.lowerBound - leading)...(target.upperBound + trailing))
                .map(Optional.some)
        } else {
            let leadingCount = maximumVisibleLineRows / 2
            let trailingCount = maximumVisibleLineRows - leadingCount
            let trailingStart = upper - trailingCount + 1
            indices = Array(lower..<(lower + leadingCount)).map(Optional.some)
                + [nil]
                + Array(trailingStart...upper).map(Optional.some)
        }

        var rows: [Row] = []
        rows.reserveCapacity(indices.count)
        for (position, index) in indices.enumerated() {
            if let index {
                rows.append(.line(lineAt(index), isTarget: target.contains(index)))
                continue
            }
            guard position > 0,
                  position + 1 < indices.count,
                  let before = indices[position - 1],
                  let after = indices[position + 1] else { continue }
            rows.append(.omission(max(after - before - 1, 0)))
        }
        return CodeContextPreview(rows: rows)
    }

    /// The same bounded rows around several runs of target lines — what a comment on a
    /// selection with gaps shows. Each run keeps its neighbours while ten code rows can hold
    /// them all; past that the neighbours go first, and past *that* the preview keeps the
    /// first and last chosen rows around one counted omission, the single-run rule. Every
    /// skip between rows is a counted omission, so a gap in the selection is stated rather
    /// than implied by two rows that happen to sit together.
    static func make(
        totalLineCount: Int,
        targets: [ClosedRange<Int>],
        lineAt: (Int) -> SourceLine
    ) -> CodeContextPreview? {
        let runs = mergedRuns(targets)
        guard let first = runs.first, let last = runs.last else { return nil }
        if runs.count == 1 {
            return make(totalLineCount: totalLineCount, target: first, lineAt: lineAt)
        }
        guard totalLineCount > 0,
              first.lowerBound >= 0,
              last.upperBound < totalLineCount else { return nil }

        func candidates(radius: Int) -> [Int] {
            var result: [Int] = []
            for run in runs {
                let lower = max(0, run.lowerBound - radius)
                let upper = min(totalLineCount - 1, run.upperBound + radius)
                for index in lower...upper where index > (result.last ?? -1) {
                    result.append(index)
                }
            }
            return result
        }
        var chosen = candidates(radius: contextRadius)
        if chosen.count > maximumVisibleLineRows {
            chosen = candidates(radius: 0)
        }
        if chosen.count > maximumVisibleLineRows {
            let leading = maximumVisibleLineRows / 2
            chosen = Array(chosen.prefix(leading))
                + Array(chosen.suffix(maximumVisibleLineRows - leading))
        }

        var rows: [Row] = []
        rows.reserveCapacity(chosen.count * 2)
        var previous: Int?
        for index in chosen {
            if let previous, index > previous + 1 {
                rows.append(.omission(index - previous - 1))
            }
            rows.append(.line(lineAt(index), isTarget: runs.contains { $0.contains(index) }))
            previous = index
        }
        return CodeContextPreview(rows: rows)
    }

    /// Runs sorted and merged where they touch or overlap, so a run is one row group of the
    /// sheet and one receipt in the chat — never two that adjoin.
    static func mergedRuns(_ runs: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []
        for run in runs.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, run.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static let contextRadius = 2
    private static let maximumVisibleLineRows = 10
    private static let maximumLineCharacters = 500
}
