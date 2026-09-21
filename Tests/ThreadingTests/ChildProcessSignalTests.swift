import XCTest
import os
@testable import Threading

/// A child spawned from a libdispatch worker thread still receives the signals its supervisor
/// sends.
///
/// `posix_spawn` gives the child the calling thread's signal mask, and a dispatch worker blocks
/// every signal. Before `ChildProcessSpawn` reset the mask, `terminate()` — `SIGTERM` to the
/// child's group — reached nothing: a supervised `ssh -N` tunnel outlived every close, and bounded
/// helpers were only ever ended by their `SIGKILL` escalation.
final class ChildProcessSignalTests: XCTestCase {

    private enum Fixture {
        static let childTimeout: TimeInterval = 5
        static let sleepSeconds = "30"
    }

    func testAChildSpawnedFromADispatchWorkerEndsOnTerminate() throws {
        let spawned = XCTestExpectation(description: "spawned")
        let outcome = OSAllocatedUnfairLock<Result<SpawnedChildProcess, Error>?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.withLock { result in
                result = Result {
                    try ChildProcessSpawn.spawn(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: [Fixture.sleepSeconds],
                        environment: [:],
                        workingDirectory: nil,
                        descriptors: [
                            AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                            AgentChildProcessDefaults.standardOutputDescriptor: .nullDevice,
                            AgentChildProcessDefaults.standardErrorDescriptor: .nullDevice
                        ]
                    )
                }
            }
            spawned.fulfill()
        }
        wait(for: [spawned], timeout: Fixture.childTimeout)
        let process = try XCTUnwrap(outcome.withLock { $0 }).get()

        process.terminate()
        let deadline = Date().addingTimeInterval(Fixture.childTimeout)
        while Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.kill()
            XCTFail("SIGTERM did not reach a child spawned from a dispatch worker")
        }
    }
}
