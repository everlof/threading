import AppKit

private struct PanelTabsPayload: Encodable {
    struct Tab: Encodable {
        let index: Int
        let id: String
        let kind: String
        let title: String
        let active: Bool
    }

    let count: Int
    let tabs: [Tab]
}

// MARK: - MCPToolHandling

/// Serves the tool calls agents make against Skalman's own MCP server.
///
/// Lives on the window controller because the tools are, by definition, requests to change
/// what the window is showing. Called on the main queue by `MCPServer`.
extension MainWindowController: MCPToolHandling {

    func handle(_ call: MCPToolCall, for sessionID: SessionID) -> MCPToolResult {
        switch call {
        case .displayImage(let arguments):
            return displayImage(arguments, for: sessionID)
        case .displayHTML(let arguments):
            return displayHTML(arguments, for: sessionID)
        default:
            return .failure("Unknown tool: \(call.name)")
        }
    }

    /// Async entry point: the browser tools finish on a page load, a DOM query, or a snapshot;
    /// everything else answers synchronously and is forwarded to `handle(_:for:)`.
    func handle(_ call: MCPToolCall, for sessionID: SessionID, completion: @escaping (MCPToolResult) -> Void) {
        // A tool that reads or changes the panel means the agent's transcript now reflects it, so
        // record that: a later resume only re-describes the panel if the user changed it in between.
        let observed: (MCPToolResult) -> Void = { [weak self] result in
            self?.markPanelObserved(sessionID)
            completion(result)
        }

        switch call {
        case .browserNavigate(let arguments):
            browserNavigate(arguments, for: sessionID, completion: observed)
        case .browserQuery(let arguments):
            browserQuery(arguments, for: sessionID, completion: observed)
        case .browserClick(let arguments):
            browserClick(arguments, for: sessionID, completion: observed)
        case .browserScreenshot:
            browserScreenshot(for: sessionID, completion: observed)
        case .panelListTabs:
            observed(panelListTabs(for: sessionID))
        case .panelActivateTab(let arguments):
            observed(panelActivateTab(arguments, for: sessionID))
        case .setProjectIcon(let arguments):
            setProjectIcon(arguments, for: sessionID, completion: completion)
        case .listReclaimableStorage:
            completion(listReclaimableStorage())
        case .proposeStorageCleanup(let arguments):
            // Answers only once the user has decided, so the agent's next turn knows the
            // outcome rather than assuming one.
            proposeStorageCleanup(arguments, completion: completion)
        case .listThemes:
            // Not `observed`: a theme is not panel content, and marking the panel seen here
            // would suppress the description a later resume owes the agent.
            completion(listThemes(for: sessionID))
        case .setTheme(let arguments):
            completion(setTheme(arguments, for: sessionID))
        case .createTheme(let arguments):
            completion(createTheme(arguments, for: sessionID))
        default:
            observed(handle(call, for: sessionID))
        }
    }

    // MARK: Panel State

    /// Describes the session's display panel for the `initialize` instructions — but only when it
    /// changed since the agent last saw it, so a resume does not repeat what the transcript shows.
    func panelState(for sessionID: SessionID) -> String {
        guard let panel = DisplayPaneStore.shared.loadLayout(for: sessionID), !panel.tabs.isEmpty else {
            return ""
        }

        let signature = panel.signature
        guard signature != DisplayPaneStore.shared.observedSignature(for: sessionID) else {
            return ""
        }

        // The agent is being told now, so the panel counts as observed — an unchanged later resume
        // then stays quiet.
        DisplayPaneStore.shared.setObserved(signature, for: sessionID)
        return "\n\n" + panel.agentDescription
    }

    private func markPanelObserved(_ sessionID: SessionID) {
        DisplayPaneStore.shared.setObserved(
            DisplayPaneStore.shared.signature(for: sessionID),
            for: sessionID
        )
    }

    // MARK: Project Icon

