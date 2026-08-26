import CoreGraphics
import ThreadingSimulatorKit
import XCTest
@testable import Threading

final class SimulatorCompatibilityProbeTests: XCTestCase {
    func testArgumentsRequireAnExactDeviceAndAbsoluteReportPath() throws {
        XCTAssertEqual(
            SimulatorCompatibilityProbeArguments.resolve(["Threading"]),
            .notRequested
        )
        XCTAssertEqual(
            SimulatorCompatibilityProbeArguments.resolve([
                "Threading",
                "--simulator-compatibility-probe",
                "not-a-device",
                "--simulator-compatibility-report",
                "/tmp/report.json",
            ]),
            .refused("The Simulator compatibility probe requires an exact device UUID.")
        )
        XCTAssertEqual(
            SimulatorCompatibilityProbeArguments.resolve([
                "Threading",
                "--simulator-compatibility-probe",
                simulatorCompatibilityDeviceID.rawValue,
                "--simulator-compatibility-report",
                "report.json",
            ]),
            .refused("The Simulator compatibility report path must be absolute.")
        )

        guard case .requested(let request) = SimulatorCompatibilityProbeArguments.resolve([
            "Threading",
            "--simulator-compatibility-probe",
            simulatorCompatibilityDeviceID.rawValue.lowercased(),
            "--simulator-compatibility-report",
            "/tmp/../tmp/threading-simulator-report.json",
        ]) else {
            return XCTFail("A valid compatibility probe was not accepted.")
        }
        XCTAssertEqual(request.deviceID, simulatorCompatibilityDeviceID)
        XCTAssertEqual(request.reportURL.path, "/tmp/threading-simulator-report.json")
    }

    func testProbeRecordsTheSignedHelperHandshakeAndFirstFrame() async throws {
        let session = SimulatorCompatibilitySessionFake()
        let coordinator = SimulatorCompatibilityCoordinatorFake(session: session)
        let request = SimulatorCompatibilityProbeRequest(
            deviceID: simulatorCompatibilityDeviceID,
            reportURL: URL(fileURLWithPath: "/tmp/unused.json")
        )

        let report = await SimulatorCompatibilityProbe.run(
            request: request,
            bundle: Bundle(for: Self.self),
            coordinator: coordinator,
            timeout: .seconds(1)
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.outcome, "compatible")
        XCTAssertEqual(report.protocolVersion, SimulatorBridgeProtocol.current)
        XCTAssertEqual(report.codec, "h264")
        XCTAssertEqual(report.coreSimulatorVersion, "CoreSimulator-1065")
        XCTAssertEqual(report.simulatorKitVersion, "SimulatorKit-1065")
        XCTAssertEqual(report.frameWidth, 2)
        XCTAssertEqual(report.frameHeight, 3)
        XCTAssertNil(report.failure)
        XCTAssertEqual(session.visibilityChanges, [true, false])
        XCTAssertTrue(session.didStop)
    }

    func testProbeFailureProducesAReportAndWriterRequiresAnExistingParent() async throws {
        let coordinator = SimulatorCompatibilityCoordinatorFake(
            error: SimulatorLiveStreamError.refused(
                .apiUnavailable,
                "This Xcode is outside the supported compatibility range."
            )
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SimulatorCompatibilityProbeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("report.json")
        let request = SimulatorCompatibilityProbeRequest(
            deviceID: simulatorCompatibilityDeviceID,
            reportURL: reportURL
        )

        let report = await SimulatorCompatibilityProbe.run(
            request: request,
            bundle: Bundle(for: Self.self),
            coordinator: coordinator,
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(report.outcome, "incompatible")
        XCTAssertTrue(report.failure?.contains("outside the supported") == true)
        XCTAssertNil(report.frameWidth)

        try SimulatorCompatibilityProbe.write(report, to: reportURL)
        let decoded = try JSONDecoder().decode(
            SimulatorCompatibilityProbeReport.self,
            from: Data(contentsOf: reportURL)
        )
        XCTAssertEqual(decoded, report)

        XCTAssertThrowsError(try SimulatorCompatibilityProbe.write(
            report,
            to: root.appendingPathComponent("missing/report.json")
        ))
    }
}

private let simulatorCompatibilityDeviceID = SimulatorDeviceID(
    "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
)!

private actor SimulatorCompatibilityCoordinatorFake: SimulatorLiveStreamCoordinating {
    private let session: SimulatorCompatibilitySessionFake?
    private let error: SimulatorLiveStreamError?

    init(session: SimulatorCompatibilitySessionFake) {
        self.session = session
        self.error = nil
    }

    init(error: SimulatorLiveStreamError) {
        self.session = nil
        self.error = error
    }

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        if let error { throw error }
        return session!
    }
}

private final class SimulatorCompatibilitySessionFake: SimulatorLiveStreamSession,
    @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>

    private let continuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation
    private let lock = NSLock()
    private var visibility: [Bool] = []
    private var stopped = false

    init() {
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.yield(.ready(
            backend: .direct(codec: .h264),
            capabilities: SimulatorBridgeCapabilities(
                codecs: [.h264, .jpeg],
                supportsTouch: true,
                supportsKeyboard: true,
                supportsButtons: true,
                maximumFramesPerSecond: 60
            ),
            coreSimulatorVersion: "CoreSimulator-1065",
            simulatorKitVersion: "SimulatorKit-1065"
        ))
        continuation.yield(.frame(SimulatorLiveFrame(
            sequence: 1,
            image: Self.makeImage(),
            codec: .h264,
            presentationTimeNanoseconds: 1
        )))
    }

    var visibilityChanges: [Bool] {
        lock.withLock { visibility }
    }

    var didStop: Bool {
        lock.withLock { stopped }
    }

    func setVisible(_ visible: Bool) {
        lock.withLock { visibility.append(visible) }
    }

    func sendInput(_ input: SimulatorBridgeInput) async throws {}

    func stop() {
        lock.withLock { stopped = true }
        continuation.finish()
    }

    private static func makeImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
