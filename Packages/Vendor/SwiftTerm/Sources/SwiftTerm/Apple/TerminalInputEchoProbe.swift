#if os(iOS) || os(visionOS)
import Foundation
import QuartzCore

/// One transient expected-cell observation. No text or cell coordinates leave this object.
/// A match is evidence of an echo-shaped cell transition, not proof of application causality.
final class TerminalInputEchoProbe: Sendable {
    struct Pending: Sendable {
        let column: Int
        let absoluteRow: Int
        let columns: Int
        let alternate: Bool
        let ascii: UInt8
        let parsed: @Sendable (TimeInterval) -> Void
        let completion: @Sendable (TimeInterval, TimeInterval) -> Void
        var parsedAt: TimeInterval?
        var sent = false
    }

    private let pending = Locked<Pending?>(nil)

    func arm(terminal: Terminal, ascii: UInt8,
             parsed: @escaping @Sendable (TimeInterval) -> Void,
             completion: @escaping @Sendable (TimeInterval, TimeInterval) -> Void) -> Bool {
        terminal.terminalLock.preconditionLocked()
        let buffer = terminal.buffer
        let row = buffer.yBase + buffer.y
        // Exclude controls, spaces, wrapping, scrollback, and cells already showing the key.
        guard ascii > 0x20, ascii < 0x7f, buffer.x >= 0,
              buffer.x < terminal.cols - 1, buffer.yDisp == buffer.yBase,
              row >= 0, row < buffer.lines.count,
              buffer.lines[row].packedCode(at: buffer.x) != Int32(ascii) else { return false }
        return pending.withLock { value in
            guard value == nil else { return false }
            value = Pending(column: buffer.x,
                            absoluteRow: row + buffer.totalLinesTrimmed,
                            columns: terminal.cols,
                            alternate: terminal.isCurrentBufferAlternate,
                            ascii: ascii, parsed: parsed, completion: completion)
            return true
        }
    }

    func cancel() { pending.withLock { $0 = nil } }

    func sent() { pending.withLock { $0?.sent = true } }

    func parsed(terminal: Terminal) {
        terminal.terminalLock.preconditionLocked()
        let matched = pending.withLock { value -> Pending? in
            guard let sample = value, sample.sent, sample.parsedAt == nil,
                  sample.columns == terminal.cols,
                  sample.alternate == terminal.isCurrentBufferAlternate else { return nil }
            let row = sample.absoluteRow - terminal.buffer.totalLinesTrimmed
            guard row >= 0, row < terminal.buffer.lines.count,
                  terminal.buffer.lines[row].packedCode(at: sample.column) == Int32(sample.ascii)
            else { return nil }
            value?.parsedAt = CACurrentMediaTime()
            return value
        }
        if let matched, let parsedAt = matched.parsedAt { matched.parsed(parsedAt) }
    }

    /// Called after the Core Graphics pass, against the exact snapshot that pass painted.
    func drawn(snapshot: TerminalSnapshot, dirtyRect: CGRect, visibleRect: CGRect,
               cellWidth: CGFloat, cellHeight: CGFloat) {
        let completed = pending.withLock { value -> Pending? in
            guard let sample = value, sample.parsedAt != nil,
                  sample.columns == snapshot.cols, sample.alternate == snapshot.isAltBuffer
            else { return nil }
            let row = sample.absoluteRow - snapshot.totalLinesTrimmed
            let rect = CGRect(x: CGFloat(sample.column) * cellWidth,
                              y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
            guard visibleRect.contains(rect), dirtyRect.contains(rect),
                  let line = snapshot.row(atAbsolute: row), line.bidiLayout == nil,
                  line.line.renderMode == .single,
                  sample.column < line.line.count else { return nil }
            let cell = line.line.packedView(at: sample.column)
            guard cell.code == Int32(sample.ascii), cell.width == 1,
                  !cell.attribute.style.contains(.invisible),
                  !cell.attribute.style.contains(.blink), line.images.isEmpty,
                  !snapshot.hasAnyImages else { return nil }
            value = nil
            return sample
        }
        if let completed, let parsedAt = completed.parsedAt {
            completed.completion(parsedAt, CACurrentMediaTime())
        }
    }
}

extension TerminalView {
    /// Watches one printable ASCII echo at the current cursor, through an actual CG draw.
    /// The callback carries monotonic seconds (CACurrentMediaTime), never terminal content.
    /// Returns false for unsupported inputs/renderers. The host owns sampling and timeout.
    /// Callbacks may run under parser/render locks: enqueue work, never reenter the view.
    public func beginInputEchoObservation(
        ascii: UInt8,
        parsed: @escaping @Sendable (TimeInterval) -> Void,
        completion: @escaping @Sendable (_ parsedAt: TimeInterval, _ drawnAt: TimeInterval) -> Void
    ) -> Bool {
        guard !isUsingMetalRenderer else { return false }
        return withTerminal { terminal in
            renderOwner.inputEchoProbe.arm(terminal: terminal, ascii: ascii, parsed: parsed, completion: completion)
        }
    }

    public func markInputEchoObservationSent() { renderOwner.inputEchoProbe.sent() }

    public func cancelInputEchoObservation() { renderOwner.inputEchoProbe.cancel() }
}
#endif
