import XCTest
@testable import Threading

final class PhysicalDeviceSessionPipeTests: XCTestCase {
    private let device = PhysicalDeviceID("00008140-0000000000000001")!
    private let script = """
        import os,struct,sys,time
        for line in sys.stdin:
            if line.strip() == 'block': time.sleep(30)
            if line.strip() == 'oversize':
                sys.stdout.buffer.write(struct.pack('>I', 99*1024*1024)); sys.stdout.buffer.flush()
                continue
            data = b'\\0' + str(os.getpid()).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(data))+data); sys.stdout.buffer.flush()
        """

    private func pipe() -> PhysicalDeviceSessionPipe {
        let script = script
        return PhysicalDeviceSessionPipe(lane: "preview", launch: { _, _ in
            (URL(fileURLWithPath: "/usr/bin/python3"), ["-u", "-c", script], ProcessInfo.processInfo.environment)
        })
    }

    func testRequestsReuseOneProcessAndStopInvalidatesIt() async throws {
        let pipe = pipe()
        defer { pipe.stop() }
        let first = try await pipe.request("frame", device: device)
        let second = try await pipe.request("frame", device: device)
        XCTAssertEqual(first, second)
        pipe.stop()
        let next = try await pipe.request("frame", device: device)
        XCTAssertNotEqual(first, next)
    }

    func testCancellationInterruptsBlockedReadAndNextRequestStartsFresh() async throws {
        let pipe = pipe()
        let device = device
        defer { pipe.stop() }
        let original = try await pipe.request("frame", device: device)
        let blocked = Task { try await pipe.request("block", device: device) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        blocked.cancel()
        do { _ = try await blocked.value; XCTFail("Cancelled request succeeded") } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        let next = try await pipe.request("frame", device: device)
        XCTAssertNotEqual(original, next)
    }

    func testOversizedReplyFailsBeforePayloadAllocation() async throws {
        let pipe = pipe()
        defer { pipe.stop() }
        do { _ = try await pipe.request("oversize", device: device); XCTFail("Accepted oversized frame") }
        catch { XCTAssertEqual(error as? PhysicalDeviceControlError, .outputTooLarge(operation: "session")) }
    }

    func testStoppingBlockedGenerationDoesNotInvalidateItsReplacement() async throws {
        let pipe = pipe()
        let device = device
        defer { pipe.stop() }
        _ = try await pipe.request("frame", device: device)
        let blocked = Task { try await pipe.request("block", device: device) }
        try await Task.sleep(for: .milliseconds(100))
        pipe.stop()
        let replacement = Task { try await pipe.request("frame", device: device) }
        do { _ = try await blocked.value; XCTFail("Stopped generation succeeded") } catch {}
        let pid = try await replacement.value
        let next = try await pipe.request("frame", device: device)
        XCTAssertEqual(pid, next)
    }

    func testBlockedPreviewDoesNotDelayIndependentInputLane() async throws {
        let preview = pipe()
        let input = pipe()
        let device = device
        defer { preview.stop(); input.stop() }
        let blocked = Task { try await preview.request("block", device: device) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        _ = try await input.request("ready", device: device)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        blocked.cancel()
        _ = try? await blocked.value
    }

    func testTouchCoordinatesAreBoundedAndPhasesCannotInjectCommands() throws {
        XCTAssertEqual(try PhysicalDeviceSessionPipe.touchCommand("down", x: 0.5, y: 1), "down 32768 65535")
        XCTAssertThrowsError(try PhysicalDeviceSessionPipe.touchCommand("up\nframe", x: 0, y: 0))
        XCTAssertThrowsError(try PhysicalDeviceSessionPipe.touchCommand("move", x: .nan, y: 0))
        XCTAssertThrowsError(try PhysicalDeviceSessionPipe.touchCommand("move", x: 0, y: 1.01))
    }

    func testKeyboardTextMapsToBoundedHIDUsagesWithoutCrossingAsText() throws {
        XCTAssertEqual(
            try PhysicalDeviceKeyboard.inputs(for: "aA1! \t\r\u{8}"),
            [
                .key(usage: 0x04, shift: false),
                .key(usage: 0x04, shift: true),
                .key(usage: 0x1E, shift: false),
                .key(usage: 0x1E, shift: true),
                .key(usage: 0x2C, shift: false),
                .key(usage: 0x2B, shift: false),
                .key(usage: 0x28, shift: false),
                .key(usage: 0x2A, shift: false),
            ]
        )
        XCTAssertThrowsError(try PhysicalDeviceKeyboard.inputs(for: "å"))
    }
}
