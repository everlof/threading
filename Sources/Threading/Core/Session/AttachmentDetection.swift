import Foundation

/// Stable preference keys shared by the desktop hosts. Detection is opt-out, while widening
/// the scanned-file scope is opt-in.
enum AttachmentDetectionPreferences {
    static let disabledAgentKindsKey = "disabledAttachmentDetectionAgentKinds"
    static let includesOutsideProjectKey = "includesAttachmentsOutsideProject"
}

/// The content policy shared by main agents, children, live streams and transcript replay.
/// Only completed assistant prose is a reference. Thinking and tool inputs/results are not.
enum AttachmentDetection {
    static func assistantTexts(in event: StreamEvent) -> [String] {
        switch event {
        case .assistantMessage(let blocks):
            return blocks.compactMap {
                guard case .text(let text) = $0, !text.isEmpty else { return nil }
                return text
            }
        case .turnFinished(let text, _, _):
            return text.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        default:
            return []
        }
    }
}
