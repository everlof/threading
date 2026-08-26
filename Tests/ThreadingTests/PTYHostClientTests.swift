import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

// MARK: - The fake daemon

/// A `threading-ptyd` that is a hundred lines of test code.
///
/// It binds a real unix socket on a per-pid scratch path and speaks the **real** codec —
/// `PTYHostFraming` in both directions, `PTYHostFrame` for control — so what these tests exercise
/// is the production wire and the production connect path, including the `poll` deadline and the
/// `hello` gate. That is the property `PTYHostFraming` was designed for: a stream socket and a
/// pure codec mean the whole link is testable with no daemon binary, no `SMAppService`, no PTY
/// and no window.
///
/// A real listener rather than a `socketpair` because the client's job starts at a *path*: a
/// socket file that is not there, and a connect the kernel refuses, are two of the degrade
/// branches, and neither exists for a descriptor handed over ready-made.
final class FakePTYHostDaemon: @unchecked Sendable {

    let socketPath: String

    private let listener: Int32
    private let acceptQueue = DispatchQueue(label: "codes.threading.tests.ptyd")
    private let lock = NSLock()
    private let onFrame: @Sendable (PTYHostWireFrame, FakePTYHostDaemon) -> Void

    private var connection: Int32 = -1
    private var decoder = PTYHostFrameDecoder()
    private var receivedStorage: [PTYHostWireFrame] = []
    private var stopsReading = false
    private var didFinishReading = false
    private var isStopped = false

    // MARK: - Initialization

    /// - Parameters:
    ///   - receiveBufferBytes: shrinks the accepted socket's receive buffer, so a fake that stops
    ///     reading fills the kernel's buffer in a few writes rather than a few thousand. Only the
    ///     write-bound test needs it.
    ///   - onFrame: called on the daemon's read thread for every complete frame the client sends.
    init(
        receiveBufferBytes: Int? = nil,
        onFrame: @escaping @Sendable (PTYHostWireFrame, FakePTYHostDaemon) -> Void
    ) throws {
        let path = FakePTYHostDaemon.scratchSocketPath()
        // The whole feature degrades rather than fails when this bound is exceeded; a *test*
        // that exceeded it would just be confusing.
        guard path.utf8.count <= PTYHostDefaults.maximumSocketPathBytes else {
            throw XCTSkip("the scratch socket path does not fit sockaddr_un on this machine")
        }
        self.socketPath = path
        self.onFrame = onFrame

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.listener = descriptor

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        FakePTYHostDaemon.write(path: path, into: &address)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }

        acceptQueue.async { [weak self] in
            self?.serve(receiveBufferBytes: receiveBufferBytes)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Sending

    func send(_ frame: PTYHostFrame) {
        guard let payload = try? JSONEncoder().encode(frame),
              let framed = try? PTYHostFraming.encode(kind: .control, payload: payload)
        else { return XCTFail("the fake daemon could not encode a control frame") }
        sendRaw(framed)
    }

    func sendOutput(_ bytes: Data) {
        guard let framed = try? PTYHostFraming.encode(kind: .output, payload: bytes) else {
            return XCTFail("the fake daemon could not frame output")
        }
        sendRaw(framed)
    }

    /// Bytes straight onto the wire, for the frames a correct encoder would refuse to make.
    func sendRaw(_ data: Data) {
        lock.lock()
        let descriptor = connection
        lock.unlock()
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    // MARK: - Observing

    var received: [PTYHostWireFrame] {
        lock.lock()
        defer { lock.unlock() }
        return receivedStorage
    }

    var receivedControl: [PTYHostFrame] {
        received
            .filter { $0.kind == .control }
            .compactMap { try? JSONDecoder().decode(PTYHostFrame.self, from: $0.payload) }
    }

    /// Stops reading without closing, so the client's writes pile up in the kernel's buffer.
    /// Called from inside `onFrame`, which runs on the read loop's own thread.
    func stopReading() {
        lock.lock()
        stopsReading = true
        lock.unlock()
    }

    /// Waits until the client shut its side down — which is what makes "and sent nothing else" a
    /// deterministic assertion rather than a sleep.
    func waitUntilReadingFinished(timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.didFinishReading
        }
    }

    func waitForFrames(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { self.received.count >= count }
    }

    func stop() {
        lock.lock()
        guard !isStopped else { return lock.unlock() }
        isStopped = true
        let open = connection
        connection = -1
        lock.unlock()

        if open >= 0 {
            _ = Darwin.shutdown(open, SHUT_RDWR)
            Darwin.close(open)
        }
        Darwin.close(listener)
        unlink(socketPath)
    }

    // MARK: - Private Methods

    private func serve(receiveBufferBytes: Int?) {
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { return }

        var enabled: Int32 = 1
        _ = setsockopt(
            accepted,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        if var bytes = receiveBufferBytes.map(Int32.init) {
            _ = setsockopt(
                accepted,
                SOL_SOCKET,
                SO_RCVBUF,
                &bytes,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        lock.lock()
        if isStopped {
            lock.unlock()
            Darwin.close(accepted)
            return
        }
        connection = accepted
        lock.unlock()

        readLoop(accepted)

        lock.lock()
        didFinishReading = true
        lock.unlock()
    }

    private func readLoop(_ descriptor: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock()
            let parked = stopsReading || isStopped
            lock.unlock()
            if parked { return }

            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }

            lock.lock()
            let outcome = decoder.accept(Data(chunk[0..<count]))
            lock.unlock()

            switch outcome {
            case .refused:
                return
            case .frames(let frames):
                for frame in frames {
                    lock.lock()
                    receivedStorage.append(frame)
                    lock.unlock()
                    onFrame(frame, self)
                }
            }
        }
    }

    private func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }

    private static func scratchSocketPath() -> String {
        let name = "ptyd-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    private static func write(path: String, into address: inout sockaddr_un) {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
    }
}

// MARK: - Recording events

/// Collects what the client delivers on its own queue, so an assertion can be made on the main
/// thread without the test having to reason about the queue it is reading from.
final class PTYHostEventRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var frameStorage: [PTYHostFrame] = []
    private var outputStorage: [Data] = []
    private var closedStorage: [PTYHostClientError?] = []
    private var sawMainQueue = false

