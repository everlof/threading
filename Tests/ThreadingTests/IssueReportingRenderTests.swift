import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

private actor IssueReportRequestCapture {
    private(set) var request: URLRequest?
    func record(_ request: URLRequest) { self.request = request }
}

/// The two sheets that send a private developer report, drawn and driven.
///
/// Rendered because the complaint that produced them was about *size and clarity* — a note box
/// one line tall under a wall of read-only markdown — and no constraint assertion catches that.
/// Driven because both sheets have an outcome path that touches the private intake, and that
/// handoff is injected precisely so a test can watch it without using the network.
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

    // MARK: - Durable private delivery

    func testMacOutboxPostsWithoutAnAppCredentialAndUsesTheUUIDForIdempotency() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-report-outbox-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let submission = makeSubmission()
        let pendingURL = directory.appendingPathComponent("\(submission.id).json")
        let capture = IssueReportRequestCapture()
        let outbox = MacIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "https://reports.example/v1/reports")!,
            transport: { request in
                await capture.record(request)
                let receipt = PublicIssueReportReceiptDTO(
                    reportID: submission.id,
                    reference: "RPT-TEST",
                    wasAlreadyReceived: false
                )
                return (
                    try JSONEncoder().encode(receipt),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        guard case .delivered(let receipt) = try await outbox.enqueueAndDeliver(submission) else {
            return XCTFail("the private intake did not return its receipt")
        }
        XCTAssertEqual(receipt.reference, "RPT-TEST")
        let request = await capture.request
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Idempotency-Key"), submission.id)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                PublicIssueReportSubmissionDTO.self,
                from: XCTUnwrap(request?.httpBody)
            ),
            submission
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func testMacOutboxUsesTheDebugReportIntakeOverride() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-local-report-outbox-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let submission = makeSubmission()
        let capture = IssueReportRequestCapture()
        let outbox = MacIssueReportOutbox(
            directory: directory,
            environment: [
                "THREADING_REPORT_INTAKE_URL": "http://127.0.0.1:8787/v1/reports",
            ],
            transport: { request in
                await capture.record(request)
                return (
                    try JSONEncoder().encode(PublicIssueReportReceiptDTO(
                        reportID: submission.id,
                        reference: "RPT-LOCAL",
                        wasAlreadyReceived: false
                    )),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        _ = try await outbox.enqueueAndDeliver(submission)

        let request = await capture.request
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:8787/v1/reports")
    }

    func testMacOutboxRetainsAnOfflineReportAndFlushesTheSameUUIDLater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-report-retry-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let submission = makeSubmission()
        let pendingURL = directory.appendingPathComponent("\(submission.id).json")
        let offline = MacIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "https://reports.example/v1/reports")!,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )

        guard case .queued = try await offline.enqueueAndDeliver(submission) else {
            return XCTFail("an offline report was not retained")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))

        let capture = IssueReportRequestCapture()
        let online = MacIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "https://reports.example/v1/reports")!,
            transport: { request in
                await capture.record(request)
                return (
                    try JSONEncoder().encode(PublicIssueReportReceiptDTO(
                        reportID: submission.id,
                        reference: "RPT-RETRY",
                        wasAlreadyReceived: true
                    )),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        await online.flush()

        let retriedRequest = await capture.request
        XCTAssertEqual(
            retriedRequest?.value(forHTTPHeaderField: "Idempotency-Key"),
            submission.id
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
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
    func testAReportSendsTheReviewedScreenshotAndShowsItsPrivateReceipt() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        let done = expectation(description: "submitted")
        var capturedDraft: DeveloperIssueReportDraft?
        var capturedScreenshot: NSImage?
        sheet.onSubmitReport = { draft, screenshot in
            capturedDraft = draft
            capturedScreenshot = screenshot
            done.fulfill()
            return .delivered(reference: "RPT-20260812-0042")
        }

        sheet.submitIssue()
        wait(for: [done], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(capturedDraft?.kind, .problem)
        XCTAssertNotNil(capturedScreenshot, "the reviewed capture never reached the intake")
        XCTAssertFalse(
            capturedDraft?.description.contains("/tmp/threading-inspect") == true,
            "a temporary local path escaped into the private report"
        )
        XCTAssertTrue(sheet.statusMessage.contains("RPT-20260812-0042"), sheet.statusMessage)
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

        // The capture is an `AnnotatedImageView` since the sheet grew a marking gesture: a click
        // now drops a pin, and opening the picture full size moved to the *keyboard* half of the
        // control. What this test guards is unchanged — the report's picture opens into the same
        // zoomable inspector every other image in the app opens into.
        let preview = try XCTUnwrap(firstSubview(of: AnnotatedImageView.self, under: host))
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
    func testARefusedReportSaysSoAndKeepsTheSheetOpen() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        var dismissed = false
        sheet.onDone = { dismissed = true }
        let done = expectation(description: "submitted")
        sheet.onSubmitReport = { _, _ in
            done.fulfill()
            return .failed(message: "The private inbox refused the report (500).")
        }

        sheet.submitIssue()
        wait(for: [done], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(sheet.statusMessage, "The private inbox refused the report (500).")
        XCTAssertFalse(dismissed, "a failed submission must not throw the report away")
    }

    @MainActor
    func testTheDraftCarriesTheNoteTheReportAndTheEnvironment() {
        let sheet = makeInspectorSheet()
        let host = laidOut(sheet)
        (view(withIdentifier: InspectorReportIdentifiers.note, under: host) as? PromptView)?
            .stringValue = "Archive button is unclickable"

        let draft = sheet.reportDraft()

        XCTAssertEqual(draft.title, "Archive button is unclickable")
        XCTAssertTrue(draft.description.contains("Archive button is unclickable"))
        XCTAssertTrue(draft.description.contains("- Element: SidebarRowView"))
        XCTAssertTrue(draft.description.contains("Threading"))
        XCTAssertTrue(draft.description.contains("- App theme: System, adaptive, drawing dark"))
        XCTAssertFalse(draft.description.contains("/tmp/threading-inspect"))
        XCTAssertEqual(draft.kind, .problem)
    }

    /// The environment is one block in three places, and the private report is the one that could hold
    /// two: the composer closes every body with an environment under a rule, so a report string
    /// that already carried its own would print the build line twice.
    @MainActor
    func testTheEnvironmentIsStatedOnceInTheReportAndOnceInTheDetails() {
        let sheet = makeInspectorSheet()
        _ = laidOut(sheet)

        let body = sheet.reportDraft().description
        XCTAssertEqual(
            body.components(separatedBy: "Threading 1.0 (1)").count - 1,
            1,
            "the environment landed in the report twice"
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
    func testTheKindAndTypedTitleReachThePrivateDraft() {
        let sheet = ReportProblemViewController()
        let host = laidOut(sheet)

        let title = view(withIdentifier: ReportProblemIdentifiers.title, under: host)
        (title as? ThemedTextField)?.stringValue = "Toolbar corner is cut off"
        let detail = view(withIdentifier: ReportProblemIdentifiers.detail, under: host)
        (detail as? PromptView)?.stringValue = "It loses the rounding at the top right."

        XCTAssertEqual(sheet.reportDraft().title, "Toolbar corner is cut off")
        XCTAssertEqual(sheet.reportDraft().kind, .problem)

        let kind = view(withIdentifier: ReportProblemIdentifiers.kind, under: host)
        (kind as? ThemedSegmentedControl)?.onSelect?(1)
        XCTAssertEqual(
            sheet.reportDraft().kind,
            .improvement,
            "the report lost the kind the user chose"
        )
    }

    @MainActor
    func testAnEmptyReportIsRefusedBeforeItReachesTheDeveloperInbox() {
        let sheet = ReportProblemViewController()
        _ = laidOut(sheet)

        var submissions = 0
        sheet.onSubmitReport = { _ in
            submissions += 1
            return .failed(message: "never")
        }

        sheet.submitIssue()

        XCTAssertEqual(submissions, 0, "an empty report was sent to a person")
        XCTAssertFalse(sheet.statusMessage.isEmpty, "and nothing said why")
    }

    @MainActor
    func testTheEnvironmentIsNamedOnScreenBeforeAnythingIsSent() {
        let sheet = ReportProblemViewController()
        let host = laidOut(sheet)

        let note = view(withIdentifier: ReportProblemIdentifiers.environment, under: host)
        let shown = (note as? NSTextField)?.stringValue ?? ""

        XCTAssertTrue(shown.contains("Threading"), shown)
        XCTAssertFalse(shown.isEmpty, "what travels with the report is not stated")
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
                    ("issue-report-inspector", sheetImage(appearance: name) { self.makeInspectorSheet() }),
                    // The marked-up state drawn as well as the empty one, because the pins, the
                    // rail beside them and the lit pair are the whole of this screen's new
                    // behaviour and none of it appears in the picture above.
                    ("issue-report-annotated", sheetImage(appearance: name) {
                        self.makeAnnotatedInspectorSheet()
                    }),
                    ("issue-report-problem", sheetImage(appearance: name) { ReportProblemViewController() })
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
        // Three sheets — empty inspector, marked-up inspector, Report a Problem — in two
        // appearances under three themes.
        XCTAssertEqual(written, 18)
    }

    // MARK: - Helpers

    private func makeSubmission() -> PublicIssueReportSubmissionDTO {
        let journal = RemoteDiagnosticJournal(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "mac-report-fixture-\(UUID().uuidString)",
                isDirectory: true
            ),
            source: .macOSHost
        )
        let report = journal.supportReport(
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "macOS 26.5",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported
        )
        return PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "manual",
            description: "The composer stopped responding.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report)
        )
    }

    /// Fixed text rather than a live `InspectorEnvironment.capture`: the renders are compared
    /// between runs, and a block carrying this machine's window size and theme would differ in
    /// every one of them.
    /// A stated window size rather than none, so the renders show the sheet somebody actually
    /// gets. Left nil, `sheetSize(inWindowOf:)` falls back to its floor and every review picture
    /// is of the smallest display in the world — which is how a capture that is legible in the
    /// app looked unreadable in the only place anybody was checking it.
    @MainActor
    private func makeInspectorSheet(
        screenshotURL: URL? = nil,
        availableSize: NSSize? = NSSize(width: 1440, height: 900)
    ) -> InspectorReportViewController {
        let sheet = InspectorReportViewController(
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
        sheet.availableSize = availableSize
        return sheet
    }

    /// The same sheet with three marks on it, the second one lit as it is while its field holds
    /// the caret. Fixed points rather than synthesized clicks: this is a picture to look at, and
    /// it has to be the same picture on every run.
    @MainActor
    private func makeAnnotatedInspectorSheet() -> InspectorReportViewController {
        let sheet = makeInspectorSheet()
        sheet.loadView()
        sheet.applyAnnotations([
            ImageAnnotation(point: CGPoint(x: 0.22, y: 0.18), note: "This padding is tight"),
            ImageAnnotation(point: CGPoint(x: 0.64, y: 0.42), note: "5h and 2% run together"),
            ImageAnnotation(point: CGPoint(x: 0.41, y: 0.79), note: "")
        ])
        return sheet
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
