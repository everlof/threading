import AppKit

// MARK: - MCPToolHandling

/// Serves the tool calls agents make against Skalman's own MCP server.
///
/// Lives on the window controller because the tools are, by definition, requests to change
/// what the window is showing. Called on the main queue by `MCPServer`.
extension MainWindowController: MCPToolHandling {

    func handle(_ call: MCPToolCall, for sessionID: UUID) -> MCPToolResult {
        switch call.name {
        case MCPTools.displayImage:
            return displayImage(call, for: sessionID)
        case MCPTools.displayHTML:
            return displayHTML(call, for: sessionID)
        default:
            return .failure("Unknown tool: \(call.name)")
        }
    }

    // MARK: Tools

    private func displayImage(_ call: MCPToolCall, for sessionID: UUID) -> MCPToolResult {
        guard let path = call.string("path"), !path.isEmpty else {
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
            return .failure("\(url.lastPathComponent) is not an image Skalman can display.")
        }

        let dimensions = pixelDescription(of: image)

        return present(
            DisplayContent(
                body: .image(image, url: url),
                title: call.string("title"),
                subtitle: "\(url.lastPathComponent) · \(dimensions)"
            ),
            for: sessionID,
            describedAs: "\(url.lastPathComponent) (\(dimensions))"
        )
    }

    private func displayHTML(_ call: MCPToolCall, for sessionID: UUID) -> MCPToolResult {
        guard let html = call.string("html"), !html.isEmpty else {
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
                title: call.string("title"),
                subtitle: "HTML · \(byteDescription(size))"
            ),
            for: sessionID,
            describedAs: "the document"
        )
    }

    // MARK: Presentation

    /// Hands content to the panel and reports back where it landed.
    ///
    /// Shared by both tools because the interesting part is not what was rendered but whether
    /// the user can currently see it.
    private func present(
        _ content: DisplayContent,
        for sessionID: UUID,
        describedAs description: String
    ) -> MCPToolResult {
        displayPaneController.setContent(content, for: sessionID)

        // Only the session the user is actually looking at opens the panel. A background
        // session's content waits until that session is selected, as its scrollback does.
        let isVisible = sessionID == currentSessionID
        if isVisible {
            setDisplayPaneVisible(true)
        }

        // The agent is told which of the two happened, so it can word its own reply honestly
        // rather than claiming the user is looking at something they cannot see yet.
        let location = isVisible
            ? "in the display panel"
            : "in this session's display panel, which opens when the user selects it"

        return .success("Showing \(description) \(location).")
    }

    // MARK: Helpers

    /// Resolves a tool's path argument, which may be relative to the session's project.
    private func resolve(path: String, for sessionID: UUID) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath

        var candidates = [URL(fileURLWithPath: expanded)]

        if !expanded.hasPrefix("/"),
           let project = ProjectStore.shared.project(forSessionID: sessionID) {
            candidates.insert(project.folderURL.appendingPathComponent(expanded), at: 0)
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The image's size in pixels, which is what the agent means, rather than in points.
    private func pixelDescription(of image: NSImage) -> String {
        if let representation = image.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return "\(representation.pixelsWide)×\(representation.pixelsHigh)"
        }

        // Vector sources such as PDF and SVG carry no pixel dimensions.
        return "\(Int(image.size.width))×\(Int(image.size.height)) pt"
    }

    private func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
