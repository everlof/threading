import Foundation

/// A text paste belongs to the selection at the keypress, even if clipboard conversion waits
/// for another process. A disjoint intervening edit can move that selection; an edit through it
/// makes the old selection unsafe to replace.
struct ComposerPasteAnchor: Sendable {
    let text: String
    let selection: NSRange

    func selection(in currentText: String) -> NSRange? {
        let original = Array(text.utf16)
        let current = Array(currentText.utf16)
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= original.count,
              selection.length <= original.count - selection.location else { return nil }
        guard original != current else { return selection }

        var prefix = 0
        while prefix < min(original.count, current.count),
              original[prefix] == current[prefix] { prefix += 1 }
        var fullSuffix = 0
        while fullSuffix < min(original.count, current.count),
              original[original.count - fullSuffix - 1]
                == current[current.count - fullSuffix - 1] { fullSuffix += 1 }
        let selectionEnd = selection.location + selection.length
        let shorterCount = min(original.count, current.count)
        // In a repeated run, the same insertion/deletion has several valid alignments.
        // Without the editor's edit history, none identifies which side of the caret changed.
        let earliestChange = shorterCount - fullSuffix
        if prefix + fullSuffix > shorterCount,
           selectionEnd >= earliestChange && selection.location <= prefix { return nil }
        var suffix = 0
        while suffix < min(original.count - prefix, current.count - prefix),
              original[original.count - suffix - 1] == current[current.count - suffix - 1] {
            suffix += 1
        }

        let changedEnd = original.count - suffix
        if changedEnd <= selection.location && prefix < selection.location {
            return NSRange(location: selection.location + current.count - original.count,
                           length: selection.length)
        }
        if prefix >= selectionEnd && changedEnd > selectionEnd { return selection }
        // A later keystroke at the same caret follows the paste in input order.
        if selection.length == 0 && prefix == selection.location && changedEnd == prefix {
            return selection
        }
        return nil
    }

    /// A later caret move or selection should still be the editor's final selection once the
    /// delayed paste has been inserted at its earlier anchor.
    static func laterSelection(_ selection: NSRange, afterReplacing target: NSRange,
                               insertedUTF16Length: Int) -> NSRange {
        let targetEnd = target.location + target.length
        let selectionEnd = selection.location + selection.length
        if selectionEnd <= target.location && selection.location < target.location {
            return selection
        }
        if selection.location >= targetEnd {
            return NSRange(location: selection.location + insertedUTF16Length - target.length,
                           length: selection.length)
        }
        return NSRange(location: target.location + insertedUTF16Length, length: 0)
    }
}
