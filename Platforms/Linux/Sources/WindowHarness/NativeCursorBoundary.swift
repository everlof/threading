#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge

/// Connects production pointer claims to SDL for the lifetime of the native shell.
@MainActor
enum NativeCursorBoundary {
    static func install(for window: OpaquePointer) {
        var reportedFailure = false
        NSCursor.platformUpdate = { kind in
            let nativeKind: TWCursorKind
            switch kind {
            case .arrow: nativeKind = TW_CURSOR_ARROW
            case .pointingHand: nativeKind = TW_CURSOR_HAND
            case .crosshair: nativeKind = TW_CURSOR_CROSSHAIR
            case .resizeLeftRight: nativeKind = TW_CURSOR_RESIZE_HORIZONTAL
            case .resizeUpDown: nativeKind = TW_CURSOR_RESIZE_VERTICAL
            case .iBeam: nativeKind = TW_CURSOR_IBEAM
            }
            if tw_set_cursor(window, Int32(nativeKind.rawValue)) != 0, !reportedFailure {
                reportedFailure = true
                FileHandle.standardError.write(Data("Native cursor unavailable: \(String(cString: tw_error()))\n".utf8))
            }
        }
        NSCursor.arrow.set()
    }

    static func uninstall() {
        NSCursor.platformUpdate = nil
    }
}
#endif
