import AppKit

// MARK: - Drag and Drop

/// Folder drops onto the sidebar become projects, and session rows drag out of it as
/// references. Split from the main controller file purely for size.
extension ProjectSidebarViewController {

    // MARK: Dragging Out

    /// A session row is a reference the moment it is picked up.
    ///
    /// The habit this replaces is **Copy ▸ Agent Session ID** followed by a sentence typed into
    /// another session's input saying what the id is and what to do with it. Dropped on a
    /// terminal the row becomes that sentence, bracketed; dropped on a native composer it
    /// becomes a receipt chip — see `SessionReference`. Only session rows write anything:
    /// projects, repository and branch groups answer nil, so they cannot be picked up at all
    /// rather than dragging as a row that then means nothing wherever it lands.
    ///
    /// The pasteboard carries the id and nothing else. Title, project and transcript are
    /// resolved when the reference lands, so a row renamed mid-drag lands under its new name.
    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let session = item as? SessionNode else { return nil }
        return SessionReferencePasteboard.item(for: session.sessionID)
    }

    // MARK: Dropping In

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only folders dropped onto the list background become new projects.
        guard item == nil, droppedFolderURLs(from: info).isEmpty == false else { return [] }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let folders = droppedFolderURLs(from: info)
        guard !folders.isEmpty else { return false }

        let added = folders.compactMap { projectStore.addProject(folderURL: $0) }
        guard !added.isEmpty else { return false }
        reload()
        return true
    }

    /// Extracts directory URLs from a drag, ignoring dropped files.
    private func droppedFolderURLs(from info: NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return [] }

        return urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }
}
