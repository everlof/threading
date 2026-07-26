import AppKit

/// Inspect mode, wired to the View menu. Element mode outlines the view under the pointer;
/// freeflow mode marks the pointer's exact position. Clicking either opens the report sheet:
/// a window screenshot with the capture marked, the text naming it, and a copy button whose
/// markdown pastes straight into a session composer.
extension MainWindowController {

    // MARK: - Public Methods

    func toggleElementInspector(mode: InspectorMode) {
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

        elementInspector.toggle(mode, over: window)
    }

    // MARK: - Private Methods

    private func presentElementReport(for target: NSView, layers: InspectorLayers) {
        guard let window else { return }

        var report = ElementReport.build(for: target, layers: layers)
        let indicator = InspectorIndicator.element(levels: report.levels, layers: layers)

        let capture = captureScreenshot(of: window, annotating: indicator)
        report.screenshotPath = capture.path

        presentReport(
            heading: InspectorStrings.elementHeading,
            subheading: report.target.className,
            markdown: report.markdown,
            screenshot: capture.image
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
        report.screenshotPath = capture.path

        presentReport(
            heading: InspectorStrings.pointHeading,
            subheading: InspectorGeometry.describe(point),
            markdown: report.markdown,
            screenshot: capture.image
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
        report.screenshotPath = capture.path

        presentReport(
            heading: InspectorStrings.regionHeading,
            subheading: InspectorGeometry.describe(rect),
            markdown: report.markdown,
            screenshot: capture.image
        )
    }

    private func captureScreenshot(
        of window: NSWindow,
        annotating indicator: InspectorIndicator
    ) -> (image: NSImage?, path: String?) {
        guard let rep = WindowSnapshot.capture(window: window, annotating: indicator) else {
            return (nil, nil)
        }

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        // A failed write costs the report its path line, never the sheet.
        return (image, WindowSnapshot.writePNG(rep)?.path)
    }

    private func presentReport(
        heading: String,
        subheading: String,
        markdown: String,
        screenshot: NSImage?
    ) {
        let sheet = InspectorReportViewController(
            heading: heading,
            subheading: subheading,
            markdown: markdown,
            screenshot: screenshot
        )
        sheet.onDone = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.contentViewController?.dismiss(sheet)
        }

        contentViewController?.presentAsSheet(sheet)
    }
}
