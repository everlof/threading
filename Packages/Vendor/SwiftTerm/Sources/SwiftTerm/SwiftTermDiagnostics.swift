//
//  SwiftTermDiagnostics.swift
//
//  Structured, content-free diagnostics for the embedding application.
//

import Foundation

/// A bounded diagnostic emitted by SwiftTerm without exposing terminal contents.
public struct SwiftTermDiagnosticEvent: Sendable {
    public enum Severity: Sendable {
        case debug
        case info
        case notice
        case warning
        case error
        case fault
    }

    /// Stable machine-readable codes. Values are safe to publish in a diagnostic log.
    public enum Code: String, Sendable {
        case parserUnhandledEscape = "parser.unhandled_escape"
        case parserUnhandledControlSequence = "parser.unhandled_control_sequence"
        case parserUnhandledDeviceControl = "parser.unhandled_device_control"
        case parserUnhandledOperatingSystemCommand = "parser.unhandled_operating_system_command"
        case parserUnhandledExecute = "parser.unhandled_execute"
        case parserStateError = "parser.state_error"
        case terminalUnsupportedSequence = "terminal.unsupported_sequence"
        case terminalUnsupportedSGR = "terminal.unsupported_sgr"
        case terminalScrollInvariant = "terminal.scroll_invariant"
        case terminalReverseIndexInvariant = "terminal.reverse_index_invariant"
        case terminalSendResponseTypeInvariant = "terminal.send_response_type_invariant"
        case ptyWriteQueued = "pty.write_queued"
        case ptyWriteCompleted = "pty.write_completed"
        case ptyReadCompleted = "pty.read_completed"
        case ptyWriteFailed = "pty.write_failed"
        case ptyDataDumpFailed = "pty.data_dump_failed"
        case characterSGREncodingUnsupported = "character.sgr_encoding_unsupported"
        case selectionShift = "selection.shift"
        case bufferWidthInvariant = "buffer.width_invariant"
        case bufferBoundsCorrected = "buffer.bounds_corrected"
        case bufferRecycleInvariant = "buffer.recycle_invariant"
        case bufferShiftInvariant = "buffer.shift_invariant"
        case bufferDumpFailed = "buffer.dump_failed"
        case bufferDebugDumpSuppressed = "buffer.debug_dump_suppressed"
        case uiUnhandledAction = "ui.unhandled_action"
        case uiTextInputUnsupported = "ui.text_input_unsupported"
        case uiScroll = "ui.scroll"
        case uiDirectionKeyInvariant = "ui.direction_key_invariant"
        case uiKeyboardInsertUnsupported = "ui.keyboard_insert_unsupported"
        case uiDrawingInspectionSuppressed = "ui.drawing_inspection_suppressed"
    }

    public let severity: Severity
    public let code: Code

    /// Structural integer facts only (counts, dimensions, errno, or enum discriminators).
    public let facts: [String: Int]

    /// Number of identical-code events suppressed since the previous emitted event.
    public let suppressedCount: Int
}

/// Installs a host-owned logging sink while keeping SwiftTerm independent of any logging stack.
///
/// Diagnostics deliberately have no arbitrary string field: escape sequences, terminal titles,
/// rendered lines, PTY bytes, paths, and errors may all contain credentials or user content and
/// must never cross this boundary. Each code is rate-limited process-wide so hostile terminal
/// output cannot create an unbounded logging surface.
public enum SwiftTermDiagnostics {
    public typealias Handler = @Sendable (SwiftTermDiagnosticEvent) -> Void

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var lastEmission: [SwiftTermDiagnosticEvent.Code: UInt64] = [:]
    private static var suppressedCounts: [SwiftTermDiagnosticEvent.Code: Int] = [:]
    private static let minimumIntervalNanoseconds: UInt64 = 60_000_000_000

    public static func installHandler(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        lastEmission.removeAll(keepingCapacity: true)
        suppressedCounts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public static func removeHandler() {
        lock.lock()
        handler = nil
        lastEmission.removeAll(keepingCapacity: true)
        suppressedCounts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func emit(
        _ severity: SwiftTermDiagnosticEvent.Severity,
        _ code: SwiftTermDiagnosticEvent.Code,
        facts: [String: Int] = [:]
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let installedHandler: Handler
        let suppressedCount: Int

        lock.lock()
        guard let currentHandler = handler else {
            lock.unlock()
            return
        }
        if let previous = lastEmission[code], now &- previous < minimumIntervalNanoseconds {
            suppressedCounts[code, default: 0] += 1
            lock.unlock()
            return
        }
        installedHandler = currentHandler
        suppressedCount = suppressedCounts.removeValue(forKey: code) ?? 0
        lastEmission[code] = now
        lock.unlock()

        installedHandler(SwiftTermDiagnosticEvent(
            severity: severity,
            code: code,
            facts: facts,
            suppressedCount: suppressedCount
        ))
    }
}
