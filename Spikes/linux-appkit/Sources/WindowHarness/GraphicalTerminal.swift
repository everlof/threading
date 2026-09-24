#if os(Linux)
@testable import CoreSlice
@testable import TerminalRuntime
import Foundation
import Dispatch
import Glibc
import LinuxWindowBridge
import ThreadingPTYHostKit

/// Experimental host-only terminal surface. Threading retains store identity, process ownership,
/// input and exit truth. This is not a new extension component or a shipping theme boundary.
final class GraphicalTerminal: @unchecked Sendable {
    private static let exitWaitSeconds: Double = 5
    private static let maximumReplayBytes = 4 * 1024 * 1024
    private static let maximumAttachColumns = 128
    private static let maximumAttachRows = 40
    struct Frame: Sendable {
        let pixels: Data
        let width: Int
        let height: Int
        let title: String
        let drawMilliseconds: Double
    }
    private let worker = DispatchQueue(label: "linux.terminal", qos: .userInteractive)
    private let drawing = DispatchQueue(label: "linux.terminal.drawing", qos: .userInteractive)
    private let lock = NSLock()
    // Lock-owned publication/admission. One snapshot/render request and one published frame.
    private var pendingFrame = false
    private var pendingInputCount = 0
    private enum Input: Sendable {
        case text(Data)
        case key(PTYEmulator.Key, PTYEmulator.Modifiers, PTYEmulator.KeyAction)
    }
    private var frame: Frame?
    private var failure: String?
    private var running = false
    private var closed = false
    private var createdTerminal = false
    private var spawnMayBeLive = false
    private var finished = false
    private var initialViewport: (Int, Int)?
    // Worker-owned runtime. Every emulator operation stays off the UI actor.
    private var emulator: PTYEmulator?
    private var client: PTYHostClient?
    private var identity: PTYHostSessionIdentity?
    private var dirty = true
    private var lastWidth = 0, lastHeight = 0
    private var exitStatus: Int32?
    private var waitingForExit = false
    private var attaching = false
    private var replayRemaining: Int?
    private var replayLabel = ""
    private var attachmentViewportApplied = false

