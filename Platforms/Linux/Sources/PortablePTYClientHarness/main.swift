@testable import CoreSlice
@testable import TerminalRuntime
@testable import ThreadingPTYClient
import Dispatch
import Foundation
import ThreadingPTYHostKit
#if os(Linux)
import Glibc

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw Failure(message: message) }
}
final class Recorder: @unchecked Sendable {
    struct State {
        var output = Data()
        var attached = false
        var exit: Int32?
        var closed = false
        var error: PTYHostClientError?
        var overflow = false
        var callbackOnMain = false
    }
    private let lock = NSLock()
    private var state = State()
    private let changed = DispatchSemaphore(value: 0)
    var events: PTYHostClient.Events {
        PTYHostClient.Events(frame: { [self] frame in
            lock.lock()
            state.callbackOnMain = state.callbackOnMain || Thread.isMainThread
            if case .attached = frame { state.attached = true }
            if case .exited(let value) = frame { state.exit = value.status }
            lock.unlock(); changed.signal()
        }, output: { [self] data in
            lock.lock()
            state.callbackOnMain = state.callbackOnMain || Thread.isMainThread
            if state.output.count + data.count <= 16 * 1024 { state.output.append(data) }
            else { state.overflow = true }
            lock.unlock(); changed.signal()
        }, closed: { [self] error in
            lock.lock(); state.closed = true; state.error = error; lock.unlock(); changed.signal()
        })
    }
    func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }
    func wait(_ predicate: (State) -> Bool) throws -> State {
        let deadline = DispatchTime.now() + 5
        while true {
            let current = snapshot()
            try check(!current.overflow && !current.callbackOnMain, "unbounded output or main-thread callback")
            if predicate(current) { return current }
            try check(changed.wait(timeout: deadline) == .success, "client event deadline")
        }
    }
}

func checkInbox() throws {
    let inbox = try HostEventInbox(maximumBytes: 8, maximumEvents: 4)
    func readable() -> Bool {
        var descriptor = pollfd(fd: inbox.descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) == 1
    }
    try check(!readable(), "empty inbox should not wake poll")
    inbox.events.output(Data("out".utf8))
    inbox.events.standardError(Data("err".utf8))
    try check(readable(), "coalesced output must wake poll")
    let batch = try inbox.take()
    try check(batch.count == 2 && !readable(), "drain must consume one notification and both events")
    guard case .delivery(.output(let out, false)) = batch[0],
          case .delivery(.output(let err, true)) = batch[1] else { throw Failure(message: "stream order") }
    try check(out == Data("out".utf8) && err == Data("err".utf8), "stream bytes")
    inbox.events.output(Data(repeating: 1, count: 8))
    inbox.events.closed(nil)
    inbox.events.output(Data("ignored after close".utf8))
    try check(readable(), "new batch must rearm notification")
    let ending = try inbox.take()
    try check(ending.count == 2, "close must follow retained output exactly once")
    guard case .closed(nil) = ending[1] else { throw Failure(message: "close ordering") }

    let bytes = try HostEventInbox(maximumBytes: 8)
    bytes.events.output(Data(repeating: 0, count: 8))
    bytes.events.output(Data([1]))
    do { _ = try bytes.take(); throw Failure(message: "byte overflow accepted") }
    catch HostEventInbox.Failure.overflow { }
    let count = try HostEventInbox(maximumEvents: 2)
    for _ in 0..<100_000 { count.events.output(Data()) }
    do { _ = try count.take(); throw Failure(message: "empty-frame flood accepted") }
    catch HostEventInbox.Failure.overflow { }
    print("PASS host event inbox: ordered streams/close, poll rearm, byte bound and 100000-event flood")
}

