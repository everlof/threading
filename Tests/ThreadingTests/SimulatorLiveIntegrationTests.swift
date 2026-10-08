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

    private static let consecutiveFrameCount = 3

    private func integrationDeviceID() throws -> SimulatorDeviceID {
        guard let rawDeviceID = ProcessInfo.processInfo.environment[
            "THREADING_SIMULATOR_INTEGRATION_UDID"
        ], !rawDeviceID.isEmpty else {
            throw XCTSkip(
                "Set THREADING_SIMULATOR_INTEGRATION_UDID to an already-booted iOS Simulator."
            )
        }
        return try XCTUnwrap(SimulatorDeviceID(rawDeviceID))
    }

    /// Read-only: the stream must keep moving after its first picture. The shipped H.264
    /// encoder once held the second frame for lookahead, which left every helper idle and the
    /// pane frozen under a live label while the first-frame checks all passed.
    /// Explicit two-device lane. The first device must already be booted; preparing the second
    /// returns a boot-ownership lease, which is released on both success and failure.
    func testTwoExactDevicesDeliverIndependentLiveFrames() async throws {
        let firstID = try integrationDeviceID()
        guard let rawSecond = ProcessInfo.processInfo.environment["THREADING_SIMULATOR_INTEGRATION_SECOND_UDID"],
              let secondID = SimulatorDeviceID(rawSecond), secondID != firstID else {
            throw XCTSkip("Set THREADING_SIMULATOR_INTEGRATION_SECOND_UDID to another installed device.")
        }
        let control = SimctlSimulatorControl()
        let secondLease = try await control.prepare(deviceID: secondID)
        let coordinator = SimulatorLiveStreamCoordinator(maximumStreams: 2)
        do {
            let first = try await coordinator.openStream(for: firstID)
            defer { first.stop() }
            let second = try await coordinator.openStream(for: secondID)
            defer { second.stop() }
            first.setVisible(true)
            second.setVisible(true)
            let counts = try await withThrowingTaskGroup(of: Int.self) { group in
                for session in [first, second] {
                    group.addTask {
                        var count = 0
                        for await event in session.events {
                            switch event {
                            case .frame(let frame):
                                guard frame.image.width > 0, frame.image.height > 0 else { throw IntegrationError.endedBeforeFrame }
                                count += 1
                                if count == Self.consecutiveFrameCount { return count }
                            case .failed(let detail): throw IntegrationError.streamFailed(detail)
                            case .ended, .geometryChanged: throw IntegrationError.endedBeforeFrame
                            case .ready, .statistics: continue
                            }
                        }
                        throw IntegrationError.endedBeforeFrame
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    throw IntegrationError.timedOut
                }
                defer { group.cancelAll() }
                var counts: [Int] = []
                for _ in 0..<2 { counts.append(try await group.next()!) }
                return counts
            }
            XCTAssertEqual(counts, [Self.consecutiveFrameCount, Self.consecutiveFrameCount])
        } catch {
            try? await control.release(secondLease)
            throw error
        }
        try await control.release(secondLease)
    }

    func testDirectStreamDeliversConsecutiveFrames() async throws {
        let deviceID = try integrationDeviceID()
        let coordinator = SimulatorLiveStreamCoordinator(maximumStreams: 1)
        let session = try await coordinator.openStream(for: deviceID)
        defer {
            session.setVisible(false)
            session.stop()
        }
        session.setVisible(true)

        let sequences = try await withThrowingTaskGroup(of: [UInt64].self) { group in
            group.addTask {
                var observed: [UInt64] = []
                for await event in session.events {
                    switch event {
                    case .ready, .statistics, .geometryChanged:
                        continue
                    case .frame(let frame):
                        observed.append(frame.sequence)
                        if observed.count >= Self.consecutiveFrameCount { return observed }
                    case .failed(let detail):
                        throw IntegrationError.streamFailed(detail)
                    case .ended:
                        throw IntegrationError.endedBeforeFrame
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

        XCTAssertEqual(sequences.count, Self.consecutiveFrameCount)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count, "Every frame carries a new sequence.")
    }

    func testDirectFramebufferDecodeAndHumanInputEnvelope() async throws {
        let deviceID = try integrationDeviceID()
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
                    case .statistics, .geometryChanged:
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

    /// The pane maps a wheel tick to this existing helper verb. Run with a scrollable app in the
    /// foreground and compare simulator screenshots before and after to verify guest movement.
    func testWheelTouchDragIsAcceptedByBootedSimulator() async throws {
        let deviceID = try integrationDeviceID()
        let coordinator = SimulatorLiveStreamCoordinator(maximumStreams: 1)
        let session = try await coordinator.openStream(for: deviceID)
        defer { session.stop() }
        try await session.sendInput(.drag(
            fromX: 0.5, fromY: 0.55,
            toX: 0.5, toY: 0.37,
            durationMilliseconds: 140
        ))
    }
}
