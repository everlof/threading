import Foundation

/// Shared limits and initial-expansion rules. A surface can override these, but the default
/// keeps Mac and iOS from silently assigning different meanings to "a large diff".
public struct DiffPresentationPolicy: Equatable, Sendable {
    public let fileLineLimit: Int
    public let totalLineLimit: Int
    public let largeFileThreshold: Int
    public let largeChangedLineThreshold: Int
    public let lineCharacterLimit: Int

    public init(
        fileLineLimit: Int = 200,
        totalLineLimit: Int = 600,
        largeFileThreshold: Int = 100,
        largeChangedLineThreshold: Int = 5_000,
        lineCharacterLimit: Int = 2_000
    ) {
        self.fileLineLimit = fileLineLimit
        self.totalLineLimit = totalLineLimit
        self.largeFileThreshold = largeFileThreshold
        self.largeChangedLineThreshold = largeChangedLineThreshold
        self.lineCharacterLimit = lineCharacterLimit
    }

    public static let `default` = DiffPresentationPolicy()

    public func initiallyExpandedPaths(in document: DiffDocument) -> Set<String> {
        let changedLines = document.files.reduce(0) { $0 + $1.added + $1.removed }
        guard document.files.count <= largeFileThreshold,
              changedLines <= largeChangedLineThreshold else {
            return []
        }

        var remaining = totalLineLimit
        var result: Set<String> = []
        for file in document.files {
            let count = file.lineCount
            guard count > 0, count <= fileLineLimit, count <= remaining else { continue }
            result.insert(file.path)
            remaining -= count
        }
        return result
    }

    public func capped(_ text: String) -> String {
        guard text.count > lineCharacterLimit else { return text }
        return String(text.prefix(lineCharacterLimit)) + "…"
    }
}

public enum DiffPresentation {
    public static func rangeTitle(for hunk: DiffHunk) -> String {
        guard let range = hunk.lineRange else { return hunk.header }
        return range.lowerBound == range.upperBound
            ? "Line \(range.lowerBound)"
            : "Lines \(range.lowerBound)–\(range.upperBound)"
    }

    public static func changeGlyph(for change: DiffFile.Change) -> String {
        switch change {
        case .modified, .binary: return "±"
        case .added, .untracked: return "+"
        case .deleted: return "−"
        case .renamed: return "→"
        }
    }
}
