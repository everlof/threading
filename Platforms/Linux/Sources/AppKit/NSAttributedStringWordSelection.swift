import Foundation

public extension NSAttributedString {
    /// Word boundaries for the AppKit transcript's double-click selection.
    func doubleClick(at index: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let source = string as NSString
        let position = min(max(0, index), length - 1)
        enum Kind { case word, space, other }
        func kind(_ range: NSRange) -> Kind {
            let scalars = source.substring(with: range).unicodeScalars
            if scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
                return .word
            }
            if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return .space
            }
            return .other
        }
        let base = source.rangeOfComposedCharacterSequence(at: position)
        let target = kind(base)
        guard target != .other else { return base }
        var lower = base.location
        var upper = NSMaxRange(base)
        while lower > 0 {
            let candidate = source.rangeOfComposedCharacterSequence(at: lower - 1)
            guard kind(candidate) == target else { break }
            lower = candidate.location
        }
        while upper < length {
            let candidate = source.rangeOfComposedCharacterSequence(at: upper)
            guard kind(candidate) == target else { break }
            upper = NSMaxRange(candidate)
        }
        return NSRange(location: lower, length: upper - lower)
    }
}
