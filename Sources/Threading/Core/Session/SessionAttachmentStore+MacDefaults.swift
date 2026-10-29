import Foundation

extension SessionAttachmentStore {
    /// Hosted tests exercise the shared store; the user's real database is not theirs to write.
    static func makePlatformDefault() -> SessionAttachmentStore {
        guard NSClassFromString("XCTestCase") == nil else {
            // The user's own database and attachment directory are not a test's to write, but
            // *refusing custody* is not the same as not writing: a store with nowhere to copy to
            // silently drops every declared file from outside the checkout, so a hosted test
            // would exercise a store that behaves like neither of the two real ones. Scratch
            // custody under `$TMPDIR` keeps both halves — the app's data untouched, the code
            // path real. The scope is read from the same setting for the same reason.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ThreadingTestAttachments/\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            return SessionAttachmentStore(
                copiesDirectory: { scratch },
                referenceRoot: { sessionID in
                    ProjectStore.shared.workingDirectory(forSessionID: sessionID).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                },
                allowsFilesOutsideProject: { AppSettings.shared.includesAttachmentsOutsideProject }
            )
        }
        return SessionAttachmentStore(
            loadPayload: { StateManager.shared.loadAttachmentsPayload(for: $0) },
            savePayload: { StateManager.shared.saveAttachmentsPayload($0, for: $1) },
            retainPersisted: { StateManager.shared.retainAttachments(sessionIDs: $0) },
            removePersisted: { StateManager.shared.deleteAttachments(for: $0) },
            copiesDirectory: { StateManager.shared.attachmentCopiesDirectory },
            referenceRoot: { sessionID in
                ProjectStore.shared.workingDirectory(forSessionID: sessionID).map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            },
            allowsFilesOutsideProject: { AppSettings.shared.includesAttachmentsOutsideProject }
        )
    }
}
