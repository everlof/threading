import Foundation

/// Source thresholds and the width cap shared by the Mac and Linux conversation rows.
enum ConversationUserRowDefaults {
    static let turnDividerHeight: CGFloat = 1
    static let bubbleMaxWidthFraction: CGFloat = 0.78
    static let longMessageCharacterCap = 600
    static let longMessageLineCap = 8

    static func collapsesUserMessage(_ text: String) -> Bool {
        text.prefix(longMessageCharacterCap + 1).count > longMessageCharacterCap
            || text.split(separator: "\n", omittingEmptySubsequences: false).count > longMessageLineCap
    }
}
