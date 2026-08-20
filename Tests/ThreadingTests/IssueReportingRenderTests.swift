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
        let pendingURL = directory
            .appendingPathComponent("Pending", isDirectory: true)
            .appendingPathComponent("\(submission.id).json")
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

        // Delivery empties the *queue*, not the archive: what the author reads afterwards is the
        // record, and the receipt is filed beside it.
        let record = directory
            .appendingPathComponent("Outbox", isDirectory: true)
            .appendingPathComponent(submission.id, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: record.appendingPathComponent("receipt.json").path
            ),
            "a delivered report kept no receipt"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: record.appendingPathComponent("submission.json").path
            ),
            "the package that was sent was deleted rather than filed with its record"
        )
    }

    /// A build that never stated an intake has nowhere to send to, and says so instead of
    /// promising a retry. This is the everyday case on a developer's machine, and it shipped the
    /// other way round: two reports sat on disk for two days while the sheet said they were queued
    /// for a service that does not exist.
    func testMacOutboxSavesWithoutSendingWhenNoEndpointIsConfigured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-report-unconfigured-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let attempted = IssueReportRequestCapture()
        let outbox = MacIssueReportOutbox(
            directory: directory,
            environment: [:],
            infoDictionary: nil,
            transport: { request in
                await attempted.record(request)
                throw URLError(.badURL)
            }
        )

        let configured = await outbox.isDeliveryConfigured
        XCTAssertFalse(configured, "an unstated endpoint is not a configured one")

        let captureURL = directory.appendingPathComponent("capture.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: captureURL)

        let saved = try await outbox.save(
            MacIssueReportRecord(
                id: UUID().uuidString.lowercased(),
                markdown: "# A hover that never settles\n\nfile:///tmp/shot.png\n",
                screenshotURL: captureURL
            )
        )

        XCTAssertEqual(saved, 1, "the record was not counted")
        let attemptedRequest = await attempted.request
        XCTAssertNil(attemptedRequest, "an unconfigured build tried to post anyway")

        let records = directory.appendingPathComponent("Outbox", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(
            at: records,
            includingPropertiesForKeys: nil
        )
        let folder = try XCTUnwrap(folders.first, "no record was written")
        let markdown = try String(
            contentsOf: folder.appendingPathComponent("report.md"),
            encoding: .utf8
        )
        XCTAssertTrue(
            markdown.contains("file:///tmp/shot.png"),
            "the local record stripped the capture's path, which is the one thing an agent "
                + "standing on this machine can act on"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("screenshot.png").path
            ),
            "the capture was not copied beside its report, so it is lost when the temporary "
                + "file is swept"
        )
    }

    /// The first shape of this directory was one loose `<id>.json` per undelivered report. Those
    /// are real reports somebody filed, so they become records rather than being left behind.
    func testMacOutboxMigratesLooseReportsIntoRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-report-migration-\(UUID().uuidString)", isDirectory: true)
        let records = directory.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let submission = makeSubmission()
        try JSONEncoder().encode(submission).write(
            to: records.appendingPathComponent("\(submission.id).json")
        )

        let outbox = MacIssueReportOutbox(
            directory: directory,
            environment: [:],
            infoDictionary: nil,
            transport: { _ in throw URLError(.badURL) }
        )
        _ = try await outbox.save(
            MacIssueReportRecord(id: UUID().uuidString.lowercased(), markdown: "# New\n", screenshotURL: nil)
        )

        let migrated = records.appendingPathComponent(submission.id, isDirectory: true)
        let markdown = try String(
            contentsOf: migrated.appendingPathComponent("report.md"),
            encoding: .utf8
        )
        XCTAssertTrue(
            markdown.contains(submission.description),
            "the migrated record lost what the report said"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: migrated.appendingPathComponent("submission.json").path
            ),
            "the original package was dropped rather than filed"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: records.appendingPathComponent("\(submission.id).json").path
            ),
            "the loose file was left beside the folder that replaced it"
        )
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
        let pendingURL = directory
            .appendingPathComponent("Pending", isDirectory: true)
            .appendingPathComponent("\(submission.id).json")
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

    // MARK: - The sheet's one action

    /// What the memory names may stop being on offer: Send to Chat is a Debug build's action, and
    /// a Release build must not come up offering a press that does nothing.
    func testTheRememberedActionIsReResolvedAgainstWhatIsAvailable() {
        XCTAssertEqual(
            DeveloperReportAction.resolvePreferred(storedID: "copy", among: [.send, .copy]),
            .copy
        )
        XCTAssertEqual(
            DeveloperReportAction.resolvePreferred(storedID: "chat", among: [.send, .copy]),
            .send,
            "a remembered Chat survived into a build that has no chat to send to"
        )
        XCTAssertEqual(
            DeveloperReportAction.resolvePreferred(storedID: nil, among: [.send, .copy]),
            .send,
            "the first action is the one a sheet opens on"
        )
        XCTAssertEqual(
            DeveloperReportAction.resolvePreferred(storedID: "nonsense", among: [.send, .copy]),
            .send
        )
    }

    /// The press is named after what it will do, and what it will do depends on whether this
    /// build states an intake. Naming it Send to Developer either way is the promise that had two
    /// reports sitting on disk for two days.
    func testTheSendActionIsNamedAfterWhereItActuallyGoes() {
        XCTAssertEqual(
            DeveloperReportAction.send.title(deliversToService: true),
            L10n.string("Send to Developer")
        )
        XCTAssertEqual(
            DeveloperReportAction.send.title(deliversToService: false),
            L10n.string("Send to Outbox")
        )
        XCTAssertEqual(
            DeveloperReportAction.copy.title(deliversToService: false),
            L10n.string("Copy Report"),
            "only the send moves — the other two do the same thing either way"
        )
    }

    /// Pressing takes the remembered action, and taking one remembers it. The control owns which
    /// action is offered; the sheet owns what each one does.
    @MainActor
    func testThePressTakesTheRememberedActionAndRemembersWhatWasTaken() {
        PreferenceStore.shared.set("copy", forKey: DeveloperReportDefaults.lastActionKey)
        defer { PreferenceStore.shared.removeObject(forKey: DeveloperReportDefaults.lastActionKey) }

        var taken: [DeveloperReportAction] = []
        let control = DeveloperReportSubmitControl(available: [.send, .copy])
        control.onPerform = { taken.append($0) }

        XCTAssertEqual(control.action, .copy)
        XCTAssertEqual(control.press.title, L10n.string("Copy Report"))

        XCTAssertTrue(control.press.accessibilityPerformPress())
        XCTAssertEqual(taken, [.copy])
        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: DeveloperReportDefaults.lastActionKey),
            "copy"
        )
    }

    /// A sheet with one action offers no chevron, for the reason the attachments pane hides its
    /// scope band: a control that is present whatever it would do teaches nothing.
    @MainActor
    func testASingleActionDrawsNoChevron() {
        let one = DeveloperReportSubmitControl(available: [.send])
        XCTAssertNil(
            one.subviews.first as? SplitButtonView,
            "a lone action was welded to a chevron with nothing behind it"
        )

        let several = DeveloperReportSubmitControl(available: [.send, .copy])
        XCTAssertNotNil(several.subviews.first as? SplitButtonView)
    }

    // MARK: - A picture taken outside Threading

    func testOnlyAnImageOpensTheReportSheet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-screenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = directory.appendingPathComponent("shot.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 12,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)

        let text = directory.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: text)

        XCTAssertTrue(DroppedScreenshotReport.isReportable(png))
        XCTAssertFalse(DroppedScreenshotReport.isReportable(text))
        XCTAssertFalse(
            DroppedScreenshotReport.isReportable(directory),
            "a folder keeps its other meaning on the app icon: it becomes a project"
        )

        // Pixels, not points: a Retina screenshot is half its own resolution when asked politely,
        // and half is the number that makes an agent measuring the PNG disagree with the report.
        let image = try XCTUnwrap(NSImage(contentsOf: png))
        let markdown = DroppedScreenshotReport.markdown(for: png, image: image)
        XCTAssertTrue(markdown.contains("12×8 pixels"), markdown)
        XCTAssertTrue(markdown.contains(png.path))
    }

    /// The dropped capture's path is local evidence, exactly like the window capture's, so it is
    /// stripped from what may be sent and kept in what is written here.
    @MainActor
    func testADroppedCapturesPathStaysOnThisMachine() throws {
        let url = URL(fileURLWithPath: "/tmp/threading-hover-20260818.png")
        let sheet = InspectorReportViewController(
            heading: "Screenshot Report",
            subheading: url.lastPathComponent,
            markdown: "## Screenshot report\n- Image: 100×50 pixels\n"
                + "- Dropped screenshot, taken outside Threading: \(url.path)",
            environment: "Threading 1.0 (1)",
            screenshot: nil,
            screenshotURL: url
        )
        _ = sheet.view

        let draft = sheet.reportDraft()
        XCTAssertFalse(
            draft.details.contains(url.path),
            "the capture's path was about to be sent to an intake service"
        )
        XCTAssertTrue(draft.details.contains("100×50 pixels"), "the reviewable facts were stripped too")
        XCTAssertTrue(
            try XCTUnwrap(draft.local).details.contains(url.path),
            "the local record lost the one form of the picture an agent can open"
        )
    }

    /// The strip beside the traffic lights takes one image and nothing else.
    ///
    /// Three refusals matter as much as the acceptance, because this target cannot be seen: it
    /// must not claim a drag that belongs to the content under it, must not claim a file it
    /// cannot open, and must not claim anything at all while nothing is listening.
    @MainActor
    func testTheTitlebarStripTakesOneDroppedImageAndRefusesTheRest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlebar-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = directory.appendingPathComponent("shot.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: notes)

        let window = TitlebarActionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Match the shipping shell. The screenshot destination is specifically the native,
        // transparent strip floating over a full-size root view; a default opaque test titlebar
        // follows a different AppKit layout path once feedback is mounted into that root.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        let strip = NSPoint(x: 60, y: window.frame.height - 2)
        let content = NSPoint(x: 60, y: 20)
        XCTAssertFalse(
            window.isInTitlebarStrip(content),
            "the shipping fixture began without content geometry: \(window.contentLayoutRect)"
        )

        // Nothing listening: the window must not take a file it has nowhere to put.
        XCTAssertEqual(drag(png, to: strip, on: window), [])

        var dropped: [URL] = []
        window.onScreenshotDropped = { dropped.append($0) }

        XCTAssertEqual(drag(png, to: strip, on: window), .copy)
        XCTAssertTrue(
            window.isScreenshotDropIndicatorPresented,
            "the invisible strip accepted the screenshot without showing where it would land"
        )
        XCTAssertFalse(
            window.isInTitlebarStrip(content),
            "feedback reclassified a content point after AppKit restated its layout origin: "
                + "\(window.contentLayoutRect)"
        )
        XCTAssertEqual(
            drag(png, to: content, on: window), [],
            "the strip claimed a drop over the content, where a pane may have its own destination"
        )
        XCTAssertFalse(
            window.isScreenshotDropIndicatorPresented,
            "the titlebar still looked ready after the drag moved into content"
        )
        XCTAssertEqual(
            drag(notes, to: strip, on: window), [],
            "the strip claimed a file the report sheet cannot open"
        )
        XCTAssertEqual(
            drag([png, notes], to: strip, on: window), [],
            "a multi-file drag has no single report to open"
        )

        XCTAssertEqual(drag(png, to: strip, on: window), .copy)
        window.draggingExited(nil)
        XCTAssertFalse(window.isScreenshotDropIndicatorPresented)

        XCTAssertEqual(drag(png, to: strip, on: window), .copy)
        XCTAssertTrue(window.performDragOperation(draggingInfo([png], at: strip, on: window)))
        XCTAssertEqual(dropped, [png])
        XCTAssertFalse(
            window.isScreenshotDropIndicatorPresented,
            "the accepted target stayed highlighted after the report sheet took the image"
        )
    }

    @MainActor
    private func drag(
        _ urls: [URL],
        to point: NSPoint,
        on window: TitlebarActionWindow
    ) -> NSDragOperation {
        window.draggingEntered(draggingInfo(urls, at: point, on: window))
    }

    @MainActor
    private func drag(
        _ url: URL,
        to point: NSPoint,
        on window: TitlebarActionWindow
    ) -> NSDragOperation {
        drag([url], to: point, on: window)
    }

    @MainActor
    private func draggingInfo(
        _ urls: [URL],
        at point: NSPoint,
        on window: NSWindow
    ) -> any NSDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("threading.test.drag.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return StubDraggingInfo(
            pasteboard: pasteboard,
            location: point,
            destinationWindow: window
        )
    }

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

/// The parts of a drag this window actually reads: where it is, what is on the pasteboard, and
/// which window it is over. Everything else is what `NSDraggingInfo` requires rather than what is
/// under test, and is answered with the least interesting legal value.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {

    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, location: NSPoint, destinationWindow: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = destinationWindow
    }

    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImage: NSImage? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
