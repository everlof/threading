import Foundation
import ThreadingRemoteKit

extension ConversationContextAttachment {
    var remoteDTO: RemoteConversationContextAttachmentDTO {
        RemoteConversationContextAttachmentDTO(
            id: id.uuidString.lowercased(),
            kind: kind.rawValue,
            source: source.rawValue,
            title: title,
            excerpt: excerpt,
            comment: comment,
            locator: locator,
            lineStart: lineStart,
            lineEnd: lineEnd
        )
    }

    init?(remoteDTO: RemoteConversationContextAttachmentDTO) {
        guard let id = UUID(uuidString: remoteDTO.id),
              let kind = Kind(rawValue: remoteDTO.kind),
              let source = Source(rawValue: remoteDTO.source) else { return nil }
        let candidate = ConversationContextAttachment(
            id: id,
            kind: kind,
            source: source,
            title: remoteDTO.title,
            excerpt: remoteDTO.excerpt,
            comment: remoteDTO.comment,
            locator: remoteDTO.locator,
            lineStart: remoteDTO.lineStart,
            lineEnd: remoteDTO.lineEnd
        )
        guard let normalized = ConversationContextPolicy.normalized([candidate]).first,
              normalized == candidate else {
            return nil
        }
        self = normalized
    }
}
