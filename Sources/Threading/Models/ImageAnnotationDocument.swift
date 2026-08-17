import CoreGraphics
import Foundation

/// One numbered mark a person put on a picture, and the sentence it stands for.
///
/// Points live in the image's normalized coordinate space (0…1, origin top-left), so the same
/// document can be drawn in the attachment preview, the fullscreen inspector, and a flattened
/// chat revision without view geometry leaking into persisted state.
struct ImageAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var point: CGPoint
    var note: String

    init(id: UUID = UUID(), point: CGPoint, note: String = "") {
        self.id = id
        self.point = point
        self.note = note
    }
}

/// The editable, session-owned source of truth behind image markup.
///
/// A flattened PNG is an immutable chat revision; this document is the thing a person comes
/// back to edit. `assetKeys` lets the same document follow both the original file and a promoted
/// session attachment without copying the annotation list or depending on one transient URL.
struct ImageAnnotationDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var assetKeys: [String]
    var sourceAttachmentID: String?
    var sourcePath: String
    var title: String
    var annotations: [ImageAnnotation]
    var revision: Int
    var sharedRevision: Int?
    var sharedAttachmentID: String?
    let contextAttachmentID: UUID
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        assetKeys: [String],
        sourceAttachmentID: String? = nil,
        sourcePath: String,
        title: String,
        annotations: [ImageAnnotation] = [],
        revision: Int = 0,
        sharedRevision: Int? = nil,
        sharedAttachmentID: String? = nil,
        contextAttachmentID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.assetKeys = Array(Set(assetKeys)).sorted()
        self.sourceAttachmentID = sourceAttachmentID
        self.sourcePath = sourcePath
        self.title = title
        self.annotations = annotations
        self.revision = revision
        self.sharedRevision = sharedRevision
        self.sharedAttachmentID = sharedAttachmentID
        self.contextAttachmentID = contextAttachmentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ImageAnnotationAssetKey {
    static func attachment(_ id: String) -> String { "attachment:\(id)" }

    static func file(_ url: URL) -> String {
        "file:\(url.standardizedFileURL.resolvingSymlinksInPath().path)"
    }
}

/// Raised only after an annotation document has reached its recoverable on-disk commit point.
struct ImageAnnotationsDidChange: AppEvent {
    static let name = Notification.Name("imageAnnotationsDidChange")
    let sessionID: SessionID
}
