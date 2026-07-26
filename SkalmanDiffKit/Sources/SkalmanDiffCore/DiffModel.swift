import Foundation

/// A platform-neutral diff document. Git, remote transport and write actions deliberately live
/// outside this model so the same document can be rendered by AppKit and UIKit.
public struct DiffDocument: Equatable, Sendable {
    public let files: [DiffFile]

    public init(files: [DiffFile]) {
        self.files = files
    }

    public var summary: DiffSummary {
        DiffSummary(
            files: files.count,
            added: files.reduce(0) { $0 + $1.added },
            removed: files.reduce(0) { $0 + $1.removed }
        )
    }
}

public struct DiffSummary: Equatable, Sendable {
    public let files: Int
    public let added: Int
    public let removed: Int

    public init(files: Int, added: Int, removed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
    }
}

public struct DiffFile: Equatable, Identifiable, Sendable {
    public enum Change: Equatable, Sendable {
        case modified
        case added
        case deleted
        case untracked
        case renamed(from: String)
        case binary
    }

    public let path: String
    public let change: Change
    public let hunks: [DiffHunk]
    public let added: Int
    public let removed: Int
    public let isTruncated: Bool

    public var id: String { path }

    public init(
        path: String,
        change: Change,
        hunks: [DiffHunk],
        added: Int,
        removed: Int,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.change = change
        self.hunks = hunks
        self.added = added
        self.removed = removed
        self.isTruncated = isTruncated
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var directory: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    public var lineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count }
    }
}

public struct DiffHunk: Equatable, Sendable {
    public let header: String
    public let lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }

    public var summary: DiffSummary {
        DiffSummary(
            files: 0,
            added: lines.lazy.filter { $0.kind == .added }.count,
            removed: lines.lazy.filter { $0.kind == .removed }.count
        )
    }

    /// The visible range represented by the hunk. A note-only hunk has no numbered range.
    public var lineRange: ClosedRange<Int>? {
        let numbers = lines.compactMap { $0.newNumber ?? $0.oldNumber }
        guard let first = numbers.min(), let last = numbers.max() else { return nil }
        return first...last
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(
        kind: Kind,
        text: String,
        oldNumber: Int? = nil,
        newNumber: Int? = nil
    ) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }

    public var displayNumber: Int? {
        newNumber ?? oldNumber
    }
}
