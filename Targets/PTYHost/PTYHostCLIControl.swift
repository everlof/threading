#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Foundation
import ThreadingPTYHostKit

/// Host-only control of a held PTY. Socket ownership is the authority boundary; this does not
/// create project records, schedule work, or implement provider-specific prompt submission.
enum PTYHostCLIControl {
    private enum Limits {
        static let inputBytes = 64 * 1024
        static let detachByte: UInt8 = 0x1D // Ctrl-]
        static let returnByte: UInt8 = 0x0D
        static let pollInterval: TimeInterval = 0.05
    }

    static func run(_ invocation: PTYHostCLIInvocation, socketPath: String, build: String) -> Int32 {
        do {
            // Validate and completely read a bounded send before touching the target. An
            // oversize file or stalled producer must never deliver a partial prompt.
            let input = invocation.verb == .send ? try readInput(enter: invocation.appendEnter) : nil
            if invocation.inputEnabled && (isatty(STDIN_FILENO) != 1 || isatty(STDOUT_FILENO) != 1) {
                throw PTYHostCLIError.refused("Interactive input needs a terminal on stdin and stdout; use send for a pipe or file.")
            }
            let client = try PTYHostCLIClient.connect(socketPath: socketPath, build: build)
            defer { client.hangUp() }
            try client.greet()
            let prefix = invocation.positional[0]
            let matches = try client.list().filter { $0.id.description.lowercased().hasPrefix(prefix.lowercased()) }
            guard matches.count == 1, let session = matches.first else {
                throw PTYHostCLIError.refused(matches.isEmpty
                    ? "No held session starts with \(prefix)."
                    : "\(matches.count) sessions start with \(prefix); name more of the id.")
            }
            guard session.resolvedChannel == .pty else {
                throw PTYHostCLIError.refused("This session uses protocol pipes, not a terminal; control it through Threading.")
            }
            guard session.exit == nil else {
                throw PTYHostCLIError.refused("This session has already ended.")
            }
            let attached = try client.attach(session.id)
            if let input {
                try client.sendInput(input)
                // This round trip establishes that the daemon read the preceding input frame.
                // It does not prove the child consumed it, nor that a provider accepted a turn.
                _ = try client.list()
                FileHandle.standardError.write(Data("Sent \(input.count) bytes to the host; agent acceptance is not confirmed.\n".utf8))
                return 0
            }
            return try attach(client, attached: attached, invocation: invocation)
        } catch let error as PTYHostCLIError {
            FileHandle.standardError.write(Data((error.sentence + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("Controller failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func readInput(enter: Bool) throws -> Data {
        guard isatty(STDIN_FILENO) != 1 else {
            throw PTYHostCLIError.refused("send reads a pipe or file on stdin; use attach --input for a keyboard.")
        }
        let flags = try PTYHostCLIIO.makeNonblocking(STDIN_FILENO)
        defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + PTYHostCLIDefaults.answerTimeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: PTYHostCLIDefaults.processReadBufferBytes)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw PTYHostCLIError.refused("stdin did not finish within five seconds; no input was sent.")
            }
            var poller = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(Limits.pollInterval * 1000))
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw PTYHostCLIError.refused("Cannot read stdin; no input was sent.") }
            let count = buffer.withUnsafeMutableBytes { PTYHostPOSIX.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw PTYHostCLIError.refused("Cannot read stdin; no input was sent.") }
            if count == 0 { break }
            guard data.count + count + (enter ? 1 : 0) <= Limits.inputBytes else {
                throw PTYHostCLIError.refused("Input exceeds 64 KiB; no input was sent.")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        if enter { data.append(Limits.returnByte) }
        guard !data.isEmpty else { throw PTYHostCLIError.refused("stdin is empty; no input was sent.") }
        return data
    }

    private static func attach(
        _ client: PTYHostCLIClient, attached: PTYHostAttached, invocation: PTYHostCLIInvocation
    ) throws -> Int32 {
        // A physical terminal answers queries automatically. Displaying history would send
        // stale answers as fresh input. Skip replay without parsing terminal escape sequences.
        guard var replayRemaining = attached.replayByteCount, replayRemaining >= 0 else {
            throw PTYHostCLIError.refused("Live attachment needs a newer host that reports the replay boundary. Update the host when its sessions can be restarted.")
        }
        let signals = PTYHostCLISignals()
        defer { signals.restore() }
        let terminal = try PTYHostCLITerminal()
        defer { terminal.restore() }
        let mode = invocation.inputEnabled ? "shared input" : "read-only"
        FileHandle.standardError.write(Data("Attached (\(mode), live output only). Ctrl-] detaches; the agent keeps running.\n".utf8))
        var resizePending = invocation.resizeEnabled
        var inputBuffer = [UInt8](repeating: 0, count: PTYHostCLIDefaults.processReadBufferBytes)
        let replayDeadline = ProcessInfo.processInfo.systemUptime + PTYHostCLIDefaults.answerTimeout
        do {
            while true {
                if let signal = signals.ending { return 128 + signal }
                if signals.takeResize() && invocation.resizeEnabled { resizePending = true }
                if replayRemaining == 0 && resizePending {
                    try client.send(.resize(PTYHostResize(id: attached.id, grid: try terminal.grid())))
                    resizePending = false
                }
                if terminal.hasKeyboard {
                    let count = inputBuffer.withUnsafeMutableBytes {
                        PTYHostPOSIX.read(STDIN_FILENO, $0.baseAddress, $0.count)
                    }
                    if count == 0 { return 0 }
                    if count < 0 && errno != EAGAIN && errno != EINTR {
                        throw PTYHostCLIError.refused("The local terminal disconnected.")
                    }
                    if count > 0 {
                        let bytes = inputBuffer[0..<count]
                        let detach = bytes.firstIndex(of: Limits.detachByte)
                        if invocation.inputEnabled {
                            let input = Data(bytes.prefix(detach ?? count))
                            if !input.isEmpty { try client.sendInput(input) }
                        }
                        if detach != nil {
                            if invocation.inputEnabled { try client.drainInput() }
                            return 0
                        }
                    }
                }
                if replayRemaining > 0 && ProcessInfo.processInfo.systemUptime >= replayDeadline {
                    throw PTYHostCLIError.answerTimedOut(what: "the replay boundary")
                }
                let outcome: Int32? = try PTYHostCLIIO.withPool {
                    guard let event = try client.nextEvent(timeout: Limits.pollInterval) else { return nil }
                    if case .output(let payload) = event {
                        let skipped = min(replayRemaining, payload.count)
                        replayRemaining -= skipped
                        let live = payload.dropFirst(skipped)
                        if !live.isEmpty {
                            try PTYHostCLIIO.write(Data(live), to: STDOUT_FILENO, interrupted: { signals.ending != nil })
                        }
                    } else if case .control(.exited(let exit)) = event {
                        FileHandle.standardError.write(Data("\r\nAgent ended (\(exit.signalled ? "signal" : "status") \(exit.status)).\r\n".utf8))
                        return 0
                    }
                    return nil
                }
                if let outcome { return outcome }
            }
        } catch {
            if let signal = signals.ending { return 128 + signal }
            throw error
        }
    }
}

/// Bounded nonblocking IO for the local terminal pump. Normal reads
/// are 64 KiB; stress output can be unbounded in total without being retained in this process.
enum PTYHostCLIIO {
    static func withPool<T>(_ action: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        return try autoreleasepool(invoking: action)
        #else
        return try action()
        #endif
    }

    static func makeNonblocking(_ descriptor: Int32) throws -> Int32 {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw PTYHostCLIError.refused("Cannot configure a controller file descriptor.")
        }
        return flags
    }

    static func write(_ data: Data, to descriptor: Int32, interrupted: () -> Bool = { false }) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + PTYHostCLIDefaults.answerTimeout
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard !interrupted() else { throw PTYHostCLIError.refused("Attachment interrupted.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw PTYHostCLIError.refused("Controller output stalled for five seconds; connection closed.")
                }
                let count = PTYHostPOSIX.rawWrite(descriptor, base + offset, bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && errno == EAGAIN else { throw PTYHostCLIError.connectionClosed }
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 50)
            }
        }
    }
}

