import Darwin
import Foundation

/// The two terminal behaviours the cross-device performance lab keeps distinct.
///
/// This is deliberately not an `AgentKind`: it lives in the test-only scenario package and
/// never becomes a provider the shipping application can launch. The labels name the behaviour
/// being stressed, not a claim that generated fixture text came from either provider.
public enum TerminalWireFixtureProvider: String, CaseIterable, Sendable {
    case codex
    case claude
}

public struct TerminalWireFixtureSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 20)
        self.rows = max(rows, 8)
    }
}

/// A responsive, token-free TUI workload for a real PTY.
///
/// Codex keeps finalized history in the terminal's normal scrollback and repairs that history
/// after a width change. Claude owns an alternate-screen viewport and consumes wheel reports to
/// move its own transcript. Those are the load-bearing differences for the iOS mirror: a single
/// static ANSI screenshot cannot exercise either resize repair or application-owned scrolling.
public struct TerminalWireFixture {
    public static let defaultHistoryLines = 2_400
    public static let maximumHistoryLines = 10_000

    public let provider: TerminalWireFixtureProvider
    public let historyLines: Int

    private var size: TerminalWireFixtureSize
    private var claudeScrollOffset = 0
    private var typedLine = Data()
    private var pendingInput = Data()
    private var turn = 0

    public init(
        provider: TerminalWireFixtureProvider,
        historyLines: Int = TerminalWireFixture.defaultHistoryLines,
        size: TerminalWireFixtureSize = .init(columns: 80, rows: 24)
    ) {
        self.provider = provider
        self.historyLines = min(max(historyLines, 1), Self.maximumHistoryLines)
        self.size = size
    }

