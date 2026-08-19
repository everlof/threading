import Foundation
import SwiftTerm

/// The one place SwiftTerm's mode vocabulary is named.
///
/// Everything above this line works in `RemoteTerminalModes`, which is a Foundation value the
/// transport and a future frontend can carry without linking an emulator.
extension RemoteTerminalModes {

    /// The sticky modes a live emulator is holding right now.
    init(_ terminal: Terminal) {
        self.init(
            mouseReporting: RemoteTerminalMouseReporting(terminal),
            applicationCursorKeys: terminal.applicationCursor,
            bracketedPaste: terminal.bracketedPasteMode
        )
    }
}

extension RemoteTerminalMouseReporting {

    /// The mouse contract a live emulator is holding, or `nil` when nothing tracks the mouse.
    init?(_ terminal: Terminal) {
        let tracking: Tracking
        switch terminal.mouseMode {
        case .off: return nil
        case .x10: tracking = .x10
        case .vt200: tracking = .vt200
        case .buttonEventTracking: tracking = .buttonEvent
        case .anyEvent: tracking = .anyEvent
        }

        let encoding: Encoding
        switch terminal.mouseProtocol {
        case .x10: encoding = .x10
        case .utf8: encoding = .utf8
        case .sgr: encoding = .sgr
        case .urxvt: encoding = .urxvt
        case .sgrPixel: encoding = .sgrPixel
        }
        self.init(tracking: tracking, encoding: encoding)
    }
}
