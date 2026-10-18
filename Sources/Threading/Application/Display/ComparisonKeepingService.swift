import Foundation
import ThreadingRemoteKit

/// Keeps a `display_compare_files` comparison where a paired phone can reach it.
///
/// The Compare tab is a panel surface and the phone has no panel; its door to what a session
/// showed is the Attachments list. So a comparison also becomes a row there:
///
/// - **Two text files** keep the `git diff --no-index` the tab parses, as a `.diff` — frozen
///   rather than referenced, because the "before" side is routinely a scratch copy in `$TMPDIR`
///   that is gone by the next turn.
/// - **Two pictures** join the list as declared files, copied in from wherever they live, and a
///   `.comparison` row names the pair. It is one row per pair, refreshed in place, because it
///   follows the two pictures the way the tab does rather than freezing them.
///
/// Separate from `AgentToolCoordinator` the way `DeviceLogAgentCommandService` is: the
/// coordinator validates the pair, opens the tab and reveals the pane; keeping the comparison and
/// telling the agent so is application-service work testable without a window.
@MainActor
struct ComparisonKeepingService {
    let attachments: SessionAttachmentStore
    let notificationTargets: NotificationTargetRegistry

    /// A compared pair, as the tool resolved and classified it.
    struct Pair {
        let old: URL
        let new: URL
        let oldTitle: String?
        let newTitle: String?
        let areImages: Bool
        let projectRoot: URL
    }

    /// Keeps the comparison, then answers. The result waits for the row so it can carry a
    /// `target_ref` that opens this exact comparison from a notification.
    func keep(_ pair: Pair, shown: String, for sessionID: SessionID) async -> MCPToolResult {
        pair.areImages
            ? await keepPictures(pair, shown: shown, for: sessionID)
            : await keepDiff(pair, shown: shown, for: sessionID)
    }

    /// Runs the diff on a worker — it is a child process — then files it.
    private func keepDiff(_ pair: Pair, shown: String, for sessionID: SessionID) async -> MCPToolResult {
        let oldPath = pair.old.path
        let newPath = pair.new.path
        let diff = await Task.detached(priority: .userInitiated) {
            try? GitProcess.compareFiles(oldPath: oldPath, newPath: newPath)
        }.value
        return result(keeping: diff, named: Self.name(old: pair.old, new: pair.new), shown: shown, for: sessionID)
    }

    /// Files the diff and says so, or says why there is nothing to keep.
    func result(
        keeping diff: Data?,
        named name: String,
        shown: String,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let diff else { return .success(shown) }
        // `git diff --no-index` prints nothing at all for identical files.
        guard !diff.isEmpty else {
            return .success("\(shown) The files are identical, so there is no diff to keep.")
        }
        guard let recorded = attachments.recordGeneratedDiff(diff, title: name, sessionID: sessionID)
        else { return .success(shown) }
        return targeted(
            "\(shown) The diff is also kept in this session's attachments, where a paired iPhone can open it.",
            attachmentID: recorded.id,
            for: sessionID
        )
    }

    /// Lists both pictures, then the row that holds them against each other.
    private func keepPictures(_ pair: Pair, shown: String, for sessionID: SessionID) async -> MCPToolResult {
        let recorded = attachments.record(
            declared: [pair.old, pair.new],
            sessionID: sessionID,
            projectRoot: pair.projectRoot,
            origin: .agent
        )
        guard recorded.count == 2 else { return .success(shown) }
        let manifest = RemoteImageComparisonDTO(
            old: .init(attachmentID: recorded[0].id, title: pair.oldTitle ?? pair.old.lastPathComponent),
            new: .init(attachmentID: recorded[1].id, title: pair.newTitle ?? pair.new.lastPathComponent)
        )
        let encoded = await Task.detached(priority: .userInitiated) {
            try? JSONEncoder().encode(manifest)
        }.value
        guard let encoded,
              let kept = attachments.recordImageComparison(
                  encoded,
                  name: Self.name(old: pair.old, new: pair.new),
                  old: recorded[0],
                  new: recorded[1],
                  sessionID: sessionID
              )
        else { return .success(shown) }
        return targeted(
            "\(shown) The comparison is also kept in this session's attachments, where a paired iPhone can open it.",
            attachmentID: kept.id,
            for: sessionID
        )
    }

    private func targeted(_ text: String, attachmentID: String, for sessionID: SessionID) -> MCPToolResult {
        let destination = RemoteNotificationDestinationDTO.attachment(id: attachmentID)
        guard let reference = notificationTargets.issue(destination, for: sessionID) else {
            return .success(text)
        }
        return .targeted(text, reference: reference, kind: destination.kind.rawValue)
    }

    /// What a kept comparison is called in the list: the file's own name when both sides share
    /// it — the usual before/after of one file — and both names otherwise.
    static func name(old: URL, new: URL) -> String {
        let oldName = old.lastPathComponent
        let newName = new.lastPathComponent
        return oldName == newName ? newName : "\(oldName) → \(newName)"
    }
}