/// Saves the actual local terminal state, including descriptor flags, for every returning path.
/// No seed is fabricated on disconnect: this client has no emulator screen to hand to the host.
private final class PTYHostCLITerminal {
    private enum Screen {
        // Let an xterm-compatible terminal preserve its own common input modes. There is no
        // hand-written escape parser or invented screen snapshot in the controller.
        static let save = "\u{1b}[?1;25;1000;1002;1003;1004;1006;2004s\u{1b}[?1049h"
        static let restore = "\u{18}\u{1b}[0m\u{1b}[?1049l\u{1b}[?1;25;1000;1002;1003;1004;1006;2004r"
    }
    private var screenSaved = false
    let hasKeyboard = isatty(STDIN_FILENO) == 1
    private var saved: termios?
    private var inputFlags: Int32?
    private var outputFlags: Int32?

    init() throws {
        do {
            outputFlags = try PTYHostCLIIO.makeNonblocking(STDOUT_FILENO)
            if hasKeyboard {
                var original = termios()
                guard tcgetattr(STDIN_FILENO, &original) == 0 else {
                    throw PTYHostCLIError.refused("Cannot read the local terminal settings.")
                }
                saved = original
                var raw = original
                cfmakeraw(&raw)
                guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
                    throw PTYHostCLIError.refused("Cannot configure the local terminal.")
                }
                inputFlags = try PTYHostCLIIO.makeNonblocking(STDIN_FILENO)
            }
            if isatty(STDOUT_FILENO) == 1 {
                screenSaved = true
                try PTYHostCLIIO.write(Data(Screen.save.utf8), to: STDOUT_FILENO)
            }
        } catch { restore(); throw error }
    }

    func grid() throws -> PTYHostGrid {
        guard let size = PTYHostPOSIX.windowSize(on: STDOUT_FILENO), size.ws_col > 0, size.ws_row > 0 else {
            throw PTYHostCLIError.refused("Cannot read the local terminal size.")
        }
        return PTYHostGrid(cols: Int(size.ws_col), rows: Int(size.ws_row), xpixel: Int(size.ws_xpixel), ypixel: Int(size.ws_ypixel))
    }

    func restore() {
        if screenSaved {
            // Best effort when a terminal has disconnected. Descriptor and termios restoration
            // below must run even when these screen bytes cannot be delivered.
            _ = PTYHostPOSIX.writeAll(STDOUT_FILENO, Data(Screen.restore.utf8))
            screenSaved = false
        }
        if var original = saved { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original); saved = nil }
        if let flags = inputFlags { _ = fcntl(STDIN_FILENO, F_SETFL, flags); inputFlags = nil }
        if let flags = outputFlags { _ = fcntl(STDOUT_FILENO, F_SETFL, flags); outputFlags = nil }
    }
}

/// Dispatch handles signals away from async-signal context. The pump polls one locked scalar,
/// so an output flood cannot create an unbounded event queue or delay terminal restoration.
private final class PTYHostCLISignals: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var resized = false
    private var sources: [DispatchSourceSignal] = []
    private var restoreActions: [() -> Void] = []

    init() {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGWINCH] {
            let previous = signal(number, SIG_IGN)
            restoreActions.append { _ = signal(number, previous) }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if number == SIGWINCH { self.resized = true } else if self.received == nil { self.received = number }
                self.lock.unlock()
            }
            sources.append(source)
            source.resume()
        }
    }

    var ending: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func takeResize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = resized
        resized = false
        return result
    }

    func restore() {
        for source in sources { source.cancel() }
        for action in restoreActions { action() }
        sources.removeAll()
        restoreActions.removeAll()
    }
}
