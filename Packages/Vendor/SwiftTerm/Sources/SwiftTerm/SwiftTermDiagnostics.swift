//
//  SwiftTermDiagnostics.swift
//
//  Structured, content-free diagnostics for the embedding application.
//

import Foundation

/// A bounded diagnostic emitted by SwiftTerm without exposing terminal contents.
public struct SwiftTermDiagnosticEvent: Sendable {
    public enum Severity: Sendable {
        case debug, info, notice, warning, error, fault
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
/// Events deliberately cannot carry terminal content and are rate-limited by code process-wide.
public enum SwiftTermDiagnostics {
    public typealias Handler = @Sendable (SwiftTermDiagnosticEvent) -> Void

    private struct State: Sendable {
        var handler: Handler?
        var lastEmission: [SwiftTermDiagnosticEvent.Code: UInt64] = [:]
        var suppressedCounts: [SwiftTermDiagnosticEvent.Code: Int] = [:]
    }

    private static let state = Locked(State())
    private static let minimumIntervalNanoseconds: UInt64 = 60_000_000_000

    public static func installHandler(_ newHandler: @escaping Handler) {
        state.withLock { state in
            state.handler = newHandler
            state.lastEmission.removeAll(keepingCapacity: true)
            state.suppressedCounts.removeAll(keepingCapacity: true)
        }
    }

    public static func removeHandler() {
        state.withLock { state in
            state.handler = nil
            state.lastEmission.removeAll(keepingCapacity: true)
            state.suppressedCounts.removeAll(keepingCapacity: true)
        }
    }

    static func emit(
        _ severity: SwiftTermDiagnosticEvent.Severity,
        _ code: SwiftTermDiagnosticEvent.Code,
        facts: [String: Int] = [:]
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let emission = state.withLock { state
            -> (handler: Handler, suppressedCount: Int)? in
            guard let handler = state.handler else { return nil }
            if let previous = state.lastEmission[code],
               now &- previous < minimumIntervalNanoseconds {
                state.suppressedCounts[code, default: 0] += 1
                return nil
            }
            let suppressedCount = state.suppressedCounts.removeValue(forKey: code) ?? 0
            state.lastEmission[code] = now
            return (handler, suppressedCount)
        }
        guard let emission else { return }

        emission.handler(SwiftTermDiagnosticEvent(
            severity: severity,
            code: code,
            facts: facts,
            suppressedCount: emission.suppressedCount))
    }
}