    func start(store: String, socket: String, directory: String, executable: String, arguments: [String]) {
        worker.async { [self] in
            do {
                let link = try connect(socket: socket)
                let id = try Self.createTerminal(store: store, directory: directory, executable: executable)
                identity = id
                lock.lock(); createdTerminal = true; lock.unlock()
                var environment = AgentEnvironment.removingInheritedIdentity(from: ProcessInfo.processInfo.environment)
                environment["TERM"] = "xterm-256color"
                environment["COLORTERM"] = "truecolor"
                environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
                // Once send is attempted, failure cannot prove that the daemon did not spawn.
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                try link.spawn(PTYHostSpawnRequest(id: id, channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
                    executable: executable, arguments: arguments,
                    environment: environment.map { "\($0.key)=\($0.value)" }, cwd: directory))
            } catch { fail(error) }
        }
    }
    private func connect(socket: String) throws -> PTYHostClient {
        emulator = try PTYEmulator(columns: 80, rows: 24) { [weak self] data in
            do { try self?.client?.sendInput(data) } catch { self?.fail(error) }
        }
        let link = PTYHostClient(socketPath: socket, build: "linux-native-window", events: .init(
            frame: { [weak self] frame in self?.received(frame) },
            output: { [weak self] data in self?.receiveOutput(data) },
            closed: { [weak self] error in
                guard let self else { return }
                if let error { self.fail(error) }
                else if self.exitStatus == nil { self.fail(WindowFailure("PTY connection closed")) }
            }), journal: { _, _ in }, queue: worker)
        client = link
        try link.connect()
        return link
    }
    func attach(store: String, socket: String, terminalID: String) {
        attach(store: store, socket: socket, savedID: terminalID, kind: .terminal)
    }
    func attachAgent(store: String, socket: String, sessionID: String) {
        attach(store: store, socket: socket, savedID: sessionID, kind: .agent)
    }
    private enum SavedKind { case terminal, agent }
    private func attach(store: String, socket: String, savedID: String, kind: SavedKind) {
        worker.async { [self] in
            do {
                attaching = true
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                let id = try Self.storedIdentity(store: store, savedID: savedID, kind: kind)
                identity = id
                let link = try connect(socket: socket)
                try link.attach(PTYHostAttach(id: id))
                worker.asyncAfter(deadline: .now() + Self.exitWaitSeconds) { [weak self] in
                    guard let self, self.replayRemaining != 0 else { return }
                    self.fail(WindowFailure("timed out waiting for terminal replay"))
                }
            } catch { fail(error) }
        }
    }
    private static func storedIdentity(store: String, savedID: String, kind: SavedKind) throws -> PTYHostSessionIdentity {
        guard let uuid = UUID(uuidString: savedID) else {
            throw WindowFailure(kind == .agent ? "invalid session UUID" : "invalid terminal identity")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        let projects = try database.load().state.projects
        switch kind {
        case .terminal:
            let id = TerminalID(uuid)
            guard projects.contains(where: { $0.terminals.contains(where: { $0.id == id }) }) else {
                throw WindowFailure("terminal is not in this store")
            }
            return PTYHostSessionIdentity(.projectTerminal(id))
        case .agent:
            let id = SessionID(uuid)
            guard projects.contains(where: { $0.sessions.contains(where: { $0.id == id }) }) else {
                throw WindowFailure("session is not in this store")
            }
            return .agentSession(id)
        }
    }
    private func receiveOutput(_ data: Data) {
        if attaching {
            guard let remaining = replayRemaining else { fail(WindowFailure("output before attach boundary")); return }
            let count = min(remaining, data.count)
            if count > 0 { emulator?.feed(data.prefix(count), replaying: true) }
            if count < data.count { emulator?.feed(data.dropFirst(count)) }
            replayRemaining = remaining - count
            if replayRemaining == 0 {
                lock.lock(); if !finished && !closed && failure == nil { running = true }; lock.unlock()
            }
        } else { emulator?.feed(data) }
        dirty = true
    }
    private static func createTerminal(store: String, directory: String, executable: String) throws -> PTYHostSessionIdentity {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        var state = try database.load().state
        let folder = URL(fileURLWithPath: directory).standardizedFileURL
        let index: Int
        if let found = state.projects.firstIndex(where: { $0.folderPath == folder.path }) { index = found }
        else { state.projects.append(Project(name: folder.lastPathComponent, folderURL: folder)); index = state.projects.count - 1 }
        let terminal = ProjectTerminal(id: TerminalID(), title: URL(fileURLWithPath: executable).lastPathComponent,
            customTitle: nil, currentDirectory: folder.path, branch: nil, themeID: nil,
            soundOverrides: nil, createdAt: Date())
        state.projects[index].terminals.append(terminal)
        try database.save(state)
        return PTYHostSessionIdentity(.projectTerminal(terminal.id))
    }
    private func received(_ frame: PTYHostFrame) {
        switch frame {
        case .attached(let value):
            guard attaching, value.id == identity, replayRemaining == nil else {
                fail(WindowFailure("unexpected attach identity or duplicate reply")); return
            }
            guard let count = value.replayByteCount, (0...Self.maximumReplayBytes).contains(count) else {
                fail(WindowFailure("daemon did not provide a valid replay boundary")); return
            }
            guard value.grid.cols <= Self.maximumAttachColumns, value.grid.rows <= Self.maximumAttachRows else {
                fail(WindowFailure("saved terminal grid exceeds current window bounds")); return
            }
            do { try emulator?.resize(columns: value.grid.cols, rows: value.grid.rows) }
            catch { fail(error); return }
            switch value.replay {
            case .cut: replayLabel = " [history cut]"
            case .exact: replayLabel = " [restored]"
            case .none:
                guard count == 0 else { fail(WindowFailure("nonempty replay marked as none")); return }
                replayLabel = " [no history]"
            }
            // Adopt the daemon grid by sizing the window; attachment itself never sends resize.
            lastWidth = max(320, value.grid.cols * 10)
            lastHeight = max(180, value.grid.rows * 22)
            replayRemaining = count
            lock.lock(); initialViewport = (lastWidth, lastHeight); running = count == 0; lock.unlock()
            dirty = true
        case .spawned(let value):
            guard !attaching, value.id == identity else { fail(WindowFailure("spawn identity mismatch")); return }
            lock.lock(); running = true; lock.unlock(); dirty = true
        case .exited(let value):
            guard value.id == identity else { fail(WindowFailure("exit identity mismatch")); return }
            guard !attaching || replayRemaining == 0 else { fail(WindowFailure("exit before completed replay")); return }
            exitStatus = value.signalled ? 128 + value.status : value.status
            lock.lock(); running = false; spawnMayBeLive = false; finished = true; lock.unlock(); dirty = true
        case .spawnRefused(let value):
            guard value.id == identity else { fail(WindowFailure("spawn refusal identity mismatch")); return }
            if value.reason != .alreadyExists {
                lock.lock(); spawnMayBeLive = false; lock.unlock()
            }
            fail(WindowFailure("spawn refused: \(value.reason)"))
        case .error(let value) where value.code == .sessionExited && value.detail == "input":
            // Input can cross child exit. Its refusal is not the child's exit status.
            lock.lock(); running = false; lock.unlock()
            guard exitStatus == nil, !waitingForExit else { return }
            waitingForExit = true
            worker.asyncAfter(deadline: .now() + Self.exitWaitSeconds) { [weak self] in
                guard let self, self.exitStatus == nil else { return }
                self.fail(WindowFailure("timed out waiting for child exit after input refusal"))
            }
        case .error(let value): fail(WindowFailure("PTY: \(value)"))
        default: break
        }
    }
    private func fail(_ error: Error) {
        lock.lock(); if !closed && failure == nil { failure = String(describing: error) }; lock.unlock()
    }
    func send(_ bytes: Data) {
        guard bytes.count <= 32 else { fail(WindowFailure("input event exceeds byte budget")); return }
        submit(.text(bytes))
    }
    func key(_ key: PTYEmulator.Key, modifiers: PTYEmulator.Modifiers, action: PTYEmulator.KeyAction) {
        submit(.key(key, modifiers, action))
    }
    private func submit(_ input: Input) {
        lock.lock()
        guard running && !closed && failure == nil else { lock.unlock(); return }
        // Text and functional events share one ordered worker hop. Native key repeat cannot
        // create an unbounded queue while output parsing is busy; overflow is explicit.
        guard pendingInputCount < 256 else {
            failure = "terminal input queue overflow"; lock.unlock(); return
        }
        pendingInputCount += 1
        worker.async { [self] in
            lock.lock()
            pendingInputCount -= 1
            let admitted = running && !closed && failure == nil
            lock.unlock()
            guard admitted else { return }
            switch input {
            case .text(let bytes): emulator?.input(bytes)
            case .key(let key, let modifiers, let action): emulator?.key(key, modifiers: modifiers, action: action)
            }
        }
        lock.unlock()
    }
    func stop() {
        lock.lock(); closed = true; running = false; frame = nil; lock.unlock()
        worker.async { [self] in client?.close() }
    }
    func takeFrame() throws -> Frame? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw WindowFailure(failure) }
        let value = frame; frame = nil; return value
    }
    var hasCreatedTerminal: Bool {
        lock.lock(); defer { lock.unlock() }
        return createdTerminal
    }
    var canReplace: Bool {
        lock.lock(); defer { lock.unlock() }
        return !spawnMayBeLive && (finished || failure != nil)
    }
    func takeInitialViewport() -> (Int, Int)? {
        lock.lock(); defer { lock.unlock() }
        let value = initialViewport; initialViewport = nil
        if value != nil { worker.async { [self] in attachmentViewportApplied = true } }
        return value
    }
    func invalidateFrame() {
        worker.async { [self] in dirty = true }
    }
    func requestFrame(width: Int, height: Int) {
        lock.lock()
        guard !pendingFrame && !closed else { lock.unlock(); return }
        pendingFrame = true; lock.unlock()
        worker.async { [self] in
            guard let emulator, !attaching || (replayRemaining == 0 && attachmentViewportApplied) else { finish(nil); return }
            do {
                if lastWidth != width || lastHeight != height {
                    let columns = max(2, width / 10), rows = max(1, height / 22)
                    try emulator.resize(columns: columns, rows: rows)
                    if let identity, exitStatus == nil {
                        try client?.resize(PTYHostResize(id: identity, grid: PTYHostGrid(cols: columns, rows: rows)))
                    }
                    lastWidth = width; lastHeight = height; dirty = true
                }
                guard dirty else { finish(nil); return }
                dirty = false
                let snapshot = emulator.snapshot()
                let title = (exitStatus.map { "Threading terminal - exited \($0)" }
                    ?? "Threading terminal - \(snapshot.title.isEmpty ? "running" : snapshot.title)") + replayLabel
                drawing.async { [self] in
                    do { finish(try Self.draw(snapshot, width: width, height: height, title: title)) }
                    catch { fail(error); finish(nil) }
                }
            } catch { fail(error); finish(nil) }
        }
    }
    private func finish(_ value: Frame?) {
        lock.lock(); if !closed, let value { frame = value }; pendingFrame = false; lock.unlock()
    }
    private static func draw(_ snapshot: PTYEmulator.Snapshot, width: Int, height: Int, title: String) throws -> Frame {
        let started = DispatchTime.now().uptimeNanoseconds
        var text = Data(), cells: [TWCell] = []
        cells.reserveCapacity(snapshot.cells.count)
        for cell in snapshot.cells {
            let bytes = Data(cell.text.utf8)
            guard text.count + bytes.count <= 4 * 1024 * 1024 else { throw WindowFailure("visible text budget exceeded") }
            cells.append(TWCell(offset: Int32(text.count), length: Int32(bytes.count), width: Int32(cell.width),
                foreground: cell.foregroundRGB, background: cell.backgroundRGB,
                bold: cell.attribute.style.contains(.bold) ? 1 : 0,
                underline: cell.attribute.style.contains(.underline) ? 1 : 0))
            text.append(bytes)
        }
        var pixels = Data(count: width * height * 4)
        let result = pixels.withUnsafeMutableBytes { pixels in
            text.withUnsafeBytes { text in
                cells.withUnsafeBufferPointer { cells in
                    tw_render_terminal(pixels.bindMemory(to: UInt8.self).baseAddress, Int32(width), Int32(height),
                        cells.baseAddress, Int32(snapshot.columns), Int32(snapshot.rows),
                        text.bindMemory(to: CChar.self).baseAddress, Int32(text.count),
                        Int32(snapshot.cursorColumn), Int32(snapshot.cursorRow))
                }
            }
        }
        guard result == 0 else { throw WindowFailure("terminal rasterization failed") }
        return Frame(pixels: pixels, width: width, height: height, title: title,
                     drawMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }
}
#endif