    /// Async because the icon may arrive over the network; the file form answers at once.
    private func setProjectIcon(
        _ arguments: SetProjectIconArguments,
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else {
            completion(.failure("This session belongs to no project."))
            return
        }

        if let path = arguments.path, !path.isEmpty {
            guard let url = resolve(path: path, for: sessionID) else {
                completion(.failure("No such file: \(path)"))
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                completion(.failure("Could not read \(url.lastPathComponent)."))
                return
            }
            completion(apply(iconData: data, to: project))
            return
        }

        if let address = arguments.url, !address.isEmpty {
            guard let url = URL(string: address), url.scheme == "https" else {
                completion(.failure("url must be an https image URL."))
                return
            }

            // Fetched off the main queue; everything that touches the store hops back.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = ProjectIconDiscovery.fetchImage(url)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let data else {
                        completion(.failure("\(address) did not serve a usable image."))
                        return
                    }
                    completion(self.apply(iconData: data, to: project))
                }
            }
            return
        }

        completion(.failure("Provide either path or url."))
    }

    private func apply(iconData: Data, to project: Project) -> MCPToolResult {
        guard let fileName = ProjectIconStore.store(imageData: iconData, for: project.id) else {
            return .failure("""
                That is not an image Skalman can use as an icon — it needs to decode as \
                PNG, JPEG, GIF, HEIC or ICO at 16px or larger.
                """)
        }

        ProjectStore.shared.setIcon(
            ProjectIcon(source: .agent, fileName: fileName),
            for: project.id
        )
        return .success("Set \"\(project.name)\"'s sidebar icon.")
    }

    // MARK: Browser Tools

    private func browserNavigate(
        _ arguments: BrowserNavigateArguments,
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard let input = arguments.url, !input.isEmpty else {
            completion(.failure("Missing required argument: url"))
            return
        }

        // The browser is a tab in this session's display panel — created if the session has none,
        // and brought to the front. It sits beside the terminal, not over it.
        let browser = displayPaneController.activateBrowser(for: sessionID)
        revealDisplayPane(for: sessionID)

        browser.navigate(to: input) { success, message in
            let address = browser.currentURL?.absoluteString ?? input
            let title = browser.currentTitle ?? ""

            if success {
                let note = message.isEmpty ? "" : " (\(message))"
                completion(.success("Loaded \(title.isEmpty ? address : "\"\(title)\" — \(address)")\(note)"))
            } else {
                completion(.failure("Could not load \(input): \(message)"))
            }
        }
    }

    private func browserQuery(
        _ arguments: BrowserSelectorArguments,
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard let selector = arguments.selector, !selector.isEmpty else {
            completion(.failure("Missing required argument: selector"))
            return
        }
        guard let browser = loadedBrowser(for: sessionID) else {
            completion(.failure("No page is loaded. Use browser_navigate first."))
            return
        }

        let javascript = Self.queryScript(selector: selector)
        Task { @MainActor in
            do {
                let result = try await browser.evaluate(javascript)
                completion(.success((result as? String) ?? "No result."))
            } catch {
                completion(.failure("Query failed: \(error.localizedDescription)"))
            }
        }
    }

    private func browserClick(
        _ arguments: BrowserSelectorArguments,
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard let selector = arguments.selector, !selector.isEmpty else {
            completion(.failure("Missing required argument: selector"))
            return
        }
        guard let browser = loadedBrowser(for: sessionID) else {
            completion(.failure("No page is loaded. Use browser_navigate first."))
            return
        }

        let javascript = Self.clickScript(selector: selector)
        Task { @MainActor in
            do {
                let result = try await browser.evaluate(javascript)
                let outcome = (result as? String) ?? "Done."
                let address = browser.currentURL?.absoluteString ?? ""
                completion(.success("\(outcome)\nNow at: \(address)"))
            } catch {
                completion(.failure("Click failed: \(error.localizedDescription)"))
            }
        }
    }

    private func browserScreenshot(
        for sessionID: SessionID,
        completion: @escaping (MCPToolResult) -> Void
    ) {
        guard let browser = loadedBrowser(for: sessionID), let url = browser.currentURL else {
            completion(.failure("No page is loaded. Use browser_navigate first."))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data = await browser.screenshot(), let image = NSImage(data: data) else {
                completion(.failure("Could not capture the page."))
                return
            }

            // The snapshot lands as its own image tab beside the browser, a record of how the
            // page looked at this moment.
            let result = self.present(
                DisplayContent(
                    body: .image(image, url: url),
                    title: browser.currentTitle,
                    subtitle: url.absoluteString
                ),
                for: sessionID,
                describedAs: "a screenshot of \(url.host ?? "the page")"
            )
            completion(result)
        }
    }

    /// The session's browser tab, but only once it actually has a page — so the DOM tools fail
    /// with a clear instruction rather than acting on a blank browser.
    private func loadedBrowser(for sessionID: SessionID) -> BrowserViewController? {
        guard let browser = displayPaneController.browser(for: sessionID), browser.currentURL != nil else {
            return nil
        }
        return browser
    }

    // MARK: Panel Tabs

    private func panelListTabs(for sessionID: SessionID) -> MCPToolResult {
        let tabs = displayPaneController.tabs(for: sessionID)
        guard !tabs.isEmpty else {
            return .success("No tabs are open in this session's display panel.")
        }

        let activeID = displayPaneController.activeTabID(for: sessionID)
        let listed: [PanelTabsPayload.Tab] = tabs.enumerated().map { index, tab in
            var kind = "document"
            if tab.browser != nil {
                kind = "browser"
            } else if tab.review != nil {
                kind = "git review"
            } else if case .image? = tab.content?.body {
                kind = "image"
            }
            return PanelTabsPayload.Tab(
                index: index,
                id: tab.id.uuidString,
                kind: kind,
                title: tab.title,
                active: tab.id == activeID
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let payload = PanelTabsPayload(count: tabs.count, tabs: listed)
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not list the tabs.")
        }
        return .success(text)
    }

    private func panelActivateTab(
        _ arguments: PanelActivateTabArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let activated: Bool
        switch arguments.tab {
        case .index(let index):
            activated = displayPaneController.activateTab(index: index, for: sessionID)
        case .identifier(let string):
            if let index = Int(string) {
                activated = displayPaneController.activateTab(index: index, for: sessionID)
            } else if let id = UUID(uuidString: string) {
                activated = displayPaneController.activateTab(id: id, for: sessionID)
            } else {
                return .failure("Missing or invalid argument: tab (a tab index or id).")
            }
        case nil:
            return .failure("Missing or invalid argument: tab (a tab index or id).")
        }

        guard activated else {
            return .failure("No such tab. Call panel_list_tabs to see what is open.")
        }

        revealDisplayPane(for: sessionID)
        let title = displayPaneController.tabs(for: sessionID)
            .first { $0.id == displayPaneController.activeTabID(for: sessionID) }?.title ?? "the tab"
        return .success("Activated \"\(title)\".")
    }

    /// Opens the display pane if the request came from the session on screen; a background
    /// session's panel waits until it is selected, exactly as its content does.
    @discardableResult
    private func revealDisplayPane(for sessionID: SessionID) -> Bool {
        let isVisible = sessionID == currentSessionID
        if isVisible {
            displayPaneController.showSession(sessionID)
            setDisplayPaneVisible(true)
        }
        return isVisible
    }

    // MARK: Browser Scripts

    /// A JSON string literal, so a selector cannot break out of the injected JavaScript.
    private static func jsLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    private static func queryScript(selector: String) -> String {
        """
        (function(){
          try {
            var els = Array.prototype.slice.call(document.querySelectorAll(\(jsLiteral(selector))), 0, 30);
            return JSON.stringify({ count: els.length, elements: els.map(function(e, i){
              var r = e.getBoundingClientRect(), attrs = {};
              ['href','src','value','placeholder','aria-label','name','type','alt','role'].forEach(function(a){
                var v = e.getAttribute(a); if (v) attrs[a] = v;
              });
              return {
                i: i,
                tag: e.tagName.toLowerCase(),
                id: e.id || undefined,
                cls: (e.className && e.className.toString().trim()) || undefined,
                text: ((e.innerText || e.textContent || '').trim().slice(0, 200)) || undefined,
                attrs: Object.keys(attrs).length ? attrs : undefined,
                rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }
              };
            }) }, null, 1);
          } catch (err) { return JSON.stringify({ error: String(err) }); }
        })()
        """
    }

    private static func clickScript(selector: String) -> String {
        """
        (function(){
          try {
            var e = document.querySelector(\(jsLiteral(selector)));
            if (!e) return 'No element matches that selector.';
            e.scrollIntoView({ block: 'center' });
            e.click();
            return 'Clicked <' + e.tagName.toLowerCase() + '> ' + ((e.innerText||'').trim().slice(0,120));
          } catch (err) { return 'Click failed: ' + String(err); }
        })()
        """
    }

    // MARK: Tools

    private func displayImage(
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
            return .failure("\(url.lastPathComponent) is not an image Skalman can display.")
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

    private func displayHTML(
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

    // MARK: Presentation

    /// Hands content to the panel and reports back where it landed.
    ///
    /// Shared by both tools because the interesting part is not what was rendered but whether
    /// the user can currently see it.
    private func present(
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
    private func resolve(path: String, for sessionID: SessionID) -> URL? {
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
