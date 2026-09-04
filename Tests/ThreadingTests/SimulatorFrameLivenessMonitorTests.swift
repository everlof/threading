import XCTest
@testable import Threading

final class SimulatorFrameLivenessMonitorTests: XCTestCase {
    private enum Timing {
        static let deadline: DispatchTimeInterval = .milliseconds(60)
        static let frameInterval: TimeInterval = 0.01
        static let feedDuration: TimeInterval = 0.25
        static let stallWait: TimeInterval = 1
        static let quietWait: TimeInterval = 0.2
    }

    private let queue = DispatchQueue(label: "codes.threading.tests.simulator-liveness")

    func testAVisibleStreamWithoutFramesStalls() {
        let stalled = expectation(description: "stall reported")
        let monitor = makeMonitor { stalled.fulfill() }

        queue.sync { monitor.setVisible(true) }

        wait(for: [stalled], timeout: Timing.stallWait)
    }

    func testFramesKeepAVisibleStreamAlive() {
        let stalledWhileFed = expectation(description: "stall while frames flow")
        stalledWhileFed.isInverted = true
        let stalledAfterFeed = expectation(description: "stall once frames stop")
        var feeding = true
        let monitor = makeMonitor {
            if feeding { stalledWhileFed.fulfill() } else { stalledAfterFeed.fulfill() }
        }

        queue.sync { monitor.setVisible(true) }
        let feeder = DispatchSource.makeTimerSource(queue: queue)
        feeder.schedule(deadline: .now(), repeating: Timing.frameInterval)
        feeder.setEventHandler { monitor.frameArrived() }
        feeder.resume()

        wait(for: [stalledWhileFed], timeout: Timing.feedDuration)
        queue.sync {
            feeder.cancel()
            feeding = false
        }
        wait(for: [stalledAfterFeed], timeout: Timing.stallWait)
    }

    func testAHiddenStreamOwesNoFrames() {
        let stalled = expectation(description: "stall while hidden")
        stalled.isInverted = true
        let monitor = makeMonitor { stalled.fulfill() }

        queue.sync {
            monitor.setVisible(true)
            monitor.setVisible(false)
        }

        wait(for: [stalled], timeout: Timing.quietWait)
    }

    func testFramesWhileHiddenDoNotArmTheDeadline() {
        let stalled = expectation(description: "stall after hidden frame")
        stalled.isInverted = true
        let monitor = makeMonitor { stalled.fulfill() }

        queue.sync { monitor.frameArrived() }

        wait(for: [stalled], timeout: Timing.quietWait)
    }

    func testInvalidationCancelsAnArmedDeadline() {
        let stalled = expectation(description: "stall after invalidation")
        stalled.isInverted = true
        let monitor = makeMonitor { stalled.fulfill() }

        queue.sync {
            monitor.setVisible(true)
            monitor.invalidate()
            monitor.setVisible(true)
            monitor.frameArrived()
        }

        wait(for: [stalled], timeout: Timing.quietWait)
    }

    private func makeMonitor(onStall: @escaping () -> Void) -> SimulatorFrameLivenessMonitor {
        SimulatorFrameLivenessMonitor(queue: queue, deadline: Timing.deadline, onStall: onStall)
    }
}