    var events: PTYHostClient.Events {
        PTYHostClient.Events(
            frame: { [weak self] frame in self?.record { $0.frameStorage.append(frame) } },
            output: { [weak self] bytes in self?.record { $0.outputStorage.append(bytes) } },
            closed: { [weak self] error in self?.record { $0.closedStorage.append(error) } }
        )
    }

    var frames: [PTYHostFrame] { read { $0.frameStorage } }
    var output: Data { read { $0.outputStorage.reduce(into: Data()) { $0.append($1) } } }
    var outputChunks: [Data] { read { $0.outputStorage } }
    var closings: [PTYHostClientError?] { read { $0.closedStorage } }

    /// The client's whole reason for existing on its own queue: no delivery may arrive on main.
    var didDeliverOnMainQueue: Bool { read { $0.sawMainQueue } }

    func waitForFrames(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { self.frames.count >= count }
    }

    func waitForOutput(_ bytes: Int, timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { self.output.count >= bytes }
    }

    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { !self.closings.isEmpty }
    }

    private func record(_ mutation: (PTYHostEventRecorder) -> Void) {
        let onMain = Thread.isMainThread
        lock.lock()
        if onMain { sawMainQueue = true }
        mutation(self)
        lock.unlock()
    }

    private func read<Value>(_ access: (PTYHostEventRecorder) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return access(self)
    }

    private func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }
}

// MARK: - Tests

final class PTYHostClientTests: XCTestCase {

    // MARK: - Fixtures