func checkEmulator() throws {
    var replies = Data()
    let emulator = try PTYEmulator(columns: 80, rows: 24) { replies.append($0) }
    for byte in "\u{1b}[2J\u{1b}[H\u{1b}[31mA界e\u{301}\u{1b}[0m\u{1b}[3;5H\u{1b}[6n".utf8 {
        emulator.feed(Data([byte]))
    }
    let screen = emulator.snapshot()
    try check(screen.cells.count == 80 * 24, "visible grid snapshot")
    try check(screen.cells[0].text == "A" && screen.cells[1].text == "界" && screen.cells[1].width == 2
              && screen.cells[2].width == 0 && screen.cells[3].text == "e\u{301}", "Unicode cells")
    try check(screen.cursorColumn == 4 && screen.cursorRow == 2, "cursor addressing")
    try check(replies == Data("\u{1b}[3;5R".utf8), "cursor query response")
    replies.removeAll()
    for byte in "\u{1b}[6n".utf8 { emulator.feed(Data([byte]), replaying: true) }
    try check(replies.isEmpty, "fragmented historical query emitted a response")
    emulator.feed(Data("\u{1b}[6n".utf8))
    try check(replies == Data("\u{1b}[3;5R".utf8), "live replies did not resume after replay")
    try check(screen.cells[0].attribute.fg == .ansi256(code: 1), "SGR cell color")
    emulator.feed(Data("\u{1b}]4;1;rgb:12/34/56\u{7}".utf8))
    try check(emulator.snapshot().cells[0].foregroundRGB == 0x123456, "renderer observes live indexed palette")
    emulator.feed(Data("\u{1b}[?1049h\u{1b}[HALT".utf8))
    try check(emulator.snapshot().cells[0].text == "A" && emulator.snapshot().cells[1].text == "L", "alternate screen")
    emulator.feed(Data("\u{1b}[?1049l".utf8))
    try check(emulator.snapshot().cells[1].text == "界", "normal screen restored")
    try emulator.resize(columns: 100, rows: 30)
    try check(emulator.snapshot().cells.count == 3000, "resized visible grid")
    do { try emulator.resize(columns: 10000, rows: 10000); throw Failure(message: "unbounded grid") }
    catch PTYEmulator.Failure.invalidGrid { }
    print("PASS production SwiftTerm on Linux: Unicode cells, cursor query, resize and grid bound")
}

func checkKeyboard() throws {
    var sent = Data()
    let emulator = try PTYEmulator(columns: 80, rows: 24) { sent.append($0) }
    func expect(_ bytes: String) throws {
        try check(sent == Data(bytes.utf8), "functional key bytes: \(Array(sent))")
        sent.removeAll()
    }
    emulator.key(.up)
    emulator.key(.up, action: .release)
    try expect("\u{1b}[A")
    emulator.feed(Data("\u{1b}[?1h".utf8))
    emulator.key(.up)
    emulator.key(.right, modifiers: [.ctrl])
    emulator.key(.delete, action: .repeatPress)
    try expect("\u{1b}OA\u{1b}[1;5C\u{1b}[3~")
    emulator.feed(Data("\u{1b}[>3u".utf8))
    emulator.key(.tab, modifiers: [.ctrl])
    emulator.key(.tab, modifiers: [.ctrl], action: .release)
    emulator.key(.up)
    emulator.key(.up, action: .repeatPress)
    emulator.key(.up, action: .release)
    try expect("\u{1b}[9;5u\u{1b}[A\u{1b}[1;1:2A\u{1b}[1;1:3A")
    emulator.feed(Data("\u{1b}[<u".utf8))
    emulator.input(Data("a".utf8)); emulator.key(.backspace)
    emulator.input(Data("b".utf8)); emulator.key(.enter)
    try expect("a\u{7f}b\r")
    print("PASS shared keyboard encoder: live cursor mode, modifiers, kitty repeat/release and ordered text")
}

