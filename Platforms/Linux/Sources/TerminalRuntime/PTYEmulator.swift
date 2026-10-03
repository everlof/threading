import Foundation
import SwiftTerm

/// Emulator adapter for graphical PTY sessions, with explicit historical-feed reply suppression. The host owns transport/lifecycle and
/// calls this only on its serial worker. No AppKit, process spawning or display-loop ownership.
final class PTYEmulator: TerminalDelegate {
    typealias Key = TerminalFunctionalKey
    typealias Modifiers = KittyKeyboardModifiers
    typealias KeyAction = KittyKeyboardEventType
    func input(_ bytes: Data) {
        terminal.terminalLock.withLock { terminal.sendUserInput(Array(bytes)[...]) }
    }
    func paste(_ bytes: Data) {
        terminal.terminalLock.withLock {
            if terminal.bracketedPasteMode {
                terminal.sendUserInput(EscapeSequences.bracketedPasteStart[...])
            }
            terminal.sendUserInput(Array(bytes)[...])
            if terminal.bracketedPasteMode {
                terminal.sendUserInput(EscapeSequences.bracketedPasteEnd[...])
            }
        }
    }
    func key(_ key: Key, modifiers: Modifiers = [], action: KeyAction = .press) {
        terminal.terminalLock.withLock {
            if let bytes = terminal.encodedFunctionalKey(key, modifiers: modifiers, eventType: action) {
                terminal.sendUserInput(bytes[...])
            }
        }
    }
    @discardableResult
    func mouseButton(x: Int, y: Int, button: Int, release: Bool, modifiers: Modifiers,
                     forceLocal: Bool = false) -> Bool {
        terminal.terminalLock.withLock {
            let mode = terminal.mouseMode
            guard (0...2).contains(button) else { return false }
            if button == 0 && selecting && release {
                let hit = clampedMouseHit(x: x, y: y)
                selection.dragExtend(row: hit.row, col: hit.column)
                selecting = false
                if !selection.hasSelectionRange { selection.selectNone() }
                return true
            }
            let local = forceLocal || mode == .off
                || (modifiers.contains(.shift) && !terminal.mouseShiftCapture)
            if button == 0 && !release && local {
                guard let hit = mouseHit(x: x, y: y) else { return false }
                selection.selectNone()
                selection.startSelection(row: hit.row, col: hit.column)
                selecting = true
                return true
            }
            guard !forceLocal, mode != .off, !local, !release || mode != .x10,
                  let hit = mouseHit(x: x, y: y) else { return false }
            let flags = terminal.encodeButton(button: button, release: release,
                shift: modifiers.contains(.shift), meta: modifiers.contains(.alt),
                control: modifiers.contains(.ctrl))
            terminal.sendEvent(buttonFlags: flags, x: hit.column, y: hit.row, pixelX: x, pixelY: y)
            return false
        }
    }
    @discardableResult
    func mouseMotion(x: Int, y: Int) -> Bool {
        terminal.terminalLock.withLock {
            guard selecting else { return false }
            let hit = clampedMouseHit(x: x, y: y)
            selection.dragExtend(row: hit.row, col: hit.column)
            return true
        }
    }
    enum CopyResult: Sendable {
        case text(Data)
        case empty
        case oversized
    }
    func copySelection(maximumBytes: Int) -> CopyResult {
        terminal.terminalLock.withLock {
            guard selection.active && selection.hasSelectionRange else { return .empty }
            let bytes = Data(selection.getSelectedText().utf8)
            guard !bytes.isEmpty else { return .empty }
            guard bytes.count <= maximumBytes else { return .oversized }
            return .text(bytes)
        }
    }
    @discardableResult
    func mouseWheel(x: Int, y: Int, steps: Int, modifiers: Modifiers,
                    forceLocal: Bool = false) -> Bool {
        terminal.terminalLock.withLock {
            guard steps != 0, let hit = mouseHit(x: x, y: y) else { return false }
            let count = min(8, abs(steps))
            let local = forceLocal || modifiers.contains(.alt)
                || (modifiers.contains(.shift) && !terminal.mouseShiftCapture)
            if !local && terminal.mouseMode != .off {
                let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false,
                    shift: modifiers.contains(.shift), meta: modifiers.contains(.alt),
                    control: modifiers.contains(.ctrl))
                for _ in 0..<count {
                    terminal.sendEvent(buttonFlags: flags, x: hit.column, y: hit.row, pixelX: x, pixelY: y)
                }
                return false
            }
            if terminal.isCurrentBufferAlternate {
                guard !local && terminal.alternateScrollMode else { return false }
                for _ in 0..<count {
                    if let bytes = terminal.encodedFunctionalKey(steps > 0 ? .up : .down) {
                        terminal.sendUserInput(bytes[...])
                    }
                }
                return false
            }
            return terminal.scrollViewport(by: (steps > 0 ? -1 : 1) * count * 3)
        }
    }
    private func mouseHit(x: Int, y: Int) -> (column: Int, row: Int)? {
        guard x >= 0, y >= 0, x < terminal.cols * 10, y < terminal.rows * 22 else { return nil }
        return (x / 10, y / 22)
    }
    private func clampedMouseHit(x: Int, y: Int) -> (column: Int, row: Int) {
        (max(0, min(terminal.cols - 1, x / 10)), max(0, min(terminal.rows - 1, y / 22)))
    }
    struct Cell: Sendable {
        let text: String
        let width: Int
        let attribute: Attribute
        let foregroundRGB: UInt32
        let backgroundRGB: UInt32
    }
    struct Snapshot: Sendable {
        let columns: Int
        let rows: Int
        let cells: [Cell]
        let cursorColumn: Int
        let cursorRow: Int
        let title: String
        let atLiveEnd: Bool
    }
    enum Failure: Error { case invalidGrid }
    private let sendBytes: (Data) -> Void
    private var title = ""
    private var terminal: Terminal!
    private var selection: SelectionService!
    private var selecting = false
    private var cursorVisible = true
    private var suppressReplies = false
    private static let maximumDirectoryBytes = 4096
    private let localHostName: String
    private var workingDirectoryUpdate: String?

    init(columns: Int, rows: Int, localHostName: String = ProcessInfo.processInfo.hostName,
         send: @escaping (Data) -> Void) throws {
        guard Self.valid(columns, rows) else { throw Failure.invalidGrid }
        self.localHostName = localHostName.lowercased()
        sendBytes = send
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: 2000))
        selection = SelectionService(terminal: terminal)
        terminal.foregroundColor = Color(red: 0xd4d4, green: 0xd4d4, blue: 0xd4d4)
        terminal.backgroundColor = Color(red: 0x1717, green: 0x1919, blue: 0x1d1d)
    }

    /// Apply the host's terminal ground and default ink without touching explicit SGR colors.
    /// The serial GraphicalTerminal worker calls this between input and snapshot requests.
    func setThemeColors(foregroundRGB: UInt32, backgroundRGB: UInt32,
                        ansiRGB: [UInt32]) {
        precondition(ansiRGB.count == 16)
        func color(_ rgb: UInt32) -> Color {
            Color(red: UInt16((rgb >> 16) & 0xff) * 257,
                  green: UInt16((rgb >> 8) & 0xff) * 257,
                  blue: UInt16(rgb & 0xff) * 257)
        }
        terminal.terminalLock.withLock {
            terminal.foregroundColor = color(foregroundRGB)
            terminal.backgroundColor = color(backgroundRGB)
            terminal.installPalette(colors: ansiRGB.map(color))
        }
    }
    private static func valid(_ columns: Int, _ rows: Int) -> Bool {
        (2...240).contains(columns) && (1...100).contains(rows)
    }
    func feed(_ bytes: Data, replaying: Bool = false) {
        terminal.terminalLock.withLock {
            suppressReplies = replaying
            defer { suppressReplies = false }
            terminal.feed(buffer: Array(bytes)[...], recordingCurrentDirectory: !replaying)
        }
    }
    /// One latest value, consumed by the host's serial worker, never a per-output write queue.
    func takeWorkingDirectoryUpdate() -> String? {
        defer { workingDirectoryUpdate = nil }
        return workingDirectoryUpdate
    }
    func hostCurrentDirectoryUpdated(source: Terminal) {
        guard !suppressReplies, let reported = source.hostCurrentDirectory,
              let path = Self.localDirectoryPath(reported, localHostName: localHostName) else { return }
        workingDirectoryUpdate = path
    }
    static func localDirectoryPath(_ raw: String, localHostName: String) -> String? {
        guard raw.utf8.prefix(maximumDirectoryBytes + 1).count <= maximumDirectoryBytes else { return nil }
        let path: String
        if raw.hasPrefix("/") { path = raw }
        else {
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "file",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            let host = (url.host ?? "").lowercased()
            guard host.isEmpty || host == "localhost" || host == localHostName.lowercased() else { return nil }
            path = url.path
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              path.utf8.count <= maximumDirectoryBytes,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return path
    }
    func resize(columns: Int, rows: Int) throws {
        guard Self.valid(columns, rows) else { throw Failure.invalidGrid }
        terminal.terminalLock.withLock { terminal.resize(cols: columns, rows: rows) }
    }
    /// Only the visible grid is copied, never the scrollback. The host requests snapshots at
    /// display cadence with one request outstanding, not once per transport chunk.
    func snapshot() -> Snapshot {
        terminal.terminalLock.withLock {
            var cells: [Cell] = []
            cells.reserveCapacity(terminal.cols * terminal.rows)
            for row in 0..<terminal.rows {
                let selected = selection.selectedColumns(inBufferRow: terminal.buffer.yDisp + row,
                                                         columns: terminal.cols)
                for column in 0..<terminal.cols {
                    let value = terminal.getCharData(col: column, row: row)!
                    let character = terminal.getCharacter(for: value)
                    let inverse = value.attribute.style.contains(.inverse)
                    let foreground = color(value.attribute.fg, foreground: true)
                    let background = color(value.attribute.bg, foreground: false)
                    let bg = inverse ? foreground : background
                    let fg = value.attribute.style.contains(.invisible) ? bg : (inverse ? background : foreground)
                    cells.append(Cell(text: character == "\0" ? " " : String(character),
                                      width: Int(value.width), attribute: value.attribute,
                                      foregroundRGB: selected?.contains(column) == true ? 0xffffff : fg,
                                      backgroundRGB: selected?.contains(column) == true ? 0x37648e : bg))
                }
            }
            let atLiveEnd = terminal.isViewportAtLiveEnd()
            return Snapshot(columns: terminal.cols, rows: terminal.rows, cells: cells,
                            cursorColumn: cursorVisible && atLiveEnd ? terminal.buffer.x : -1,
                            cursorRow: terminal.buffer.y, title: title, atLiveEnd: atLiveEnd)
        }
    }
    private func color(_ value: Attribute.Color, foreground: Bool) -> UInt32 {
        let resolved: Color
        switch value {
        case .ansi256(let code): resolved = terminal.ansiColor(at: Int(code))!
        case .trueColor(let r, let g, let b): return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        case .defaultColor: resolved = foreground ? terminal.foregroundColor : terminal.backgroundColor
        case .defaultInvertedColor: resolved = foreground ? terminal.backgroundColor : terminal.foregroundColor
        }
        return UInt32(resolved.red >> 8) << 16 | UInt32(resolved.green >> 8) << 8 | UInt32(resolved.blue >> 8)
    }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        if !suppressReplies { sendBytes(Data(data)) }
    }
    func setTerminalTitle(source: Terminal, title: String) { self.title = String(title.prefix(256)) }
}