    /// Fills the Mac's real capture ring before a phone joins, then leaves one stable prompt.
    public mutating func bootstrap() -> Data {
        switch provider {
        case .codex:
            return codexReflow(prefix: true)
        case .claude:
            // A long alternate-screen chat is a succession of complete frames rather than a
            // growing terminal scrollback. Keep enough distinct prior frames in the ring to
            // reproduce the attach workload that made old screens flash on a phone.
            var data = Data("\u{1b}]0;Claude wire stress\u{7}\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8)
            let frames = min(max(historyLines / 18, 24), 150)
            for frame in 0..<frames {
                claudeScrollOffset = min(frame * 3, maximumClaudeOffset)
                data.append(claudeFrame(status: "Hydrating recorded frame \(frame + 1)/\(frames)"))
            }
            claudeScrollOffset = 0
            data.append(claudeFrame(status: "Ready · type more, fill, or finish"))
            return data
        }
    }

    /// Responds to the real PTY grid changing. Codex repairs terminal-owned scrollback; Claude
    /// repaints only the alternate viewport it owns.
    public mutating func resize(to newSize: TerminalWireFixtureSize) -> Data? {
        guard newSize != size else { return nil }
        size = newSize
        switch provider {
        case .codex:
            return codexReflow(prefix: false)
        case .claude:
            return claudeFrame(status: "Repainted at \(size.columns)×\(size.rows)")
        }
    }

    /// Consumes exactly the raw bytes a terminal program receives. Complete line submissions
    /// generate streaming output; SGR wheel reports move only Claude's application viewport.
    public mutating func receive(_ bytes: Data) -> (outputs: [Data], shouldExit: Bool) {
        pendingInput.append(bytes)
        var outputs: [Data] = []
        var shouldExit = false

        while !pendingInput.isEmpty {
            if pendingInput.starts(with: [0x1b, 0x5b, 0x3c]) { // ESC [ <
                guard let end = pendingInput.firstIndex(where: { $0 == 0x4d || $0 == 0x6d }) else {
                    break
                }
                let report = pendingInput.prefix(through: end)
                // `Data.Index` is not a zero-based count after earlier bytes have been removed.
                // A swipe can deliver many SGR reports in one read, so using `end + 1` as the
                // removal count eventually walked past the remaining buffer and trapped the
                // fixture process. Convert the absolute index to a distance first.
                let consumed = pendingInput.distance(from: pendingInput.startIndex, to: end) + 1
                pendingInput.removeFirst(consumed)
                if provider == .claude, let direction = Self.wheelDirection(report) {
                    let delta = max(size.rows / 3, 3)
                    if direction < 0 {
                        claudeScrollOffset = min(claudeScrollOffset + delta, maximumClaudeOffset)
                    } else {
                        claudeScrollOffset = max(claudeScrollOffset - delta, 0)
                    }
                    outputs.append(claudeFrame(status: "Transcript offset \(claudeScrollOffset)"))
                }
                continue
            }

            let byte = pendingInput.removeFirst()
            if byte == 0x0d || byte == 0x0a {
                guard !typedLine.isEmpty else { continue }
                let line = String(decoding: typedLine, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                typedLine.removeAll(keepingCapacity: true)
                let result = submit(line)
                outputs.append(contentsOf: result.outputs)
                shouldExit = shouldExit || result.shouldExit
                continue
            }
            if byte == 0x08 || byte == 0x7f {
                guard !typedLine.isEmpty else { continue }
                typedLine.removeLast()
                switch provider {
                case .codex:
                    outputs.append(Data("\u{8} \u{8}".utf8))
                case .claude:
                    outputs.append(claudeFrame(status: "Editing local fixture prompt"))
                }
                continue
            }
            // Ignore control sequences the generated composer does not advertise. Printable
            // UTF-8 bytes stay byte-for-byte until Return so non-ASCII input remains valid.
            if byte == 0x1b {
                continue
            }
            if byte >= 0x20 {
                typedLine.append(byte)
                switch provider {
                case .codex:
                    outputs.append(Data([byte]))
                case .claude:
                    // Claude-shaped input is application-owned: typing dirties and repaints its
                    // viewport rather than relying on the terminal driver's canonical echo.
                    outputs.append(claudeFrame(status: "Editing local fixture prompt"))
                }
            }
        }
        return (outputs, shouldExit)
    }

    // MARK: - Codex-shaped normal scrollback

    private mutating func codexReflow(prefix: Bool) -> Data {
        var text = ""
        if prefix {
            text += "\u{1b}]0;Codex wire stress\u{7}\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1006l"
        }
        // Erase Codex-owned history before re-emitting it at the new width. This is the expensive
        // real behaviour the fixture exists to put through the Mac ring and iOS parser.
        text += "\u{1b}[3J\u{1b}[2J\u{1b}[H"
        text.reserveCapacity(historyLines * 88)
        for index in 0..<historyLines {
            text += codexHistoryLine(index)
            text += "\r\n"
        }
        text += "\u{1b}[1;36mCodex wire stress\u{1b}[0m  generated PTY fixture\r\n"
        text += "\u{1b}[2mNormal scrollback · \(size.columns)×\(size.rows) · \(historyLines) history rows\u{1b}[0m\r\n"
        text += "Type \u{1b}[1mmore\u{1b}[0m, \u{1b}[1mfill\u{1b}[0m, or \u{1b}[1mfinish\u{1b}[0m, then use ordinary terminal scrollback.\r\n"
        text += "\u{1b}[1;32m›\u{1b}[0m "
        return Data(text.utf8)
    }

    private func codexHistoryLine(_ index: Int) -> String {
        let phase = index % 6
        switch phase {
        case 0:
            return "\u{1b}[1;34m•\u{1b}[0m Inspected remote terminal pipeline checkpoint \(index)"
        case 1:
            return "  \u{1b}[2mSources/ThreadingMobile/TerminalViewRepresentable.swift:\(80 + index % 220)\u{1b}[0m"
        case 2:
            return "  Measured viewport repair, ring replay, parser feed, layout, display, and scroll"
        case 3:
            return "  \u{1b}[32m✓ deterministic check \(index) passed\u{1b}[0m"
        case 4:
            return "  A deliberately long logical line \(index) crosses the phone width so resize reflow has real wrapping work to repair."
        default:
            return ""
        }
    }

    // MARK: - Claude-shaped alternate viewport

    private var maximumClaudeOffset: Int {
        max(historyLines - max(size.rows - 6, 1), 0)
    }

    private func claudeFrame(status: String) -> Data {
        let contentRows = max(size.rows - 6, 2)
        let newestStart = max(historyLines - contentRows, 0)
        let start = max(newestStart - claudeScrollOffset, 0)
        var text = "\u{1b}[?25l\u{1b}[H\u{1b}[2J"
        text += "\u{1b}[1;35mClaude Code wire stress\u{1b}[0m  generated PTY fixture\u{1b}[K\r\n"
        text += "\u{1b}[2mAlternate viewport · \(size.columns)×\(size.rows) · \(historyLines) virtual rows\u{1b}[0m\u{1b}[K\r\n"
        for row in 0..<contentRows {
            let index = min(start + row, max(historyLines - 1, 0))
            text += claudeHistoryLine(index)
            text += "\u{1b}[K\r\n"
        }
        text += "\u{1b}[2m────────────────────────────────────────\u{1b}[0m\u{1b}[K\r\n"
        text += "\u{1b}[2m\(status) · one-finger scroll belongs to the TUI\u{1b}[0m\u{1b}[K\r\n"
        let composer = typedLine.isEmpty
            ? "Type more, fill, or finish"
            : String(decoding: typedLine, as: UTF8.self)
        text += "\u{1b}[1;35m❯\u{1b}[0m \(composer)\u{1b}[K\u{1b}[?25h"
        return Data(text.utf8)
    }

    private func claudeHistoryLine(_ index: Int) -> String {
        switch index % 5 {
        case 0: return "\u{1b}[35m●\u{1b}[0m Read(TerminalViewRepresentable.swift) · row \(index)"
        case 1: return "   ⎿ Compared the real Mac and iPhone grids"
        case 2: return "\u{1b}[35m●\u{1b}[0m Update(RemoteSessionConnection.swift)"
        case 3: return "   ⎿ Kept the replay bounded and the repaint observable"
        default: return "\u{1b}[32m✓\u{1b}[0m Verification checkpoint \(index)"
        }
    }

    // MARK: - Interaction

    private mutating func submit(_ line: String) -> (outputs: [Data], shouldExit: Bool) {
        guard line != "finish" else {
            let ending = provider == .claude
                ? Data("\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?1049lFixture complete.\r\n".utf8)
                : Data("\r\nFixture complete.\r\n".utf8)
            return ([ending], true)
        }

        turn += 1
        let count = line == "fill" ? 220 : 56
        switch provider {
        case .codex:
            var outputs = [Data("\r\n\u{1b}[1m› \(line)\u{1b}[0m\r\n".utf8)]
            outputs.reserveCapacity(count + 2)
            for index in 0..<count {
                outputs.append(Data(
                    "\u{1b}[36m•\u{1b}[0m streamed Codex fixture turn \(turn), chunk \(index + 1)/\(count) with enough text to wrap at compact widths\r\n".utf8
                ))
            }
            outputs.append(Data("\u{1b}[32m✓ turn complete\u{1b}[0m\r\n\u{1b}[1;32m›\u{1b}[0m ".utf8))
            return (outputs, false)

        case .claude:
            var outputs: [Data] = []
            outputs.reserveCapacity(min(count, 80) + 1)
            let frames = min(count, 80)
            for index in 0..<frames {
                outputs.append(claudeFrame(
                    status: "Streaming fixture turn \(turn) · frame \(index + 1)/\(frames)"
                ))
            }
            outputs.append(claudeFrame(status: "Turn \(turn) complete"))
            return (outputs, false)
        }
    }

    private static func wheelDirection(_ report: Data.SubSequence) -> Int? {
        guard let text = String(data: Data(report), encoding: .utf8),
              let marker = text.range(of: "[<") else { return nil }
        let suffix = text[marker.upperBound...]
        guard let first = suffix.split(separator: ";").first,
              let code = Int(first) else { return nil }
        if code == 64 { return -1 }
        if code == 65 { return 1 }
        return nil
    }
}

/// Runs the responsive fixture against the process's actual PTY. A short poll owns both stdin
/// and resize observation so the executable needs no unsafe signal callback and still responds
/// to SIGWINCH-driven `TIOCGWINSZ` changes within a few frames.
public enum TerminalWireFixtureRunner {
    public static func run(
        provider: TerminalWireFixtureProvider,
        historyLines: Int = TerminalWireFixture.defaultHistoryLines,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) throws -> Int32 {
        var originalMode = termios()
        let ownsTerminalMode = tcgetattr(input.fileDescriptor, &originalMode) == 0
        if ownsTerminalMode {
            var rawMode = originalMode
            cfmakeraw(&rawMode)
            guard tcsetattr(input.fileDescriptor, TCSANOW, &rawMode) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        defer {
            if ownsTerminalMode {
                var restored = originalMode
                _ = tcsetattr(input.fileDescriptor, TCSANOW, &restored)
            }
        }

        var size = terminalSize(output.fileDescriptor)
        var fixture = TerminalWireFixture(
            provider: provider,
            historyLines: historyLines,
            size: size
        )
        try output.write(contentsOf: fixture.bootstrap())

        var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let result = withUnsafeMutablePointer(to: &descriptor) {
                Darwin.poll($0, 1, 40)
            }
            if result < 0, errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            let currentSize = terminalSize(output.fileDescriptor)
            if currentSize != size {
                size = currentSize
                if let repaint = fixture.resize(to: currentSize) {
                    try output.write(contentsOf: repaint)
                }
            }

            guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { continue }
            let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
            if count == 0 { return 0 }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let response = fixture.receive(Data(buffer[0..<count]))
            for chunk in response.outputs {
                try output.write(contentsOf: chunk)
                // Keep chunks distinct at the PTY tap. The delay is short enough to produce a
                // real streaming burst without spending the scenario tape's timing budget.
                if response.outputs.count > 1 { usleep(8_000) }
            }
            if response.shouldExit { return 0 }
        }
    }

    private static func terminalSize(_ descriptor: Int32) -> TerminalWireFixtureSize {
        var value = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &value) == 0,
              value.ws_col > 0, value.ws_row > 0 else {
            return TerminalWireFixtureSize(columns: 80, rows: 24)
        }
        return TerminalWireFixtureSize(
            columns: Int(value.ws_col),
            rows: Int(value.ws_row)
        )
    }
}