func checkScrollback() throws {
    var sent = Data()
    let emulator = try PTYEmulator(columns: 10, rows: 3) { sent.append($0) }
    for index in 0..<8 { emulator.feed(Data("R\(index)\r\n".utf8)) }
    let live = emulator.snapshot()
    try check(live.atLiveEnd && live.cursorColumn >= 0, "live viewport or cursor missing")
    try check(emulator.mouseWheel(x: 5, y: 5, steps: 1, modifiers: []), "wheel did not move into history")
    let held = emulator.snapshot()
    try check(!held.atLiveEnd && held.cursorColumn == -1, "historical viewport drew live cursor")
    try check(held.cells[1].text != live.cells[1].text, "historical viewport did not change rows")
    emulator.feed(Data("R8\r\n".utf8))
    let afterOutput = emulator.snapshot()
    try check(afterOutput.cells[1].text == held.cells[1].text && !afterOutput.atLiveEnd,
              "new output pulled a held viewport to the live end")
    try check(emulator.mouseWheel(x: 5, y: 5, steps: -8, modifiers: []), "wheel did not return to live end")
    let returned = emulator.snapshot()
    try check(returned.atLiveEnd && returned.cursorColumn >= 0,
              "cursor did not return at the live viewport")
    emulator.feed(Data("\u{1b}[?1049h".utf8))
    sent.removeAll()
    try check(!emulator.mouseWheel(x: 5, y: 5, steps: 1, modifiers: []),
              "alternate screen scrolled its own buffer")
    try check(sent == Data("\u{1b}[A".utf8), "alternate screen did not receive a cursor key")
    print("PASS Linux viewport: bounded history, held output, live cursor and alternate-screen wheel")
}

func checkSelection() throws {
    var sent = Data()
    let emulator = try PTYEmulator(columns: 20, rows: 3) { sent.append($0) }
    emulator.feed(Data("copy 界\r\nnext line".utf8))
    try check(emulator.mouseButton(x: 5, y: 5, button: 0, release: false, modifiers: []),
              "local selection did not start")
    try check(emulator.mouseMotion(x: 75, y: 5), "local drag did not move")
    try check(emulator.mouseButton(x: 75, y: 5, button: 0, release: true, modifiers: []),
              "local selection did not finish")
    let selected = emulator.snapshot()
    try check(selected.cells[0].backgroundRGB == 0x37648e && selected.cells[7].backgroundRGB != 0x37648e,
              "selected cells were not painted from the shared range")
    guard case .text(let copied) = emulator.copySelection(maximumBytes: 1024) else {
        throw Failure(message: "local selection had no copy text")
    }
    try check(copied == Data("copy 界".utf8) && sent.isEmpty, "copy text or PTY isolation differed")
    emulator.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
    sent.removeAll()
    try check(emulator.mouseButton(x: 5, y: 27, button: 0, release: false, modifiers: [.shift]),
              "Shift did not claim local selection under mouse tracking")
    _ = emulator.mouseMotion(x: 95, y: 27)
    _ = emulator.mouseButton(x: 95, y: 27, button: 0, release: true, modifiers: [])
    guard case .text(let shifted) = emulator.copySelection(maximumBytes: 1024) else {
        throw Failure(message: "Shift-selected text was missing")
    }
    try check(shifted == Data("next line".utf8) && sent.isEmpty,
              "Shift selection leaked a mouse report")
    _ = emulator.mouseButton(x: 5, y: 27, button: 0, release: false, modifiers: [])
    try check(!sent.isEmpty, "ordinary tracking click did not reach the child")
    print("PASS Linux selection: Unicode copy, visible highlight, Shift bypass and mouse authority")
}

