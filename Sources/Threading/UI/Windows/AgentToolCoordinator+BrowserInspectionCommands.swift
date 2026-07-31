import AppKit

@MainActor
extension AgentToolCoordinator {
    func browserConsole(
        _ arguments: BrowserConsoleArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let level = arguments.level?.lowercased()
        if let level, !["debug", "info", "warning", "warn", "error"].contains(level) {
            completion(.failure("level must be debug, info, warning, or error."))
            return
        }
        withAuthorizedBrowser(for: sessionID, purpose: "read") { browser in
            guard let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            completion(.success(browser.consoleOutput(
                minimumLevel: level,
                clear: arguments.clear ?? false
            )))
        }
    }

    func browserNetwork(
        _ arguments: BrowserNetworkArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        withAuthorizedBrowser(for: sessionID, purpose: "inspect network activity from") { browser in
            guard let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            completion(.success(browser.networkOutput(
                kind: arguments.kind,
                errorsOnly: arguments.errorsOnly ?? false,
                clear: arguments.clear ?? false
            )))
        }
    }

    func browserPerformance(
        _ arguments: BrowserPerformanceArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let maximumResources =
            arguments.maximumResources ?? BrowserAgentDefaults.defaultPerformanceResources
        guard (0...BrowserAgentDefaults.maximumPerformanceResources)
            .contains(maximumResources) else {
            completion(.failure(
                "maximum_resources must be between 0 and "
                    + "\(BrowserAgentDefaults.maximumPerformanceResources)."
            ))
            return
        }

        withAuthorizedBrowser(
            for: sessionID,
            purpose: "measure performance on"
        ) { [weak self] browser in
            guard let self, let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            guard let measuredURL = browser.currentURL else {
                completion(.failure("The page closed before performance measurement began."))
                return
            }
            guard let measuredPage = browser.agentPageIdentity else {
                completion(.failure("The page closed before performance measurement began."))
                return
            }
            Task { @MainActor in
                do {
                    let report = try await browser.agentPerformanceReport(
                        maximumResources: maximumResources
                    )
                    guard let finalURL = browser.currentURL else {
                        completion(.failure(
                            "The page closed before performance measurements were returned."
                        ))
                        return
                    }
                    let allowed = await self.authorizeBrowserAccess(
                        to: finalURL,
                        for: sessionID,
                        purpose: "return performance measurements from"
                    )
                    guard allowed else {
                        completion(.failure(
                            "The page moved to \(finalURL.host ?? "another origin"), and the user "
                                + "did not allow its performance data to be returned."
                        ))
                        return
                    }
                    guard browser.agentPageIdentity == measuredPage else {
                        completion(.failure(
                            "The page navigated while performance was being measured; retry on "
                                + "the current page."
                        ))
                        return
                    }
                    completion(.success(
                        report.agentText
                            + "\nMeasured URL: "
                            + BrowserURLRedactor.redact(measuredURL.absoluteString)
                    ))
                } catch {
                    completion(.failure(
                        "Could not measure page performance: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    func browserAccessibilityAudit(
        _ arguments: BrowserAccessibilityAuditArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let maximumIssues =
            arguments.maximumIssues ?? BrowserAgentDefaults.defaultAccessibilityAuditIssues
        guard (1...BrowserAgentDefaults.maximumAccessibilityAuditIssues)
            .contains(maximumIssues) else {
            completion(.failure(
                "maximum_issues must be between 1 and "
                    + "\(BrowserAgentDefaults.maximumAccessibilityAuditIssues)."
            ))
            return
        }

        withAuthorizedBrowser(
            for: sessionID,
            purpose: "audit accessibility on"
        ) { [weak self] browser in
            guard let self, let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            guard let auditedURL = browser.currentURL else {
                completion(.failure("The page closed before the accessibility audit began."))
                return
            }
            guard let auditedPage = browser.agentPageIdentity else {
                completion(.failure("The page closed before the accessibility audit began."))
                return
            }
            Task { @MainActor in
                do {
                    let report = try await browser.agentAccessibilityAudit(
                        maximumIssues: maximumIssues
                    )
                    guard let finalURL = browser.currentURL else {
                        completion(.failure(
                            "The page closed before the accessibility audit was returned."
                        ))
                        return
                    }
                    let allowed = await self.authorizeBrowserAccess(
                        to: finalURL,
                        for: sessionID,
                        purpose: "return the accessibility audit from"
                    )
                    guard allowed else {
                        completion(.failure(
                            "The page moved to \(finalURL.host ?? "another origin"), and the user "
                                + "did not allow its accessibility data to be returned."
                        ))
                        return
                    }
                    guard browser.agentPageIdentity == auditedPage else {
                        completion(.failure(
                            "The page navigated while accessibility was being audited; retry on "
                                + "the current page."
                        ))
                        return
                    }
                    completion(.success(
                        report.agentText
                            + "\nAudited URL: "
                            + BrowserURLRedactor.redact(auditedURL.absoluteString)
                    ))
                } catch {
                    completion(.failure(
                        "Could not audit page accessibility: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    func browserScreenshot(
        _ arguments: BrowserScreenshotArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let hasRef = arguments.ref?.isEmpty == false
        let hasSelector = arguments.selector?.isEmpty == false
        let hasLocator = arguments.locator != nil
        guard [hasRef, hasSelector, hasLocator].filter({ $0 }).count <= 1 else {
            completion(.failure(
                "Provide ref, selector, or locator for an element capture, not a combination."
            ))
            return
        }
        let hasTarget = hasRef || hasSelector || hasLocator
        guard !(hasTarget && arguments.fullPage == true) else {
            completion(.failure("full_page cannot be combined with ref or selector."))
            return
        }

        withAuthorizedBrowser(for: sessionID, purpose: "capture") { [weak self] browser in
            guard let self, let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            guard let capturedPage = browser.agentPageIdentity else {
                completion(.failure("The page closed before the screenshot began."))
                return
            }

            Task { @MainActor in
                let capture: BrowserScreenshotCapture
                let clippedTarget: Bool
                do {
                    if hasTarget {
                        let result = try await browser.screenshot(
                            ref: arguments.ref,
                            selector: arguments.selector,
                            locator: arguments.locator
                        )
                        guard result.target.ok else {
                            completion(.failure(result.target.message))
                            return
                        }
                        guard let elementCapture = result.capture else {
                            completion(.failure("Could not capture the target element."))
                            return
                        }
                        capture = elementCapture
                        clippedTarget = result.target.clipped
                    } else {
                        guard let pageCapture = await browser.screenshot(
                            fullPage: arguments.fullPage ?? false
                        ) else {
                            completion(.failure("Could not capture the page."))
                            return
                        }
                        capture = pageCapture
                        clippedTarget = false
                    }
                } catch {
                    completion(.failure(
                        "Could not resolve the screenshot target: \(error.localizedDescription)"
                    ))
                    return
                }

                guard browser.agentPageIdentity == capturedPage,
                      let url = URL(string: capturedPage.url) else {
                    completion(.failure(
                        "The browser document changed while the screenshot was being captured; "
                            + "retry against the current page."
                    ))
                    return
                }
                let allowed = await self.authorizeBrowserAccess(
                    to: url,
                    for: sessionID,
                    purpose: hasTarget
                        ? "return an element screenshot after scrolling on"
                        : "return a screenshot of"
                )
                guard allowed else {
                    completion(.failure(
                        "The page moved to \(url.host ?? "another origin"), and the user did not "
                            + "allow the screenshot to be returned."
                    ))
                    return
                }
                guard browser.agentPageIdentity == capturedPage else {
                    completion(.failure(
                        "The browser document changed while access to the screenshot was being "
                            + "decided; retry against the current page."
                    ))
                    return
                }
                guard let image = NSImage(data: capture.data) else {
                    completion(.failure("The captured PNG could not be decoded."))
                    return
                }

                let cachedURL = self.dependencies.displayStore.cacheBrowserScreenshot(
                    capture.data,
                    for: sessionID
                )
                let show = arguments.show ?? true
                if show {
                    _ = self.present(
                        DisplayContent(
                            body: .image(image, url: cachedURL ?? url),
                            title: browser.currentTitle,
                            subtitle: url.absoluteString
                        ),
                        for: sessionID,
                        describedAs: "a screenshot of \(url.host ?? "the page")"
                    )
                }

                let subject = hasTarget ? "the target on " : ""
                var text = "Captured \(capture.width)×\(capture.height) PNG of \(subject)"
                    + "\(BrowserURLRedactor.redact(url.absoluteString))."
                if clippedTarget {
                    text += "\nThe target exceeded a visible frame or viewport, so the PNG "
                        + "contains its visible portion."
                }
                if let cachedURL {
                    text += "\nSaved at: \(cachedURL.path)"
                }
                if show {
                    text += "\nThe user can also see it in the display panel."
                }
                completion(.screenshot(
                    text,
                    pngData: capture.data,
                    includeImage: arguments.includeImage ?? true
                ))
            }
        }
    }

    func browserVisualCompare(
        _ arguments: BrowserVisualCompareArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let baselinePath = arguments.baselinePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !baselinePath.isEmpty,
              (baselinePath as NSString).isAbsolutePath else {
            completion(.failure("baseline_path must be an absolute path to a PNG."))
            return
        }
        let baselineURL = URL(fileURLWithPath: baselinePath).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: baselineURL.path),
              let values = try? baselineURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true else {
            completion(.failure("baseline_path is not a readable regular file."))
            return
        }
        guard (values.fileSize ?? 0) <= BrowserDefaults.maximumVisualBaselineBytes else {
            completion(.failure(
                "The PNG baseline exceeds the \(BrowserDefaults.maximumVisualBaselineBytes) "
                    + "byte comparison limit."
            ))
            return
        }
        let baselineData: Data
        do {
            baselineData = try Data(contentsOf: baselineURL, options: .mappedIfSafe)
        } catch {
            completion(.failure("Could not read the PNG baseline: \(error.localizedDescription)"))
            return
        }

        let threshold = arguments.channelThreshold ?? 16
        guard (0...255).contains(threshold) else {
            completion(.failure("channel_threshold must be between 0 and 255."))
            return
        }
        let maximumRatio = arguments.maximumDifferentRatio ?? 0.001
        guard (0...1).contains(maximumRatio) else {
            completion(.failure("maximum_different_ratio must be between 0 and 1."))
            return
        }
        let hasRef = arguments.ref?.isEmpty == false
        let hasSelector = arguments.selector?.isEmpty == false
        let hasLocator = arguments.locator != nil
        guard [hasRef, hasSelector, hasLocator].filter({ $0 }).count <= 1 else {
            completion(.failure(
                "Provide ref, selector, or locator for an element comparison, not a combination."
            ))
            return
        }
        let hasTarget = hasRef || hasSelector || hasLocator
        guard !(hasTarget && arguments.fullPage == true) else {
            completion(.failure(
                "full_page cannot be combined with ref, selector, or locator."
            ))
            return
        }

        withAuthorizedBrowser(
            for: sessionID,
            purpose: "capture pixels for visual comparison on"
        ) { [weak self] browser in
            guard let self, let browser else {
                completion(.failure("No authorized page is loaded. Use browser_navigate first."))
                return
            }
            guard let capturedPage = browser.agentPageIdentity else {
                completion(.failure("The page closed before visual comparison began."))
                return
            }

            Task { @MainActor in
                let capture: BrowserScreenshotCapture
                let clippedTarget: Bool
                do {
                    if hasTarget {
                        let result = try await browser.screenshot(
                            ref: arguments.ref,
                            selector: arguments.selector,
                            locator: arguments.locator
                        )
                        guard result.target.ok else {
                            completion(.failure(result.target.message))
                            return
                        }
                        guard let targetCapture = result.capture else {
                            completion(.failure(
                                "Could not capture the visual-comparison target."
                            ))
                            return
                        }
                        capture = targetCapture
                        clippedTarget = result.target.clipped
                    } else {
                        guard let pageCapture = await browser.screenshot(
                            fullPage: arguments.fullPage ?? false
                        ) else {
                            completion(.failure(
                                "Could not capture the page for visual comparison."
                            ))
                            return
                        }
                        capture = pageCapture
                        clippedTarget = false
                    }
                } catch {
                    completion(.failure(
                        "Could not resolve the comparison target: \(error.localizedDescription)"
                    ))
                    return
                }

                guard browser.agentPageIdentity == capturedPage,
                      let capturedURL = URL(string: capturedPage.url) else {
                    completion(.failure(
                        "The browser document changed during capture; retry the visual comparison."
                    ))
                    return
                }
                let allowed = await self.authorizeBrowserAccess(
                    to: capturedURL,
                    for: sessionID,
                    purpose: "return visual-comparison pixels from"
                )
                guard allowed else {
                    completion(.failure(
                        "The user did not allow visual-comparison pixels to be returned."
                    ))
                    return
                }
                guard browser.agentPageIdentity == capturedPage else {
                    completion(.failure(
                        "The browser document changed while visual-comparison access was being "
                            + "decided; retry on the current page."
                    ))
                    return
                }

                let comparison: BrowserVisualComparison
                do {
                    comparison = try BrowserVisualComparator.compare(
                        baseline: baselineData,
                        actual: capture.data,
                        channelThreshold: threshold,
                        maximumDifferentRatio: maximumRatio
                    )
                } catch {
                    completion(.failure(
                        "Could not compare the PNGs: \(error.localizedDescription)"
                    ))
                    return
                }
                guard browser.agentPageIdentity == capturedPage else {
                    completion(.failure(
                        "The browser document changed while its pixels were being compared."
                    ))
                    return
                }

                let actualURL = self.dependencies.displayStore.cacheBrowserVisualArtifact(
                    capture.data,
                    kind: "actual",
                    for: sessionID
                )
                let evidenceData = comparison.diffPNG ?? capture.data
                let evidenceKind = comparison.diffPNG == nil ? "actual" : "diff"
                let evidenceURL = comparison.diffPNG.flatMap {
                    self.dependencies.displayStore.cacheBrowserVisualArtifact(
                        $0,
                        kind: "diff",
                        for: sessionID
                    )
                } ?? actualURL
                let shouldShow = arguments.show ?? !comparison.matches
                if shouldShow, let image = NSImage(data: evidenceData) {
                    _ = self.present(
                        DisplayContent(
                            body: .image(image, url: evidenceURL ?? capturedURL),
                            title: comparison.matches
                                ? L10n.string("Visual comparison")
                                : L10n.string("Visual difference"),
                            subtitle: L10n.format(
                                "Compared with %@",
                                baselineURL.lastPathComponent
                            )
                        ),
                        for: sessionID,
                        describedAs: comparison.matches
                            ? "a matching visual comparison"
                            : "a visual comparison difference"
                    )
                }

                var lines = [
                    "Visual comparison: \(comparison.matches ? "MATCH" : "MISMATCH")",
                    "Dimensions: actual \(comparison.width)×\(comparison.height); "
                        + "baseline \(comparison.baselineWidth)×\(comparison.baselineHeight)",
                    "Dimensions match: \(comparison.dimensionsMatch)",
                    "Different pixels: \(comparison.differentPixels)",
                    "Different ratio: \(String(format: "%.6f", comparison.differentRatio))",
                    "Allowed ratio: \(String(format: "%.6f", maximumRatio))",
                    "Channel threshold: \(threshold)",
                    "Maximum channel delta: \(comparison.maximumChannelDelta)"
                ]
                if clippedTarget {
                    lines.append(
                        "The target exceeded a frame or viewport; both baseline and actual must "
                            + "represent the same visible clipping."
                    )
                }
                if let actualURL { lines.append("Actual PNG: \(actualURL.path)") }
                if evidenceKind == "diff", let evidenceURL {
                    lines.append("Diff PNG: \(evidenceURL.path)")
                }
                if shouldShow {
                    lines.append("The user can see the comparison evidence in the display panel.")
                }
                completion(.screenshot(
                    lines.joined(separator: "\n"),
                    pngData: evidenceData,
                    includeImage: arguments.includeImage ?? true
                ))
            }
        }
    }

    /// The session's browser tab, but only once it actually has a page — so the DOM tools fail
    /// with a clear instruction rather than acting on a blank browser.
    func loadedBrowser(for sessionID: SessionID) -> BrowserViewController? {
        guard let browser = displayPaneController.browser(for: sessionID), browser.currentURL != nil else {
            return nil
        }
        return browser
    }

    func currentBrowserPageLease(for sessionID: SessionID) -> BrowserPageLease? {
        guard let browser = loadedBrowser(for: sessionID),
              let page = browser.agentPageIdentity,
              let tab = displayPaneController.tabs(for: sessionID).first(where: {
                  $0.browser === browser
              }) else {
            return nil
        }
        return BrowserPageLease(browser: browser, tabID: tab.id, page: page)
    }

    func browserPageLeaseIsCurrent(
        _ lease: BrowserPageLease,
        for sessionID: SessionID
    ) -> Bool {
        guard displayPaneController.browser(for: sessionID) === lease.browser,
              displayPaneController.tabs(for: sessionID).contains(where: {
                  $0.id == lease.tabID && $0.browser === lease.browser
              }) else {
            return false
        }
        return lease.browser.agentPageIdentity == lease.page
    }

    static func validTarget(
        ref: String?,
        selector: String?,
        locator: BrowserSemanticLocator?
    ) -> Bool {
        let hasRef = ref?.isEmpty == false
        let hasSelector = selector?.isEmpty == false
        return [hasRef, hasSelector, locator != nil].filter { $0 }.count == 1
    }

    /// Resolves the live page and asks for origin access before returning any authenticated page
    /// data to the agent.
    func withAuthorizedBrowser(
        for sessionID: SessionID,
        purpose: String,
        completion: @escaping (BrowserViewController?) -> Void
    ) {
        guard let lease = currentBrowserPageLease(for: sessionID),
              let url = URL(string: lease.page.url) else {
            completion(nil)
            return
        }
        authorizeBrowserAccess(to: url, for: sessionID, purpose: purpose) { [weak self] allowed in
            guard let self,
                  allowed,
                  self.browserPageLeaseIsCurrent(lease, for: sessionID) else {
                completion(nil)
                return
            }
            completion(lease.browser)
        }
    }

    func authorizeBrowserAccess(
        to url: URL,
        for sessionID: SessionID,
        purpose: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let origin = BrowserOrigin(url: url) else {
            completion(false)
            return
        }

        let applyDecision: (BrowserAccessDecision) -> Void = { [weak self] decision in
            guard let self else {
                completion(false)
                return
            }
            switch decision {
            case .allowOnce:
                self.temporaryBrowserOrigins[sessionID, default: []].insert(origin)
                completion(true)
            case .allowPersistently:
                self.browserAccessStore.allowPersistently(origin)
                completion(true)
            case .deny:
                completion(false)
            }
        }

        if let browserAccessDecisionProvider {
            browserAccessDecisionProvider(origin, purpose, applyDecision)
            return
        }
        if hasBrowserAccess(to: origin, for: sessionID) {
            completion(true)
            return
        }

        // Three affirmative answers and a way out, so this goes through `choose` rather than
        // `ask`: "Always Allow This Host" is this prompt's own remembered answer, scoped to one
        // host and revocable in Settings ▸ Tools. A "Don't ask again" box beside it would
        // remember *something* about every host at once, which is why the register marks a
        // grant `.alwaysAsks` and why `choose` refuses a suppressible prompt.
        let request = ChoiceRequest(
            prompt: .grantBrowserOriginAccess,
            title: L10n.format("Allow the agent to use %@?", origin.displayName),
            message: L10n.format("""
                The agent wants to %@ this website in Threading's browser. This browser may \
                contain signed-in sessions and cookies that are not available to the agent's shell.

                Page content is untrusted. Allow access only when this host is relevant to your task.
                """, L10n.string(purpose)),
            options: [
                ConfirmationOption(title: L10n.string("Allow Once")),
                ConfirmationOption(title: L10n.string("Always Allow This Host"))
            ],
            cancelTitle: L10n.string("Deny"),
            style: .informational
        )

        ConfirmationAlert.choose(request, in: windowProvider()) { chosen in
            switch chosen {
            case 0: applyDecision(.allowOnce)
            case 1: applyDecision(.allowPersistently)
            default: applyDecision(.deny)
            }
        }
    }

    func hasBrowserAccess(to url: URL, for sessionID: SessionID) -> Bool {
        guard let origin = BrowserOrigin(url: url) else { return false }
        return hasBrowserAccess(to: origin, for: sessionID)
    }

    func hasBrowserAccess(to origin: BrowserOrigin, for sessionID: SessionID) -> Bool {
        origin.scheme == "about"
            || origin.isLocal
            || browserAccessStore.isPersistentlyAllowed(origin)
            || temporaryBrowserOrigins[sessionID, default: []].contains(origin)
    }

    func authorizeBrowserAccess(
        to url: URL,
        for sessionID: SessionID,
        purpose: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            authorizeBrowserAccess(
                to: url,
                for: sessionID,
                purpose: purpose
            ) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func browserActionResult(
        _ outcome: BrowserActionOutcome,
        browser: BrowserViewController,
        sessionID: SessionID
    ) async -> MCPToolResult {
        guard outcome.ok else { return .failure(outcome.message) }

        // Let synchronous application handlers and a resulting top-level navigation settle. A
        // streaming page may never report idle, so this wait is deliberately bounded.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try? await Task.sleep(nanoseconds: 120_000_000)
        } while browser.webView.isLoading && Date() < deadline

        guard displayPaneController.browser(for: sessionID) === browser else {
            return .failure(
                "\(outcome.message), but a different browser tab became active before its "
                    + "result was read; retry against the tab now selected."
            )
        }
        guard let authorizedPage = browser.agentPageIdentity,
              let url = URL(string: authorizedPage.url) else {
            return .failure(
                "\(outcome.message), but the browser page closed before its result was read."
            )
        }
        let allowed = await authorizeBrowserAccess(
            to: url,
            for: sessionID,
            purpose: "read after navigating to"
        )
        guard allowed else {
            return .failure(
                "\(outcome.message), but the page moved to \(url.host ?? url.absoluteString) "
                    + "and the user did not allow access to the new origin."
            )
        }
        guard browser.agentPageIdentity == authorizedPage else {
            return .failure(
                "\(outcome.message), but the browser document changed while access to its "
                    + "result was being decided; retry against the current page."
            )
        }
        guard displayPaneController.browser(for: sessionID) === browser else {
            return .failure(
                "\(outcome.message), but a different browser tab became active while access "
                    + "to its result was being decided."
            )
        }

        do {
            let snapshot = try await browser.agentSnapshot()
            guard browser.agentPageIdentity == authorizedPage,
                  displayPaneController.browser(for: sessionID) === browser else {
                return .failure(
                    "\(outcome.message), but the browser document changed while its result "
                        + "was being read; retry against the current page."
                )
            }
            return .success(outcome.message + "\n\n" + snapshot.agentText)
        } catch {
            guard browser.agentPageIdentity == authorizedPage,
                  displayPaneController.browser(for: sessionID) === browser else {
                return .failure(
                    "\(outcome.message), but the browser document or selected tab changed while "
                        + "its result was being read; retry against the current page."
                )
            }
            return .success(
                outcome.message
                    + "\nNow at: "
                    + BrowserURLRedactor.redact(authorizedPage.url)
            )
        }
    }

    func confirmSensitiveBrowserAction(
        _ action: String,
        target: BrowserTargetDescription,
        browser: BrowserViewController
    ) async -> Bool {
        let host = browser.currentURL?.host ?? L10n.string("this page")
        let label = target.name.flatMap { name in
            name.isEmpty ? nil : L10n.format("\nControl: %@", name)
        } ?? ""

        let request = ConfirmationRequest(
            prompt: .approveSensitiveBrowserAction,
            title: L10n.format("%@ on %@?", L10n.string(action), host),
            message: L10n.format("""
                This can change data outside Threading using the browser's signed-in session.%@

                Approve only if this is part of the task you gave the agent.
                """, label),
            confirmTitle: L10n.string("Allow"),
            cancelTitle: L10n.string("Deny")
        )

        return await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(request, in: windowProvider()) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    // MARK: Browser Scripts

    /// A JSON string literal, so a selector cannot break out of the injected JavaScript.
    static func jsLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    static func queryScript(selector: String) -> String {
        """
        (function(){
          try {
            function safeURL(value, base) {
              try {
                var url = new URL(String(value || ''), base || location.href);
                url.username = ''; url.password = ''; url.hash = '';
                var sensitive = [
                  'access_token', 'auth', 'code', 'credential', 'key', 'password',
                  'secret', 'session', 'signature', 'token'
                ];
                Array.from(url.searchParams.keys()).forEach(function(name) {
                  var lower = name.toLowerCase();
                  if (sensitive.some(function(part) { return lower.includes(part); })) {
                    url.searchParams.set(name, '[redacted]');
                  }
                });
                return url.href.slice(0, 2000);
              } catch (_) { return '(invalid or redacted URL)'; }
            }
            var selector = \(jsLiteral(selector)), els = [];
            function visit(root) {
              var children = Array.prototype.slice.call((root && root.children) || []);
              for (var i = 0; i < children.length && els.length < 30; i += 1) {
                var child = children[i];
                if (child.matches(selector)) els.push(child);
                if (child.shadowRoot) visit(child.shadowRoot);
                if (child.tagName.toLowerCase() === 'iframe') {
                  try {
                    if (child.contentDocument && child.contentDocument.documentElement) {
                      visit(child.contentDocument);
                    }
                  } catch (_) {}
                }
                visit(child);
              }
            }
            function frameOffset(element) {
              var x = 0, y = 0, targetDocument = element.ownerDocument;
              while (targetDocument && targetDocument !== document) {
                var frame = null;
                try { frame = targetDocument.defaultView.frameElement; } catch (_) {}
                if (!frame) break;
                var frameRect = frame.getBoundingClientRect();
                x += frameRect.left + Number(frame.clientLeft || 0);
                y += frameRect.top + Number(frame.clientTop || 0);
                targetDocument = frame.ownerDocument;
              }
              return { x: x, y: y };
            }
            visit(document);
            return JSON.stringify({ count: els.length, elements: els.map(function(e, i){
              var r = e.getBoundingClientRect(), offset = frameOffset(e), attrs = {};
              ['href','src','placeholder','aria-label','name','type','alt','role'].forEach(function(a){
                var v = e.getAttribute(a); if (v) attrs[a] = v;
                if (v && (a === 'href' || a === 'src')) {
                  attrs[a] = safeURL(v, e.ownerDocument.baseURI);
                }
              });
              return {
                i: i,
                tag: e.tagName.toLowerCase(),
                id: e.id || undefined,
                cls: (e.className && e.className.toString().trim()) || undefined,
                text: ((e.innerText || e.textContent || '').trim().slice(0, 200)) || undefined,
                attrs: Object.keys(attrs).length ? attrs : undefined,
                rect: {
                  x: Math.round(r.x + offset.x), y: Math.round(r.y + offset.y),
                  w: Math.round(r.width), h: Math.round(r.height)
                }
              };
            }) }, null, 1);
          } catch (err) { return JSON.stringify({ error: String(err) }); }
        })()
        """
    }

}
