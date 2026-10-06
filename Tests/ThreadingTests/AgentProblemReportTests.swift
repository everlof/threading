import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

private actor AgentReportRequestCapture {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private actor AgentReportDeliveryGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

@MainActor
final class AgentProblemReportTests: XCTestCase {
    private var directory: URL!
    private let environment = "Threading 1.2 (42) · macOS 26.5"
    private let endpoint = URL(string: "https://reports.example/v1/reports")!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-report-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testReportDeliversThroughThePrivateOutboxWithStructuredEvidenceAndSafeDiagnostics() async throws {
        let capture = AgentReportRequestCapture()
        let outbox = configuredOutbox(capture: capture)
        let service = makeService(outbox)
        let session = SessionID()
        let receipt = try await service.report(arguments(), for: session).get()
        XCTAssertEqual(receipt.status, .delivered)
        XCTAssertEqual(receipt.reference, "RPT-AGENT")
        XCTAssertFalse(receipt.duplicate)
        let requests = await capture.requests
        let request = try XCTUnwrap(requests.first)
        let submission = try JSONDecoder().decode(PublicIssueReportSubmissionDTO.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), receipt.reportID)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(submission.trigger, .manual)
        XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))
        for content in ["Reported by an agent", "Reproduction steps", "browser_snapshot", "Expected behavior", "Actual behavior", "Evidence", environment] {
            XCTAssertTrue(submission.description.contains(content), content)
        }
        XCTAssertFalse(submission.description.contains(session.uuidString))
        XCTAssertFalse(submission.description.contains(directory.path))
        XCTAssertEqual(submission.diagnostics.appBuild, "42")
        XCTAssertEqual(submission.diagnostics.records, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.recordPath) + "/receipt.json"))
    }

    func testIdenticalReportAfterServiceRestartReusesItsDurableReceipt() async throws {
        let capture = AgentReportRequestCapture()
        let outbox = configuredOutbox(capture: capture)
        let session = SessionID()
        let first = try await makeService(outbox).report(arguments(), for: session).get()
        let second = try await makeService(configuredOutbox(capture: capture)).report(arguments(), for: session).get()
        XCTAssertEqual(second.reportID, first.reportID)
        XCTAssertEqual(second.reference, first.reference)
        XCTAssertTrue(second.duplicate)
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try recordCount(), 1)
    }

    func testUnconfiguredBuildSavesWithoutCollectingDiagnosticsOrSending() async throws {
        let capture = AgentReportRequestCapture()
        let outbox = MacIssueReportOutbox(directory: directory, environment: [:], infoDictionary: nil, transport: { request in
            await capture.record(request)
            throw URLError(.badURL)
        })
        let submitter = MacIssueReportSubmitter(diagnosticsProvider: { XCTFail("unconfigured report collected diagnostics"); throw MacIssueReportError.invalidPackage }, outbox: outbox)
        let service = AgentProblemReportService(submitter: submitter, environment: environment)
        let receipt = try await service.report(arguments(), for: SessionID()).get()
        XCTAssertEqual(receipt.status, .saved)
        XCTAssertNil(receipt.reference)
        XCTAssertNotNil(receipt.recordPath)
        let requests = await capture.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try recordCount(), 1)
    }

    func testLostResponseQueuesOnePackageAndRetryDoesNotPostAgain() async throws {
        let capture = AgentReportRequestCapture()
        let outbox = MacIssueReportOutbox(directory: directory, endpoint: endpoint, transport: { request in
            await capture.record(request)
            throw URLError(.networkConnectionLost)
        })
        let service = makeService(outbox)
        let session = SessionID()
        let first = try await service.report(arguments(), for: session).get()
        let retry = try await service.report(arguments(), for: session).get()
        XCTAssertEqual(first.status, .queued)
        XCTAssertEqual(retry.status, .queued)
        XCTAssertTrue(retry.duplicate)
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Pending/\(first.reportID).json").path))
        let delivering = configuredOutbox(capture: capture)
        await delivering.flush()
        let delivered = try await makeService(delivering).report(arguments(), for: session).get()
        XCTAssertEqual(delivered.status, .delivered)
        XCTAssertTrue(delivered.duplicate)
        XCTAssertEqual(delivered.reportID, first.reportID)
    }

    func testRejectedDeliveryKeepsTheRecordAndDoesNotClaimSuccess() async throws {
        let outbox = MacIssueReportOutbox(directory: directory, endpoint: endpoint, transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        let receipt = try await makeService(outbox).report(arguments(), for: SessionID()).get()
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertNil(receipt.reference)
        XCTAssertNotNil(receipt.recordPath)
        XCTAssertTrue(receipt.message.contains("remains saved locally"))
        XCTAssertEqual(try recordCount(), 1)
    }

    func testFailedRecordSaveDoesNotInventARecordPath() async throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocked)
        let outbox = MacIssueReportOutbox(directory: blocked, environment: [:], infoDictionary: nil)
        let receipt = try await makeService(outbox).report(arguments(), for: SessionID()).get()
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertNil(receipt.recordPath)
        XCTAssertNil(receipt.reference)
        XCTAssertTrue(receipt.message.contains("could not save"))
    }

    func testInvalidAndOversizedInputsNeverReachTheOutbox() async throws {
        let service = makeService(unconfiguredOutbox())
        let session = SessionID()
        var invalid = arguments()
        invalid.description = " \n "
        assertRefusal(await service.report(invalid, for: session), contains: "nonempty")
        invalid = arguments(); invalid.title = String(repeating: "a", count: 81)
        assertRefusal(await service.report(invalid, for: session), contains: "80 characters")
        invalid = arguments(); invalid.evidence = String(repeating: "å", count: 6_000)
        assertRefusal(await service.report(invalid, for: session), contains: "10240 UTF-8")
        invalid = arguments(); invalid.description = String(repeating: "a", count: 10_200)
        invalid.reproductionSteps = nil; invalid.expectedBehavior = nil; invalid.actualBehavior = nil; invalid.evidence = nil
        assertRefusal(await service.report(invalid, for: session), contains: "10240 UTF-8")
        invalid = arguments(); invalid.imagePaths = Array(repeating: "/tmp/image.png", count: 5)
        assertRefusal(await service.report(invalid, for: session), contains: "four images")
        invalid.imagePaths = ["relative.png"]
        assertRefusal(await service.report(invalid, for: session), contains: "absolute")
        invalid.imagePaths = ["/tmp/image.png"]
        assertRefusal(await service.report(invalid, for: session, isRemote: true), contains: "remote-host")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Outbox").path))
    }

    func testImagesAreFrozenKeptInCustodyAndDeduplicatedByBytes() async throws {
        let capture = AgentReportRequestCapture()
        let source = directory.appendingPathComponent("source.png")
        let otherPath = directory.appendingPathComponent("same.png")
        let image = try png()
        try image.write(to: source); try image.write(to: otherPath)
        let outbox = configuredOutbox(capture: capture)
        let service = makeService(outbox)
        let session = SessionID()
        var request = arguments(); request.imagePaths = [source.path]
        let first = try await service.report(request, for: session).get()
        request.imagePaths = [otherPath.path]
        let duplicate = try await service.report(request, for: session).get()
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(duplicate.reportID, first.reportID)
        try FileManager.default.removeItem(at: source)
        let record = URL(fileURLWithPath: try XCTUnwrap(first.recordPath))
        let attachment = record.appendingPathComponent("attachment-01.png")
        XCTAssertEqual(try Data(contentsOf: attachment), image)
        let markdown = try String(contentsOf: record.appendingPathComponent("report.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains(attachment.path))
        XCTAssertFalse(markdown.contains("threading-agent-report-"))
        let requests = await capture.requests
        let submission = try JSONDecoder().decode(PublicIssueReportSubmissionDTO.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(submission.imagePreviews?.count, 1)
        XCTAssertFalse(submission.description.contains(source.path))
        XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))
        try png(red: 255).write(to: otherPath)
        let changed = try await service.report(request, for: session).get()
        XCTAssertFalse(changed.duplicate)
        XCTAssertNotEqual(changed.reportID, first.reportID)
    }

    func testNonImagesAndOversizedFilesAreRefusedBeforeFiling() async throws {
        let service = makeService(unconfiguredOutbox())
        let source = directory.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: source)
        var request = arguments(); request.imagePaths = [source.path]
        assertRefusal(await service.report(request, for: SessionID()), contains: "PNG/JPEG")
        try Data(count: AgentProblemReportPolicy.maximumImageBytes + 1).write(to: source)
        assertRefusal(await service.report(request, for: SessionID()), contains: "8 MiB")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Outbox").path))
    }

    func testRateLimitAllowsDuplicateReceiptsAndResetsAfterAnHour() async throws {
        var date = Date()
        let service = makeService(unconfiguredOutbox(), now: { date })
        let session = SessionID()
        for index in 0..<AgentProblemReportPolicy.maximumReportsPerHour {
            var request = arguments(); request.title = "Problem \(index)"
            let receipt = try await service.report(request, for: session).get()
            XCTAssertEqual(receipt.status, .saved)
        }
        var duplicate = arguments(); duplicate.title = "Problem 0"
        let duplicateReceipt = try await service.report(duplicate, for: session).get()
        XCTAssertTrue(duplicateReceipt.duplicate)
        assertRefusal(await service.report(arguments(), for: session), contains: "ten new")
        date = date.addingTimeInterval(AgentProblemReportPolicy.rateWindow)
        let later = try await service.report(arguments(), for: session).get()
        XCTAssertEqual(later.status, .saved)
    }

    func testThousandOverlappingCallsAdmitOnlyOneReport() async throws {
        let gate = AgentReportDeliveryGate()
        let started = expectation(description: "the first report reached transport")
        let capture = AgentReportRequestCapture()
        let outbox = MacIssueReportOutbox(directory: directory, endpoint: endpoint, transport: { request in
            await capture.record(request)
            started.fulfill()
            await gate.wait()
            return try Self.deliveryResponse(request)
        })
        let service = makeService(outbox)
        let first = Task { await service.report(arguments(), for: SessionID()) }
        await fulfillment(of: [started], timeout: 5)
        let rejected = expectation(description: "overlapping calls were refused without awaiting delivery")
        let overlapping = Task {
            for _ in 0..<1_000 {
                assertRefusal(await service.report(arguments(), for: SessionID()), contains: "Another agent report")
            }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 10)
        await gate.release()
        await overlapping.value
        let receipt = try await first.value.get()
        XCTAssertEqual(receipt.status, .delivered)
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try recordCount(), 1)
    }

    private func arguments() -> ReportProblemArguments {
        ReportProblemArguments(title: "Snapshot failed", description: "Threading's browser snapshot returned an error.",
            reproductionSteps: "Call browser_snapshot after navigating.", expectedBehavior: "A snapshot.",
            actualBehavior: "The tool returned unavailable.", evidence: "Error: browser unavailable.")
    }

    private func makeService(_ outbox: MacIssueReportOutbox, now: @escaping () -> Date = Date.init) -> AgentProblemReportService {
        let journal = RemoteDiagnosticJournal(directory: directory.appendingPathComponent("diagnostics"), source: .macOSHost)
        let diagnostics = PublicIssueReportDiagnosticsDTO(bounding: journal.supportReport(
            appVersion: "1.2", appBuild: "42", operatingSystem: "macOS 26.5",
            protocolVersion: RemoteProtocol.current, minimumProtocolVersion: RemoteProtocol.minimumSupported
        ))
        return AgentProblemReportService(submitter: MacIssueReportSubmitter(diagnosticsProvider: { diagnostics }, outbox: outbox), environment: environment, now: now)
    }

    private func configuredOutbox(capture: AgentReportRequestCapture) -> MacIssueReportOutbox {
        MacIssueReportOutbox(directory: directory, endpoint: endpoint, transport: { request in
            await capture.record(request)
            return try Self.deliveryResponse(request)
        })
    }

    private func unconfiguredOutbox() -> MacIssueReportOutbox {
        MacIssueReportOutbox(directory: directory, environment: [:], infoDictionary: nil)
    }

    nonisolated private static func deliveryResponse(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let submission = try JSONDecoder().decode(PublicIssueReportSubmissionDTO.self, from: XCTUnwrap(request.httpBody))
        return (try JSONEncoder().encode(PublicIssueReportReceiptDTO(reportID: submission.id, reference: "RPT-AGENT", wasAlreadyReceived: false)),
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }

    private func recordCount() throws -> Int { try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Outbox"), includingPropertiesForKeys: nil).count }

    private func png(red: UInt8 = 0) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<64 { pixels[index * 4] = red; pixels[index * 4 + 3] = 255 }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func assertRefusal(
        _ result: Result<AgentProblemReportReceipt, AgentProblemReportRefusal>, contains text: String
    ) {
        guard case .failure(let refusal) = result else { return XCTFail("Expected refusal") }
        XCTAssertTrue(refusal.message.contains(text), refusal.message)
    }
}
