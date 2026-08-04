import AppKit
import ThreadingExtensionKit

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
      return .failure(
        """
        \(url.lastPathComponent) is \(byteDescription(size)), larger than the \
        \(byteDescription(MCPDefaults.maximumImageBytes)) the display panel accepts.
        """)
    }

    guard let image = NSImage(contentsOf: url), image.isValid else {
      return .failure("\(url.lastPathComponent) is not an image Threading can display.")
    }

    // The recorded row *is* the presentation now, so what the store made of the file is the
    // thing to point at — nil only when the session has no project to record against, or when
    // the store could not take custody of the bytes.
    var recorded: SessionAttachment?
    if let project = dependencies.projects.project(forSessionID: sessionID) {
      recorded = dependencies.attachments.record(
        declared: url,
        sessionID: sessionID,
        projectRoot: URL(fileURLWithPath: project.folderPath, isDirectory: true),
        origin: .agent
      )
    }

    let dimensions = pixelDescription(of: image)
    let description = "\(url.lastPathComponent) (\(dimensions))"

    if let recorded,
      let attachments = displayPaneController.activateAttachments(for: sessionID)
    {
      attachments.showAttachment(at: recorded.url)
      return .success("Showing \(description) \(attachmentsLocation(for: sessionID)).")
    }

    // The fallback, and the only remaining route to an image tab: a session with no project
    // cannot have an Attachments tab at all (`makeAttachments` needs a folder to belong to), so
    // the picture is shown the old way rather than not at all.
    return present(
      DisplayContent(
        body: .image(image, url: url),
        title: arguments.title,
        subtitle: "\(url.lastPathComponent) · \(dimensions)"
      ),
      for: sessionID,
      describedAs: description
    )
  }

  func displayScene(
    _ arguments: DisplaySceneArguments,
    for sessionID: SessionID
  ) -> MCPToolResult {
    guard let suppliedScene = arguments.scene else {
      return .failure("Missing required argument: scene")
    }

    // A display tool has no process waiting for a later click. Preserve every visual and
    // accessibility value while removing action IDs, so informative marks never masquerade
    // as controls that silently do nothing.
    let scene = ExtensionScene(
      accessibilityLabel: suppliedScene.accessibilityLabel,
      preferredAspectRatio: suppliedScene.preferredAspectRatio,
      items: suppliedScene.items.map { item in
        ExtensionSceneItem(
          id: item.id,
          frame: ExtensionSceneRect(
            x: item.frame.x,
            y: item.frame.y,
            width: item.frame.width,
            height: item.frame.height
          ),
          shape: extensionSceneShape(item.shape),
          color: extensionSceneColor(item.color),
          label: item.label,
          detail: item.detail,
          accessibilityLabel: item.accessibilityLabel,
          accessibilityValue: item.accessibilityValue,
          actionID: nil,
          isEnabled: item.isEnabled,
          isSelected: item.isSelected
        )
      }
    )
    do {
      try ExtensionPanel.nodeConstraints.validate(.scene(scene))
    } catch {
      return .failure("The semantic scene is invalid: \(error.localizedDescription)")
    }
    let subtitle =
      arguments.subtitle
      ?? "\(scene.items.count) native semantic \(scene.items.count == 1 ? "mark" : "marks")"
    return present(
      DisplayContent(
        body: .semanticScene(scene),
        title: arguments.title,
        subtitle: subtitle
      ),
      for: sessionID,
      describedAs: "a native semantic scene with \(scene.items.count) marks"
    )
  }

  private func extensionSceneShape(_ shape: MCPSceneShape) -> ExtensionSceneShape {
    switch shape {
    case .rectangle: .rectangle
    case .roundedRectangle: .roundedRectangle
    case .ellipse: .ellipse
    }
  }

  private func extensionSceneColor(_ color: MCPSceneColor) -> ExtensionSceneColorRole {
    switch color {
    case .neutral: .neutral
    case .accent: .accent
    case .positive: .positive
    case .warning: .warning
    case .negative: .negative
    case .category1: .category1
    case .category2: .category2
    case .category3: .category3
    case .category4: .category4
    case .category5: .category5
    case .category6: .category6
    }
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
      return .failure(
        """
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
      return .failure(
        """
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
      let project = dependencies.projects.project(forSessionID: sessionID)
    {
      dependencies.attachments.record(
        declared: [oldURL, newURL],
        sessionID: sessionID,
        projectRoot: URL(fileURLWithPath: project.folderPath, isDirectory: true),
        origin: .agent
      )
    }

    displayPaneController.addCompareTab(
      for: sessionID,
      oldPath: oldURL.path,
      newPath: newURL.path,
      oldTitle: arguments.oldTitle,
      newTitle: arguments.newTitle
    )
    let isVisible = revealDisplayPane(for: sessionID)
    let location =
      isVisible
      ? "in the display panel"
      : "in this session's display panel, which opens when the user selects it"
    return .success(
      """
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
    // A new tab that coexists with what was there before rather than replacing it: a document,
    // a scene, a browser capture, or the no-project image fallback. A `display_image` from a
    // session that *has* a project no longer arrives here — it joins the Attachments list, which
    // is the panel's one chronology of the files this session has shown (see
    // `mcp-and-display.md`). A browser capture is evidence of a page rather than a file the
    // session exchanged, and the store never recorded one, so it stays a tab.
    displayPaneController.addContentTab(content, for: sessionID)

    // Only the session the user is actually looking at opens the panel. A background
    // session's content waits until that session is selected, as its scrollback does.
    let isVisible = revealDisplayPane(for: sessionID)

    // The agent is told which of the two happened, so it can word its own reply honestly
    // rather than claiming the user is looking at something they cannot see yet.
    let location =
      isVisible
      ? "in the display panel"
      : "in this session's display panel, which opens when the user selects it"

    return .success("Showing \(description) \(location).")
  }

  /// Where an image the list took landed, in the same two honest forms `present` reports.
  ///
  /// The Attachments tab is *in* the display panel, so the sentence stays true; it names the
  /// list because that is where the agent should expect to find the picture again, and because
  /// a second image no longer replaces the first anywhere the agent can see.
  private func attachmentsLocation(for sessionID: SessionID) -> String {
    revealDisplayPane(for: sessionID)
      ? "in the display panel's Attachments list"
      : "in this session's display panel, which opens when the user selects it"
  }

  // MARK: Helpers

  /// Resolves a tool's path argument, which may be relative to the session's project.
  func resolve(path: String, for sessionID: SessionID) -> URL? {
    let expanded = (path as NSString).expandingTildeInPath

    var candidates = [URL(fileURLWithPath: expanded)]

    if !expanded.hasPrefix("/"),
      let project = dependencies.projects.project(forSessionID: sessionID)
    {
      candidates.insert(project.folderURL.appendingPathComponent(expanded), at: 0)
    }

    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// The image's size in pixels, which is what the agent means, rather than in points.
  func pixelDescription(of image: NSImage) -> String {
    if let representation = image.representations.first,
      representation.pixelsWide > 0, representation.pixelsHigh > 0
    {
      return "\(representation.pixelsWide)×\(representation.pixelsHigh)"
    }

    // Vector sources such as PDF and SVG carry no pixel dimensions.
    return "\(Int(image.size.width))×\(Int(image.size.height)) pt"
  }

  func byteDescription(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}
