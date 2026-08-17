import AppKit

// MARK: - Content Menu

/// Actions on the file behind whatever the panel is showing.
///
/// The panel is where an image the agent produced first becomes visible, so it is also where
/// the user first wants to do something with it — keep the path, open it properly, find it on
/// disk. Without these the only route back to the file is retyping the path.
extension DisplayPaneController {

  /// The actions that make sense for what is currently shown.
  ///
  /// Built per click rather than once at setup: an image and a document have almost nothing
  /// in common to act on, and a menu of mostly-disabled items is worse than a short one.
  ///
  /// Internal rather than private so it can be asserted on: a presented menu is unreachable
  /// from a script, and the items whose presence is conditional on the file still existing
  /// are exactly the kind of thing that rot silently.
  func makeContentEntries() -> [ThemedMenuEntry] {
    switch currentContent?.body {
    case .image(_, let url):
      var entries: [ThemedMenuEntry] = []
      if QuickLookPresenter.canPreview(url) {
        entries.append(item(L10n.string("Inspect"), symbol: "magnifyingglass") {
          [weak self] in self?.inspectImage()
        })
        entries.append(.separator)
      }
      entries.append(item(L10n.string("Copy Image"), symbol: "photo.on.rectangle") {
        [weak self] in self?.copyImage()
      })
      entries.append(item(L10n.string("Copy File Name"), symbol: "textformat") {
        [weak self] in self?.copyFileName()
      })
      entries.append(item(L10n.string("Copy File Path"), symbol: "folder") {
        [weak self] in self?.copyFilePath()
      })
      entries.append(.separator)
      entries.append(item(L10n.string("Reveal in Finder"), symbol: "magnifyingglass") {
        [weak self] in self?.revealInFinder()
      })
      entries.append(item(L10n.string("Open in Default App"), symbol: "arrow.up.forward.app") {
        [weak self] in self?.openInDefaultApp()
      })
      if QuickLookPresenter.canPreview(url) {
        entries.append(.separator)
        entries.append(item(L10n.string("Open in System Quick Look"), symbol: "eye") {
          [weak self] in
          self?.quickLookImage()
        })
      }
      return entries

    case .html:
      return [
        item(L10n.string("Copy HTML"), symbol: "doc.on.doc") { [weak self] in self?.copyHTML() },
        .separator,
        item(L10n.string("Open in Browser"), symbol: "globe") {
          [weak self] in self?.openHTMLInBrowser()
        },
        item(L10n.string("Reload"), symbol: "arrow.clockwise") { [weak self] in self?.reloadHTML() }
      ]

    case .chart(let spec):
      // A chart is the one content kind whose source is small enough to hand back whole, and
      // the numbers are what a reader wants next — into a spreadsheet, or into a message.
      return [
        item(L10n.string("Copy Chart Data"), symbol: "tablecells") {
          [weak self] in self?.copyChartData(spec)
        }
      ]

    case .semanticScene, nil:
      return []
    }
  }

  private func copyChartData(_ spec: ChartSpec) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(spec.tabSeparatedValues, forType: .string)
  }

  private func item(
    _ title: String,
    symbol: String? = nil,
    action: @escaping () -> Void
  ) -> ThemedMenuEntry {
    .item(ThemedMenuItem(
      title: title,
      image: symbol.flatMap(ThemedMenuIcon.symbol),
      onChoose: action
    ))
  }

  @objc func contentMenuButtonClicked(_ sender: ThemedButton) {
    let entries = makeContentEntries()
    guard entries.contains(where: \.isItem) else { return }

    // The button sits at the bottom edge of the pane; the presenter measures the room and
    // opens the panel above it on its own.
    contentMenuSession = ThemedMenuPresenter.present(
      ThemedMenuPresentation(entries: entries, minimumWidth: DisplayPaneDefaults.contentMenuWidth),
      from: sender,
      selectedEntryIndex: nil,
      onChoose: { _, item in item.onChoose?() },
      onDismiss: { [weak self] in self?.contentMenuSession = nil }
    )
  }

  // MARK: Image Actions

  @objc private func inspectImage() {
    guard case .image(let image, let url) = currentContent?.body else { return }
    guard MediaInspectorPresenter.present(
      MediaInspectorItem(url: url, image: image),
      from: view
    ) else {
      NSSound.beep()
      return
    }
  }

  /// The system panel remains the last-resort renderer and an explicit escape hatch for people
  /// who want Quick Look's own window and actions.
  @objc private func quickLookImage() {
    guard case .image(_, let url) = currentContent?.body else { return }
    guard QuickLookPresenter.shared.present(url) else {
      NSSound.beep()
      return
    }
  }

  @objc private func copyImage() {
    guard case .image(let image, _) = currentContent?.body else { return }
    write(to: NSPasteboard.general) { $0.writeObjects([image]) }
  }

  @objc private func copyFileName() {
    guard case .image(_, let url) = currentContent?.body else { return }
    write(to: NSPasteboard.general) { $0.setString(url.lastPathComponent, forType: .string) }
  }

  @objc private func copyFilePath() {
    guard case .image(_, let url) = currentContent?.body else { return }

    // Both representations: the string for pasting into the terminal beside this panel,
    // the file URL so a paste into Finder or a document lands as the file itself.
    write(to: NSPasteboard.general) {
      $0.writeObjects([url as NSURL])
      $0.setString(url.path, forType: .string)
    }
  }

  @objc private func revealInFinder() {
    guard case .image(_, let url) = currentContent?.body else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc private func openInDefaultApp() {
    guard case .image(_, let url) = currentContent?.body else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: HTML Actions

  @objc private func copyHTML() {
    guard case .html(let html) = currentContent?.body else { return }
    write(to: NSPasteboard.general) { $0.setString(html, forType: .string) }
  }

  /// Opens the document in the real browser, for when a side panel is too narrow for it.
  ///
  /// Written to a temporary file because a browser cannot be handed a string. The name is
  /// derived from the session so repeated opens replace one file rather than littering.
  @objc private func openHTMLInBrowser() {
    guard case .html(let html) = currentContent?.body, let sessionID = currentSessionID else {
      return
    }

    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("threading-\(sessionID.uuidString)")
      .appendingPathExtension("html")

    do {
      try html.write(to: file, atomically: true, encoding: .utf8)
      DefaultBrowserLauncher.open([file])
    } catch {
      ThreadingLogger.mcp.error(
        "Display HTML export failed session=\(sessionID.uuidString, privacy: .public) destination=\(file.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
      )
      NSSound.beep()
    }
  }

  /// Re-renders the document, which is the only way to restart a page whose script has
  /// finished or wedged.
  @objc private func reloadHTML() {
    render()
  }

  /// Clearing first is required: the pasteboard keeps whatever the last owner wrote until
  /// a new declaration, so writing without it can leave a stale type alongside the new one.
  private func write(to pasteboard: NSPasteboard, _ body: (NSPasteboard) -> Void) {
    pasteboard.clearContents()
    body(pasteboard)
  }
}
