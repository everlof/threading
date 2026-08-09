import AppKit
import XCTest
@testable import Threading

/// The two sheets that file a ticket, drawn and driven.
///
/// Rendered because the complaint that produced them was about *size and clarity* — a note box
/// one line tall under a wall of read-only markdown — and no constraint assertion catches that.
/// Driven because both sheets have an outcome path that touches a network, a clipboard and a
/// browser, and all three are injected precisely so a test can watch them without any of it.
final class IssueReportingRenderTests: XCTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - The inspector's sheet

    @MainActor
    func testTheDescriptionIsTheLargestFieldAndSitsAboveTheEvidence() {
        let sheet = makeInspectorSheet()
        let host = laidOut(sheet)

        guard let note = view(
            withIdentifier: InspectorReportIdentifiers.note,
            under: host
        ) else {
            return XCTFail("the description field fell out of the tree")
        }

        XCTAssertGreaterThanOrEqual(
            note.frame.height,
            InspectorReportLayout.noteHeight,
            "the description opened smaller than a paragraph"
        )

        // A window's top is a higher y in an unflipped view; "above" is therefore greater maxY.
        let evidence = host.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first
        if let evidence {
            XCTAssertGreaterThan(
                note.convert(note.bounds, to: host).minY,
                evidence.convert(evidence.bounds, to: host).maxY - 1,
                "the captured details sit above the description again"
            )
        }
    }

    @MainActor
    func testAFiledIssueCopiesTheScreenshotAndOpensTheIssue() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        let issue = URL(string: "https://github.com/everlof/threading/issues/42")!
        var opened: [URL] = []
        var copied: [NSImage] = []
        sheet.openURL = { opened.append($0) }
        sheet.copyImageToPasteboard = { copied.append($0) }
        sheet.onSubmitIssue = { _ in .created(url: issue, number: 42, tier: .ghCLI) }

        let done = expectation(description: "submitted")
        sheet.submitIssue()
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(opened, [issue])
        XCTAssertEqual(copied.count, 1, "the capture never reached the clipboard")
        XCTAssertTrue(sheet.statusMessage.contains("42"), sheet.statusMessage)
    }

    @MainActor
    func testTheScreenshotPreviewOpensTheZoomableInspector() throws {
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-inspector-preview-\(UUID().uuidString).png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(swatch().tiffRepresentation)
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: screenshotURL)
        defer { try? FileManager.default.removeItem(at: screenshotURL) }

        let sheet = makeInspectorSheet(screenshotURL: screenshotURL)
        let host = laidOut(sheet)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { MediaInspectorPresenter.dismiss(in: window) }

        let preview = try XCTUnwrap(firstSubview(of: ThemedImagePreview.self, under: host))
        XCTAssertEqual(preview.fileURL, screenshotURL)
        XCTAssertNotNil(preview.accessibilityHelp(), "the preview does not advertise inspection")
        XCTAssertTrue(preview.performPrimaryAction(), "the report image did not open")
        host.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(firstSubview(of: MediaInspectorCanvas.self, under: host))
        let fittedScale = canvas.displayedScale
        canvas.zoomIn()
        XCTAssertGreaterThan(
            canvas.displayedScale,
            fittedScale,
            "the opened report image cannot zoom"
        )
    }

    @MainActor
    func testARefusedIssueSaysSoAndKeepsTheSheetOpen() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        var opened: [URL] = []
        var dismissed = false
        sheet.openURL = { opened.append($0) }
        sheet.onDone = { dismissed = true }
        sheet.onSubmitIssue = { _ in .failed(message: "GitHub refused the report (500).") }

        let done = expectation(description: "submitted")
        sheet.submitIssue()
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(sheet.statusMessage, "GitHub refused the report (500).")
        XCTAssertTrue(opened.isEmpty, "nothing was created, so nothing should open")
        XCTAssertFalse(dismissed, "a failed submission must not throw the report away")
    }

    @MainActor
    func testTheDraftCarriesTheNoteTheReportAndTheEnvironment() {
        let sheet = makeInspectorSheet()
        let host = laidOut(sheet)
        (view(withIdentifier: InspectorReportIdentifiers.note, under: host) as? PromptView)?
            .stringValue = "Archive button is unclickable"

        let draft = sheet.issueDraft()

        XCTAssertEqual(draft.title, "Archive button is unclickable")
        XCTAssertTrue(draft.body.hasPrefix("Archive button is unclickable"))
        XCTAssertTrue(draft.body.contains("- Element: SidebarRowView"))
        XCTAssertTrue(draft.body.contains("Threading"))
        XCTAssertTrue(draft.body.contains("- App theme: System, adaptive, drawing dark"))
        XCTAssertEqual(draft.labels, ["bug"])
    }

    /// The environment is one block in three places, and the ticket is the one that could hold
    /// two: the composer closes every body with an environment under a rule, so a report string
    /// that already carried its own would print the build line twice.
    @MainActor
    func testTheEnvironmentIsStatedOnceInTheTicketAndOnceInTheDetails() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        let body = sheet.issueDraft().body
        XCTAssertEqual(
            body.components(separatedBy: "Threading 1.0 (1)").count - 1,
            1,
            "the environment landed in the ticket twice"
        )

        XCTAssertTrue(
            sheet.details.contains("- Window: 1440×900 at 2×"),
            "the box says what was captured, not what it was captured under"
        )
        XCTAssertTrue(
            sheet.details.hasPrefix("- Element: SidebarRowView"),
            "the capture still leads the details"
        )
    }

    // MARK: - Help ▸ Report a Problem

    @MainActor
    func testTheKindPicksTheLabelAndTheTitleWinsOverTheFirstLine() {
        let sheet = ReportProblemViewController()
        let host = laidOut(sheet)

        let title = view(withIdentifier: ReportProblemIdentifiers.title, under: host)
        (title as? ThemedTextField)?.stringValue = "Toolbar corner is cut off"
        let detail = view(withIdentifier: ReportProblemIdentifiers.detail, under: host)
        (detail as? PromptView)?.stringValue = "It loses the rounding at the top right."

        XCTAssertEqual(sheet.issueDraft().title, "Toolbar corner is cut off")
        XCTAssertEqual(sheet.issueDraft().labels, ["bug"])

        let kind = view(withIdentifier: ReportProblemIdentifiers.kind, under: host)
        (kind as? ThemedSegmentedControl)?.onSelect?(1)
        XCTAssertEqual(
            sheet.issueDraft().labels,
            ["enhancement"],
            "an improvement filed as a bug is how a label stops meaning anything"
        )
    }

    @MainActor
    func testAnEmptyReportIsRefusedBeforeItReachesGitHub() {
        let sheet = ReportProblemViewController()
        _ = laidOut(sheet)

        var submissions = 0
        sheet.onSubmitIssue = { _ in
            submissions += 1
            return .failed(message: "never")
        }

        sheet.submitIssue()

        XCTAssertEqual(submissions, 0, "an empty ticket was sent to a person")
        XCTAssertFalse(sheet.statusMessage.isEmpty, "and nothing said why")
    }

    @MainActor
    func testTheEnvironmentIsNamedOnScreenBeforeAnythingIsSent() {
        let sheet = ReportProblemViewController()
        let host = laidOut(sheet)

        let note = view(withIdentifier: ReportProblemIdentifiers.environment, under: host)
        let shown = (note as? NSTextField)?.stringValue ?? ""

        XCTAssertTrue(shown.contains("Threading"), shown)
        XCTAssertFalse(shown.isEmpty, "what travels with the ticket is not stated")
    }

    /// A theme states a typeface, and one of them is a wide monospace in which a single caption
    /// runs longer than the sheet. A label that will not compress does not merely truncate
    /// badly — it makes the content wider than the frame, AppKit breaks a pin, and every
    /// control below runs off the right edge. Caught in a render; asserted here so it stays fixed.
    @MainActor
    func testNoSheetOutgrowsItsWidthUnderAWideMonospaceTheme() {
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.cyberpunk)

        for (label, controller) in [
            ("inspector", makeInspectorSheet() as NSViewController),
            ("report a problem", ReportProblemViewController())
        ] {
            let host = laidOut(controller)
            let widest = widestSubview(under: host, in: host)

            XCTAssertLessThanOrEqual(
                widest.rounded(),
                host.bounds.width,
                "\(label) draws \(widest - host.bounds.width) points past its own edge"
            )
        }
    }

    // MARK: - Rendered

    @MainActor
    func testRendersBothSheetsLightDarkAndUnderTwoThemes() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer { AppThemePalette.set(.system) }

        var written = 0
        for (suffix, style) in [
            ("system", nil),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist)
        ] as [(String, AppTheme?)] {
            AppThemePalette.set(style ?? .system)
            for name: NSAppearance.Name in [.aqua, .darkAqua] {
                let mode = name == .aqua ? "light" : "dark"
                for (label, image) in [
                    ("inspector-report", sheetImage(appearance: name) { self.makeInspectorSheet() }),
                    ("report-problem", sheetImage(appearance: name) { ReportProblemViewController() })
                ] {
                    guard let image else {
                        XCTFail("no image for \(label) \(suffix) \(mode)")
                        continue
                    }
                    try image.write(
                        to: Render.directory
                            .appendingPathComponent("\(label)-\(suffix)-\(mode).png")
                    )
                    written += 1
                }
            }
        }
        XCTAssertEqual(written, 12)
    }

    // MARK: - Helpers

    /// Fixed text rather than a live `InspectorEnvironment.capture`: the renders are compared
    /// between runs, and a block carrying this machine's window size and theme would differ in
    /// every one of them.
    @MainActor
    private func makeInspectorSheet(
        screenshotURL: URL? = nil
    ) -> InspectorReportViewController {
        InspectorReportViewController(
            heading: InspectorStrings.elementHeading,
            subheading: "SidebarRowView",
            markdown: """
            - Element: SidebarRowView
            - Frame: {{12, 40}, {248, 28}}
            - Window screenshot, target outlined: /tmp/threading-inspect-20260731-160412.png
            """,
            environment: """
            - Threading 1.0 (1) · Version 15.5 (Build 24F74)
            - App theme: System, adaptive, drawing dark
            - Window chrome: the native frame
            - Window: 1440×900 at 2×
            - Text size: standard
            """,
            screenshot: swatch(),
            screenshotURL: screenshotURL
        )
    }

    @MainActor
    private func swatch() -> NSImage {
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        image.unlockFocus()
        return image
    }

    @MainActor
    private func laidOut(_ controller: NSViewController) -> NSView {
        let size = controller.view.frame.size
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: host.topAnchor),
            child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func sheetImage(
        appearance name: NSAppearance.Name,
        make: @escaping () -> NSViewController
    ) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render = {
            let controller = make()
            let host = self.laidOut(controller)
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    /// The furthest right edge anything in the tree reaches, in the host's coordinates.
    @MainActor
    private func widestSubview(under root: NSView, in host: NSView) -> CGFloat {
        var widest = root.convert(root.bounds, to: host).maxX
        for child in root.subviews {
            widest = max(widest, widestSubview(under: child, in: host))
        }
        return widest
    }

    @MainActor
    private func view(withIdentifier identifier: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = view(withIdentifier: identifier, under: child) { return found }
        }
        return nil
    }

    @MainActor
    private func firstSubview<View: NSView>(of type: View.Type, under root: NSView) -> View? {
        if let match = root as? View { return match }
        for child in root.subviews {
            if let match = firstSubview(of: type, under: child) { return match }
        }
        return nil
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
