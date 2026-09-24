import Foundation
@testable import Threading

/// A mutable terminal-text fixture whose reads may run on the attachment worker.
final class TerminalScanTextBuffer: @unchecked Sendable {
    private struct State {
        var text: String
        var nextAbsoluteRow: Int
    }

    private let lock = NSLock()
    private var state: State
    private var readCursors: [Int] = []

    init(text: String, nextAbsoluteRow: Int = 0) {
        state = State(text: text, nextAbsoluteRow: nextAbsoluteRow)
    }

    var text: String {
        get { lock.withLock { state.text } }
        set { lock.withLock { state.text = newValue } }
    }

    var nextAbsoluteRow: Int {
        get { lock.withLock { state.nextAbsoluteRow } }
        set { lock.withLock { state.nextAbsoluteRow = newValue } }
    }

    var reads: [Int] { lock.withLock { readCursors } }

    func read(since: Int) -> TerminalScanRead {
        lock.withLock {
            readCursors.append(since)
            return TerminalScanRead(text: state.text, nextAbsoluteRow: state.nextAbsoluteRow)
        }
    }
}
