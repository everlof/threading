import XCTest
@testable import ThreadingAndroidKit

/// Opt-in: `THREADING_ANDROID_LIVE_AVD=<name>` names an already-running emulator (started the way
/// a person starts one, with the SDK's default JWT security). `scripts/android_workspace_verify.sh`
/// boots a dedicated AVD for it. The test drops a public key into the emulator's advertised
/// `jwks` directory, proves the audience-scoped token is accepted, reads the screen through both
/// the unary and the streaming path, and removes the key again.
final class LiveEmulatorControlTests: XCTestCase {
    private var record: RunningEmulatorRecord!
    private var signer: EmulatorTokenSigner!
    private var keyFile: URL?

    override func setUp() async throws {
        guard let name = ProcessInfo.processInfo.environment["THREADING_ANDROID_LIVE_AVD"] else {
            throw XCTSkip("Set THREADING_ANDROID_LIVE_AVD to a running emulator's AVD name.")
        }
        record = try XCTUnwrap(RunningEmulatorRecord.scan().first { $0.avdName == name }, "\(name) is not running")
        signer = EmulatorTokenSigner()
        let directory = try XCTUnwrap(record.jwksDirectory, "the emulator advertises no jwks directory")
        let file = directory.appendingPathComponent("\(signer.keyID).jwk")
        try signer.publicJWK().write(to: file, options: .atomic)
        keyFile = file
        let active = try XCTUnwrap(record.activeJWKFile)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try? Data(contentsOf: active), EmulatorJWKSet.contains(keyID: signer.keyID, in: data) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the emulator never activated Threading's key")
    }

    override func tearDown() {
        if let keyFile { try? FileManager.default.removeItem(at: keyFile) }
    }

    private func client() async throws -> EmulatorControlClient {
        let channel = GRPCChannel(port: try XCTUnwrap(record.grpcPort))
        try await channel.connect()
        let signer = signer!
        let tokens = Dictionary(uniqueKeysWithValues: try EmulatorControlMethod.allCases.map { method in
            (method, try signer.token(issuer: EmulatorTokenSigner.audienceScopedIssuer, methods: [method]))
        })
        return EmulatorControlClient(channel: channel) { tokens[$0] }
    }

    func testStatusScreenshotAndTwoStreamedFrames() async throws {
        let client = try await client()
        let status = try await client.status()
        XCTAssertFalse(status.version.isEmpty)
        try await client.channel.ping()

        let still = try await client.screenshot(EmulatorScreenshotRequest(format: .rgba8888, width: 540, height: 1200))
        XCTAssertGreaterThan(still.width, 0)
        XCTAssertEqual(still.pixels.count, still.width * still.height * 4)

        let frames = expectation(description: "two streamed frames")
        frames.assertForOverFulfill = false
        let counter = FrameCounter()
        let handle = client.streamScreenshots(
            EmulatorScreenshotRequest(format: .rgba8888, width: 540, height: 1200),
            onImage: { result in
                if case .success(let image) = result, !image.isEmpty, counter.increment() == 2 { frames.fulfill() }
            },
            onEnd: { _ in }
        )
        // A still screen sends one frame; a touch-free key press makes the next.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await client.pressKey("GoHome")
        await fulfillment(of: [frames], timeout: 10)
        handle.cancel()
        client.channel.close()
    }

    func testRefusesAMethodTheTokenDoesNotName() async throws {
        let channel = GRPCChannel(port: try XCTUnwrap(record.grpcPort))
        try await channel.connect()
        let token = try signer.token(issuer: EmulatorTokenSigner.audienceScopedIssuer, methods: [.getStatus])
        let client = EmulatorControlClient(channel: channel) { _ in token }
        do {
            _ = try await client.screenshot(EmulatorScreenshotRequest(format: .png))
            XCTFail("a getStatus-only token must not read the screen")
        } catch let status as GRPCStatus {
            XCTAssertTrue([.unauthenticated, .permissionDenied].contains(status.code), "\(status)")
        }
        channel.close()
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
