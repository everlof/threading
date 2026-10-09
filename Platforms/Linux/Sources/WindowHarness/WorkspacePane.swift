#if os(Linux)
import LinuxWindowBridge

/// Surface-neutral workspace ownership. Header chrome is shared; each pane owns its input.
@MainActor
protocol WorkspacePane: AnyObject {
    var chrome: WorkspacePaneChrome { get }
    var title: String { get }
    var needsPolling: Bool { get }
    func takeInitialViewport() -> (Int, Int)?
    func focus(_ focused: Bool, window: OpaquePointer)
    func setThemeAppearance()
    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int, focused: Bool) throws
    func handle(_ event: TWEvent, window: OpaquePointer)
}
#endif
