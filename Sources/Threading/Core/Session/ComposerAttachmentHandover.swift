import Foundation

/// Turning files a person attached to a prompt into something an agent can open.
///
/// Three composers reach this: the Mac's `PromptView`, a scheduled message finally sending on
/// Monday, and a paired phone whose bytes arrived over the wire. They must agree, because the
/// agent cannot tell them apart — a path with a space in it is quoted one way or the picture is
/// two arguments, and a file handed over from a directory about to be deleted is a path the
/// agent opens after it has gone.
///
/// It lives in `Core` rather than beside `PromptView` for the third of those callers. The remote
/// server composes a prompt with no window, no pasteboard and no AppKit anywhere in reach; the
/// half of the old `PromptAttachment` that reads an `NSPasteboard` stays in `UI/Design`, and the
/// half that decides custody and spelling is here where every composer can share it.
enum ComposerAttachmentHandover {

    struct RecordedHandover {
        let paths: [String]
        let attachments: [SessionAttachment]
    }

    /// Files the user handed to a session, filed so they sit beside what the agent made of them.
    ///
    /// The one rename: a pasted screenshot is written under a generated name, which is right for
    /// a file that only has to outlive the turn and unreadable as a row someone is scanning. A
    /// dropped file keeps the name it already had.
    ///
    /// The rows are handed back for the caller that has something to do with the file *as an
    /// attachment* the moment it is one — the attachments pane, where a picture dropped onto a
    /// row is filed and then compared against that row. Discardable, because every other caller
    /// is simply filing what the user sent.
    @MainActor
    @discardableResult
    static func record(
        paths: [String],
        sessionID: SessionID,
        projectRoot: URL,
        turnID: String? = nil,
        turnPlacement: SessionAttachment.TurnPlacement = .none,
        store: SessionAttachmentStore = .shared
    ) -> [SessionAttachment] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            let isGenerated = url.lastPathComponent.hasPrefix(
                ComposerAttachmentDefaults.generatedPrefix
            )
            return store.record(
                declared: url,
                sessionID: sessionID,
                projectRoot: projectRoot,
                origin: .user,
                preferredName: isGenerated ? L10n.string("Pasted image") : nil,
                turnID: turnID,
                turnPlacement: turnPlacement
            )
        }
    }

    /// Files pictures with the session about to be handed them, and answers the paths to name.
    ///
    /// The answer is the session's **own** copies, not the caller's: a scheduled send hands over
    /// files from a directory it is about to delete, and a path in a prompt that names one of
    /// those is a picture the agent opens after it has gone. Falls back to what it was given if
    /// custody could not be taken, because a path that might still work beats no picture at all.
    @MainActor
    static func handOverRecording(
        paths: [String],
        sessionID: SessionID,
        projectRoot: URL,
        store: SessionAttachmentStore = .shared
    ) -> RecordedHandover {
        guard !paths.isEmpty else { return RecordedHandover(paths: [], attachments: []) }
        let recorded = record(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot,
            turnPlacement: .next,
            store: store
        )
        return RecordedHandover(
            paths: recorded.isEmpty ? paths : recorded.map(\.url.path),
            attachments: recorded
        )
    }

    @MainActor
    static func handOver(
        paths: [String],
        sessionID: SessionID,
        projectRoot: URL,
        store: SessionAttachmentStore = .shared
    ) -> [String] {
        handOverRecording(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot,
            store: store
        ).paths
    }

    /// Takes custody of server-owned staging files, or refuses the whole handoff.
    ///
    /// `handOver` deliberately falls back to the caller's paths for a local file the user may
    /// still own. A remote server is about to delete its staging duplicate, so that fallback is
    /// a dead path and must never enter a prompt. This stricter answer is shared by ordinary
    /// phone composer submissions and a report session's opening attachment.
    @MainActor
    static func handOverStaged(
        paths: [String],
        sessionID: SessionID,
        projectRoot: URL,
        store: SessionAttachmentStore = .shared
    ) -> [String]? {
        guard !paths.isEmpty else { return [] }
        let handover = handOverRecording(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot,
            store: store
        )
        guard handover.paths.count == paths.count, handover.paths != paths else { return nil }
        return handover.paths
    }

    /// The words followed by quoted paths — the only form of an image either CLI can open.
    ///
    /// Shared with the scheduled send that finally hands its pictures over: the composer builds
    /// this at submission time from the box's own attachments, and a message scheduled on Friday
    /// builds it on Monday from the copies the app took. One spelling, so a path with a space in
    /// it is quoted the same way in both.
    static func appending(paths: [String], to text: String) -> String {
        guard !paths.isEmpty else { return text }

        let addition = paths.map(quotedPath).joined(separator: " ")
        guard !text.isEmpty else { return addition }
        guard !text.hasSuffix(" "), !text.hasSuffix("\n") else {
            return text + addition
        }
        return text + " " + addition
    }

    static func quotedPath(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}

// MARK: - Constants

enum ComposerAttachmentDefaults {
    /// The name a composer writes bytes under when the bytes arrived without a name worth
    /// showing: a pasted screenshot, or a phone upload the host re-names from its declared type.
    ///
    /// Load-bearing in two places — `record(paths:…)` reads it to decide whether the row needs a
    /// human-readable name instead, and the staged-upload directory keeps it so a file the host
    /// wrote is recognisable as one it wrote.
    static let generatedPrefix = "threading-attachment-"
    static let generatedImageExtension = "png"
}
