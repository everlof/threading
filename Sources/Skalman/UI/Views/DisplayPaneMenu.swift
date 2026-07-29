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
    /// Internal rather than private so it can be asserted on: a popped menu is modal and
    /// unreachable from a script, and the one item whose presence is conditional — Quick Look,
    /// which needs the file to still exist — is exactly the kind of thing that rots silently.
    func makeContentMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch currentContent?.body {
        case .image(_, let url):
            // First, and separated: it is the one action that keeps the user where they are.
            // The rest hand the file to something else — the clipboard, Finder, another app.
            // Offered only when the file is still there, since a Quick Look of a deleted file
            // can do nothing but beep.
            if QuickLookPresenter.canPreview(url) {
                menu.addItem(
                    withTitle: L10n.string("Quick Look"),
                    action: #selector(quickLookImage),
                    keyEquivalent: ""
                )
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: L10n.string("Copy Image"), action: #selector(copyImage), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("Copy File Name"), action: #selector(copyFileName), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("Copy File Path"), action: #selector(copyFilePath), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.string("Reveal in Finder"), action: #selector(revealInFinder), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("Open in Default App"), action: #selector(openInDefaultApp), keyEquivalent: "")

        case .html:
            menu.addItem(withTitle: L10n.string("Copy HTML"), action: #selector(copyHTML), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.string("Open in Browser"), action: #selector(openHTMLInBrowser), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("Reload"), action: #selector(reloadHTML), keyEquivalent: "")

        case nil:
            break
        }

        for item in menu.items {
            item.target = self
        }

        return menu
    }

    @objc func contentMenuButtonClicked(_ sender: ThemedButton) {
        guard currentContent != nil else { return }

        // Popped above the button, which sits at the bottom edge of the pane: a menu dropped
        // below it would open off the window.
        makeContentMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    // MARK: Image Actions

    /// The same panel the picture itself opens on Space or a double-click. Here as well
    /// because the `⋯` button is the one affordance that *advertises* what can be done with
    /// what is on screen — a gesture nobody tries is not a feature.
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
            .appendingPathComponent("skalman-\(sessionID.uuidString)")
            .appendingPathExtension("html")

        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
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
