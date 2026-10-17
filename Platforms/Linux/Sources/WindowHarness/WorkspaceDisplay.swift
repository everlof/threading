import AppKit
import Foundation

/// SDL's bounded software workspace exchanges pixels with the native host. Keep its AppKit
/// point conversion in one place, shared by painting, input, IME and accessibility geometry.
/// Standalone drawing probes retain their original 2x fixture; the ordinary X11 app uses 1x.
@MainActor
enum WorkspaceDisplay {
    private(set) static var scale: CGFloat = 2

    static var sidebarPixels: Int { Int((SidebarDefaults.defaultWidth * scale).rounded()) }

    static func configureForApp() throws {
        let value = ProcessInfo.processInfo.environment["THREADING_LINUX_UI_SCALE"] ?? "1"
        guard let requested = Int(value), requested == 1 || requested == 2 else {
            throw WindowFailure("THREADING_LINUX_UI_SCALE must be 1 or 2")
        }
        scale = CGFloat(requested)
    }
}