func run() throws {
    try checkInbox()
    try checkEmulator()
    try checkWorkingDirectoryReports()
    try checkKeyboard()
    try checkScrollback()
    try checkSelection()
    guard CommandLine.arguments.count == 2 else { throw Failure(message: "usage: PortablePTYClientHarness SOCKET") }
    let socketPath = CommandLine.arguments[1]
    try checkLiveEmulation(socketPath)
    let id = PTYHostSessionIdentity.agentSession(SessionID())
    let firstEvents = Recorder()
    let first = PTYHostClient(socketPath: socketPath, build: "portable-client-fixture",
                              events: firstEvents.events, journal: { _, _ in })
    defer { first.close() }
    try first.connect()
    try first.spawn(PTYHostSpawnRequest(id: id, channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
        executable: "/usr/bin/timeout", arguments: ["15", "/bin/sh", "-c",
        "printf 'READY:%s\\n' \"$$\"; IFS= read -r value; printf 'DONE:%s:%s\\n' \"$$\" \"$value\"; exit 7"],
        environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"], cwd: "/tmp"))
    let before = try firstEvents.wait { String(decoding: $0.output, as: UTF8.self).contains("READY:") && $0.output.contains(10) }
    let ready = String(decoding: before.output, as: UTF8.self).split(separator: "\n").first(where: { $0.contains("READY:") })!
    first.close()
    _ = try firstEvents.wait { $0.closed }

    let secondEvents = Recorder()
    let second = PTYHostClient(socketPath: socketPath, build: "portable-client-fixture",
                               events: secondEvents.events, journal: { _, _ in })
    defer { second.close() }
    try second.connect()
    try second.attach(PTYHostAttach(id: id))
    _ = try secondEvents.wait { $0.attached && String(decoding: $0.output, as: UTF8.self).contains(ready) }
    try second.sendInput(Data("portable-input\n".utf8))
    try check(second.drainWrites(until: Date().addingTimeInterval(5)), "input drain")
    let after = try secondEvents.wait { $0.exit != nil }
    try check(after.exit == 7 && String(decoding: after.output, as: UTF8.self).contains(":portable-input"),
              "reattached child input and authoritative exit")
    print("PASS full production client on Linux: spawn, replay, same-child attach, input, drain and exit")

    let overflowEvents = Recorder()
    let limited = PTYHostClient(socketPath: socketPath, build: "portable-client-fixture",
                                events: overflowEvents.events, journal: { _, _ in }, maximumQueuedWriteBytes: 1)
    defer { limited.close() }
    try limited.connect()
    do {
        try limited.attach(PTYHostAttach(id: id))
        throw Failure(message: "unbounded write admitted")
    } catch PTYHostClientError.writeQueueOverflow { }
    let closed = try overflowEvents.wait { $0.closed }
    guard case .writeQueueOverflow? = closed.error else { throw Failure(message: "overflow close cause") }
    try check(limited.boundSession == nil && !limited.isReady, "overflow teardown")
    print("PASS production write admission closes and releases the binding on overflow")

    var pair: [Int32] = [-1, -1]
    try check(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0, "socketpair")
    defer { Glibc.close(pair[0]); Glibc.close(pair[1]) }
    var sendSize: Int32 = 4096
    _ = setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendSize, socklen_t(MemoryLayout<Int32>.size))
    let started = DispatchTime.now().uptimeNanoseconds
    do {
        try PTYHostSocket.writeAll(descriptor: pair[0], data: Data(repeating: 1, count: 1024 * 1024), timeout: 0.05)
        throw Failure(message: "wedged peer accepted all bytes")
    } catch PTYHostClientError.writeFailed(let code) { try check(code == ETIMEDOUT, "write deadline cause") }
    try check(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000, "write deadline was not bounded")
    let writer = try PTYHostSocketWriter(descriptor: pair[0])
    defer { writer.close() }
    _ = Glibc.close(pair[1]); pair[1] = -1
    let broken = Recorder()
    let releaseCompletion = DispatchSemaphore(value: 0)
    defer { releaseCompletion.signal() }
    writer.write(Data("closed-peer".utf8)) { error in
        broken.events.closed(.writeFailed(errno: error))
        _ = releaseCompletion.wait(timeout: .now() + 5)
    }
    let failed = try broken.wait { $0.closed }
    guard case .writeFailed(let code)? = failed.error else { throw Failure(message: "closed peer write cause") }
    try check(code == EPIPE || code == ECONNRESET, "closed peer did not refuse")
    let cancelled = Recorder()
    writer.write(Data("queued-after-error".utf8)) { error in cancelled.events.closed(.writeFailed(errno: error)) }
    writer.close()
    releaseCompletion.signal()
    let cancellation = try cancelled.wait { $0.closed }
    try check(cancellation.error == .writeFailed(errno: ECANCELED), "close did not cancel queued writes")
    print("PASS stalled write deadline, safe closed-peer error and queued-write cancellation")
}

do { try run() }
catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
#else
print("PortablePTYClientHarness currently requires Linux")
#endif
