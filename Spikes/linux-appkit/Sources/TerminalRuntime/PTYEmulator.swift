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
    }
    enum Failure: Error { case invalidGrid }
    private let sendBytes: (Data) -> Void
    private var title = ""
    private var terminal: Terminal!
    private var cursorVisible = true
    private var suppressReplies = false

    init(columns: Int, rows: Int, send: @escaping (Data) -> Void) throws {
        guard Self.valid(columns, rows) else { throw Failure.invalidGrid }
        sendBytes = send
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: 2000))
        terminal.foregroundColor = Color(red: 0xd4d4, green: 0xd4d4, blue: 0xd4d4)
        terminal.backgroundColor = Color(red: 0x1717, green: 0x1919, blue: 0x1d1d)
    }
    private static func valid(_ columns: Int, _ rows: Int) -> Bool {
        (2...240).contains(columns) && (1...100).contains(rows)
    }
    func feed(_ bytes: Data, replaying: Bool = false) {
        terminal.terminalLock.withLock {
            suppressReplies = replaying
            defer { suppressReplies = false }
            terminal.feed(byteArray: Array(bytes))
        }
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
                for column in 0..<terminal.cols {
                    let value = terminal.getCharData(col: column, row: row)!
                    let character = terminal.getCharacter(for: value)
                    let inverse = value.attribute.style.contains(.inverse)
                    let foreground = color(value.attribute.fg, foreground: true)
                    let background = color(value.attribute.bg, foreground: false)
                    let bg = inverse ? foreground : background
                    let fg = value.attribute.style.contains(.invisible) ? bg : (inverse ? background : foreground)
                    cells.append(Cell(text: character == "\0" ? " " : String(character),
                                      width: Int(value.width), attribute: value.attribute, foregroundRGB: fg, backgroundRGB: bg))
                }
            }
            return Snapshot(columns: terminal.cols, rows: terminal.rows, cells: cells,
                            cursorColumn: cursorVisible ? terminal.buffer.x : -1, cursorRow: terminal.buffer.y, title: title)
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
