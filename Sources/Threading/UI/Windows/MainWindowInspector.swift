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

    /// Help ▸ Report a Problem. Lives beside the inspector's own sheet because both send the
    /// same private DTO through the same durable outbox; only the reviewed evidence differs.
    func presentReportProblem() {
        MacRemoteDiagnostics.record(.issueReportOpened, fields: [
            .reason: "manual",
            .surface: "helpMenu",
        ])
        let sheet = ReportProblemViewController()
        sheet.onDone = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.contentViewController?.dismiss(sheet)
        }

        if let submitter = issueReportSubmitter {
            sheet.onSubmitReport = { draft in
                await submitter.submit(trigger: "manual", draft: draft)
            }
        }
#if DEBUG
        sheet.onSendToChat = { [weak self] request in
            guard let self else {
                return .failed(message: DeveloperReportChatStrings.notCreated)
            }
            return self.startDeveloperReportChat(request)
        }
#endif

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

    /// Opens the report sheet on a picture taken outside Threading.
    ///
    /// Two doors lead here, and both are the app icon in the sense that matters: the Dock's, and
    /// the strip beside the traffic lights. Neither is discoverable by looking, which is the one
    /// weakness of the feature and the reason it is worth having anyway — the person who needs it
    /// has just pressed ⌘⇧4 and is holding a file, and both are where a Mac user already drops
    /// one.
    ///
    /// The sheet is the same sheet. What differs is the capture's provenance, which is why the
    /// report says so in its first line rather than pretending the window took it.
    func presentDroppedScreenshotReport(at url: URL, from source: DroppedScreenshotReport.Source) {
        guard DroppedScreenshotReport.isReportable(url), let image = NSImage(contentsOf: url) else {
            return
        }
        MacRemoteDiagnostics.record(.issueReportOpened, fields: [
            .reason: source.rawValue,
            .surface: "droppedScreenshot",
        ])
        showWindow(nil)
        presentReport(
            heading: L10n.string("Screenshot Report"),
            subheading: url.lastPathComponent,
            markdown: DroppedScreenshotReport.markdown(for: url, image: image),
            screenshot: image,
            screenshotURL: url
        )
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
        MacRemoteDiagnostics.record(.issueReportOpened, fields: [
            .reason: "manual",
            .surface: "inspector",
        ])
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
        // Read before the view loads, because the sheet sizes itself to the window it is about
        // to slide out of — the capture is the content now, and it is worth the whole window.
        sheet.availableSize = window?.contentView?.bounds.size
        sheet.onDone = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.contentViewController?.dismiss(sheet)
        }

        if let submitter = issueReportSubmitter {
            sheet.onSubmitReport = { draft, screenshot in
                await submitter.submit(
                    trigger: "manual",
                    draft: draft,
                    screenshot: screenshot
                )
            }
        }
#if DEBUG
        sheet.onSendToChat = { [weak self] request in
            guard let self else {
                return .failed(message: DeveloperReportChatStrings.notCreated)
            }
            return self.startDeveloperReportChat(request)
        }
#endif

        contentViewController?.presentAsSheet(sheet)
    }
}
