import CoreGraphics
import Foundation
import ThreadingRemoteKit

/// A kept picture comparison, read and decoded off the main actor for the Attachments pane.
///
/// The record supplies the captions the agent gave; each picture comes from its own row's file
/// under the same bound every full-size preview uses. What reaches the main actor is two
/// finished frames, so mounting the comparison is wrapping them, not decoding them.
struct AttachmentComparisonFrames: @unchecked Sendable {
    struct Side {
        let frame: CGImage
        let title: String
    }

    let old: Side?
    let new: Side?

    /// The record is a few hundred bytes; anything past this is not one Threading wrote.
    static let maximumRecordBytes = 64 * 1024

    /// Blocking — callers run it on a worker.
    static func load(
        record: URL,
        old: (url: URL, name: String),
        new: (url: URL, name: String)
    ) -> AttachmentComparisonFrames {
        let manifest = (try? BoundedFileReader.read(record, maximumBytes: maximumRecordBytes))
            .flatMap { try? JSONDecoder().decode(RemoteImageComparisonDTO.self, from: $0) }
        // A record that cannot be read still names its pair through the row's source key, so the
        // pictures draw under their file names rather than not at all.
        return AttachmentComparisonFrames(
            old: side(at: old.url, title: manifest?.old.title ?? old.name),
            new: side(at: new.url, title: manifest?.new.title ?? new.name)
        )
    }

    private static func side(at url: URL, title: String) -> Side? {
        BoundedImageDecoder.thumbnailFrame(at: url, policy: .userMedia)
            .map { Side(frame: $0, title: title) }
    }
}
