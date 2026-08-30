import ThreadingSimulatorKit
import XCTest
@testable import Threading

/// Opt-in coverage for the Xcode-private compatibility boundary.
///
/// Unit fakes prove deterministic policy. This test is intentionally environment-gated because
/// it requires one already-booted iOS device and the active Xcode's private frameworks. Running
/// it from the hosted test bundle also proves the shipped app/helper signing relationship.
final class SimulatorLiveIntegrationTests: XCTestCase {
    private struct Evidence: Sendable {
        let codec: SimulatorBridgeCodec
        let capabilities: SimulatorBridgeCapabilities
        let width: Int
        let height: Int
    }

    private enum IntegrationError: LocalizedError {
        case streamFailed(String)
        case endedBeforeFrame
        case timedOut

        var errorDescription: String? {
            switch self {
            case .streamFailed(let detail): return detail
            case .endedBeforeFrame: return "The direct Simulator stream ended before a frame."
            case .timedOut: return "The direct Simulator stream did not produce a frame in time."
            }
        }
    }

    func testDirectFramebufferDecodeAndHumanInputEnvelope() async throws {
        guard let rawDeviceID = ProcessInfo.processInfo.environment[
            "THREADING_SIMULATOR_INTEGRATION_UDID"
        ], !rawDeviceID.isEmpty else {
            throw XCTSkip(
                "Set THREADING_SIMULATOR_INTEGRATION_UDID to an already-booted iOS Simulator."
            )
        }
        let deviceID = try XCTUnwrap(SimulatorDeviceID(rawDeviceID))
        let coordinator = SimulatorLiveStreamCoordinator(maximumStreams: 1)
        let session = try await coordinator.openStream(for: deviceID)
        defer {
            session.setVisible(false)
            session.stop()
        }
        session.setVisible(true)

        let evidence = try await withThrowingTaskGroup(of: Evidence.self) { group in
            group.addTask {
                var codec: SimulatorBridgeCodec?
                var capabilities: SimulatorBridgeCapabilities?
                for await event in session.events {
                    switch event {
                    case .ready(let backend, let readyCapabilities, _, _):
                        guard case .direct(let readyCodec) = backend else { continue }
                        codec = readyCodec
                        capabilities = readyCapabilities
                    case .frame(let frame):
                        guard let codec, let capabilities else { continue }
                        return Evidence(
                            codec: codec,
                            capabilities: capabilities,
                            width: frame.image.width,
                            height: frame.image.height
                        )
                    case .failed(let detail):
                        throw IntegrationError.streamFailed(detail)
                    case .ended:
                        throw IntegrationError.endedBeforeFrame
                    case .statistics:
                        continue
                    }
                }
                throw IntegrationError.endedBeforeFrame
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw IntegrationError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }

        XCTAssertTrue([SimulatorBridgeCodec.h264, .jpeg].contains(evidence.codec))
        XCTAssertGreaterThan(evidence.width, 0)
        XCTAssertGreaterThan(evidence.height, 0)
        XCTAssertTrue(evidence.capabilities.supportsButtons)
        XCTAssertTrue(evidence.capabilities.supportsTouch)
        try await session.sendInput(.button(.home))
        try await session.sendInput(.tap(x: 0.5, y: 0.5))
    }
}
