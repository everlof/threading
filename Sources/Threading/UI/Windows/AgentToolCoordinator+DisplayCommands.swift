import AppKit

@MainActor
extension AgentToolCoordinator {
    func displayImage(
        _ arguments: DisplayImageArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let path = arguments.path, !path.isEmpty else {
            return .failure("Missing required argument: path")
        }

        guard let url = resolve(path: path, for: sessionID) else {
            return .failure("No such file: \(path)")
        }

        // Size is read before the bytes: an image far too large for a side panel should be
        // refused with an explanation, not loaded and then discarded.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= MCPDefaults.maximumImageBytes else {
            return .failure("""
                \(url.lastPathComponent) is \(byteDescription(size)), larger than the \
                \(byteDescription(MCPDefaults.maximumImageBytes)) the display panel accepts.
                """)
        }

        guard let image = NSImage(contentsOf: url), image.isValid else {
            return .failure("\(url.lastPathComponent) is not an image Threading can display.")
        }

        if let project = dependencies.projects.project(forSessionID: sessionID) {
            dependencies.attachments.record(
                url: url,
                sessionID: sessionID,
                projectRoot: URL(fileURLWithPath: project.folderPath, isDirectory: true)
            )
        }

        let dimensions = pixelDescription(of: image)

        return present(
            DisplayContent(
                body: .image(image, url: url),
                title: arguments.title,
                subtitle: "\(url.lastPathComponent) · \(dimensions)"
            ),
            for: sessionID,
            describedAs: "\(url.lastPathComponent) (\(dimensions))"
        )
    }

    func displayHTML(
        _ arguments: DisplayHTMLArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let html = arguments.html, !html.isEmpty else {
            return .failure("Missing required argument: html")
        }

        let size = html.utf8.count
        guard size <= MCPDefaults.maximumHTMLBytes else {
            return .failure("""
                The document is \(byteDescription(size)), larger than the \
                \(byteDescription(MCPDefaults.maximumHTMLBytes)) the display panel accepts. \
                Consider loading large data from a file or a CDN instead of inlining it.
                """)
        }

        return present(
            DisplayContent(
                body: .html(html),
                title: arguments.title,
                subtitle: "HTML · \(byteDescription(size))"
            ),
            for: sessionID,
            describedAs: "the document"
        )
    }

    func displayCompareFiles(
        _ arguments: DisplayCompareFilesArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let oldPath = arguments.oldPath, !oldPath.isEmpty else {
            return .failure("Missing required argument: old_path")
        }
        guard let newPath = arguments.newPath, !newPath.isEmpty else {
            return .failure("Missing required argument: new_path")
        }
        guard let oldURL = resolve(path: oldPath, for: sessionID) else {
            return .failure("No such file: \(oldPath)")
        }
        guard let newURL = resolve(path: newPath, for: sessionID) else {
            return .failure("No such file: \(newPath)")
        }
        guard oldURL.standardizedFileURL != newURL.standardizedFileURL else {
            return .failure("old_path and new_path are the same file; nothing to compare.")
        }

        // Classified from the bytes before a tab is spent on it, so a pair with no comparison
        // to draw fails the call instead of opening a tab that says so.
        let oldKind = CompareFileClassifier.classify(path: oldURL.path)
        let newKind = CompareFileClassifier.classify(path: newURL.path)
        let comparison: String
        switch (oldKind, newKind) {
        case (.image, .image):
            comparison = "an interactive image comparison"
        case (.text, .text):
            comparison = "a diff"
        case (.tooLarge, _), (_, .tooLarge):
            return .failure("""
                One side is larger than the \
                \(byteDescription(CompareDefaults.maximumBytes)) the comparison reads.
                """)
        case (.image, .text), (.text, .image):
            return .failure(
                "One file is an image and the other is text; there is no comparison to draw."
            )
        default:
            return .failure(
                "These files are binary, and not images Threading can compare."
            )
        }

        if oldKind == .image,
           let project = dependencies.projects.project(forSessionID: sessionID) {
            let projectRoot = URL(fileURLWithPath: project.folderPath, isDirectory: true)
            for url in [oldURL, newURL] {
                dependencies.attachments.record(
                    url: url, sessionID: sessionID, projectRoot: projectRoot
                )
            }
        }

        displayPaneController.addCompareTab(
            for: sessionID,
            oldPath: oldURL.path,
            newPath: newURL.path,
            oldTitle: arguments.oldTitle,
            newTitle: arguments.newTitle
        )
        let isVisible = revealDisplayPane(for: sessionID)
        let location = isVisible
            ? "in the display panel"
            : "in this session's display panel, which opens when the user selects it"
        return .success("""
            Showing \(comparison) of \(oldURL.lastPathComponent) against \
            \(newURL.lastPathComponent) \(location).
            """)
    }

    // MARK: Presentation

    /// Hands content to the panel and reports back where it landed.
    ///
    /// Shared by both tools because the interesting part is not what was rendered but whether
    /// the user can currently see it.
    func present(
        _ content: DisplayContent,
        for sessionID: SessionID,
        describedAs description: String
    ) -> MCPToolResult {
        // Each shown artefact is a new tab that coexists with what was there before, rather than
        // replacing it — the display pane accumulates the session's images and documents.
        displayPaneController.addContentTab(content, for: sessionID)

        // Only the session the user is actually looking at opens the panel. A background
        // session's content waits until that session is selected, as its scrollback does.
        let isVisible = revealDisplayPane(for: sessionID)

        // The agent is told which of the two happened, so it can word its own reply honestly
        // rather than claiming the user is looking at something they cannot see yet.
        let location = isVisible
            ? "in the display panel"
            : "in this session's display panel, which opens when the user selects it"

        return .success("Showing \(description) \(location).")
    }

    // MARK: Helpers

    /// Resolves a tool's path argument, which may be relative to the session's project.
    func resolve(path: String, for sessionID: SessionID) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath

        var candidates = [URL(fileURLWithPath: expanded)]

        if !expanded.hasPrefix("/"),
           let project = dependencies.projects.project(forSessionID: sessionID) {
            candidates.insert(project.folderURL.appendingPathComponent(expanded), at: 0)
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The image's size in pixels, which is what the agent means, rather than in points.
    func pixelDescription(of image: NSImage) -> String {
        if let representation = image.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return "\(representation.pixelsWide)×\(representation.pixelsHigh)"
        }

        // Vector sources such as PDF and SVG carry no pixel dimensions.
        return "\(Int(image.size.width))×\(Int(image.size.height)) pt"
    }

    func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