    private var journalDirectory: URL!
    private var journal: EventLog!
    private var daemons: [FakePTYHostDaemon] = []
    private var clients: [PTYHostClient] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Never `EventLog.shared`: the bundle is hosted in the app, so the shared journal is the
        // developer's own, and a test that writes lifecycle records into it is a test writing
        // into the running app's evidence.
        journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTYHostClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        journal = EventLog(directory: journalDirectory)
    }

    override func tearDownWithError() throws {
        for client in clients { client.close() }
        clients.removeAll()
        for daemon in daemons { daemon.stop() }
        daemons.removeAll()
        if let journalDirectory { try? FileManager.default.removeItem(at: journalDirectory) }
        try super.tearDownWithError()
    }

    private func makeDaemon(
        receiveBufferBytes: Int? = nil,
        onFrame: @escaping @Sendable (PTYHostWireFrame, FakePTYHostDaemon) -> Void
    ) throws -> FakePTYHostDaemon {
        let daemon = try FakePTYHostDaemon(
            receiveBufferBytes: receiveBufferBytes,
            onFrame: onFrame
        )
        daemons.append(daemon)
        return daemon
    }

    private func makeClient(
        socketPath: String,
        events: PTYHostClient.Events,
        maximumQueuedWriteBytes: Int = PTYHostDefaults.maximumQueuedWriteBytes
    ) -> PTYHostClient {
        let client = PTYHostClient(
            socketPath: socketPath,
            build: "1.2.3 (456)",
            events: events,
            eventLog: journal,
            maximumQueuedWriteBytes: maximumQueuedWriteBytes
        )
        clients.append(client)
        return client
    }

    private static let session = PTYHostSessionIdentity.agentSession(SessionID())

    private static func hello(protocolVersion: Int, minimum: Int) -> PTYHostFrame {
        .hello(
            PTYHostHello(
                protocolVersion: protocolVersion,
                minimumSupported: minimum,
                build: "9.9.9 (999)",
                pid: 4_242
            )
        )
    }

    /// Answers a client `hello` with one this build admits.
    private static func greetingDaemon(
        also extras: @escaping @Sendable (FakePTYHostDaemon) -> Void = { _ in }
    ) -> @Sendable (PTYHostWireFrame, FakePTYHostDaemon) -> Void {
        { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload),
                  case .hello = control
            else { return }
            daemon.send(
                hello(
                    protocolVersion: PTYHostProtocol.current,
                    minimum: PTYHostProtocol.minimumSupported
                )
            )
            extras(daemon)
        }
    }

    // MARK: - The handshake

    /// The client is part of the key-to-echo UI loop even though it deliberately stays off main.
    func testTheDefaultClientQueueHasUserInteractiveQoS() {
        let client = makeClient(socketPath: "/unused", events: .ignored)

        XCTAssertEqual(client.queue.qos.qosClass, .userInteractive)
    }

    func testACompatibleHelloBecomesReadyAndRecordsTheBuildAndTheLostSet() throws {
        let lostSession = PTYHostSessionIdentity.agentSession(SessionID())
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let daemon = try makeDaemon(
            onFrame: Self.greetingDaemon { daemon in
                daemon.send(.lost(PTYHostLost(ids: [lostSession], since: since)))
            }
        )
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)

        let peer = try client.connect()

        XCTAssertTrue(client.isReady)
        XCTAssertEqual(peer.build, "9.9.9 (999)")
        XCTAssertEqual(peer.pid, 4_242)
        XCTAssertEqual(client.peerHello?.build, "9.9.9 (999)")

        XCTAssertTrue(recorder.waitForFrames(1), "the daemon's lost set must reach the client")
        XCTAssertEqual(client.reportedLoss?.ids, [lostSession])
        XCTAssertEqual(client.reportedLoss?.since, since)
        XCTAssertFalse(
            recorder.didDeliverOnMainQueue,
            "the frame pump must never deliver on the main queue"
        )

        // The client speaks first: exactly one frame, and it is `hello`.
        XCTAssertEqual(daemon.received.count, 1)
        guard case .hello(let mine)? = daemon.receivedControl.first else {
            return XCTFail("the client must open with hello")
        }
        XCTAssertEqual(mine.protocolVersion, PTYHostProtocol.current)
        XCTAssertEqual(mine.minimumSupported, PTYHostProtocol.minimumSupported)
        XCTAssertEqual(mine.build, "1.2.3 (456)")
        XCTAssertEqual(mine.pid, getpid())
    }

    func testAnOlderDaemonIsSentExactlyHelloThenRetireAndNothingElse() throws {
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control else { return }
            guard let control = try? JSONDecoder().decode(
                PTYHostFrame.self,
                from: frame.payload
            ), case .hello = control else { return }
            // Below this build's `minimumSupported`, so `evaluate` answers `peerTooOld`.
            daemon.send(Self.hello(protocolVersion: 0, minimum: 0))
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)

        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(error as? PTYHostClientError, .incompatible(.peerTooOld))
        }

        XCTAssertTrue(daemon.waitUntilReadingFinished())
        let sent = daemon.receivedControl
        XCTAssertEqual(sent.count, 2, "hello, then retire, and nothing else")
        guard case .hello = sent.first else { return XCTFail("the first frame must be hello") }
        XCTAssertEqual(sent.last, .retire)
        XCTAssertFalse(client.isReady)
        XCTAssertNil(client.boundSession)
        XCTAssertTrue(
            recorder.closings.isEmpty,
            "a connect that throws is its own report; it must not also fire closed"
        )
    }

    func testANewerDaemonIsSentNothingAfterHello() throws {
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control else { return }
            guard let control = try? JSONDecoder().decode(
                PTYHostFrame.self,
                from: frame.payload
            ), case .hello = control else { return }
            // Its minimum is above this build's `current`, so `evaluate` answers `selfTooOld`.
            daemon.send(Self.hello(protocolVersion: 99, minimum: 99))
        }
        let client = makeClient(socketPath: daemon.socketPath, events: PTYHostEventRecorder().events)

        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(error as? PTYHostClientError, .incompatible(.selfTooOld))
        }

        XCTAssertTrue(daemon.waitUntilReadingFinished())
        XCTAssertEqual(daemon.receivedControl.count, 1, "only the client's own hello")
        guard case .hello = daemon.receivedControl.first else {
            return XCTFail("the only frame must be hello")
        }
    }

    func testAHelloRefusalIsReportedFromTheAppsOwnPerspective() throws {
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control else { return }
            // The daemon evaluated *us*, so its `peerTooOld` means the app is behind.
            daemon.send(
                .helloRefused(
                    PTYHostHelloRefusal(compatibility: .peerTooOld, update: .app)
                )
            )
        }
        let client = makeClient(socketPath: daemon.socketPath, events: PTYHostEventRecorder().events)

        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(
                error as? PTYHostClientError,
                .incompatible(.selfTooOld),
                "the daemon's peerTooOld is the app's selfTooOld"
            )
        }
        XCTAssertTrue(daemon.waitUntilReadingFinished())
        XCTAssertEqual(daemon.receivedControl.count, 1)
    }

    func testConnectingWhereNothingIsListeningFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-ptyd-\(UUID().uuidString.prefix(8)).sock").path
        let client = makeClient(socketPath: missing, events: PTYHostEventRecorder().events)

        XCTAssertThrowsError(try client.connect())
        XCTAssertFalse(client.isReady)
    }

    // MARK: - Attach, replay and input

    func testAttachDeliversReplayBytesInOrderAndThenLiveOutput() throws {
        let session = Self.session
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload)
            else { return }
            switch control {
            case .hello:
                daemon.send(
                    Self.hello(
                        protocolVersion: PTYHostProtocol.current,
                        minimum: PTYHostProtocol.minimumSupported
                    )
                )
            case .attach:
                daemon.send(
                    .attached(
                        PTYHostAttached(
                            id: session,
                            pid: 909,
                            grid: PTYHostGrid(cols: 120, rows: 40, xpixel: 960, ypixel: 640),
                            replay: .exact(fromOffset: 17),
                            totalBytesWritten: 1_024
                        )
                    )
                )
                daemon.sendOutput(Data("seed".utf8))
                daemon.sendOutput(Data("ring".utf8))
                daemon.sendOutput(Data("modes".utf8))
                daemon.sendOutput(Data("live".utf8))
            default:
                break
            }
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()

        try client.attach(PTYHostAttach(id: session, replayBudget: 64 * 1024))

        XCTAssertTrue(recorder.waitForFrames(1))
        guard case .attached(let attached)? = recorder.frames.first else {
            return XCTFail("the daemon's attached frame must be delivered")
        }
        XCTAssertEqual(attached.pid, 909)
        XCTAssertEqual(attached.grid.cols, 120)
        XCTAssertEqual(attached.replay, .exact(fromOffset: 17))
        XCTAssertEqual(attached.totalBytesWritten, 1_024)

        XCTAssertTrue(recorder.waitForOutput(Data("seedringmodeslive".utf8).count))
        XCTAssertEqual(
            String(decoding: recorder.output, as: UTF8.self),
            "seedringmodeslive",
            "replay bytes then live output, in wire order"
        )
        XCTAssertEqual(client.boundSession, session)
    }

    func testInputLeavesAsAKindTwoFrameWithNoEnvelope() throws {
        let session = Self.session
        let daemon = try makeDaemon(onFrame: Self.attachingDaemon(session))
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()
        try client.attach(PTYHostAttach(id: session))
        XCTAssertTrue(recorder.waitForFrames(1))

        try client.sendInput(Data([0x1B, 0x5B, 0x41, 0x00, 0xFF]))

        XCTAssertTrue(daemon.waitForFrames(3))
        let input = try XCTUnwrap(daemon.received.last)
        XCTAssertEqual(input.kind, .input)
        XCTAssertEqual(input.payload, Data([0x1B, 0x5B, 0x41, 0x00, 0xFF]))
    }

    func testInputBeforeABindingIsRefused() throws {
        let daemon = try makeDaemon(onFrame: Self.greetingDaemon())
        let client = makeClient(socketPath: daemon.socketPath, events: PTYHostEventRecorder().events)
        try client.connect()

        XCTAssertThrowsError(try client.sendInput(Data("x".utf8))) { error in
            XCTAssertEqual(error as? PTYHostClientError, .notBound)
        }
    }

    func testASecondAttachOnABoundConnectionIsARefusalNotASecondStream() throws {
        let session = Self.session
        let other = PTYHostSessionIdentity.agentSession(SessionID())
        let daemon = try makeDaemon(onFrame: Self.attachingDaemon(session))
        let client = makeClient(socketPath: daemon.socketPath, events: PTYHostEventRecorder().events)
        try client.connect()
        try client.attach(PTYHostAttach(id: session))

        XCTAssertThrowsError(try client.attach(PTYHostAttach(id: other))) { error in
            XCTAssertEqual(error as? PTYHostClientError, .alreadyBound(session))
        }
        XCTAssertThrowsError(
            try client.resize(PTYHostResize(id: other, grid: PTYHostGrid(cols: 80, rows: 24)))
        ) { error in
            XCTAssertEqual(
                error as? PTYHostClientError,
                .sessionMismatch(bound: session, frame: other)
            )
        }
        XCTAssertEqual(client.boundSession, session)
    }

    // MARK: - Tolerance and refusal

    func testAnUnknownControlTypeIsIgnoredAndTheConnectionSurvives() throws {
        let session = Self.session
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload),
                  case .hello = control
            else { return }

            // One write is deliberate. A stream may expose all three frames in the handshake's
            // same decoded batch; returning as soon as `hello` appeared used to discard the two
            // frames that were already beside it. The unknown frame is exactly the additive
            // `foreground` push a later build may add, and only that frame should disappear.
            let unknown = Data(#"{"type":"foreground","body":{"pgid":4321}}"#.utf8)
            let exited = PTYHostFrame.exited(
                PTYHostExited(id: session, status: 0, signalled: false)
            )
            guard let helloPayload = try? JSONEncoder().encode(Self.hello(
                protocolVersion: PTYHostProtocol.current,
                minimum: PTYHostProtocol.minimumSupported
            )),
                  let unknownWire = try? PTYHostFraming.encode(
                    kind: .control,
                    payload: unknown
                  ),
                  let exitedPayload = try? JSONEncoder().encode(exited),
                  let helloWire = try? PTYHostFraming.encode(
                    kind: .control,
                    payload: helloPayload
                  ),
                  let exitedWire = try? PTYHostFraming.encode(
                    kind: .control,
                    payload: exitedPayload
                  )
            else { return XCTFail("the fake daemon could not encode its handshake batch") }

            daemon.sendRaw(helloWire + unknownWire + exitedWire)
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()

        XCTAssertTrue(recorder.waitForFrames(1), "the frame after the unknown one must arrive")
        XCTAssertEqual(
            recorder.frames,
            [.exited(PTYHostExited(id: session, status: 0, signalled: false))],
            "the unknown frame is dropped, and only it"
        )
        XCTAssertTrue(recorder.closings.isEmpty, "an unknown type must not close the connection")
        XCTAssertTrue(client.isReady)
    }

    func testAnOversizeHeaderFromTheDaemonClosesWithTheTypedRefusal() throws {
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload)
            else { return }
            switch control {
            case .hello:
                daemon.send(
                    Self.hello(
                        protocolVersion: PTYHostProtocol.current,
                        minimum: PTYHostProtocol.minimumSupported
                    )
                )
            case .list:
                // A header claiming 2 MiB, past `maximumPayloadBytes`, and not one payload byte
                // behind it: the refusal has to come from the header alone. Sent after the gate
                // so it reaches the running pump rather than the handshake.
                var header = Data([PTYHostFrameKind.output.rawValue, 0, 0, 0])
                let length = UInt32(2 * 1024 * 1024)
                header.append(UInt8(truncatingIfNeeded: length))
                header.append(UInt8(truncatingIfNeeded: length >> 8))
                header.append(UInt8(truncatingIfNeeded: length >> 16))
                header.append(UInt8(truncatingIfNeeded: length >> 24))
                daemon.sendRaw(header)
            default:
                break
            }
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()

        try client.list()

        XCTAssertTrue(recorder.waitForClose())
        XCTAssertEqual(recorder.closings.count, 1)
        XCTAssertEqual(
            recorder.closings.first ?? nil,
            .framing(.oversizePayload(length: 2 * 1024 * 1024))
        )
        XCTAssertFalse(client.isReady)
    }

    func testAnOversizeHeaderDuringTheHandshakeRefusesTheConnectItself() throws {
        let daemon = try makeDaemon { frame, daemon in
            guard frame.kind == .control else { return }
            var header = Data([PTYHostFrameKind.control.rawValue, 0, 0, 0])
            let length = UInt32(2 * 1024 * 1024)
            header.append(UInt8(truncatingIfNeeded: length))
            header.append(UInt8(truncatingIfNeeded: length >> 8))
            header.append(UInt8(truncatingIfNeeded: length >> 16))
            header.append(UInt8(truncatingIfNeeded: length >> 24))
            daemon.sendRaw(header)
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)

        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(
                error as? PTYHostClientError,
                .framing(.oversizePayload(length: 2 * 1024 * 1024))
            )
        }
        XCTAssertTrue(
            recorder.closings.isEmpty,
            "a connect that throws is its own report"
        )
    }

    func testTheWriteQueueBoundClosesTheConnectionRatherThanGrowing() throws {
        let session = Self.session
        let daemon = try makeDaemon(receiveBufferBytes: 4 * 1024) { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload),
                  case .hello = control
            else { return }
            daemon.send(
                Self.hello(
                    protocolVersion: PTYHostProtocol.current,
                    minimum: PTYHostProtocol.minimumSupported
                )
            )
            // From here the daemon is wedged: it never reads another byte, and never closes.
            daemon.stopReading()
        }
        let recorder = PTYHostEventRecorder()
        let client = makeClient(
            socketPath: daemon.socketPath,
            events: recorder.events,
            maximumQueuedWriteBytes: 64 * 1024
        )
        try client.connect()
        try client.attach(PTYHostAttach(id: session))

        var overflow: PTYHostClientError?
        let chunk = Data(repeating: 0x61, count: 8 * 1024)
        for _ in 0..<512 {
            do {
                try client.sendInput(chunk)
            } catch let error as PTYHostClientError {
                overflow = error
                break
            }
            usleep(1_000)
        }

        guard case .writeQueueOverflow(let queued)? = overflow else {
            return XCTFail("a daemon that stops reading must trip the write bound, not grow it")
        }
        XCTAssertGreaterThan(queued, 64 * 1024)
        XCTAssertTrue(recorder.waitForClose())
        XCTAssertEqual(recorder.closings.first ?? nil, overflow)
        XCTAssertFalse(client.isReady)
    }

    // MARK: - Closing

    func testCloseIsIdempotentAndReportsExactlyOnce() throws {
        let daemon = try makeDaemon(onFrame: Self.greetingDaemon())
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()

        client.close()
        client.close()
        client.close()

        XCTAssertTrue(recorder.waitForClose())
        XCTAssertEqual(recorder.closings.count, 1)
        XCTAssertNil(recorder.closings.first ?? nil, "a deliberate close carries no error")
        XCTAssertThrowsError(try client.list()) { error in
            XCTAssertEqual(error as? PTYHostClientError, .notReady)
        }
    }

    func testTheDaemonGoingAwayClosesTheClientWithNoError() throws {
        let daemon = try makeDaemon(onFrame: Self.greetingDaemon())
        let recorder = PTYHostEventRecorder()
        let client = makeClient(socketPath: daemon.socketPath, events: recorder.events)
        try client.connect()

        daemon.stop()

        XCTAssertTrue(recorder.waitForClose())
        XCTAssertEqual(recorder.closings.count, 1)
        XCTAssertNil(recorder.closings.first ?? nil)
    }

    // MARK: - Helpers

    private static func attachingDaemon(
        _ session: PTYHostSessionIdentity
    ) -> @Sendable (PTYHostWireFrame, FakePTYHostDaemon) -> Void {
        { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload)
            else { return }
            switch control {
            case .hello:
                daemon.send(
                    hello(
                        protocolVersion: PTYHostProtocol.current,
                        minimum: PTYHostProtocol.minimumSupported
                    )
                )
            case .attach:
                daemon.send(
                    .attached(
                        PTYHostAttached(
                            id: session,
                            pid: 101,
                            grid: PTYHostGrid(cols: 80, rows: 24),
                            replay: .none,
                            totalBytesWritten: 0
                        )
                    )
                )
            default:
                break
            }
        }
    }
}
