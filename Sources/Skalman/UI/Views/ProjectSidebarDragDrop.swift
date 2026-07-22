import AppKit

// MARK: - Drag and Drop

/// Folder drops onto the sidebar become projects. Split from the main controller file
/// purely for size.
extension ProjectSidebarViewController {

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

        for folder in folders {
            ProjectStore.shared.addProject(folderURL: folder)
        }
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
