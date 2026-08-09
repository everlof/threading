import AppKit

/// Inspect mode, wired to the View menu. One command: the view under the pointer is outlined
/// as you move, a click picks it, a drag captures the rectangle it draws, and ⇧ suppresses
/// detection so a click marks the pointer's exact position instead. Any of the three opens the
/// report sheet: a window screenshot with the capture marked, the text naming it, and a copy
/// button whose markdown pastes straight into a session composer.
extension MainWindowController {

    // MARK: - Public Methods

    func toggleElementInspector() {
        guard let window else { return }

        elementInspector.onPick = { [weak self] picked, layers in
            self?.presentElementReport(for: picked, layers: layers)
        }
        elementInspector.onPickPoint = { [weak self] point in
            self?.presentPointReport(at: point)
        }
        elementInspector.onPickRegion = { [weak self] rect in
            self?.presentRegionReport(for: rect)
        }

        elementInspector.toggle(over: window)
    }

    /// Help ▸ Report a Problem. Lives beside the inspector's own sheet because both file the
    /// same kind of ticket through the same chain; only the evidence differs.
    func presentReportProblem() {
        let sheet = ReportProblemViewController()
        sheet.onDone = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.contentViewController?.dismiss(sheet)
        }

        let submitter = GitHubIssueSubmitter.live()
        sheet.onSubmitIssue = { draft in await submitter.submit(draft) }

        contentViewController?.presentAsSheet(sheet)
    }

    // MARK: - Private Methods

    private func presentElementReport(for target: NSView, layers: InspectorLayers) {
        guard let window else { return }

        var report = ElementReport.build(for: target, layers: layers)
        let indicator = InspectorIndicator.element(levels: report.levels, layers: layers)

        let capture = captureScreenshot(of: window, annotating: indicator)
        report.screenshotPath = capture.url?.path

        presentReport(
            heading: InspectorStrings.elementHeading,
            subheading: report.target.className,
            markdown: report.markdown,
            screenshot: capture.image,
            screenshotURL: capture.url
        )
    }

    private func presentPointReport(at point: NSPoint) {
        guard let window else { return }

        var report = PointReport(
            point: point,
            windowSize: window.frame.size,
            screenshotPath: nil
        )
        let indicator = InspectorIndicator.point(
            point,
            label: InspectorGeometry.describe(point)
        )

        let capture = captureScreenshot(of: window, annotating: indicator)
        report.screenshotPath = capture.url?.path

        presentReport(
            heading: InspectorStrings.pointHeading,
            subheading: InspectorGeometry.describe(point),
            markdown: report.markdown,
            screenshot: capture.image,
            screenshotURL: capture.url
        )
    }

    private func presentRegionReport(for rect: NSRect) {
        guard let window else { return }

        var report = RegionReport(
            rect: rect,
            windowSize: window.frame.size,
            screenshotPath: nil
        )
        let indicator = InspectorIndicator.region(
            rect,
            label: InspectorGeometry.describe(rect.size)
        )

        let capture = captureScreenshot(of: window, annotating: indicator)
        report.screenshotPath = capture.url?.path

        presentReport(
            heading: InspectorStrings.regionHeading,
            subheading: InspectorGeometry.describe(rect),
            markdown: report.markdown,
            screenshot: capture.image,
            screenshotURL: capture.url
        )
    }

    private func captureScreenshot(
        of window: NSWindow,
        annotating indicator: InspectorIndicator
    ) -> (image: NSImage?, url: URL?) {
        guard let rep = WindowSnapshot.capture(window: window, annotating: indicator) else {
            return (nil, nil)
        }

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        // A failed write costs the report its path line, never the sheet.
        return (image, WindowSnapshot.writePNG(rep))
    }

    /// The environment is read here rather than by each report, because it is the same reading
    /// for all three and it belongs to the *window* the capture was taken from — which is the
    /// one thing an `ElementReport` built from a detached view in a test cannot have.
    private func presentReport(
        heading: String,
        subheading: String,
        markdown: String,
        screenshot: NSImage?,
        screenshotURL: URL?
    ) {
        let environment = InspectorEnvironment.capture(
            window: window,
            sessionID: currentSessionID
        )

        let sheet = InspectorReportViewController(
            heading: heading,
            subheading: subheading,
            markdown: markdown,
            environment: environment.markdown,
            screenshot: screenshot,
            screenshotURL: screenshotURL
        )
        sheet.onDone = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.contentViewController?.dismiss(sheet)
        }

        // Resolved here rather than held by the sheet: the credential chain is the window's
        // business, and a sheet that reached for it could not be built in a test.
        let submitter = GitHubIssueSubmitter.live()
        sheet.onSubmitIssue = { draft in await submitter.submit(draft) }

        contentViewController?.presentAsSheet(sheet)
    }
}
