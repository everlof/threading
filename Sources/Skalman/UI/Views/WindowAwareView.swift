import AppKit

/// A view that reports when it joins or leaves a window.
///
/// The display pane parents a hosted controller's *view* without adopting the controller, so
/// `viewDidAppear` / `viewDidDisappear` never fire for a tab. The view's own move-to-window is
/// the reliable signal for "this surface is on screen", which is what any watching, polling or
/// re-reading should be gated on — a tab nobody is looking at should cost nothing.
final class WindowAwareView: NSView {

    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
