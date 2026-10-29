import Foundation

extension SessionAttachmentStore {
    /// The native host installs backed storage before exposing Attachments.
    static func makePlatformDefault() -> SessionAttachmentStore {
        SessionAttachmentStore()
    }
}
