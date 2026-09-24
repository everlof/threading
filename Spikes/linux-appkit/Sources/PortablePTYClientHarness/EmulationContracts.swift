#if os(Linux)
@testable import CoreSlice
@testable import TerminalRuntime
import Dispatch
import Foundation
import ThreadingPTYHostKit

/// Test owner: serializes every emulator operation and never parses on the UI actor.
private final class EmulatedPeer: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var emulator: PTYEmulator!
    private var client: PTYHostClient!
    private var failure: Error?
    private var status: Int32?
    private var closed = false
    private let identity: PTYHostSessionIdentity
    private var replayRemaining: Int?
    private var attaching = false

    init(socketPath: String, identity: PTYHostSessionIdentity = .agentSession(SessionID())) throws {
        self.identity = identity
        emulator = try PTYEmulator(columns: 80, rows: 24) { [weak self] bytes in
            // Called by feed/resize under this owner's lock. Client admission never invokes
            // event callbacks inline, so replies do not re-enter emulator state.
            guard let self else { return }
            do { try self.client.sendInput(bytes) } catch { self.failure = error }
        }
        client = PTYHostClient(socketPath: socketPath, build: "emulated-pty-fixture", events: .init(
            frame: { [weak self] frame in
                guard let self else { return }
                self.lock.lock()
                if case .attached(let value) = frame {
                    do {
                        try check(value.id == self.identity, "emulated attach identity")
                        guard let count = value.replayByteCount else { throw Failure(message: "missing replay boundary") }
                        try check(count >= 0 && count <= 4 * 1024 * 1024, "invalid replay boundary")
                        try self.emulator.resize(columns: value.grid.cols, rows: value.grid.rows)
                        self.replayRemaining = count
                    } catch { self.failure = error }
                }
                if case .exited(let value) = frame { self.status = value.status }
                if case .spawnRefused = frame { self.failure = Failure(message: "emulator spawn refused") }
                self.lock.unlock(); self.changed.signal()
            }, output: { [weak self] bytes in
                guard let self else { return }
                self.lock.lock()
                if self.attaching && self.replayRemaining == nil {
                    self.failure = Failure(message: "output before attach boundary")
                } else {
                    let replay = min(self.replayRemaining ?? 0, bytes.count)
                    if replay > 0 { self.emulator.feed(bytes.prefix(replay), replaying: true) }
                    if replay < bytes.count { self.emulator.feed(bytes.dropFirst(replay)) }
                    if let remaining = self.replayRemaining { self.replayRemaining = remaining - replay }
                }
                self.lock.unlock(); self.changed.signal()
            }, closed: { [weak self] error in
                guard let self else { return }
                self.lock.lock(); self.closed = true
                if let error { self.failure = error }
                self.lock.unlock(); self.changed.signal()
            }), journal: { _, _ in })
    }
    deinit { client.close() }
    func disconnect() { client.close() }
    func attach() throws {
        lock.lock(); attaching = true; lock.unlock()
        try client.connect()
        try client.attach(PTYHostAttach(id: identity))
    }
    func start() throws {
        try client.connect()
        let script = #"""
        import os, tty, fcntl, termios, struct
        tty.setraw(0)
        os.write(1, '\x1b[2J\x1b[H\x1b[31mA界e\u0301\x1b[0m\x1b[3;5H\x1b[6n'.encode())
        reply = b''
        while not reply.endswith(b'R'):
            reply += os.read(0, 1)
        assert reply == b'\x1b[3;5R', repr(reply)
        os.write(1, b'\x1b]0;Emulated PTY\x07\x1b[4;1HREADY')
        assert os.read(0, 1) == b'x'
        rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
        os.write(1, ('\x1b[5;1HDONE:%dx%d' % (rows, cols)).encode())
        raise SystemExit(7)
        """#
        try client.spawn(PTYHostSpawnRequest(id: identity, channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
            executable: "/usr/bin/timeout", arguments: ["15", "/usr/bin/python3", "-c", script],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=C.UTF-8"], cwd: "/tmp"))
    }
    func resizeAndType() throws {
        lock.lock(); defer { lock.unlock() }
        try emulator.resize(columns: 100, rows: 30)
        try client.resize(PTYHostResize(id: identity, grid: PTYHostGrid(cols: 100, rows: 30)))
        try client.sendInput(Data("x".utf8))
    }
    func wait(_ predicate: (PTYEmulator.Snapshot, Int32?) -> Bool) throws -> PTYEmulator.Snapshot {
        let deadline = DispatchTime.now() + 5
        while true {
            lock.lock()
            let screen = emulator.snapshot(), error = failure, exit = status, ended = closed
            lock.unlock()
            if let error { throw error }
            if predicate(screen, exit) { return screen }
            try check(!ended && exit == nil, "emulated child ended before expected screen")
            try check(changed.wait(timeout: deadline) == .success, "emulated screen deadline")
        }
    }
}

func checkLiveEmulation(_ socketPath: String) throws {
    let identity = PTYHostSessionIdentity.agentSession(SessionID())
    let peer = try EmulatedPeer(socketPath: socketPath, identity: identity)
    try peer.start()
    let ready = try peer.wait { screen, _ in
        screen.title == "Emulated PTY" && screen.cells[3 * screen.columns].text == "R"
    }
    try check(ready.cells[1].text == "界" && ready.cells[1].width == 2 && ready.cells[3].text == "e\u{301}",
              "live PTY Unicode cells")
    peer.disconnect()
    let rejoined = try EmulatedPeer(socketPath: socketPath, identity: identity)
    try rejoined.attach()
    let replayed = try rejoined.wait { screen, _ in screen.title == "Emulated PTY" }
    try check(replayed.cells.map(\.text) == ready.cells.map(\.text), "replayed emulator cells changed")
    // The child's next read must see x, not a second response to the replayed cursor query.
    try rejoined.resizeAndType()
    let final = try rejoined.wait { _, status in status == 7 }
    let line = final.cells[(4 * final.columns)..<(5 * final.columns)].map(\.text).joined()
    try check(final.columns == 100 && final.rows == 30 && line.hasPrefix("DONE:30x100"),
              "emulator and real PTY resize/input diverged")
    print("PASS live emulated PTY: reconnect, replay without query replies, keyboard, resize and exit 7")
}
#endif
