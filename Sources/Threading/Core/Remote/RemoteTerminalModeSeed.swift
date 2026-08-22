import Foundation

/// States the sticky modes of a mirrored terminal to a client that joins mid-session.
///
/// `RemoteScreenSeed` reproduces the *picture* a running terminal is showing. It cannot reproduce
/// the *modes* the program set, and those are what decide how the client behaves: whether a tap
/// is a click, whether an arrow is SS3 or CSI, whether keys report releases, whether a paste is
/// delimited. A full-screen program arms them once, with private-mode sequences it emits at
/// startup, and every renderer that saw them follows from then on. A phone attaching an hour
/// later sees only the ring, whose
/// 512 KB window rolled those sequences away long ago — so its emulator sat at
/// `mouseMode == .off` and swallowed every tap, which is why "click to go to bottom" answered the
/// Mac and nothing on the phone.
///
/// The statement is authoritative rather than additive: it turns every tracking mode and every
/// encoding off before setting the ones in force. A mirror is replayed history, and history holds
/// modes that are no longer true — an agent that has since exited to a shell would otherwise
/// leave the phone reporting clicks into a bash prompt as pasted escape text.
///
/// A pure function over a value, so the byte stream is unit-tested directly.
enum RemoteTerminalModeSeed {

    // MARK: - Constants

    /// The private modes that arm tracking. Reset before use, then exactly one is set.
    private enum Tracking {
        static let x10 = 9
        static let vt200 = 1_000
        static let buttonEvent = 1_002
        static let anyEvent = 1_003

        static let all = [x10, vt200, buttonEvent, anyEvent]
    }

    /// The private modes that choose how a report is written. x10 is the encoding a terminal
    /// holds when none of these is set, so it is expressed by resetting the others.
    private enum Encoding {
        static let utf8 = 1_005
        static let sgr = 1_006
        static let urxvt = 1_015
        static let sgrPixel = 1_016

        static let all = [utf8, sgr, urxvt, sgrPixel]
    }

    /// CAN. Aborts a control sequence the client is part-way through parsing and returns it to
    /// ground, which is what makes this statement readable after a ring snapshot: the ring is a
    /// window over raw bytes and can end anywhere, including inside an escape sequence, and a
    /// statement swallowed by one is silently the bug it exists to fix.
    private static let cancelPendingSequence = "\u{18}"

    /// The modes that are simply on or off.
    private enum Switched {
        static let applicationCursorKeys = 1
        static let bracketedPaste = 2_004
    }

    // MARK: - Public Methods

    /// The private-mode statement for `modes`, ready to be replayed into a client.
    static func bytes(for modes: RemoteTerminalModes) -> Data {
        var out = cancelPendingSequence
        // Tracking first: resetting an encoding also stops tracking on a terminal that couples
        // them — SwiftTerm is one — so the resets have to be finished before anything is set.
        for mode in Tracking.all { out += reset(mode) }
        for mode in Encoding.all { out += reset(mode) }

        if let reporting = modes.mouseReporting {
            if let encoding = privateMode(for: reporting.encoding) {
                out += set(encoding)
            }
            out += set(privateMode(for: reporting.tracking))
        }

        out += statement(Switched.applicationCursorKeys, on: modes.applicationCursorKeys)
        out += statement(Switched.bracketedPaste, on: modes.bracketedPaste)
        // Mode 1 replaces the kitty flags rather than adding to them. Zero matters: replayed
        // history may have armed enhanced reporting for a program that has since exited.
        out += "\u{1b}[=\(modes.keyboardEnhancementFlags);1u"
        return Data(out.utf8)
    }

    // MARK: - Private Methods

    private static func statement(_ mode: Int, on: Bool) -> String {
        on ? set(mode) : reset(mode)
    }

    private static func set(_ mode: Int) -> String { "\u{1b}[?\(mode)h" }

    private static func reset(_ mode: Int) -> String { "\u{1b}[?\(mode)l" }

    private static func privateMode(for tracking: RemoteTerminalMouseReporting.Tracking) -> Int {
        switch tracking {
        case .x10: return Tracking.x10
        case .vt200: return Tracking.vt200
        case .buttonEvent: return Tracking.buttonEvent
        case .anyEvent: return Tracking.anyEvent
        }
    }

    /// `nil` for x10, which the resets above already selected.
    private static func privateMode(for encoding: RemoteTerminalMouseReporting.Encoding) -> Int? {
        switch encoding {
        case .x10: return nil
        case .utf8: return Encoding.utf8
        case .sgr: return Encoding.sgr
        case .urxvt: return Encoding.urxvt
        case .sgrPixel: return Encoding.sgrPixel
        }
    }
}
